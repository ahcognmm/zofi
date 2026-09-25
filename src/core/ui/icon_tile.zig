//! A square tile showing either a real freedesktop icon or a colored
//! rounded-rect background with the entry's first letter, uppercased --
//! the fallback used whenever an icon can't be resolved/decoded (see
//! `icon.zig`'s doc comment). Used by any row-like list of named,
//! icon-bearing things (Apps/Windows rows, the dashboard's Recent strip).
const std = @import("std");
const z2d = @import("z2d");
const Theme = @import("../theme.zig").Theme;
const theme_mod = @import("../theme.zig");
const icon_mod = @import("../icon.zig");
const layout = @import("layout.zig");
const shapes = @import("shapes.zig");
const image = @import("image.zig");

pub const IconTile = struct {
    /// Resolved real icon, if any -- `null` draws the fallback tile.
    icon: ?icon_mod.Icon,
    /// Used to pick the fallback letter when `icon` is null.
    label: []const u8,
    /// Picks a stable fallback color from `theme.icon_palette` -- an
    /// entry's original (unsorted/unfiltered) index, so its tile color
    /// doesn't jump around as a query narrows results.
    color_index: usize,
    radius: f64,
    letter_font_size: f64,

    pub fn draw(self: IconTile, ctx: *z2d.Context, surface: *z2d.Surface, rect: layout.Rect) !void {
        if (self.icon) |img| {
            (image.Image{ .icon = img }).draw(surface, rect);
            return;
        }

        ctx.setSourceToPixel(theme_mod.icon_palette[self.color_index % theme_mod.icon_palette.len]);
        try shapes.roundedRect(ctx, rect.x, rect.y, rect.w, rect.h, self.radius);
        try ctx.fill();
        ctx.resetPath();

        if (self.label.len == 0) return;
        ctx.setFontSize(self.letter_font_size);
        ctx.setSourceToPixel(.{ .rgba = (z2d.pixel.RGBA{ .r = 255, .g = 255, .b = 255, .a = 255 }).multiply() });
        var upper_buf: [4]u8 = undefined;
        const first_len = std.unicode.utf8ByteSequenceLength(self.label[0]) catch 1;
        const letter = std.ascii.upperString(&upper_buf, self.label[0..@min(first_len, self.label.len)]);
        const letter_w = Theme.charWidth(self.letter_font_size);
        try ctx.showText(letter, rect.x + (rect.w - letter_w) / 2, rect.y + (rect.h - self.letter_font_size) / 2);
        ctx.resetPath();
    }
};

test "fallback tile paints its palette color and the uppercased first letter's glyph" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var surface = try z2d.Surface.init(.image_surface_argb, std.testing.allocator, 20, 20);
    defer surface.deinit(std.testing.allocator);
    var ctx = z2d.Context.init(io, std.testing.allocator, &surface);
    defer ctx.deinit();

    const tile: IconTile = .{ .icon = null, .label = "firefox", .color_index = 0, .radius = 4, .letter_font_size = 8 };
    try tile.draw(&ctx, &surface, .{ .x = 0, .y = 0, .w = 20, .h = 20 });

    // icon_palette[0] is hex 0x3D5F8F, fully opaque -- checked by channel
    // rather than comparing whole `Pixel` unions, since filling onto an
    // ARGB surface stores the composited result tagged `.argb`, not the
    // source color's original `.rgba` tag.
    const painted = surface.getPixel(10, 1).?.argb;
    try std.testing.expectEqual(@as(u8, 255), painted.a);
    try std.testing.expectEqual(@as(u8, 0x3D), painted.r);
    try std.testing.expectEqual(@as(u8, 0x5F), painted.g);
    try std.testing.expectEqual(@as(u8, 0x8F), painted.b);
}

test "a real icon draws via Image instead of the fallback tile" {
    var surface = try z2d.Surface.init(.image_surface_argb, std.testing.allocator, 4, 4);
    defer surface.deinit(std.testing.allocator);

    const red = z2d.pixel.ARGB{ .a = 255, .r = 255, .g = 0, .b = 0 };
    const pixels = [_]z2d.pixel.ARGB{ red, red, red, red };
    const icon = icon_mod.Icon{ .width = 2, .height = 2, .pixels = &pixels };

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var ctx = z2d.Context.init(threaded.io(), std.testing.allocator, &surface);
    defer ctx.deinit();

    const tile: IconTile = .{ .icon = icon, .label = "x", .color_index = 0, .radius = 0, .letter_font_size = 8 };
    try tile.draw(&ctx, &surface, .{ .x = 0, .y = 0, .w = 4, .h = 4 });

    try std.testing.expectEqual(red, surface.getPixel(0, 0).?.argb);
}
