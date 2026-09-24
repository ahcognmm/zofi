const std = @import("std");
const Io = std.Io;

const core = @import("core");
const wayland_backend = @import("platform/wayland/backend.zig");

const Show = wayland_backend.LauncherMode;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const environ = init.environ_map;

    const args = try init.minimal.args.toSlice(arena);
    var dmenu = false;
    var show: ?Show = null;
    var query: []const u8 = "";
    var dmenu_prompt: ?[]const u8 = null;
    var display_columns: ?[]usize = null;
    var display_column_separator: []const u8 = "\t";

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "-dmenu") or std.mem.eql(u8, arg, "--dmenu")) {
            dmenu = true;
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
            } else {
                fatal("unknown -show mode '{s}' (expected drun, run or windows)", .{mode});
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
            .drun => try core.sources.desktop.scan(arena, io, environ, terminal_cmd),
            .run => try core.sources.path.scan(arena, io, environ),
            // Nothing to scan up front: the live window list only exists
            // once wlr-foreign-toplevel-management is bound, which
            // happens inside wayland_backend.run() itself.
            .windows => &.{},
        };
        try runLauncher(arena, io, environ, entries, mode, terminal_cmd, debug);
        return;
    }

    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin_reader = Io.File.Reader.init(.stdin(), io, &stdin_buffer);
    const entries = try core.sources.stdin.readEntries(arena, &stdin_reader.interface);
    try runRankHarness(arena, io, entries, query);
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
    theme.font_path = (try core.font.fcMatch(arena, io, "monospace")) orelse
        (try core.font.find(arena, io, &.{ "DejaVuSansMono", "Mono", "Consolas", "Menlo" })) orelse
        (try core.font.find(arena, io, &.{ "DejaVuSans", "Inter", "Noto", "Liberation" })) orelse
        (try core.font.fcMatch(arena, io, "sans-serif")) orelse
        (try core.font.findAny(arena, io));
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

    const chosen = try wayland_backend.run(arena, io, theme, entries, .{ .debug = debug });
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
) !void {
    var theme = try defaultTheme(arena, io);
    theme.show_tabs = true;
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
    }

    const chosen = try wayland_backend.run(arena, io, theme, entries, .{
        .debug = debug,
        .mode = mode,
        .environ = environ,
        .terminal_cmd = terminal_cmd,
    });
    const entry = chosen orelse std.process.exit(1);

    // Windows mode already focused the window itself, inside run(), while
    // the Wayland connection was still open -- there's nothing left to
    // shell out to here, and entry.action isn't even a command.
    if (mode == .windows) return;

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
        try w.print("{s}\n", .{entries[r.index].label});
    }
    try w.flush();
}

test {
    _ = wayland_backend;
}
