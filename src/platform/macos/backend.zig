//! macOS backend: a borderless AppKit window (window.m, reached through the
//! plain-C zofi_macos.h) showing frames rendered by `core.render` at the
//! display's backing scale, with AppKit key events translated into
//! `core.state.KeyEvent`s. Same `run` contract as the Wayland backend, so
//! main.zig drives either one identically.
//!
//! Windows mode lists running apps rather than individual windows: listing
//! other apps' windows needs the Screen Recording permission, and raising
//! a specific one needs Accessibility, while activating an app needs
//! neither.
const std = @import("std");
const Io = std.Io;
const core = @import("core");
const z2d = @import("z2d");

pub const c = @cImport({
    @cInclude("zofi_macos.h");
});

pub const LauncherMode = core.mode.LauncherMode;

/// Runs the launcher. On accept, returns the chosen entry (still owned by
/// the caller-supplied `entries` slice); on cancel/close, returns `null`.
pub const RunOptions = struct {
    debug: bool = false,
    /// Non-null enables Tab/Shift+Tab mode switching; see `App.mode`.
    mode: ?LauncherMode = null,
    environ: ?*const std.process.Environ.Map = null,
    terminal_cmd: []const u8 = "",
};

const App = struct {
    allocator: std.mem.Allocator,
    io: Io,
    /// Null only while `zofi_mac_window_create` is still running, which can
    /// already fire `onRescale` as the view attaches to its window.
    window: ?*c.ZofiMacWindow = null,

    theme: core.theme.Theme,
    state: core.state.State,
    accepted: ?core.state.Entry = null,

    /// Set from `ZOFI_DEBUG` in the environment. See `dbg`.
    debug: bool = false,

    /// Non-null enables Tab/Shift+Tab mode switching (Apps/Run/Windows).
    /// Null for dmenu, which has a single fixed entry list and no tabs.
    mode: ?LauncherMode = null,
    environ: ?*const std.process.Environ.Map = null,
    terminal_cmd: []const u8 = "",

    /// Parallel to `state.entries` only while `mode == .windows`: pid to
    /// activate for each entry index, since `Entry` itself is backend-
    /// agnostic.
    window_pids: []const i32 = &.{},

    /// Lazily-populated real-icon lookup for Apps/Windows rows; null when
    /// there's no environ to search with (dmenu).
    icon_cache: ?core.icon.Cache = null,

    /// Lazily-populated content/decode cache for the clipboard tab's
    /// preview pane; only touched while `mode == .clipboard`.
    clipboard_preview: core.clipboard.PreviewCache = .{},

    /// Frame buffer in device pixels (logical size x backing scale),
    /// reallocated whenever that pixel size changes.
    pixels: []z2d.pixel.ARGB = &.{},
    px_width: i32 = 0,
    px_height: i32 = 0,
};

/// Logs to stderr when `ZOFI_DEBUG` is set. No-op (and the `args`
/// formatting is skipped) otherwise.
fn dbg(app: *const App, comptime fmt: []const u8, args: anytype) void {
    if (!app.debug) return;
    std.debug.print(fmt ++ "\n", args);
}

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    theme: core.theme.Theme,
    entries: []const core.state.Entry,
    options: RunOptions,
) !?core.state.Entry {
    var app: App = .{
        .allocator = allocator,
        .io = io,
        .theme = theme,
        .state = try core.state.State.init(allocator, entries),
        .debug = options.debug,
        .mode = options.mode,
        .environ = options.environ,
        .terminal_cmd = options.terminal_cmd,
    };
    defer app.state.deinit();
    defer allocator.free(app.pixels);
    if (options.environ) |environ| {
        app.icon_cache = core.icon.Cache.init(allocator, io, environ) catch null;
    }
    // State's scroll/paging math and render()'s row count must agree on the
    // same page size.
    app.state.visible_rows = app.theme.visibleRows();
    app.state.browser = app.theme.browser_cmd;

    if (options.mode == .windows) {
        try replaceEntries(&app, try buildWindowEntries(&app));
    }

    const callbacks: c.ZofiMacCallbacks = .{
        .ctx = &app,
        .key = onKey,
        .rescale = onRescale,
        .close = onClose,
    };
    const sz = core.render.size(&app.theme);
    const window = c.zofi_mac_window_create(sz.width, sz.height, &callbacks) orelse return error.NoWindow;
    app.window = window;
    defer c.zofi_mac_window_destroy(window);

    try present(&app);
    c.zofi_mac_window_show(window);
    c.zofi_mac_window_run(window);

    return app.accepted;
}

