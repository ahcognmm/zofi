//! The magnifying-glass icon shown in the prompt row when there's no
//! dmenu `-p` prompt override.
const std = @import("std");
const z2d = @import("z2d");

pub const SearchIcon = struct {
    color: z2d.Pixel,

    /// `x` is the icon's left edge, `cy` its vertical center (letting the
    /// caller center it in a row taller than the icon itself without a
    /// full `layout.Rect` -- the glass isn't drawn centered on `size`'s
    /// own box, its handle extends past it, same as the original design).
    pub fn draw(self: SearchIcon, ctx: *z2d.Context, x: f64, cy: f64, size: f64, scale: f64) !void {
        const icon_cx = x + size * 0.4;
        const icon_r = size * 0.3;

        ctx.setSourceToPixel(self.color);
        ctx.setLineWidth(@max(1.0, 1.5 * scale));
        try ctx.arc(icon_cx, cy, icon_r, 0, std.math.pi * 2);
        try ctx.stroke();
        ctx.resetPath();

        const hx = icon_cx + icon_r * 0.7;
        const hy = cy + icon_r * 0.7;
        try ctx.moveTo(hx, hy);
        try ctx.lineTo(hx + icon_r * 0.7, hy + icon_r * 0.7);
        try ctx.stroke();
        ctx.resetPath();
    }
};

test "draw executes without error" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var surface = try z2d.Surface.init(.image_surface_argb, std.testing.allocator, 20, 20);
    defer surface.deinit(std.testing.allocator);
    var ctx = z2d.Context.init(threaded.io(), std.testing.allocator, &surface);
    defer ctx.deinit();

    const icon: SearchIcon = .{ .color = .{ .argb = .{ .a = 255, .r = 1, .g = 1, .b = 1 } } };
    try icon.draw(&ctx, 0, 10, 18, 1.0);
}
