//! An optional rounded-rect background behind a centered `text.Label` --
//! e.g. the footer's "Enter"/"Tab"/"Esc" key caps, or a future clickable
//! action row. Not yet wired into any existing screen (see this
//! directory's other files' doc comments for why).
const z2d = @import("z2d");
const layout = @import("layout.zig");
const shapes = @import("shapes.zig");
const text = @import("text.zig");

pub const Button = struct {
    label: text.Label,
    bg: ?z2d.Pixel = null,
    radius: f64 = 4,

    /// `rect` is the button's full box; the label is centered within it.
    pub fn draw(self: Button, ctx: *z2d.Context, rect: layout.Rect) !void {
        if (self.bg) |bg| {
            ctx.setSourceToPixel(bg);
            try shapes.roundedRect(ctx, rect.x, rect.y, rect.w, rect.h, self.radius);
            try ctx.fill();
            ctx.resetPath();
        }
        const label_w = self.label.width();
        const label_rect: layout.Rect = .{
            .x = rect.x + (rect.w - label_w) / 2,
            .y = rect.y + (rect.h - self.label.font_size) / 2,
            .w = label_w,
            .h = self.label.font_size,
        };
        try self.label.draw(ctx, label_rect);
    }
};

const std = @import("std");

test "draw fills the background before drawing the label (no crash, background actually painted)" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var surface = try z2d.Surface.init(.image_surface_argb, std.testing.allocator, 20, 20);
    defer surface.deinit(std.testing.allocator);
    var ctx = z2d.Context.init(io, std.testing.allocator, &surface);
    defer ctx.deinit();

    const bg = z2d.pixel.ARGB{ .a = 255, .r = 10, .g = 20, .b = 30 };
    const btn: Button = .{
        .label = .{ .text = "Hi", .font_size = 8, .color = .{ .argb = .{ .a = 255, .r = 255, .g = 255, .b = 255 } } },
        .bg = .{ .argb = bg },
    };
    try btn.draw(&ctx, .{ .x = 0, .y = 0, .w = 20, .h = 20 });

    // A corner well inside the (unrounded-enough-here) background fill
    // should now be the button's bg color, not the surface's default.
    try std.testing.expectEqual(bg, surface.getPixel(10, 1).?.argb);
}
