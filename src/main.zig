const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const core = @import("core");

const is_macos = builtin.os.tag == .macos;
/// AppKit on macOS, Wayland everywhere else. Both expose the same `run`.
const backend = if (is_macos)
    @import("platform/macos/backend.zig")
else
    @import("platform/wayland/backend.zig");

const Show = core.mode.LauncherMode;

/// What a URL-shaped query gets handed to unless `$ZOFI_BROWSER` says
/// otherwise. macOS's `open` goes to the user's default browser.
const default_browser = if (is_macos) "open" else "firefox";

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const environ = init.environ_map;

    const args = try init.minimal.args.toSlice(arena);

    // Hidden: spawned detached by `core.weather.maybeRefresh` to do the
    // actual network fetch off the interactive render path. Not a
    // user-facing flag.
    if (args.len > 1 and std.mem.eql(u8, args[1], "--internal-refresh-weather")) {
        core.weather.refreshNow(arena, io, environ);
        return;
    }

    // Long-running background listener (meant to be started once, e.g. by
    // a systemd --user unit or a launchd agent -- see contrib/), not the
    // interactive launcher: no singleton lock, no window, never returns on
    // its own.
    if (args.len > 1 and std.mem.eql(u8, args[1], "--clipboard-daemon")) {
        try backend.runClipboardDaemon(arena, io, environ, environ.get("ZOFI_DEBUG") != null);
        return;
    }

    var dmenu = false;
    var show: ?Show = null;
    var rank_harness = false;
    var query: []const u8 = "";
    var dmenu_prompt: ?[]const u8 = null;
    var display_columns: ?[]usize = null;
    var display_column_separator: []const u8 = "\t";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "help")) {
            try printUsage(io);
            return;
        } else if (std.mem.eql(u8, arg, "-dmenu") or std.mem.eql(u8, arg, "--dmenu")) {
            dmenu = true;
        } else if (std.mem.eql(u8, arg, "--rank-harness")) {
            // Internal dev tool (Phase 1 ranking tuning), not documented in
            // --help: `echo -e "a\nb" | zofi --rank-harness query`. Must be
            // explicit -- bare `zofi` always means "open the launcher",
            // even when stdin isn't a tty (e.g. spawned by a compositor
            // keybind, which typically isn't one either).
            rank_harness = true;
        } else if (std.mem.eql(u8, arg, "-show") or std.mem.eql(u8, arg, "--show")) {
            i += 1;
            if (i >= args.len) fatal("-show requires an argument (drun or run)", .{});
            const mode = args[i];
            if (std.mem.eql(u8, mode, "drun")) {
                show = .drun;
            } else if (std.mem.eql(u8, mode, "run")) {
                show = .run;
            } else if (std.mem.eql(u8, mode, "windows")) {
                show = .windows;
            } else if (std.mem.eql(u8, mode, "clipboard")) {
                show = .clipboard;
            } else {
                fatal("unknown -show mode '{s}' (expected drun, run, windows or clipboard)", .{mode});
            }
        } else if (std.mem.eql(u8, arg, "-p") or std.mem.eql(u8, arg, "--p")) {
            i += 1;
            if (i >= args.len) fatal("-p requires an argument", .{});
            dmenu_prompt = args[i];
        } else if (std.mem.eql(u8, arg, "-display-columns")) {
            i += 1;
            if (i >= args.len) fatal("-display-columns requires an argument", .{});
            var cols: std.ArrayList(usize) = .empty;
            var it = std.mem.splitScalar(u8, args[i], ',');
            while (it.next()) |part| {
                const n = std.fmt.parseInt(usize, part, 10) catch fatal("-display-columns: invalid column '{s}'", .{part});
                try cols.append(arena, n);
            }
            display_columns = try cols.toOwnedSlice(arena);
        } else if (std.mem.eql(u8, arg, "-display-column-separator")) {
            i += 1;
            if (i >= args.len) fatal("-display-column-separator requires an argument", .{});
            display_column_separator = args[i];
        } else {
            query = arg;
        }
    }

    const debug = environ.get("ZOFI_DEBUG") != null;

    // Every path opens a layer-shell surface except the headless rank
    // harness, which has nothing to conflict with.
    if (dmenu or show != null) {
        if (!core.singleton.acquire(io, environ)) {
            if (debug) std.debug.print("zofi: another instance is already running, exiting\n", .{});
            return;
        }
    }

    if (dmenu) {
        var stdin_buffer: [64 * 1024]u8 = undefined;
        var stdin_reader = Io.File.Reader.init(.stdin(), io, &stdin_buffer);
        const entries = try core.sources.stdin.readEntriesWithColumns(arena, &stdin_reader.interface, .{
            .display_columns = display_columns,
            .separator = display_column_separator,
        });
        try runDmenu(arena, io, entries, debug, dmenu_prompt);
        return;
    }

    if (show) |mode| {
        const terminal_cmd = environ.get("TERMINAL") orelse "xterm";
        const entries = switch (mode) {
            .drun => try scanApps(arena, io, environ, terminal_cmd),
            .run => try core.sources.path.scan(arena, io, environ),
            // Nothing to scan up front: the backend builds the window list
            // itself inside run() (on Wayland it only exists once
            // wlr-foreign-toplevel-management is bound).
            .windows => &.{},
            .clipboard => try core.sources.clipboard.toEntries(arena, io, environ),
        };
        try runLauncher(arena, io, environ, entries, mode, terminal_cmd, debug, false);
        return;
    }

    if (rank_harness) {
        var stdin_buffer: [64 * 1024]u8 = undefined;
        var stdin_reader = Io.File.Reader.init(.stdin(), io, &stdin_buffer);
        const entries = try core.sources.stdin.readEntries(arena, &stdin_reader.interface);
        try runRankHarness(arena, io, entries, query);
        return;
    }

    // No `-dmenu`/`-show`/`--rank-harness`: bare `zofi`, however it was
    // launched (interactive terminal or a compositor keybind -- stdin
    // typically isn't a tty either way). Open the default idle dashboard --
    // the same app launcher as `-show drun`, but with the clock/calendar/
    // recents view in place of the row list until you start typing.
    if (!core.singleton.acquire(io, environ)) {
        if (debug) std.debug.print("zofi: another instance is already running, exiting\n", .{});
        return;
    }
    core.weather.maybeRefresh(arena, io, environ);
    const terminal_cmd = environ.get("TERMINAL") orelse "xterm";
    const entries = try scanApps(arena, io, environ, terminal_cmd);
    try runLauncher(arena, io, environ, entries, .drun, terminal_cmd, debug, true);
}

