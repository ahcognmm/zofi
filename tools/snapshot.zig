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
    theme.font_path = try font_mod.findDefault(arena, io);
    state.visible_rows = theme.visibleRows();

    for ([_]f64{ 1, 2 }) |scale| {
        const w: i32 = @intFromFloat(theme.panel_width * scale);
        const h: i32 = @intFromFloat(theme.panel_height * scale);
        var surface = try z2d.Surface.init(.image_surface_rgba, arena, w, h);

        try render_mod.render(io, arena, &surface, &theme, &state, scale, null, null, null);

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

        try render_mod.render(io, arena, &surface, &dash_theme, &dash_state, scale, null, environ, null);

        var buf: [64]u8 = undefined;
        const filename = try std.fmt.bufPrint(&buf, "zofi-snapshot-dashboard@{d}x.png", .{@as(u32, @intFromFloat(scale))});
        try z2d.png_exporter.writeToPNGFile(io, surface, filename, .{});
        std.log.info("wrote {s} ({d}x{d})", .{ filename, w, h });
    }

    // Clipboard tab: split list + preview pane. Inserts synthetic rows of
    // every kind (image/color/link/text) into an isolated temp db -- never
    // the real `$XDG_CACHE_HOME/zofi/clipboard.db` -- so this tool never
    // pollutes an actual user's clipboard history.
    const clip_mod = core.clipboard;
    const clip_db = try clip_mod.openAt(arena, io, "/tmp/zofi-snapshot-clipboard.db");

    {
        var img_surface = try z2d.Surface.init(.image_surface_rgba, arena, 64, 48);
        var img_ctx = z2d.Context.init(io, arena, &img_surface);
        defer img_ctx.deinit();
        img_ctx.setSourceToPixel(.{ .rgba = (z2d.pixel.RGBA{ .r = 0x3D, .g = 0x5F, .b = 0x8F, .a = 255 }).multiply() });
        try core.ui.shapes.fillRect(&img_ctx, 0, 0, 64, 48);
        img_ctx.resetPath();
        img_ctx.setSourceToPixel(.{ .rgba = (z2d.pixel.RGBA{ .r = 0xF0, .g = 0xB4, .b = 0x4C, .a = 255 }).multiply() });
        try core.ui.shapes.fillRect(&img_ctx, 8, 8, 32, 24);
        img_ctx.resetPath();

        const tmp_png_path = "/tmp/zofi-snapshot-clip-source.png";
        try z2d.png_exporter.writeToPNGFile(io, img_surface, tmp_png_path, .{});
        const png_bytes = try Io.Dir.cwd().readFileAlloc(io, tmp_png_path, arena, .unlimited);
        try clip_mod.insert(arena, clip_db, "image/png", png_bytes);
    }
    try clip_mod.insert(arena, clip_db, "text/plain;charset=utf-8", "#f0b44c");
    try clip_mod.insert(arena, clip_db, "text/plain;charset=utf-8", "https://z2d.vancluevertech.com/docs");
    try clip_mod.insert(
        arena,
        clip_db,
        "text/plain;charset=utf-8",
        "On Wayland the clipboard belongs to the app that copied it, so history needs a small daemon that watches the data-control protocol and saves each entry before that app closes.",
    );

    const clip_rows = try clip_mod.list(arena, clip_db);
    var clip_entries = try arena.alloc(state_mod.Entry, clip_rows.len);
    for (clip_rows, 0..) |row, i| {
        clip_entries[i] = .{
            .label = row.preview,
            .action = try std.fmt.allocPrint(arena, "clipboard:{d}", .{row.id}),
            .is_clipboard_marker = true,
        };
    }

    var clip_state = try state_mod.State.init(arena, clip_entries);
    var clip_theme = theme;
    clip_theme.dashboard_enabled = false;
    clip_theme.active_tab = .clipboard;
    clip_theme.compact_rows = false;
    clip_state.visible_rows = clip_theme.visibleRows();

    var clip_preview_cache = clip_mod.PreviewCache{};
    clip_preview_cache.attach(clip_db);

    for ([_]f64{ 1, 2 }) |scale| {
        const w: i32 = @intFromFloat(clip_theme.panel_width * scale);
        const h: i32 = @intFromFloat(clip_theme.panel_height * scale);
        var surface = try z2d.Surface.init(.image_surface_rgba, arena, w, h);

        try render_mod.render(io, arena, &surface, &clip_theme, &clip_state, scale, null, environ, &clip_preview_cache);

        var buf: [64]u8 = undefined;
        const filename = try std.fmt.bufPrint(&buf, "zofi-snapshot-clipboard@{d}x.png", .{@as(u32, @intFromFloat(scale))});
        try z2d.png_exporter.writeToPNGFile(io, surface, filename, .{});
        std.log.info("wrote {s} ({d}x{d})", .{ filename, w, h });
    }
}
