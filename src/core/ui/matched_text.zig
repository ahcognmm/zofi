//! A label with a subset of codepoints (given by byte offset) rendered in
//! a highlight color -- the fuzzy-match highlighting used by Apps/Run row
//! names. Pure rendering: positions are supplied by the caller (typically
//! `fuzzy.scoreWithPositions`), this module has no matching logic or
//! dependency of its own. Truncates with an ellipsis when the label
//! doesn't fit `max_chars`.
const std = @import("std");
const z2d = @import("z2d");

pub const MatchedLabel = struct {
    text: []const u8,
    /// Byte offsets into `text` to render in `highlight` rather than `color`.
    positions: []const usize,
    font_size: f64,
    color: z2d.Pixel,
    highlight: z2d.Pixel,
    /// Ellipsis color when truncated.
    faint: z2d.Pixel,

    /// `char_w` is the font's per-character advance (exact for a true
    /// monospace font -- see `theme.zig`'s `charWidth`), which is what
    /// makes drawing this as several sequential single-codepoint
    /// `showText` calls butt together correctly instead of drifting.
    pub fn draw(self: MatchedLabel, ctx: *z2d.Context, x: f64, y: f64, char_w: f64, max_chars: usize) !void {
        var label = self.text;
        var truncated = false;
        if (max_chars > 1 and label.len > max_chars) {
            // Byte length vs. character budget: walk codepoints rather than
            // slicing at a raw byte offset, which can land mid-sequence and
            // hand `showText` a truncated multi-byte tail (z2d's
            // `InvalidSequence`) whenever `label` has non-ASCII text -- a
            // window title, say.
            var end: usize = 0;
            var count: usize = 0;
            while (end < label.len and count < max_chars - 1) : (count += 1) {
                end += std.unicode.utf8ByteSequenceLength(label[end]) catch 1;
            }
            label = label[0..end];
            truncated = true;
        }

        ctx.setFontSize(self.font_size);
        var cx = x;
        var byte_i: usize = 0;
        while (byte_i < label.len) {
            const cp_len = std.unicode.utf8ByteSequenceLength(label[byte_i]) catch 1;
            const end = @min(byte_i + cp_len, label.len);
            ctx.setSourceToPixel(if (containsPos(self.positions, byte_i)) self.highlight else self.color);
            try ctx.showText(label[byte_i..end], cx, y);
            ctx.resetPath();
            cx += char_w;
            byte_i = end;
        }
        if (truncated) {
            ctx.setSourceToPixel(self.faint);
            try ctx.showText("\xE2\x80\xA6", cx, y); // "…"
            ctx.resetPath();
        }
    }
};

fn containsPos(positions: []const usize, byte_pos: usize) bool {
    for (positions) |p| {
        if (p == byte_pos) return true;
    }
    return false;
}

test "containsPos finds an exact byte offset and rejects others" {
    const positions = [_]usize{ 0, 4, 6 };
    try std.testing.expect(containsPos(&positions, 4));
    try std.testing.expect(!containsPos(&positions, 5));
}

test "draw renders every codepoint and stops (no ellipsis) when it all fits" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var surface = try z2d.Surface.init(.image_surface_argb, std.testing.allocator, 100, 20);
    defer surface.deinit(std.testing.allocator);
    var ctx = z2d.Context.init(threaded.io(), std.testing.allocator, &surface);
    defer ctx.deinit();

    const label: MatchedLabel = .{
        .text = "hi",
        .positions = &.{0},
        .font_size = 10,
        .color = .{ .argb = .{ .a = 255, .r = 1, .g = 1, .b = 1 } },
        .highlight = .{ .argb = .{ .a = 255, .r = 2, .g = 2, .b = 2 } },
        .faint = .{ .argb = .{ .a = 255, .r = 3, .g = 3, .b = 3 } },
    };
    // Just needs to not error with generous room (max_chars far exceeds
    // the text, so no truncation path).
    try label.draw(&ctx, 0, 0, 6, 50);
}