fn present(app: *App) !void {
    const window = app.window orelse return;
    const scale = @max(1.0, c.zofi_mac_window_scale(window));
    const sz = core.render.size(&app.theme);
    const w: i32 = @intFromFloat(@round(sz.width * scale));
    const h: i32 = @intFromFloat(@round(sz.height * scale));

    if (w != app.px_width or h != app.px_height) {
        app.allocator.free(app.pixels);
        app.pixels = &.{};
        app.pixels = try app.allocator.alloc(z2d.pixel.ARGB, @as(usize, @intCast(w)) * @as(usize, @intCast(h)));
        app.px_width = w;
        app.px_height = h;
        dbg(app, "present: {d}x{d} px at scale {d}", .{ w, h, scale });
    }

    // initBuffer clears to transparent, which is what's left showing
    // outside the panel's rounded corners.
    var surface = z2d.Surface.initBuffer(.image_surface_argb, null, app.pixels, w, h);
    try core.render.render(
        app.io,
        app.allocator,
        &surface,
        &app.theme,
        &app.state,
        scale,
        if (app.icon_cache) |*cache| cache else null,
        app.environ,
        &app.clipboard_preview,
    );
    c.zofi_mac_window_present(window, app.pixels.ptr, w, h);
}

fn stop(app: *App) void {
    if (app.window) |window| c.zofi_mac_window_stop(window);
}

fn onKey(ctx: ?*anyopaque, event: [*c]const c.ZofiMacKeyEvent) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    handleKey(app, event.*) catch |err| dbg(app, "handleKey error: {t}", .{err});
}

fn onRescale(ctx: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    present(app) catch |err| dbg(app, "rescale present error: {t}", .{err});
}

fn onClose(ctx: ?*anyopaque) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(ctx.?));
    dbg(app, "window closed or lost focus, cancelling", .{});
    stop(app);
}

fn handleKey(app: *App, ev: c.ZofiMacKeyEvent) !void {
    const text: []const u8 = if (ev.text_len > 0) ev.text[0..ev.text_len] else "";
    const unmodified: []const u8 = if (ev.text_unmodified_len > 0) ev.text_unmodified[0..ev.text_unmodified_len] else "";
    dbg(app, "key: named={d} ctrl={} shift={} cmd={} repeat={} text_len={d}", .{ ev.named, ev.ctrl, ev.shift, ev.command, ev.repeat, text.len });

    if (ev.named == c.ZOFI_MAC_KEY_TAB and app.mode != null) {
        // A one-shot mode switch: letting a held Tab auto-repeat would spin
        // through every mode.
        if (!ev.repeat) try cycleMode(app, ev.shift);
        return;
    }

    // Clipboard tab only: remove the selected history entry. Handled here,
    // not by `state.handleKey`, since it needs the DB and an entry-list
    // rebuild.
    if (ev.named == c.ZOFI_MAC_KEY_DELETE and app.mode == .clipboard) {
        try deleteSelectedClipboardEntry(app);
        return;
    }

    const key = translateKey(ev, text, unmodified) orelse return;
    const action = try app.state.handleKey(key);
    dbg(app, "key: action={t} query_len={d} results={d} selected={d}", .{
        action,
        app.state.query.items.len,
        app.state.results.items.len,
        app.state.selected,
    });

    switch (action) {
        .nothing => {},
        .redraw => try present(app),
        .accept => {
            // Windows mode brings the chosen app forward right here, while
            // zofi is still the active app and so still allowed to hand
            // focus over; main.zig knows not to launch anything for it.
            if (app.mode == .windows) activateSelectedApp(app);
            app.accepted = if (app.state.selectedEntry()) |e|
                try core.state.State.dupeEntry(e, app.allocator)
            else
                null;
            stop(app);
        },
        .cancel => stop(app),
    }
}

