//! Wayland backend: wlr-layer-shell (falling back to plain xdg_toplevel),
//! wl_shm double buffering, and xkbcommon-driven keyboard input with
//! software key repeat via timerfd. Links libwayland-client + libxkbcommon
//! (see build.zig's `addWaylandBackend`) rather than speaking the wire
//! protocol directly -- the plan's stated fallback for getting a real
//! window working first.
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Io = std.Io;
const core = @import("core");

pub const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("wlr-layer-shell-unstable-v1-client-protocol.h");
    @cInclude("wlr-foreign-toplevel-management-unstable-v1-client-protocol.h");
    @cInclude("wlr-data-control-unstable-v1-client-protocol.h");
    @cInclude("xkbcommon/xkbcommon.h");
});

/// A live open window, tracked via wlr-foreign-toplevel-management. Heap
/// allocated individually (not stored by value in a resizable list) since
/// its address is handed to Wayland as listener userdata and must stay
/// stable across appends elsewhere.
const Toplevel = struct {
    allocator: std.mem.Allocator,
    handle: *c.zwlr_foreign_toplevel_handle_v1,
    title: []u8 = &.{},
    app_id: []u8 = &.{},
    closed: bool = false,
};

const Buffer = struct {
    wl_buffer: ?*c.wl_buffer = null,
    pixels: []core_z2d.pixel.ARGB = &.{},
    busy: bool = false,
};

const core_z2d = @import("z2d");

pub const App = struct {
    allocator: std.mem.Allocator,
    io: Io,

    display: *c.wl_display,
    registry: *c.wl_registry,

    compositor: ?*c.wl_compositor = null,
    shm: ?*c.wl_shm = null,
    seat: ?*c.wl_seat = null,
    layer_shell: ?*c.zwlr_layer_shell_v1 = null,
    xdg_wm_base: ?*c.xdg_wm_base = null,
    toplevel_manager: ?*c.zwlr_foreign_toplevel_manager_v1 = null,

    surface: ?*c.wl_surface = null,
    layer_surface: ?*c.zwlr_layer_surface_v1 = null,
    xdg_surface: ?*c.xdg_surface = null,
    xdg_toplevel: ?*c.xdg_toplevel = null,

    keyboard: ?*c.wl_keyboard = null,
    xkb_context: ?*c.xkb_context = null,
    xkb_keymap: ?*c.xkb_keymap = null,
    xkb_state: ?*c.xkb_state = null,

    repeat_rate: i32 = 25,
    repeat_delay: i32 = 600,
    repeat_keycode: u32 = 0,
    timer_fd: i32 = -1,

    configured: bool = false,
    width: i32 = 0,
    height: i32 = 0,
    pool_map: []align(std.heap.page_size_min) u8 = &.{},

    buffers: [2]Buffer = .{ .{}, .{} },
    cur_buffer: usize = 0,

    theme: core.theme.Theme,
    state: core.state.State,
    need_redraw: bool = true,

    running: bool = true,
    accepted: ?core.state.Entry = null,

    /// Set from `ZOFI_DEBUG` in the environment. See `dbg`.
    debug: bool = false,

    /// Non-null enables Tab/Shift+Tab mode switching (Apps/Run/Windows).
    /// Null for dmenu, which has a single fixed entry list and no tabs.
    mode: ?LauncherMode = null,
    environ: ?*const std.process.Environ.Map = null,
    terminal_cmd: []const u8 = "",

    /// Live open windows, tracked continuously (not just while in Windows
    /// mode) via wlr-foreign-toplevel-management, since events arrive
    /// whenever the compositor sends them.
    toplevels: std.ArrayList(*Toplevel) = .empty,
    /// Parallel to `state.entries` only while `mode == .windows`: handle to
    /// activate for each entry index, since `Entry` itself is backend-
    /// agnostic and can't carry a Wayland object.
    window_handles: []const *c.zwlr_foreign_toplevel_handle_v1 = &.{},

    /// Lazily-populated real-icon lookup for Apps/Windows rows; null when
    /// there's no environ to search with (dmenu).
    icon_cache: ?core.icon.Cache = null,

    /// Lazily-populated content/decode cache for the clipboard tab's
    /// preview pane, keyed by the selected row's id. Always present (not
    /// optional): cheap to zero-init, and only ever touched while
    /// `mode == .clipboard`.
    clipboard_preview: core.clipboard.PreviewCache = .{},
};

pub const LauncherMode = enum {
    drun,
    run,
    windows,
    clipboard,

    fn next(self: LauncherMode) LauncherMode {
        return switch (self) {
            .drun => .run,
            .run => .windows,
            .windows => .clipboard,
            .clipboard => .drun,
        };
    }

    fn prev(self: LauncherMode) LauncherMode {
        return switch (self) {
            .drun => .clipboard,
            .run => .drun,
            .windows => .run,
            .clipboard => .windows,
        };
    }
};

/// Logs to stderr when `ZOFI_DEBUG` is set, so a hang/freeze can be
/// diagnosed from what the log stops after, not guessed at. No-op (and the
/// `args` formatting is skipped) otherwise.
fn dbg(app: *const App, comptime fmt: []const u8, args: anytype) void {
    if (!app.debug) return;
    std.debug.print(fmt ++ "\n", args);
}

const registry_listener: c.wl_registry_listener = .{
    .global = registryGlobal,
    .global_remove = registryGlobalRemove,
};

fn registryGlobal(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    const iface = std.mem.span(interface);
    dbg(app, "registryGlobal: {s} v{d} (name={d})", .{ iface, version, name });

    if (std.mem.eql(u8, iface, std.mem.span(c.wl_compositor_interface.name))) {
        app.compositor = @ptrCast(@alignCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, @min(version, 4)).?));
    } else if (std.mem.eql(u8, iface, std.mem.span(c.wl_shm_interface.name))) {
        app.shm = @ptrCast(@alignCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1).?));
    } else if (std.mem.eql(u8, iface, std.mem.span(c.wl_seat_interface.name))) {
        app.seat = @ptrCast(@alignCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, @min(version, 7)).?));
        _ = c.wl_seat_add_listener(app.seat, &seat_listener, app);
    } else if (std.mem.eql(u8, iface, std.mem.span(c.zwlr_layer_shell_v1_interface.name))) {
        app.layer_shell = @ptrCast(@alignCast(c.wl_registry_bind(registry, name, &c.zwlr_layer_shell_v1_interface, @min(version, 4)).?));
    } else if (std.mem.eql(u8, iface, std.mem.span(c.xdg_wm_base_interface.name))) {
        app.xdg_wm_base = @ptrCast(@alignCast(c.wl_registry_bind(registry, name, &c.xdg_wm_base_interface, @min(version, 6)).?));
        _ = c.xdg_wm_base_add_listener(app.xdg_wm_base, &wm_base_listener, app);
    } else if (std.mem.eql(u8, iface, std.mem.span(c.zwlr_foreign_toplevel_manager_v1_interface.name))) {
        app.toplevel_manager = @ptrCast(@alignCast(c.wl_registry_bind(registry, name, &c.zwlr_foreign_toplevel_manager_v1_interface, @min(version, 3)).?));
        _ = c.zwlr_foreign_toplevel_manager_v1_add_listener(app.toplevel_manager, &toplevel_manager_listener, app);
    }
}