/// The Apps tab's entries: `.app` bundles on macOS, `.desktop` files
/// everywhere else.
fn scanApps(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, terminal_cmd: []const u8) ![]core.state.Entry {
    if (is_macos) return core.sources.macapps.scan(arena, io, environ);
    return core.sources.desktop.scan(arena, io, environ, terminal_cmd);
}

fn printUsage(io: Io) !void {
    var stdout_buffer: [4 * 1024]u8 = undefined;
    var stdout_writer = Io.File.Writer.init(.stdout(), io, &stdout_buffer);
    const w = &stdout_writer.interface;
    try w.writeAll(
        \\zofi - a rofi-style application launcher for Wayland/Hyprland and macOS
        \\
        \\Usage:
        \\  zofi                       Default: app launcher with clock/calendar/recents
        \\  zofi -show drun            Launch an application (.desktop entries, or
        \\                             .app bundles on macOS)
        \\  zofi -show run             Launch a command from $PATH
        \\  zofi -show windows         Switch between open windows
        \\  zofi -show clipboard       Pick from clipboard history, copy it back
        \\  zofi -dmenu                Pick a line from stdin, print it to stdout
        \\  echo -e "a\nb" | zofi -dmenu
        \\  zofi -h | --help | help    Show this message
        \\
        \\dmenu options (rofi-compatible):
        \\  -p TEXT                          Prompt label shown left of the input
        \\  -display-columns N[,M...]        Show only these 1-indexed columns
        \\  -display-column-separator SEP    Column separator (default: tab)
        \\
        \\Environment:
        \\  ZOFI_DEBUG=1      Verbose logging to stderr
        \\  ZOFI_BROWSER=cmd  Browser used to open URL-shaped queries (default: firefox;
        \\                    on macOS, `open`, i.e. the default browser)
        \\  TERMINAL=cmd      Terminal used to launch terminal .desktop entries
        \\
        \\Clipboard history (-show clipboard) needs a background listener
        \\running: zofi --clipboard-daemon, normally started once via
        \\systemd --user (see contrib/systemd/zofi-clipboard.service), or on
        \\macOS a launchd agent (see contrib/launchd/).
        \\
    );
    try w.flush();
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("zofi: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

fn defaultTheme(arena: std.mem.Allocator, io: Io) !core.theme.Theme {
    var theme = core.theme.Theme{};
    // A monospace font makes approxCharWidth's per-char advance estimate
    // (theme.zig) exact instead of approximate, which is what keeps the
    // cursor, truncation and query-viewport scrolling pixel-accurate.
    theme.font_path = try core.font.findDefault(arena, io);
    return theme;
}

/// Real windowed mode: `ls | zofi -dmenu`. Prints the chosen entry to
/// stdout and exits 0 on accept, or exits 1 on cancel/close, matching
/// rofi's `-dmenu` contract.
fn runDmenu(arena: std.mem.Allocator, io: Io, entries: []const core.state.Entry, debug: bool, prompt: ?[]const u8) !void {
    var theme = try defaultTheme(arena, io);
    theme.compact_rows = true;
    theme.show_tabs = false;
    theme.placeholder = "Filter";
    theme.dmenu_prompt = prompt;

    const chosen = try backend.run(arena, io, theme, entries, .{ .debug = debug });
    const entry = chosen orelse std.process.exit(1);

    var stdout_buffer: [4 * 1024]u8 = undefined;
    var stdout_writer = Io.File.Writer.init(.stdout(), io, &stdout_buffer);
    const w = &stdout_writer.interface;
    try w.print("{s}\n", .{entry.action orelse entry.label});
    try w.flush();
}

/// `-show drun|run`: launches the chosen entry's action directly instead of
/// printing it, matching rofi's application-launcher modes.
fn runLauncher(
    arena: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    entries: []const core.state.Entry,
    mode: Show,
    terminal_cmd: []const u8,
    debug: bool,
    dashboard: bool,
) !void {
    var theme = try defaultTheme(arena, io);
    theme.show_tabs = true;
    theme.browser_cmd = environ.get("ZOFI_BROWSER") orelse default_browser;
    theme.dashboard_enabled = dashboard;
    switch (mode) {
        .drun => {
            theme.compact_rows = false;
            theme.active_tab = .apps;
            theme.placeholder = "Search apps";
        },
        .run => {
            theme.compact_rows = true;
            theme.active_tab = .run;
            theme.placeholder = "Search commands";
        },
        .windows => {
            theme.compact_rows = false;
            theme.active_tab = .windows;
            theme.placeholder = "Search windows";
        },
        .clipboard => {
            // Split-pane view (render.zig's drawClipboardSplit), not the
            // compact single-line list -- see backend.zig's cycleMode for
            // why compact_rows must match whatever row height that view
            // actually uses.
            theme.compact_rows = false;
            theme.active_tab = .clipboard;
            theme.placeholder = "Search clipboard history";
        },
    }

    const chosen = try backend.run(arena, io, theme, entries, .{
        .debug = debug,
        .mode = mode,
        .environ = environ,
        .terminal_cmd = terminal_cmd,
    });
    const entry = chosen orelse std.process.exit(1);

    // Windows mode already focused the window itself, inside run(), while
    // the Wayland connection (or AppKit session) was still open -- there's
    // nothing left to shell out to here, and entry.action isn't even a
    // command.
    if (mode == .windows) return;

    // Doesn't run a command: `entry.action` is a "clipboard:<id>" marker
    // (see `sources/clipboard.zig`), not something `core.launch.launch`
    // could shell out to. Re-queries the DB for the real content and puts
    // it back on the system clipboard instead (`wl-copy` on Wayland,
    // NSPasteboard on macOS).
    if (mode == .clipboard) {
        try backend.copyToClipboard(arena, io, environ, entry.action orelse entry.label);
        return;
    }

    if (entry.is_url) {
        try core.launch.launchUrl(arena, io, environ, theme.browser_cmd, entry.action orelse entry.label);
        return;
    }
    core.history.recordLaunch(arena, io, environ, entry);
    try core.launch.launch(arena, io, environ, entry.action orelse entry.label);
}

/// Phase 1 tuning harness: pipe entries in on stdin, pass a query as the
/// first argument, print the ranked top 10 labels. No window; lets ranking
/// be tuned without a compositor.
fn runRankHarness(arena: std.mem.Allocator, io: Io, entries: []const core.state.Entry, query: []const u8) !void {
    var state = try core.state.State.init(arena, entries);
    try state.setQuery(query);

    var stdout_buffer: [4 * 1024]u8 = undefined;
    var stdout_writer = Io.File.Writer.init(.stdout(), io, &stdout_buffer);
    const w = &stdout_writer.interface;

    const n = @min(state.results.items.len, 10);
    for (state.results.items[0..n]) |r| {
        try w.print("{s}\n", .{state.entryAt(r.index).label});
    }
    try w.flush();
}

test {
    _ = backend;
}
