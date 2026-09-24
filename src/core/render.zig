//! Draws the whole UI into a z2d surface at a given scale. Knows about
//! queries, entries and scores; backends only call `render` and copy pixels.
const std = @import("std");
const Io = std.Io;
const z2d = @import("z2d");
const Theme = @import("theme.zig").Theme;
const State = @import("state.zig").State;

pub const Size = struct { width: f64, height: f64 };

/// Logical (pre-scale) window size the backend should request/create.
pub fn size(theme: *const Theme) Size {
    return .{ .width = theme.panel_width, .height = theme.panelHeight() };
}

pub fn render(
    io: Io,
    alloc: std.mem.Allocator,
    surface: *z2d.Surface,
    theme: *const Theme,
    state: *State,
    scale: f64,
) !void {
    var ctx = z2d.Context.init(io, alloc, surface);
    defer ctx.deinit();

    if (theme.font_path) |path| {
        ctx.setFontToFile(path) catch {};
    }

    const width = theme.panel_width * scale;
    const height = theme.panelHeight() * scale;
    const radius = theme.corner_radius * scale;
    const padding = theme.padding * scale;
    const row_h = theme.row_height * scale;
    const font_size = theme.font_size * scale;
    const char_w = theme.approxCharWidth() * scale;

    ctx.setAntiAliasingMode(.default);
    ctx.setSourceToPixel(theme.background);
    try roundedRect(&ctx, 0, 0, width, height, radius);
    try ctx.fill();
    ctx.resetPath();

    ctx.setFontSize(font_size);

    const prompt = "> ";
    const text_baseline_y = padding + (row_h - font_size) / 2;
    ctx.setSourceToPixel(theme.dim_text);
    try ctx.showText(prompt, padding, text_baseline_y);
    ctx.resetPath();

    // char_w is deliberately biased wide (see approxCharWidth) so long
    // labels truncate instead of overflowing. That bias is wrong for this
    // specific, fixed, narrow literal -- using it here left a visible gap
    // before the cursor. This constant is tuned by eye, not measured.
    const prompt_w = font_size * 0.95;

    // The query has no natural truncation point like a label does (the
    // cursor is always at the end, and that's the part the user needs to
    // see), so instead of cutting it off, drop codepoints off the *front*
    // once it's too long to fit -- like a shell prompt scrolling left.
    const query_avail_px = width - padding - (padding + prompt_w);
    const max_query_chars: usize = if (char_w > 0) @intFromFloat(@max(0.0, query_avail_px / char_w)) else 0;
    const total_chars = std.unicode.utf8CountCodepoints(state.query.items) catch state.query.items.len;
    var display_query = state.query.items;
    var shown_chars = total_chars;
    if (max_query_chars > 0 and total_chars > max_query_chars) {
        shown_chars = max_query_chars;
        var skip = total_chars - max_query_chars;
        var start: usize = 0;
        while (skip > 0) : (skip -= 1) {
            start += std.unicode.utf8ByteSequenceLength(state.query.items[start]) catch 1;
        }
        display_query = state.query.items[start..];
    }

    ctx.setSourceToPixel(theme.text);
    try ctx.showText(display_query, padding + prompt_w, text_baseline_y);
    ctx.resetPath();

    // Hairline strokes centered on a coordinate that lands exactly between
    // two pixel rows/columns split their antialiased coverage ~50/50 across
    // both, which combined with a low-contrast color can wash out to
    // nothing after any recompression. Filled, pixel-snapped rects instead
    // of `stroke()` sidestep that entirely.
    const cursor_x = @floor(padding + prompt_w + @as(f64, @floatFromInt(shown_chars)) * char_w);
    const line_px = @max(1.0, scale);
    ctx.setSourceToPixel(theme.text);
    try fillRect(&ctx, cursor_x, padding + row_h * 0.15, line_px, row_h * 0.7);
    ctx.resetPath();

    const sep_y = @floor(padding + row_h);
    ctx.setSourceToPixel(theme.separator);
    try fillRect(&ctx, padding, sep_y, width - padding * 2, line_px);
    ctx.resetPath();

    const rows_top = sep_y + scale;
    const visible = @min(theme.visible_rows, state.results.items.len -| state.scroll);

    for (0..visible) |row_i| {
        const result_i = state.scroll + row_i;
        const result = state.results.items[result_i];
        const entry = state.entries[result.index];
        const row_y = rows_top + @as(f64, @floatFromInt(row_i)) * row_h;

        if (result_i == state.selected) {
            ctx.setSourceToPixel(theme.selected_row);
            try ctx.moveTo(padding * 0.5, row_y);
            try ctx.lineTo(width - padding * 0.5, row_y);
            try ctx.lineTo(width - padding * 0.5, row_y + row_h);
            try ctx.lineTo(padding * 0.5, row_y + row_h);
            try ctx.closePath();
            try ctx.fill();
            ctx.resetPath();
        }

        const avail_px = width - padding * 2;
        const max_chars: usize = if (char_w > 0) @intFromFloat(@max(0.0, avail_px / char_w)) else 0;
        var label = entry.label;
        var truncated = false;
        if (max_chars > 1 and label.len > max_chars) {
            label = label[0 .. max_chars - 1];
            truncated = true;
        }

        const label_y = row_y + (row_h - font_size) / 2;
        ctx.setSourceToPixel(if (result_i == state.selected) theme.accent else theme.text);
        try ctx.showText(label, padding, label_y);
        ctx.resetPath();
        if (truncated) {
            try ctx.showText("\xE2\x80\xA6", width - padding - char_w, label_y); // "…"
            ctx.resetPath();
        }
    }
}

fn fillRect(ctx: *z2d.Context, x: f64, y: f64, w: f64, h: f64) !void {
    try ctx.moveTo(x, y);
    try ctx.lineTo(x + w, y);
    try ctx.lineTo(x + w, y + h);
    try ctx.lineTo(x, y + h);
    try ctx.closePath();
    try ctx.fill();
}

fn roundedRect(ctx: *z2d.Context, x: f64, y: f64, w: f64, h: f64, r: f64) !void {
    const rr = @min(r, @min(w, h) / 2);
    const half_pi = std.math.pi / 2.0;
    try ctx.moveTo(x + rr, y);
    try ctx.lineTo(x + w - rr, y);
    try ctx.arc(x + w - rr, y + rr, rr, -half_pi, 0);
    try ctx.lineTo(x + w, y + h - rr);
    try ctx.arc(x + w - rr, y + h - rr, rr, 0, half_pi);
    try ctx.lineTo(x + rr, y + h);
    try ctx.arc(x + rr, y + h - rr, rr, half_pi, std.math.pi);
    try ctx.lineTo(x, y + rr);
    try ctx.arc(x + rr, y + rr, rr, std.math.pi, std.math.pi + half_pi);
    try ctx.closePath();
}