fn registryGlobalRemove(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = name;
}

const wm_base_listener: c.xdg_wm_base_listener = .{ .ping = wmBasePing };

fn wmBasePing(data: ?*anyopaque, wm_base: ?*c.xdg_wm_base, serial: u32) callconv(.c) void {
    _ = data;
    c.xdg_wm_base_pong(wm_base, serial);
}

const toplevel_manager_listener: c.zwlr_foreign_toplevel_manager_v1_listener = .{
    .toplevel = toplevelManagerToplevel,
    .finished = toplevelManagerFinished,
};

fn toplevelManagerToplevel(data: ?*anyopaque, manager: ?*c.zwlr_foreign_toplevel_manager_v1, handle: ?*c.zwlr_foreign_toplevel_handle_v1) callconv(.c) void {
    _ = manager;
    const app: *App = @ptrCast(@alignCast(data.?));
    const t = app.allocator.create(Toplevel) catch return;
    t.* = .{ .allocator = app.allocator, .handle = handle.? };
    app.toplevels.append(app.allocator, t) catch {
        app.allocator.destroy(t);
        return;
    };
    _ = c.zwlr_foreign_toplevel_handle_v1_add_listener(handle, &toplevel_handle_listener, t);
    dbg(app, "toplevel: new handle, {d} tracked", .{app.toplevels.items.len});
}

fn toplevelManagerFinished(data: ?*anyopaque, manager: ?*c.zwlr_foreign_toplevel_manager_v1) callconv(.c) void {
    _ = data;
    c.zwlr_foreign_toplevel_manager_v1_destroy(manager);
}

const toplevel_handle_listener: c.zwlr_foreign_toplevel_handle_v1_listener = .{
    .title = toplevelTitle,
    .app_id = toplevelAppId,
    .output_enter = toplevelOutputEnter,
    .output_leave = toplevelOutputLeave,
    .state = toplevelState,
    .done = toplevelDone,
    .closed = toplevelClosed,
    .parent = toplevelParent,
};

fn toplevelTitle(data: ?*anyopaque, handle: ?*c.zwlr_foreign_toplevel_handle_v1, title: [*c]const u8) callconv(.c) void {
    _ = handle;
    const t: *Toplevel = @ptrCast(@alignCast(data.?));
    t.allocator.free(t.title);
    t.title = t.allocator.dupe(u8, std.mem.span(title)) catch &.{};
}

fn toplevelAppId(data: ?*anyopaque, handle: ?*c.zwlr_foreign_toplevel_handle_v1, app_id: [*c]const u8) callconv(.c) void {
    _ = handle;
    const t: *Toplevel = @ptrCast(@alignCast(data.?));
    t.allocator.free(t.app_id);
    t.app_id = t.allocator.dupe(u8, std.mem.span(app_id)) catch &.{};
}

fn toplevelDone(data: ?*anyopaque, handle: ?*c.zwlr_foreign_toplevel_handle_v1) callconv(.c) void {
    _ = handle;
    _ = data;
    // Nothing to do: windows-mode entries are rebuilt fresh from
    // `app.toplevels` whenever the user switches into that mode, not kept
    // continuously in sync with `state`.
}

fn toplevelClosed(data: ?*anyopaque, handle: ?*c.zwlr_foreign_toplevel_handle_v1) callconv(.c) void {
    const t: *Toplevel = @ptrCast(@alignCast(data.?));
    t.closed = true;
    c.zwlr_foreign_toplevel_handle_v1_destroy(handle);
}

// Handle events this launcher doesn't need: which output(s) the window is
// visible on, its maximized/minimized/activated state, and its parent.
fn toplevelOutputEnter(data: ?*anyopaque, handle: ?*c.zwlr_foreign_toplevel_handle_v1, output: ?*c.wl_output) callconv(.c) void {
    _ = .{ data, handle, output };
}
fn toplevelOutputLeave(data: ?*anyopaque, handle: ?*c.zwlr_foreign_toplevel_handle_v1, output: ?*c.wl_output) callconv(.c) void {
    _ = .{ data, handle, output };
}
fn toplevelState(data: ?*anyopaque, handle: ?*c.zwlr_foreign_toplevel_handle_v1, state: ?*c.wl_array) callconv(.c) void {
    _ = .{ data, handle, state };
}
fn toplevelParent(data: ?*anyopaque, handle: ?*c.zwlr_foreign_toplevel_handle_v1, parent: ?*c.zwlr_foreign_toplevel_handle_v1) callconv(.c) void {
    _ = .{ data, handle, parent };
}

const seat_listener: c.wl_seat_listener = .{
    .capabilities = seatCapabilities,
    .name = seatName,
};

fn seatCapabilities(data: ?*anyopaque, seat: ?*c.wl_seat, capabilities: u32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    const has_keyboard = capabilities & c.WL_SEAT_CAPABILITY_KEYBOARD != 0;
    if (has_keyboard and app.keyboard == null) {
        app.keyboard = c.wl_seat_get_keyboard(seat);
        _ = c.wl_keyboard_add_listener(app.keyboard, &keyboard_listener, app);
    }
}

fn seatName(data: ?*anyopaque, seat: ?*c.wl_seat, name: [*c]const u8) callconv(.c) void {
    _ = data;
    _ = seat;
    _ = name;
}

const keyboard_listener: c.wl_keyboard_listener = .{
    .keymap = keyboardKeymap,
    .enter = keyboardEnter,
    .leave = keyboardLeave,
    .key = keyboardKey,
    .modifiers = keyboardModifiers,
    .repeat_info = keyboardRepeatInfo,
};

