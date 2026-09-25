//! Composites a decoded icon into a resolved layout rect. Bypasses z2d's
//! Context/Pattern pipeline entirely -- it has no image/bitmap pattern to
//! fill a shape with -- by writing straight to the surface's pixel
//! buffer, alpha-blended with whatever's already there. Same technique as
//! render.zig's private `blitIcon`, which existing screens still call
//! directly; this is the version future views should reach for.
const std = @import("std");
const z2d = @import("z2d");
const icon_mod = @import("../icon.zig");
const layout = @import("layout.zig");

pub const Image = struct {
    icon: icon_mod.Icon,

    /// Nearest-neighbor samples into `rect` (typically square -- icons
    /// aren't designed for non-uniform scaling).
    pub fn draw(self: Image, surface: *z2d.Surface, rect: layout.Rect) void {
        const x0: i32 = @intFromFloat(@round(rect.x));
        const y0: i32 = @intFromFloat(@round(rect.y));
        const w: i32 = @intFromFloat(@round(rect.w));
        const h: i32 = @intFromFloat(@round(rect.h));
        if (w <= 0 or h <= 0) return;

        var row: i32 = 0;
        while (row < h) : (row += 1) {
            const v = (@as(f64, @floatFromInt(row)) + 0.5) / @as(f64, @floatFromInt(h));
            var col: i32 = 0;
            while (col < w) : (col += 1) {
                const u = (@as(f64, @floatFromInt(col)) + 0.5) / @as(f64, @floatFromInt(w));
                const px = self.icon.sample(u, v);
                surface.compositeStride(x0 + col, y0 + row, 1, .{ .argb = px }, .src_over, 255);
            }
        }
    }
};

test "draw composites the icon's pixels into the target rect" {
    const red = z2d.pixel.ARGB{ .a = 255, .r = 255, .g = 0, .b = 0 };
    const pixels = [_]z2d.pixel.ARGB{ red, red, red, red };
    const icon = icon_mod.Icon{ .width = 2, .height = 2, .pixels = &pixels };

    var surface = try z2d.Surface.init(.image_surface_argb, std.testing.allocator, 4, 4);
    defer surface.deinit(std.testing.allocator);

    // Untouched corner stays at the surface's zeroed (transparent) default.
    try std.testing.expectEqual(z2d.pixel.ARGB{ .a = 0, .r = 0, .g = 0, .b = 0 }, surface.getPixel(3, 3).?.argb);

    (Image{ .icon = icon }).draw(&surface, .{ .x = 0, .y = 0, .w = 2, .h = 2 });

    try std.testing.expectEqual(red, surface.getPixel(0, 0).?.argb);
    try std.testing.expectEqual(red, surface.getPixel(1, 1).?.argb);
    try std.testing.expectEqual(z2d.pixel.ARGB{ .a = 0, .r = 0, .g = 0, .b = 0 }, surface.getPixel(3, 3).?.argb);
}
