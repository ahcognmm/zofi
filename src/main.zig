const std = @import("std");
const Io = std.Io;

const core = @import("core");
const wayland_backend = @import("platform/wayland/backend.zig");

const Show = enum { drun, run };

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const environ = init.environ_map;

    const args = try init.minimal.args.toSlice(arena);
    var dmenu = false;
    var show: ?Show = null;
    var query: []const u8 = "";

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
            } else {
                fatal("unknown -show mode '{s}' (expected drun or run)", .{mode});
            }
        } else {
            query = arg;
        }
    }

    if (dmenu) {
        var stdin_buffer: [64 * 1024]u8 = undefined;
        var stdin_reader = Io.File.Reader.init(.stdin(), io, &stdin_buffer);
        const entries = try core.sources.stdin.readEntries(arena, &stdin_reader.interface);
        try runDmenu(arena, io, entries);
        return;
    }

    if (show) |mode| {
        const entries = switch (mode) {
            .drun => try core.sources.desktop.scan(arena, io, environ, environ.get("TERMINAL") orelse "xterm"),
            .run => try core.sources.path.scan(arena, io, environ),
        };
        try runLauncher(arena, io, environ, entries);
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
    theme.font_path = (try core.font.find(arena, io, &.{ "DejaVuSans", "Inter", "Noto", "Liberation" })) orelse
        (try core.font.fcMatch(arena, io, "sans-serif")) orelse
        (try core.font.findAny(arena, io));
    return theme;
}

/// Real windowed mode: `ls | zofi -dmenu`. Prints the chosen entry to
/// stdout and exits 0 on accept, or exits 1 on cancel/close, matching
/// rofi's `-dmenu` contract.
fn runDmenu(arena: std.mem.Allocator, io: Io, entries: []const core.state.Entry) !void {
    const theme = try defaultTheme(arena, io);
    const chosen = try wayland_backend.run(arena, io, theme, entries);
    const entry = chosen orelse std.process.exit(1);

    var stdout_buffer: [4 * 1024]u8 = undefined;
    var stdout_writer = Io.File.Writer.init(.stdout(), io, &stdout_buffer);
    const w = &stdout_writer.interface;
    try w.print("{s}\n", .{entry.action orelse entry.label});
    try w.flush();
}

/// `-show drun|run`: launches the chosen entry's action directly instead of
/// printing it, matching rofi's application-launcher modes.
fn runLauncher(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, entries: []const core.state.Entry) !void {
    const theme = try defaultTheme(arena, io);
    const chosen = try wayland_backend.run(arena, io, theme, entries);
    const entry = chosen orelse std.process.exit(1);

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