fn translateKey(ev: c.ZofiMacKeyEvent, text: []const u8, unmodified: []const u8) ?core.state.KeyEvent {
    const named: ?core.state.NamedKey = switch (ev.named) {
        c.ZOFI_MAC_KEY_ESCAPE => .escape,
        c.ZOFI_MAC_KEY_ENTER => .enter,
        c.ZOFI_MAC_KEY_BACKSPACE => .backspace,
        c.ZOFI_MAC_KEY_LEFT => .left,
        c.ZOFI_MAC_KEY_RIGHT => .right,
        c.ZOFI_MAC_KEY_UP => .up,
        c.ZOFI_MAC_KEY_DOWN => .down,
        c.ZOFI_MAC_KEY_PAGE_UP => .page_up,
        c.ZOFI_MAC_KEY_PAGE_DOWN => .page_down,
        c.ZOFI_MAC_KEY_HOME => .home,
        c.ZOFI_MAC_KEY_END => .end,
        c.ZOFI_MAC_KEY_TAB => .tab,
        else => null,
    };
    if (named) |k| return .{ .named = k };

    // Cmd+<key> is always a shortcut on macOS, never text to type.
    if (ev.command) return null;
    if (ev.ctrl) {
        if (unmodified.len != 1) return null;
        return switch (std.ascii.toLower(unmodified[0])) {
            'w' => .{ .ctrl = .w },
            'u' => .{ .ctrl = .u },
            'n' => .{ .ctrl = .n },
            'p' => .{ .ctrl = .p },
            else => null,
        };
    }
    if (text.len == 0) return null;
    // Copied into the query by State.handleKey before `text` goes stale.
    return .{ .text = text };
}

/// Rebuilds `app.state` around `entries`, preserving the typed query.
fn replaceEntries(app: *App, entries: []const core.state.Entry) !void {
    const query = try app.allocator.dupe(u8, app.state.query.items);
    defer app.allocator.free(query);
    app.state.deinit();
    app.state = try core.state.State.init(app.allocator, entries);
    try app.state.setQuery(query);
    app.state.visible_rows = app.theme.visibleRows();
    app.state.browser = app.theme.browser_cmd;
}

/// Rescans entries for the next (or previous) mode. `app.mode`/`environ`
/// being non-null is the caller's contract that this is reachable (dmenu,
/// with its single fixed entry list, never wires Tab to this).
fn cycleMode(app: *App, backward: bool) !void {
    const current = app.mode.?;
    const next_mode = if (backward) current.prev() else current.next();
    const environ = app.environ.?;

    const entries: []const core.state.Entry = switch (next_mode) {
        .drun => core.sources.macapps.scan(app.allocator, app.io, environ) catch |err| {
            dbg(app, "cycleMode: drun scan failed: {t}", .{err});
            return;
        },
        .run => core.sources.path.scan(app.allocator, app.io, environ) catch |err| {
            dbg(app, "cycleMode: run scan failed: {t}", .{err});
            return;
        },
        .windows => try buildWindowEntries(app),
        .clipboard => core.sources.clipboard.toEntries(app.allocator, app.io, environ) catch |err| {
            dbg(app, "cycleMode: clipboard scan failed: {t}", .{err});
            return;
        },
    };
    if (next_mode != .windows) app.window_pids = &.{};

    app.mode = next_mode;
    // Clipboard's split view uses the tall row height too; `compact_rows`
    // only feeds `visibleRows()` there.
    app.theme.compact_rows = next_mode == .run;
    app.theme.active_tab = switch (next_mode) {
        .drun => .apps,
        .run => .run,
        .windows => .windows,
        .clipboard => .clipboard,
    };
    app.theme.placeholder = switch (next_mode) {
        .drun => "Search apps",
        .run => "Search commands",
        .windows => "Search windows",
        .clipboard => "Search clipboard history",
    };
    // After the theme update: the page size depends on the row style.
    try replaceEntries(app, entries);

    try present(app);
    dbg(app, "cycleMode: switched to {t}, {d} entries", .{ next_mode, entries.len });
}

