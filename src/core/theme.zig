//! Panel geometry, colors and font. All sizes are logical (pre-scale); the
//! renderer multiplies everything by the caller's scale factor.
const z2d = @import("z2d");

fn rgba(r: u8, g: u8, b: u8, a: u8) z2d.Pixel {
    return .{ .rgba = (z2d.pixel.RGBA{ .r = r, .g = g, .b = b, .a = a }).multiply() };
}

pub const Theme = struct {
    panel_width: f64 = 640,
    padding: f64 = 16,
    row_height: f64 = 32,
    corner_radius: f64 = 12,
    font_size: f64 = 16,
    visible_rows: usize = 10,

    background: z2d.Pixel = rgba(0x1e, 0x1e, 0x2e, 0xF0),
    text: z2d.Pixel = rgba(0xcd, 0xd6, 0xf4, 0xFF),
    dim_text: z2d.Pixel = rgba(0x7f, 0x84, 0x9c, 0xFF),
    accent: z2d.Pixel = rgba(0x89, 0xb4, 0xfa, 0xFF),
    selected_row: z2d.Pixel = rgba(0x31, 0x32, 0x44, 0xFF),
    separator: z2d.Pixel = rgba(0x45, 0x47, 0x5a, 0xFF),

    /// Path to a TrueType/OpenType font file. Populated by `core/font.zig`
    /// discovery (or config) before the first render.
    font_path: ?[]const u8 = null,

    pub fn panelHeight(self: Theme) f64 {
        return self.padding * 2 + self.row_height + 1 +
            self.row_height * @as(f64, @floatFromInt(self.visible_rows));
    }

    /// Crude average-advance-width estimate, used for truncation and cursor
    /// placement since z2d doesn't yet expose text extents/shaping. Biased
    /// wide on purpose: z2d has no clip API, so underestimating here lets
    /// a long label's real (proportional-font) width overflow the window
    /// with nothing to cut it off. Overestimating just truncates a little
    /// earlier than strictly necessary, which is the safe failure mode.
    pub fn approxCharWidth(self: Theme) f64 {
        return self.font_size * 0.62;
    }
};
