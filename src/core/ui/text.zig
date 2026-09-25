//! A single line of monospace text. Knows its own natural size exactly
//! (see `layout.zig`'s doc comment on why there's no general "hug
//! content" sizing: z2d has no text-measurement API, but a true monospace
//! font makes `len * Theme.charWidth(font_size)` exact rather than
//! estimated) -- callers can size a `layout.Node` from a `Label` directly
//! instead of hand-computing that product at every call site.
const std = @import("std");
const z2d = @import("z2d");
const Theme = @import("../theme.zig").Theme;
const layout = @import("layout.zig");

pub const Label = struct {
    text: []const u8,
    font_size: f64,
    color: z2d.Pixel,

    pub fn width(self: Label) f64 {
        return @as(f64, @floatFromInt(self.text.len)) * Theme.charWidth(self.font_size);
    }

    /// A `layout.Node` sized to this label's natural extent. Still needs
    /// wiring into a parent's `.children` and a `layout.layout()` call
    /// before `.result` (and thus `draw`) makes sense.
    pub fn sizedNode(self: Label) layout.Node {
        return .{ .width = .{ .fixed = self.width() }, .height = .{ .fixed = self.font_size } };
    }

    /// `rect` is normally this label's own `sizedNode().result` after
    /// layout, but any rect works -- e.g. a caller centering the label
    /// inside a larger box itself (see `button.zig`).
    pub fn draw(self: Label, ctx: *z2d.Context, rect: layout.Rect) !void {
        ctx.setFontSize(self.font_size);
        ctx.setSourceToPixel(self.color);
        try ctx.showText(self.text, rect.x, rect.y);
        ctx.resetPath();
    }

    /// Clips to whatever fits `rect.w`, no ellipsis -- matches the
    /// existing weather-card truncation behavior in render.zig (silent
    /// clipping reads better than "Ho Chi Minh Ci…" in a narrow card).
    pub fn drawClipped(self: Label, ctx: *z2d.Context, rect: layout.Rect) !void {
        const char_w = Theme.charWidth(self.font_size);
        if (char_w <= 0) return self.draw(ctx, rect);
        const max_chars: usize = @intFromFloat(@max(0.0, rect.w / char_w));
        var clipped = self;
        clipped.text = if (self.text.len > max_chars) self.text[0..max_chars] else self.text;
        try clipped.draw(ctx, rect);
    }
};

test "width is exact for monospace text (no measurement needed)" {
    const l = Label{ .text = "12:34", .font_size = 20, .color = undefined };
    try std.testing.expectEqual(@as(f64, 5 * 20 * 0.6), l.width());
}

test "sizedNode carries the label's natural size as fixed dimensions" {
    const l = Label{ .text = "abc", .font_size = 10, .color = undefined };
    const node = l.sizedNode();
    try std.testing.expectEqual(layout.Size{ .fixed = 3 * 10 * 0.6 }, node.width);
    try std.testing.expectEqual(layout.Size{ .fixed = 10 }, node.height);
}