/// Deletes the selected clipboard-tab entry (forward delete) and rebuilds
/// the list without switching modes.
fn deleteSelectedClipboardEntry(app: *App) !void {
    const entry = app.state.selectedEntry() orelse return;
    const marker = entry.action orelse return;
    const id = core.clipboard.parseMarker(marker) catch |err| {
        dbg(app, "deleteSelectedClipboardEntry: bad marker {s}: {t}", .{ marker, err });
        return;
    };
    const environ = app.environ orelse return;

    var db = core.clipboard.open(app.allocator, app.io, environ) catch |err| {
        dbg(app, "deleteSelectedClipboardEntry: open failed: {t}", .{err});
        return;
    };
    defer db.close();
    core.clipboard.deleteEntry(db, id) catch |err| {
        dbg(app, "deleteSelectedClipboardEntry: delete failed: {t}", .{err});
        return;
    };
    app.clipboard_preview.invalidate(id);

    const entries = core.sources.clipboard.toEntries(app.allocator, app.io, environ) catch |err| {
        dbg(app, "deleteSelectedClipboardEntry: rescan failed: {t}", .{err});
        return;
    };
    try replaceEntries(app, entries);
    try present(app);
}

fn activateSelectedApp(app: *App) void {
    if (app.state.results.items.len == 0) return;
    const idx = app.state.results.items[app.state.selected].index;
    // The synthetic "open in browser" row has index == entries.len, past
    // the end of `window_pids`.
    if (idx >= app.window_pids.len) return;
    const pid = app.window_pids[idx];
    if (!c.zofi_mac_activate_app(pid)) dbg(app, "activate: pid {d} refused or gone", .{pid});
}

const RunningApps = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(core.state.Entry) = .empty,
    pids: std.ArrayList(i32) = .empty,
    failed: bool = false,

    fn add(self: *RunningApps, pid: i32, name: []const u8, bundle_id: []const u8) !void {
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        try self.pids.ensureUnusedCapacity(self.allocator, 1);
        self.entries.appendAssumeCapacity(.{
            .label = try self.allocator.dupe(u8, if (name.len > 0) name else "(unnamed)"),
            .subtitle = if (bundle_id.len > 0) try self.allocator.dupe(u8, bundle_id) else null,
        });
        self.pids.appendAssumeCapacity(pid);
    }
};

fn visitRunningApp(ctx: ?*anyopaque, pid: i32, name: [*c]const u8, bundle_id: [*c]const u8) callconv(.c) void {
    const list: *RunningApps = @ptrCast(@alignCast(ctx.?));
    list.add(pid, std.mem.span(name), std.mem.span(bundle_id)) catch {
        list.failed = true;
    };
}

/// Snapshots the running apps into entries, filling `app.window_pids` in
/// the same order so `.accept` can look up which one to activate.
fn buildWindowEntries(app: *App) ![]core.state.Entry {
    var list: RunningApps = .{ .allocator = app.allocator };
    errdefer {
        list.entries.deinit(app.allocator);
        list.pids.deinit(app.allocator);
    }
    c.zofi_mac_list_running_apps(&list, visitRunningApp);
    if (list.failed) return error.OutOfMemory;

    app.window_pids = try list.pids.toOwnedSlice(app.allocator);
    return list.entries.toOwnedSlice(app.allocator);
}