fn keyboardKeymap(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
    _ = keyboard;
    const app: *App = @ptrCast(@alignCast(data.?));
    defer _ = linux.close(fd);

    if (format != c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) return;

    const map = posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) catch return;
    defer posix.munmap(map);

    if (app.xkb_context == null) app.xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
    const context = app.xkb_context orelse return;

    if (app.xkb_keymap) |km| c.xkb_keymap_unref(km);
    app.xkb_keymap = c.xkb_keymap_new_from_string(
        context,
        @ptrCast(map.ptr),
        c.XKB_KEYMAP_FORMAT_TEXT_V1,
        c.XKB_KEYMAP_COMPILE_NO_FLAGS,
    );

    if (app.xkb_state) |st| c.xkb_state_unref(st);
    app.xkb_state = if (app.xkb_keymap) |km| c.xkb_state_new(km) else null;
}

fn keyboardEnter(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, serial: u32, surface: ?*c.wl_surface, keys: ?*c.wl_array) callconv(.c) void {
    _ = data;
    _ = keyboard;
    _ = serial;
    _ = surface;
    _ = keys;
}

fn keyboardLeave(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, serial: u32, surface: ?*c.wl_surface) callconv(.c) void {
    _ = keyboard;
    _ = serial;
    _ = surface;
    const app: *App = @ptrCast(@alignCast(data.?));
    disarmRepeat(app);
}

fn keyboardKey(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, serial: u32, time: u32, key: u32, state: u32) callconv(.c) void {
    _ = keyboard;
    _ = serial;
    _ = time;
    const app: *App = @ptrCast(@alignCast(data.?));
    const pressed = state == c.WL_KEYBOARD_KEY_STATE_PRESSED;
    dbg(app, "keyboardKey: raw_key={d} pressed={} repeat_keycode={d}", .{ key, pressed, app.repeat_keycode });

    if (pressed) {
        processKeycode(app, key) catch |err| dbg(app, "processKeycode error: {t}", .{err});
        // Tab is a one-shot mode switch, not something that makes sense to
        // hold-and-repeat -- arming it anyway meant a single keypress with
        // any repeat-timer/release-event delay (as little as a fast
        // synthetic press, not even a real hold) span the repeat delay
        // and fire cycleMode() repeatedly, spinning through every mode.
        if (app.repeat_rate > 0 and key != evdev_key_tab) armRepeat(app, key);
    } else if (app.repeat_keycode == key) {
        disarmRepeat(app);
    }
}

const evdev_key_tab: u32 = 15;

fn keyboardModifiers(
    data: ?*anyopaque,
    keyboard: ?*c.wl_keyboard,
    serial: u32,
    mods_depressed: u32,
    mods_latched: u32,
    mods_locked: u32,
    group: u32,
) callconv(.c) void {
    _ = keyboard;
    _ = serial;
    const app: *App = @ptrCast(@alignCast(data.?));
    if (app.xkb_state) |st| {
        _ = c.xkb_state_update_mask(st, mods_depressed, mods_latched, mods_locked, 0, 0, group);
    }
}

fn keyboardRepeatInfo(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
    _ = keyboard;
    const app: *App = @ptrCast(@alignCast(data.?));
    app.repeat_rate = rate;
    app.repeat_delay = delay;
}

const layer_surface_listener: c.zwlr_layer_surface_v1_listener = .{
    .configure = layerSurfaceConfigure,
    .closed = layerSurfaceClosed,
};

fn layerSurfaceConfigure(data: ?*anyopaque, layer_surface: ?*c.zwlr_layer_surface_v1, serial: u32, width: u32, height: u32) callconv(.c) void {
    _ = width;
    _ = height;
    const app: *App = @ptrCast(@alignCast(data.?));
    c.zwlr_layer_surface_v1_ack_configure(layer_surface, serial);
    app.configured = true;
}

fn layerSurfaceClosed(data: ?*anyopaque, layer_surface: ?*c.zwlr_layer_surface_v1) callconv(.c) void {
    _ = layer_surface;
    const app: *App = @ptrCast(@alignCast(data.?));
    app.running = false;
}

const xdg_surface_listener: c.xdg_surface_listener = .{ .configure = xdgSurfaceConfigure };

fn xdgSurfaceConfigure(data: ?*anyopaque, xdg_surface: ?*c.xdg_surface, serial: u32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    c.xdg_surface_ack_configure(xdg_surface, serial);
    app.configured = true;
}

const xdg_toplevel_listener: c.xdg_toplevel_listener = .{
    .configure = xdgToplevelConfigure,
    .close = xdgToplevelClose,
};

fn xdgToplevelConfigure(data: ?*anyopaque, toplevel: ?*c.xdg_toplevel, width: i32, height: i32, states: ?*c.wl_array) callconv(.c) void {
    _ = data;
    _ = toplevel;
    _ = width;
    _ = height;
    _ = states;
}

fn xdgToplevelClose(data: ?*anyopaque, toplevel: ?*c.xdg_toplevel) callconv(.c) void {
    _ = toplevel;
    const app: *App = @ptrCast(@alignCast(data.?));
    app.running = false;
}

const buffer_listener: c.wl_buffer_listener = .{ .release = bufferRelease };

fn bufferRelease(data: ?*anyopaque, wl_buffer: ?*c.wl_buffer) callconv(.c) void {
    _ = wl_buffer;
    const buf: *Buffer = @ptrCast(@alignCast(data.?));
    buf.busy = false;
}

/// Runs the launcher. On accept, returns the chosen entry (still owned by
/// the caller-supplied `entries` slice); on cancel/close, returns `null`.
pub const RunOptions = struct {
    debug: bool = false,
    /// Non-null enables Tab/Shift+Tab mode switching; see `App.mode`.
    mode: ?LauncherMode = null,
    environ: ?*const std.process.Environ.Map = null,
    terminal_cmd: []const u8 = "",
};

pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    theme: core.theme.Theme,
    entries: []const core.state.Entry,
    options: RunOptions,
) !?core.state.Entry {
    const display = c.wl_display_connect(null) orelse return error.NoWaylandDisplay;
    defer c.wl_display_disconnect(display);

    const registry = c.wl_display_get_registry(display) orelse return error.NoRegistry;

    var app: App = .{
        .allocator = allocator,
        .io = io,
        .display = display,
        .registry = registry,
        .theme = theme,
        .state = try core.state.State.init(allocator, entries),
        .debug = options.debug,
        .mode = options.mode,
        .environ = options.environ,
        .terminal_cmd = options.terminal_cmd,
    };
    if (options.environ) |environ| {
        app.icon_cache = core.icon.Cache.init(allocator, io, environ) catch null;
    }
    defer app.state.deinit();
    // State's scroll/paging math and render()'s row count must agree on the
    // same page size, or the highlighted row and what's actually painted
    // can disagree once a config lets these diverge.
    app.state.visible_rows = app.theme.visibleRows();
    app.state.browser = app.theme.browser_cmd;

    _ = c.wl_registry_add_listener(registry, &registry_listener, &app);
    if (c.wl_display_roundtrip(display) == -1) return error.RoundtripFailed;
    // Second roundtrip so seat capabilities (bound during the first)
    // resolve too, and so do each toplevel handle's title/app_id/done
    // events (bound during the first roundtrip's `toplevel` events, so
    // their own detail events are a roundtrip behind).
    if (c.wl_display_roundtrip(display) == -1) return error.RoundtripFailed;

    if (options.mode == .windows) {
        const window_entries = buildWindowEntries(&app) catch &.{};
        app.state.deinit();
        app.state = try core.state.State.init(allocator, window_entries);
        app.state.visible_rows = app.theme.visibleRows();
        app.state.browser = app.theme.browser_cmd;
    }

    const compositor = app.compositor orelse return error.NoCompositor;
    const shm = app.shm orelse return error.NoShm;
    _ = shm;

    app.surface = c.wl_compositor_create_surface(compositor) orelse return error.NoSurface;

    const sz = core.render.size(&app.theme);
    app.width = @intFromFloat(sz.width);
    app.height = @intFromFloat(sz.height);

    if (app.layer_shell) |layer_shell| {
        const ls = c.zwlr_layer_shell_v1_get_layer_surface(
            layer_shell,
            app.surface,
            null,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "zofi",
        ) orelse return error.NoLayerSurface;
        app.layer_surface = ls;
        c.zwlr_layer_surface_v1_set_size(ls, @intCast(app.width), @intCast(app.height));
        c.zwlr_layer_surface_v1_set_anchor(ls, 0);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(ls, c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE);
        _ = c.zwlr_layer_surface_v1_add_listener(ls, &layer_surface_listener, &app);
        c.wl_surface_commit(app.surface);
    } else if (app.xdg_wm_base) |wm_base| {
        const xsurface = c.xdg_wm_base_get_xdg_surface(wm_base, app.surface) orelse return error.NoXdgSurface;
        app.xdg_surface = xsurface;
        _ = c.xdg_surface_add_listener(xsurface, &xdg_surface_listener, &app);

        const toplevel = c.xdg_surface_get_toplevel(xsurface) orelse return error.NoXdgToplevel;
        app.xdg_toplevel = toplevel;
        c.xdg_toplevel_set_title(toplevel, "zofi");
        c.xdg_toplevel_set_app_id(toplevel, "zofi");
        _ = c.xdg_toplevel_add_listener(toplevel, &xdg_toplevel_listener, &app);
        c.wl_surface_commit(app.surface);
    } else {
        return error.NoShellProtocol;
    }

    while (!app.configured and app.running) {
        if (c.wl_display_dispatch(display) == -1) return error.DispatchFailed;
    }
    if (!app.running) return null;

    try createBuffers(&app);
    defer if (app.pool_map.len > 0) posix.munmap(app.pool_map);

    // NONBLOCK is load-bearing: poll() reporting the timer fd readable can
    // race with disarmRepeat() (a key release processed from the *same*
    // wakeup can disarm the timer before we get to reading it), and a
    // blocking read() on a disarmed timerfd with nothing pending waits
    // forever -- hanging the whole event loop, and with it all keyboard
    // input, since this surface holds an exclusive grab.
    app.timer_fd = @intCast(linux.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true }));
    defer _ = linux.close(app.timer_fd);

    try eventLoop(&app);

    // The loop can exit right after queuing a request (e.g. `activate()`
    // for windows-mode accept) without another pass through its own
    // flush() -- and disconnect() below does not flush on its own, so
    // that request would otherwise be silently dropped.
    _ = c.wl_display_flush(app.display);

    return app.accepted;
}

