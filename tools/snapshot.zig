//! Phase 2 dev tool: renders a fixed mock state to a PNG at scale 1 and
//! scale 2, so the UI can be tuned by eyeballing images before any window
//! exists. Not part of the shipped `zofi` binary.
const std = @import("std");
const Io = std.Io;
const z2d = @import("z2d");

const core = @import("core");
const theme_mod = core.theme;
const state_mod = core.state;
const render_mod = core.render;
const font_mod = core.font;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const environ = init.environ_map;

    const entries = [_]state_mod.Entry{
        .{ .label = "firefox", .subtitle = "Web Browser", .action = "/usr/bin/firefox" },
        .{ .label = "file-manager", .subtitle = "File Manager", .action = "/usr/bin/file-manager" },
        .{ .label = "fire-extinguisher-simulator", .subtitle = "Game" },
        .{ .label = "vim", .subtitle = "Text Editor" },
        .{ .label = "visual-studio-code", .subtitle = "Code Editor" },
        .{ .label = "terminal", .subtitle = "Terminal Emulator" },
        .{ .label = "gimp", .subtitle = "Image Editor" },
        .{ .label = "inkscape", .subtitle = "Vector Graphics" },
        .{ .label = "blender", .subtitle = "3D Creation Suite" },
        .{ .label = "a-very-long-application-name-that-should-truncate-nicely", .subtitle = "Truncation Test" },
        .{ .label = "spotify", .subtitle = "Music Streaming" },
    };

    var state = try state_mod.State.init(arena, &entries);
    try state.setQuery("fi");
    _ = try state.handleKey(.{ .named = .down });

    var theme = theme_mod.Theme{};
    theme.show_tabs = true;
    theme.active_tab = .apps;
    theme.font_path = (try font_mod.fcMatch(arena, io, "monospace")) orelse
        (try font_mod.find(arena, io, &.{ "DejaVuSansMono", "Mono", "Consolas", "Menlo" })) orelse
        (try font_mod.find(arena, io, &.{ "DejaVuSans", "Inter", "Noto", "Liberation" })) orelse
        (try font_mod.fcMatch(arena, io, "sans-serif")) orelse
        (try font_mod.findAny(arena, io));
    state.visible_rows = theme.visibleRows();

    for ([_]f64{ 1, 2 }) |scale| {
        const w: i32 = @intFromFloat(theme.panel_width * scale);
        const h: i32 = @intFromFloat(theme.panel_height * scale);
        var surface = try z2d.Surface.init(.image_surface_rgba, arena, w, h);

        try render_mod.render(io, arena, &surface, &theme, &state, scale, null, null);

        var buf: [64]u8 = undefined;
        const filename = try std.fmt.bufPrint(&buf, "zofi-snapshot@{d}x.png", .{@as(u32, @intFromFloat(scale))});
        try z2d.png_exporter.writeToPNGFile(io, surface, filename, .{});
        std.log.info("wrote {s} ({d}x{d})", .{ filename, w, h });
    }

    var dash_state = try state_mod.State.init(arena, &entries);
    var dash_theme = theme;
    dash_theme.dashboard_enabled = true;
    dash_theme.active_tab = .apps;
    for ([_]f64{ 1, 2 }) |scale| {
        const w: i32 = @intFromFloat(dash_theme.panel_width * scale);
        const h: i32 = @intFromFloat(dash_theme.panel_height * scale);
        var surface = try z2d.Surface.init(.image_surface_rgba, arena, w, h);

        try render_mod.render(io, arena, &surface, &dash_theme, &dash_state, scale, null, environ);

        var buf: [64]u8 = undefined;
        const filename = try std.fmt.bufPrint(&buf, "zofi-snapshot-dashboard@{d}x.png", .{@as(u32, @intFromFloat(scale))});
        try z2d.png_exporter.writeToPNGFile(io, surface, filename, .{});
        std.log.info("wrote {s} ({d}x{d})", .{ filename, w, h });
    }
}