/// Puts a clipboard-history entry (`"clipboard:<id>"` marker) back on the
/// system clipboard via NSPasteboard. Counterpart of the Wayland backend's
/// `copyToClipboard`, which pipes into `wl-copy`.
pub fn copyToClipboard(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, marker: []const u8) !void {
    const id = try core.clipboard.parseMarker(marker);
    var db = try core.clipboard.open(allocator, io, environ);
    defer db.close();
    const content = try core.clipboard.fetchContent(allocator, db, id);

    const mime_z = try allocator.dupeZ(u8, content.mime);
    defer allocator.free(mime_z);
    if (!c.zofi_mac_pasteboard_write(mime_z.ptr, content.bytes.ptr, content.bytes.len)) {
        return error.PasteboardWriteFailed;
    }
}

// ---------------------------------------------------------------------
// Clipboard daemon: `zofi --clipboard-daemon`, normally run by a launchd
// agent (see contrib/launchd/). macOS has no clipboard-change events, so
// this polls NSPasteboard's change counter -- the same approach every
// macOS clipboard manager takes.

/// How often to check for a new copy. Override with
/// `ZOFI_CLIPBOARD_POLL_MS` (100-10000): lower catches copies made in quick
/// succession, higher wakes the Mac less often.
const default_poll_ms: u32 = 500;

const DaemonCtx = struct {
    allocator: std.mem.Allocator,
    db: core.clipboard.Db,
    debug: bool,
};

pub fn runClipboardDaemon(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, debug: bool) !void {
    var db = try core.clipboard.open(allocator, io, environ);
    defer db.close();
    const poll_ms = core.env.int(u32, environ, "ZOFI_CLIPBOARD_POLL_MS", default_poll_ms, 100, 10_000);

    // Per-change scratch memory, reset every time: this process runs for
    // days, and `allocator` is main's never-freed arena.
    var scratch: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer scratch.deinit();

    // -1 so whatever is on the clipboard at startup gets recorded too, as
    // the Wayland daemon does when the compositor sends the current
    // selection on bind.
    var last_count: i64 = -1;
    if (debug) std.debug.print("clipboard daemon: polling every {d}ms, keeping up to {d}MB\n", .{ poll_ms, @divTrunc(db.cap_bytes, 1024 * 1024) });
    while (true) {
        const count = c.zofi_mac_pasteboard_change_count();
        if (count != last_count) {
            last_count = count;
            _ = scratch.reset(.retain_capacity);
            var ctx: DaemonCtx = .{ .allocator = scratch.allocator(), .db = db, .debug = debug };
            if (!c.zofi_mac_pasteboard_read(&ctx, visitPasteboard) and debug) {
                std.debug.print("clipboard daemon: change {d} has nothing to keep\n", .{count});
            }
        }
        try Io.sleep(io, .fromMilliseconds(poll_ms), .awake);
    }
}

fn visitPasteboard(ctx_ptr: ?*anyopaque, mime: [*c]const u8, bytes: ?*const anyopaque, len: usize) callconv(.c) void {
    const ctx: *DaemonCtx = @ptrCast(@alignCast(ctx_ptr.?));
    const content: []const u8 = if (len > 0) @as([*]const u8, @ptrCast(bytes.?))[0..len] else "";
    core.clipboard.insert(ctx.allocator, ctx.db, std.mem.span(mime), content) catch |err| {
        if (ctx.debug) std.debug.print("clipboard daemon: insert failed: {t}\n", .{err});
        return;
    };
    if (ctx.debug) std.debug.print("clipboard daemon: stored {d} bytes of {s}\n", .{ len, std.mem.span(mime) });
}