fn createBuffers(app: *App) !void {
    const w: usize = @intCast(app.width);
    const h: usize = @intCast(app.height);
    const stride = w * 4;
    const single_size = stride * h;
    const pool_size = single_size * 2;

    const fd = try posix.memfd_create("zofi-shm", 0);
    defer _ = linux.close(fd);
    if (linux.ftruncate(@intCast(fd), @intCast(pool_size)) != 0) return error.TruncateFailed;

    const map = try posix.mmap(null, pool_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    app.pool_map = map;

    const shm = app.shm orelse return error.NoShm;
    const pool = c.wl_shm_create_pool(shm, fd, @intCast(pool_size)) orelse return error.NoShmPool;
    defer c.wl_shm_pool_destroy(pool);

    const all_pixels = std.mem.bytesAsSlice(core_z2d.pixel.ARGB, map);
    const px_per_buf = single_size / 4;

    for (0..2) |i| {
        const offset = single_size * i;
        const wl_buffer = c.wl_shm_pool_create_buffer(
            pool,
            @intCast(offset),
            @intCast(app.width),
            @intCast(app.height),
            @intCast(stride),
            c.WL_SHM_FORMAT_ARGB8888,
        ) orelse return error.NoBuffer;

        app.buffers[i].wl_buffer = wl_buffer;
        app.buffers[i].pixels = all_pixels[px_per_buf * i .. px_per_buf * (i + 1)];
        _ = c.wl_buffer_add_listener(wl_buffer, &buffer_listener, &app.buffers[i]);
    }
}

/// Returns `true` if a frame was actually presented. Both buffers can be
/// busy at once under fast repeated input; the caller must keep
/// `need_redraw` set (not drop it) when this returns `false`, or the
/// display can go stale relative to `app.state`.
fn presentFrame(app: *App) !bool {
    const buf = &app.buffers[app.cur_buffer];
    if (buf.busy) {
        dbg(app, "presentFrame: buffer {d} still busy, skipping", .{app.cur_buffer});
        return false; // still owned by the compositor; retry next loop
    }

    var surface = core_z2d.Surface.initBuffer(.image_surface_argb, null, buf.pixels, app.width, app.height);
    try core.render.render(app.io, app.allocator, &surface, &app.theme, &app.state, 1.0, if (app.icon_cache) |*cache| cache else null, app.environ, &app.clipboard_preview);

    c.wl_surface_attach(app.surface, buf.wl_buffer, 0, 0);
    c.wl_surface_damage_buffer(app.surface, 0, 0, app.width, app.height);
    c.wl_surface_commit(app.surface);
    buf.busy = true;
    dbg(app, "presentFrame: presented buffer {d}", .{app.cur_buffer});
    app.cur_buffer = 1 - app.cur_buffer;
    return true;
}

fn eventLoop(app: *App) !void {
    var iteration: u64 = 0;
    while (app.running) {
        iteration += 1;
        if (app.need_redraw) {
            app.need_redraw = !(try presentFrame(app));
        }

        var prepare_spins: u32 = 0;
        while (c.wl_display_prepare_read(app.display) != 0) {
            prepare_spins += 1;
            if (prepare_spins > 1000) {
                dbg(app, "eventLoop: prepare_read spun >1000 times, bailing to avoid a true hang", .{});
                return error.PrepareReadStuck;
            }
            _ = c.wl_display_dispatch_pending(app.display);
        }
        _ = c.wl_display_flush(app.display);

        dbg(app, "eventLoop: iter={d} polling (need_redraw={})", .{ iteration, app.need_redraw });
        var fds = [_]posix.pollfd{
            .{ .fd = c.wl_display_get_fd(app.display), .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = app.timer_fd, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = posix.poll(&fds, -1) catch {
            c.wl_display_cancel_read(app.display);
            return;
        };
        dbg(app, "eventLoop: iter={d} woke: wl_fd={} timer_fd={}", .{ iteration, fds[0].revents & posix.POLL.IN != 0, fds[1].revents & posix.POLL.IN != 0 });

        if (fds[0].revents & posix.POLL.IN != 0) {
            _ = c.wl_display_read_events(app.display);
        } else {
            c.wl_display_cancel_read(app.display);
        }
        _ = c.wl_display_dispatch_pending(app.display);

        if (fds[1].revents & posix.POLL.IN != 0) {
            var expirations: u64 = 0;
            // A disarm racing this read (see the NONBLOCK comment above)
            // can mean there's nothing left to read even though poll()
            // said so a moment ago; that's expected, not an error, and
            // must not trigger a phantom repeat of a key that was just
            // released.
            const n = posix.read(app.timer_fd, std.mem.asBytes(&expirations)) catch 0;
            if (n > 0 and expirations > 0) {
                processKeycode(app, app.repeat_keycode) catch {};
            }
        }
    }
}

fn armRepeat(app: *App, keycode: u32) void {
    app.repeat_keycode = keycode;
    const rate: i64 = @max(1, app.repeat_rate);
    const interval_ns: i64 = @divTrunc(1_000_000_000, rate);
    const delay_ns: i64 = @as(i64, app.repeat_delay) * 1_000_000;

    const spec: linux.itimerspec = .{
        .it_interval = .{ .sec = @divTrunc(interval_ns, 1_000_000_000), .nsec = @mod(interval_ns, 1_000_000_000) },
        .it_value = .{ .sec = @divTrunc(delay_ns, 1_000_000_000), .nsec = @mod(delay_ns, 1_000_000_000) },
    };
    _ = linux.timerfd_settime(app.timer_fd, .{}, &spec, null);
    dbg(app, "armRepeat: keycode={d} rate={d} delay={d}ms", .{ keycode, app.repeat_rate, app.repeat_delay });
}

fn disarmRepeat(app: *App) void {
    const zero: linux.itimerspec = .{ .it_interval = .{ .sec = 0, .nsec = 0 }, .it_value = .{ .sec = 0, .nsec = 0 } };
    _ = linux.timerfd_settime(app.timer_fd, .{}, &zero, null);
    dbg(app, "disarmRepeat", .{});
}

fn processKeycode(app: *App, wayland_keycode: u32) !void {
    const st = app.xkb_state orelse {
        dbg(app, "processKeycode: no xkb_state yet, dropping key {d}", .{wayland_keycode});
        return;
    };
    const xkb_keycode = wayland_keycode + 8;
    const sym = c.xkb_state_key_get_one_sym(st, xkb_keycode);

    const ctrl_active = c.xkb_state_mod_name_is_active(st, c.XKB_MOD_NAME_CTRL, c.XKB_STATE_MODS_EFFECTIVE) == 1;

    // Shift+Tab doesn't reliably show up as Tab-plus-modifier: many xkb
    // layouts remap it to the distinct ISO_Left_Tab keysym instead (a
    // long-standing X11/XKB convention), so relying on the shift modifier
    // alone misses it entirely.
    if ((sym == c.XKB_KEY_Tab or sym == c.XKB_KEY_ISO_Left_Tab) and app.mode != null) {
        const shift_active = c.xkb_state_mod_name_is_active(st, c.XKB_MOD_NAME_SHIFT, c.XKB_STATE_MODS_EFFECTIVE) == 1;
        try cycleMode(app, shift_active or sym == c.XKB_KEY_ISO_Left_Tab);
        return;
    }

    // Only meaningful on the clipboard tab (remove the selected history
    // entry) -- intercepted here rather than routed through
    // `state.handleKey` since it needs DB access and a full entry-list
    // rebuild, both backend concerns `state.zig` deliberately has no way
    // to reach.
    if (sym == c.XKB_KEY_Delete and app.mode == .clipboard) {
        try deleteSelectedClipboardEntry(app);
        return;
    }

    const event: ?core.state.KeyEvent = switch (sym) {
        c.XKB_KEY_Escape => .{ .named = .escape },
        c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => .{ .named = .enter },
        c.XKB_KEY_BackSpace => .{ .named = .backspace },
        c.XKB_KEY_Left => .{ .named = .left },
        c.XKB_KEY_Right => .{ .named = .right },
        c.XKB_KEY_Up => .{ .named = .up },
        c.XKB_KEY_Down => .{ .named = .down },
        c.XKB_KEY_Prior => .{ .named = .page_up },
        c.XKB_KEY_Next => .{ .named = .page_down },
        c.XKB_KEY_Home => .{ .named = .home },
        c.XKB_KEY_End => .{ .named = .end },
        c.XKB_KEY_Tab => .{ .named = .tab },
        c.XKB_KEY_w, c.XKB_KEY_W => if (ctrl_active) core.state.KeyEvent{ .ctrl = .w } else null,
        c.XKB_KEY_u, c.XKB_KEY_U => if (ctrl_active) core.state.KeyEvent{ .ctrl = .u } else null,
        c.XKB_KEY_n, c.XKB_KEY_N => if (ctrl_active) core.state.KeyEvent{ .ctrl = .n } else null,
        c.XKB_KEY_p, c.XKB_KEY_P => if (ctrl_active) core.state.KeyEvent{ .ctrl = .p } else null,
        else => null,
    };

    const resolved = event orelse blk: {
        if (ctrl_active) break :blk null;
        var buf: [8]u8 = undefined;
        const n = c.xkb_state_key_get_utf8(st, xkb_keycode, &buf, buf.len);
        if (n <= 0) break :blk null;
        break :blk core.state.KeyEvent{ .text = try app.allocator.dupe(u8, buf[0..@intCast(n)]) };
    } orelse return;

    dbg(app, "processKeycode: sym=0x{x} ctrl={} event_kind={t}", .{ sym, ctrl_active, std.meta.activeTag(resolved) });

    const action = try app.state.handleKey(resolved);
    dbg(app, "processKeycode: action={t} query_len={d} results={d} selected={d}", .{
        action,
        app.state.query.items.len,
        app.state.results.items.len,
        app.state.selected,
    });
    switch (action) {
        .nothing => {},
        .redraw => app.need_redraw = true,
        .accept => {
            if (app.mode == .windows) {
                // Windows mode focuses a live window instead of launching
                // something; that has to happen here, now, while the
                // Wayland connection is still open, not by handing an
                // "action" string back to main.zig to shell out. Still set
                // `accepted` (main.zig knows to skip launch() for this
                // mode) so a successful activation doesn't get treated
                // like a cancel -- both currently leave it null otherwise.
                dbg(app, "accept(windows): results={d} selected={d} window_handles={d} seat={}", .{
                    app.state.results.items.len,
                    app.state.selected,
                    app.window_handles.len,
                    app.seat != null,
                });
                if (app.state.results.items.len > 0) {
                    const idx = app.state.results.items[app.state.selected].index;
                    dbg(app, "accept(windows): idx={d}", .{idx});
                    if (idx < app.window_handles.len) {
                        if (app.seat) |seat| {
                            dbg(app, "accept(windows): activating handle", .{});
                            c.zwlr_foreign_toplevel_handle_v1_activate(app.window_handles[idx], seat);
                        }
                    }
                    // zwlr_foreign_toplevel_handle_v1.activate is a no-op
                    // on Hyprland (verified: correct handle, correct seat,
                    // matching protocol version, request flushed -- still
                    // doesn't focus anything), a known-ish gap in the
                    // wlroots-ecosystem's activate support. hyprctl is
                    // authoritative there, so use it directly when present.
                    if (app.state.selectedEntry()) |entry| {
                        focusViaHyprctl(app, entry.label, entry.subtitle orelse "");
                    }
                }
                app.accepted = if (app.state.selectedEntry()) |e|
                    try core.state.State.dupeEntry(e, app.allocator)
                else
                    null;
                app.running = false;
            } else {
                app.accepted = if (app.state.selectedEntry()) |e|
                    try core.state.State.dupeEntry(e, app.allocator)
                else
                    null;
                app.running = false;
            }
        },
        .cancel => app.running = false,
    }
}

/// Rescans entries for the next (or previous) mode and rebuilds `app.state`
/// with them, preserving the typed query. `app.mode`/`environ` being
/// non-null is the caller's contract that this is reachable (dmenu, with
/// its single fixed entry list, never wires Tab to this).
/// Best-effort: shells out to `hyprctl` to focus the window matching
/// `title`/`app_id` by its unique compositor address, when running under
/// Hyprland (detected via `HYPRLAND_INSTANCE_SIGNATURE`). No-op anywhere
/// else, and swallows all its own failures -- this is a fallback for a
/// protocol gap, not something that should ever crash the picker.
fn focusViaHyprctl(app: *App, title: []const u8, app_id: []const u8) void {
    const environ = app.environ orelse return;
    if (environ.get("HYPRLAND_INSTANCE_SIGNATURE") == null) return;

    const clients_result = std.process.run(app.allocator, app.io, .{
        .argv = &.{ "hyprctl", "-j", "clients" },
    }) catch |err| {
        dbg(app, "focusViaHyprctl: hyprctl clients failed: {t}", .{err});
        return;
    };
    if (clients_result.term != .exited or clients_result.term.exited != 0) {
        dbg(app, "focusViaHyprctl: hyprctl clients exited non-zero", .{});
        return;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, app.allocator, clients_result.stdout, .{}) catch |err| {
        dbg(app, "focusViaHyprctl: bad JSON from hyprctl: {t}", .{err});
        return;
    };
    defer parsed.deinit();
    const clients = switch (parsed.value) {
        .array => |a| a.items,
        else => return,
    };

    // Prefer an exact title+class match; a shared class (e.g. two Firefox
    // windows) is common enough that class alone would be ambiguous.
    var address: ?[]const u8 = null;
    for (clients) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const t = obj.get("title") orelse continue;
        const cl = obj.get("class") orelse continue;
        if (t != .string or cl != .string) continue;
        if (std.mem.eql(u8, t.string, title) and std.mem.eql(u8, cl.string, app_id)) {
            address = (obj.get("address") orelse continue).string;
            break;
        }
    }
    if (address == null) {
        for (clients) |item| {
            const obj = switch (item) {
                .object => |o| o,
                else => continue,
            };
            const cl = obj.get("class") orelse continue;
            if (cl != .string or !std.mem.eql(u8, cl.string, app_id)) continue;
            address = (obj.get("address") orelse continue).string;
            break;
        }
    }
    const addr = address orelse {
        dbg(app, "focusViaHyprctl: no client matched title={s} class={s}", .{ title, app_id });
        return;
    };

    const target = std.fmt.allocPrint(app.allocator, "address:{s}", .{addr}) catch return;
    const dispatch_result = std.process.run(app.allocator, app.io, .{
        .argv = &.{ "hyprctl", "dispatch", "focuswindow", target },
    }) catch |err| {
        dbg(app, "focusViaHyprctl: dispatch failed: {t}", .{err});
        return;
    };
    dbg(app, "focusViaHyprctl: focused {s} (term={t})", .{ addr, dispatch_result.term });
}

fn cycleMode(app: *App, backward: bool) !void {
    const current = app.mode.?;
    const next_mode = if (backward) current.prev() else current.next();
    const environ = app.environ.?;

    app.window_handles = &.{};
    const entries: []const core.state.Entry = switch (next_mode) {
        .drun => core.sources.desktop.scan(app.allocator, app.io, environ, app.terminal_cmd) catch |err| {
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

    app.mode = next_mode;
    // Clipboard rows aren't drawn by `drawRows` at all (see
    // `render.zig`'s `drawClipboardSplit`, which always uses the tall
    // 48px row height) -- `compact_rows` only matters here for
    // `Theme.visibleRows()`'s scroll/paging math, which must agree with
    // whatever row height that split view actually uses.
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

    // Must run after the `compact_rows`/`active_tab` assignments above,
    // not before: `visibleRows()` reads `compact_rows`, and computing it
    // off the *previous* tab's value left scroll/paging one switch behind
    // (harmless when every tab used the same row height, load-bearing now
    // that clipboard's split view has its own).
    const query = try app.allocator.dupe(u8, app.state.query.items);
    app.state.deinit();
    app.state = try core.state.State.init(app.allocator, entries);
    try app.state.setQuery(query);
    app.state.visible_rows = app.theme.visibleRows();
    app.state.browser = app.theme.browser_cmd;

    app.need_redraw = true;
    dbg(app, "cycleMode: switched to {t}, {d} entries", .{ next_mode, entries.len });
}

/// Deletes the currently selected clipboard-tab entry (the Del key) and
/// rebuilds `app.state` with the refreshed history, same shape as
/// `cycleMode`'s rebuild but without switching modes. No-op if nothing's
/// selected or the accept marker can't be parsed.
fn deleteSelectedClipboardEntry(app: *App) !void {
    const entry = app.state.selectedEntry() orelse return;
    const marker = entry.action orelse return;
    const id = core.clipboard.parseMarker(marker) catch |err| {
        dbg(app, "deleteSelectedClipboardEntry: bad marker {s}: {t}", .{ marker, err });
        return;
    };

    const environ = app.environ.?;
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
    const query = try app.allocator.dupe(u8, app.state.query.items);
    app.state.deinit();
    app.state = try core.state.State.init(app.allocator, entries);
    try app.state.setQuery(query);
    app.state.visible_rows = app.theme.visibleRows();
    app.state.browser = app.theme.browser_cmd;

    app.need_redraw = true;
    dbg(app, "deleteSelectedClipboardEntry: deleted id={d}, {d} entries left", .{ id, entries.len });
}

/// Snapshots the live `app.toplevels` list into entries, filling
/// `app.window_handles` in the same order so `.accept` can look up which
/// handle to activate. Closed toplevels are dropped (and freed) here
/// rather than immediately on the `closed` event, since that event can
/// arrive while this isn't the active mode.
fn buildWindowEntries(app: *App) ![]core.state.Entry {
    var entries: std.ArrayList(core.state.Entry) = .empty;
    var handles: std.ArrayList(*c.zwlr_foreign_toplevel_handle_v1) = .empty;

    var write: usize = 0;
    for (app.toplevels.items) |t| {
        if (t.closed) {
            app.allocator.free(t.title);
            app.allocator.free(t.app_id);
            app.allocator.destroy(t);
            continue;
        }
        app.toplevels.items[write] = t;
        write += 1;

        const title = if (t.title.len > 0) t.title else "(untitled)";
        try entries.append(app.allocator, .{
            .label = title,
            .subtitle = t.app_id,
            .icon_name = if (t.app_id.len > 0) t.app_id else null,
        });
        try handles.append(app.allocator, t.handle);
    }
    app.toplevels.shrinkRetainingCapacity(write);

    app.window_handles = try handles.toOwnedSlice(app.allocator);
    return entries.toOwnedSlice(app.allocator);
}

// ---------------------------------------------------------------------
// Clipboard daemon: `zofi --clipboard-daemon`. A separate, long-running
// Wayland client -- no layer-shell surface, no rendering, no keyboard grab
// -- that listens for clipboard changes via zwlr_data_control_manager_v1
// and writes them into core.clipboard's SQLite history. Meant to be
// started once (e.g. by a systemd --user unit, see
// contrib/systemd/zofi-clipboard.service), not spawned per zofi launch.
// Deliberately its own minimal connect/registry/dispatch loop rather than
// reusing App/eventLoop above: there's no surface to configure, no frames
// to present, and nothing else to poll for.

const ClipboardDaemon = struct {
    allocator: std.mem.Allocator,
    io: Io,
    display: *c.wl_display,
    debug: bool,
    manager: ?*c.zwlr_data_control_manager_v1 = null,
    seat: ?*c.wl_seat = null,
    db: core.clipboard.Db = undefined,
};

fn dbgDaemon(d: *const ClipboardDaemon, comptime fmt: []const u8, args: anytype) void {
    if (!d.debug) return;
    std.debug.print(fmt ++ "\n", args);
}

pub fn runClipboardDaemon(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, debug: bool) !void {
    const display = c.wl_display_connect(null) orelse return error.NoWaylandDisplay;
    defer c.wl_display_disconnect(display);
    const registry = c.wl_display_get_registry(display) orelse return error.NoRegistry;

    var d: ClipboardDaemon = .{ .allocator = allocator, .io = io, .display = display, .debug = debug };
    _ = c.wl_registry_add_listener(registry, &clip_registry_listener, &d);
    if (c.wl_display_roundtrip(display) == -1) return error.RoundtripFailed;

    const manager = d.manager orelse return error.NoDataControlManager;
    const seat = d.seat orelse return error.NoSeat;

    d.db = try core.clipboard.open(allocator, io, environ);
    defer d.db.close();

    const device = c.zwlr_data_control_manager_v1_get_data_device(manager, seat) orelse return error.NoDataDevice;
    _ = c.zwlr_data_control_device_v1_add_listener(device, &clip_device_listener, &d);

    dbgDaemon(&d, "clipboard daemon: listening", .{});
    while (true) {
        if (c.wl_display_dispatch(display) == -1) return error.DispatchFailed;
    }
}

const clip_registry_listener: c.wl_registry_listener = .{
    .global = clipRegistryGlobal,
    .global_remove = registryGlobalRemove,
};

fn clipRegistryGlobal(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    const d: *ClipboardDaemon = @ptrCast(@alignCast(data.?));
    const iface = std.mem.span(interface);
    dbgDaemon(d, "clipboard daemon: registryGlobal: {s} v{d}", .{ iface, version });

    if (std.mem.eql(u8, iface, std.mem.span(c.wl_seat_interface.name))) {
        d.seat = @ptrCast(@alignCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, @min(version, 7)).?));
    } else if (std.mem.eql(u8, iface, std.mem.span(c.zwlr_data_control_manager_v1_interface.name))) {
        d.manager = @ptrCast(@alignCast(c.wl_registry_bind(registry, name, &c.zwlr_data_control_manager_v1_interface, @min(version, 2)).?));
    }
}

const clip_device_listener: c.zwlr_data_control_device_v1_listener = .{
    .data_offer = clipDataOffer,
    .selection = clipSelection,
    .finished = clipDeviceFinished,
    .primary_selection = clipPrimarySelection,
};

/// Accumulates one selection's advertised mime types (`offer` events)
/// between the `data_offer` event that creates it and the `selection`
/// event that says "this one's now current" -- see clipSelection.
const OfferCtx = struct {
    daemon: *ClipboardDaemon,
    mime_types: std.ArrayList([]u8) = .empty,
};

fn clipDataOffer(data: ?*anyopaque, device: ?*c.zwlr_data_control_device_v1, id: ?*c.zwlr_data_control_offer_v1) callconv(.c) void {
    _ = device;
    const d: *ClipboardDaemon = @ptrCast(@alignCast(data.?));
    const ctx = d.allocator.create(OfferCtx) catch return;
    ctx.* = .{ .daemon = d };
    _ = c.zwlr_data_control_offer_v1_add_listener(id, &clip_offer_listener, ctx);
}

const clip_offer_listener: c.zwlr_data_control_offer_v1_listener = .{ .offer = clipOfferMime };

fn clipOfferMime(data: ?*anyopaque, offer: ?*c.zwlr_data_control_offer_v1, mime_type: [*c]const u8) callconv(.c) void {
    _ = offer;
    const ctx: *OfferCtx = @ptrCast(@alignCast(data.?));
    const dup = ctx.daemon.allocator.dupe(u8, std.mem.span(mime_type)) catch return;
    ctx.mime_types.append(ctx.daemon.allocator, dup) catch return;
}

fn clipSelection(data: ?*anyopaque, device: ?*c.zwlr_data_control_device_v1, id: ?*c.zwlr_data_control_offer_v1) callconv(.c) void {
    _ = device;
    const d: *ClipboardDaemon = @ptrCast(@alignCast(data.?));
    const offer = id orelse return; // clipboard cleared, nothing to capture

    const ctx: *OfferCtx = @ptrCast(@alignCast(c.wl_proxy_get_user_data(@ptrCast(offer))));
    defer {
        for (ctx.mime_types.items) |m| d.allocator.free(m);
        ctx.mime_types.deinit(d.allocator);
        d.allocator.destroy(ctx);
        c.zwlr_data_control_offer_v1_destroy(offer);
    }

    const mime = pickMime(ctx.mime_types.items) orelse {
        dbgDaemon(d, "clipboard daemon: no usable mime type offered, skipping", .{});
        return;
    };

    const content = receiveOffer(d, offer, mime) catch |err| {
        dbgDaemon(d, "clipboard daemon: receive failed: {t}", .{err});
        return;
    };
    defer d.allocator.free(content);

    core.clipboard.insert(d.allocator, d.db, mime, content) catch |err| {
        dbgDaemon(d, "clipboard daemon: insert failed: {t}", .{err});
    };
}

fn clipDeviceFinished(data: ?*anyopaque, device: ?*c.zwlr_data_control_device_v1) callconv(.c) void {
    _ = .{ data, device };
}

fn clipPrimarySelection(data: ?*anyopaque, device: ?*c.zwlr_data_control_device_v1, id: ?*c.zwlr_data_control_offer_v1) callconv(.c) void {
    _ = .{ data, device };
    // Not tracked -- the primary selection (X11-style select-to-copy)
    // fires far more often than deliberate copies and isn't history-worthy
    // the way Ctrl+C/Ctrl+V is.
    if (id) |offer| c.zwlr_data_control_offer_v1_destroy(offer);
}

/// Text first (any of the common encodings), then the image types the
/// clipboard tab's preview knows how to size -- anything else (e.g. an
/// offer that's only `text/uri-list`, common for file-manager copies) is
/// deliberately skipped rather than stored as an opaque blob nothing could
/// preview or usefully paste back.
fn pickMime(mime_types: []const []const u8) ?[]const u8 {
    const text_prefs = [_][]const u8{ "text/plain;charset=utf-8", "text/plain", "UTF8_STRING", "STRING" };
    for (text_prefs) |want| {
        for (mime_types) |m| if (std.mem.eql(u8, m, want)) return m;
    }
    const image_prefs = [_][]const u8{ "image/png", "image/jpeg" };
    for (image_prefs) |want| {
        for (mime_types) |m| if (std.mem.eql(u8, m, want)) return m;
    }
    return null;
}

/// Blocking: creates a pipe, asks the offer to write `mime`'s content into
/// it, flushes so the source client sees the request, then reads to EOF.
/// Simplest correct approach for a daemon that has nothing else to do
/// while it waits -- see the section doc above for why this isn't folded
/// into a poll loop the way the launcher's eventLoop is.
fn receiveOffer(d: *ClipboardDaemon, offer: *c.zwlr_data_control_offer_v1, mime: []const u8) ![]u8 {
    var fds: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&fds, .{})) != .SUCCESS) return error.PipeFailed;
    const read_fd = fds[0];
    const write_fd = fds[1];

    const mime_z = try d.allocator.dupeZ(u8, mime);
    defer d.allocator.free(mime_z);
    c.zwlr_data_control_offer_v1_receive(offer, mime_z.ptr, write_fd);
    _ = linux.close(write_fd);
    _ = c.wl_display_flush(d.display);

    defer _ = linux.close(read_fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(d.allocator);
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = posix.read(read_fd, &buf) catch break;
        if (n == 0) break;
        try out.appendSlice(d.allocator, buf[0..n]);
    }
    return out.toOwnedSlice(d.allocator);
}
