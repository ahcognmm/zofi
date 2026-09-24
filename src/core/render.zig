//! Draws the whole UI into a z2d surface at a given scale. Knows about
//! queries, entries and scores; backends only call `render` and copy pixels.
const std = @import("std");
const Io = std.Io;
const z2d = @import("z2d");
const theme_mod = @import("theme.zig");
const Theme = theme_mod.Theme;
const state_mod = @import("state.zig");
const State = state_mod.State;
const fuzzy = @import("fuzzy.zig");
const icon_mod = @import("icon.zig");

pub const Size = struct { width: f64, height: f64 };

/// Logical (pre-scale) window size the backend should request/create.
pub fn size(theme: *const Theme) Size {
    return .{ .width = theme.panel_width, .height = theme.panel_height };
}

pub fn render(
    io: Io,
    alloc: std.mem.Allocator,
    surface: *z2d.Surface,
    theme: *const Theme,
    state: *State,
    scale: f64,
    icon_cache: ?*icon_mod.Cache,
) !void {
    var ctx = z2d.Context.init(io, alloc, surface);
    defer ctx.deinit();

    if (theme.font_path) |path| ctx.setFontToFile(path) catch {};
    ctx.setAntiAliasingMode(.default);

    const width = theme.panel_width * scale;
    const height = theme.panel_height * scale;
    const padding = theme.panel_padding * scale;

    try drawPanel(&ctx, theme, width, height, scale);

    const prompt_h = theme.prompt_row_height * scale;
    try drawPrompt(&ctx, theme, state, width, padding, prompt_h, scale);
    if (theme.show_tabs) try drawTabs(&ctx, theme, width, padding, prompt_h, scale);

    const sep_y = @floor(prompt_h);
    const inset = theme.divider_inset * scale;
    ctx.setSourceToPixel(theme.border);
    try fillRect(&ctx, inset, sep_y, width - inset * 2, @max(1.0, scale));
    ctx.resetPath();

    const rows_top = sep_y + scale + theme.list_padding * scale;
    try drawRows(&ctx, surface, theme, state, width, padding, rows_top, scale, icon_cache);

    const footer_y = height - theme.footer_height * scale;
    try drawFooter(&ctx, theme, state, width, padding, footer_y, theme.footer_height * scale, scale);
}

fn drawPanel(ctx: *z2d.Context, theme: *const Theme, width: f64, height: f64, scale: f64) !void {
    const radius = theme.corner_radius * scale;
    const border_w = @max(1.0, theme.border_width * scale);

    ctx.setSourceToPixel(theme.panel_bg);
    try roundedRect(ctx, 0, 0, width, height, radius);
    try ctx.fill();
    ctx.resetPath();

    ctx.setSourceToPixel(theme.border);
    ctx.setLineWidth(border_w);
    try roundedRect(ctx, border_w * 0.5, border_w * 0.5, width - border_w, height - border_w, @max(0.0, radius - border_w * 0.5));
    try ctx.stroke();
    ctx.resetPath();
}

fn drawPrompt(ctx: *z2d.Context, theme: *const Theme, state: *State, width: f64, padding: f64, prompt_h: f64, scale: f64) !void {
    const query_fs = theme.query_font_size * scale;
    const char_w = Theme.charWidth(query_fs);
    const icon_size = theme.prompt_icon_size * scale;
    const gap = theme.prompt_gap * scale;
    ctx.setFontSize(query_fs);
    const text_y = (prompt_h - query_fs) / 2;

    var text_x = padding;
    if (theme.dmenu_prompt) |p| {
        ctx.setSourceToPixel(theme.accent);
        try ctx.showText(p, text_x, text_y);
        ctx.resetPath();
        text_x += @as(f64, @floatFromInt(p.len)) * char_w + gap;
    } else {
        const icon_cx = text_x + icon_size * 0.4;
        const icon_cy = prompt_h / 2;
        const icon_r = icon_size * 0.3;
        ctx.setSourceToPixel(theme.dim);
        ctx.setLineWidth(@max(1.0, 1.5 * scale));
        try ctx.arc(icon_cx, icon_cy, icon_r, 0, std.math.pi * 2);
        try ctx.stroke();
        ctx.resetPath();
        const hx = icon_cx + icon_r * 0.7;
        const hy = icon_cy + icon_r * 0.7;
        try ctx.moveTo(hx, hy);
        try ctx.lineTo(hx + icon_r * 0.7, hy + icon_r * 0.7);
        try ctx.stroke();
        ctx.resetPath();
        text_x += icon_size + gap;
    }

    const total_chars = std.unicode.utf8CountCodepoints(state.query.items) catch state.query.items.len;
    const cursor_char = std.unicode.utf8CountCodepoints(state.query.items[0..state.cursor]) catch state.cursor;

    if (total_chars == 0) {
        ctx.setSourceToPixel(theme.faint);
        try ctx.showText(theme.placeholder, text_x, text_y);
        ctx.resetPath();
    } else {
        // The query has no natural truncation point like a label does (the
        // cursor can be anywhere in it, and that's the part the user needs
        // to see), so instead of cutting it off, slide a window of visible
        // codepoints so it always contains the cursor -- like a shell
        // prompt scrolling to keep up with where you're typing.
        const query_avail_px = width - padding - text_x;
        const max_query_chars: usize = if (char_w > 0) @intFromFloat(@max(0.0, query_avail_px / char_w)) else 0;

        var display_query = state.query.items;
        var view_start_char: usize = 0;
        if (max_query_chars > 0 and total_chars > max_query_chars) {
            view_start_char = if (cursor_char > max_query_chars) cursor_char - max_query_chars else 0;
            const view_end_char = @min(total_chars, view_start_char + max_query_chars);

            var start_byte: usize = 0;
            for (0..view_start_char) |_| start_byte += std.unicode.utf8ByteSequenceLength(state.query.items[start_byte]) catch 1;
            var end_byte = start_byte;
            for (view_start_char..view_end_char) |_| end_byte += std.unicode.utf8ByteSequenceLength(state.query.items[end_byte]) catch 1;
            display_query = state.query.items[start_byte..end_byte];
        }

        ctx.setSourceToPixel(theme.text);
        try ctx.showText(display_query, text_x, text_y);
        ctx.resetPath();

        // Hairline strokes centered on a coordinate that lands exactly
        // between two pixel rows/columns split their antialiased coverage
        // ~50/50 across both, which can wash out to nothing after any
        // recompression. A filled, pixel-snapped rect sidesteps that.
        const cursor_x = @floor(text_x + @as(f64, @floatFromInt(cursor_char - view_start_char)) * char_w);
        ctx.setSourceToPixel(theme.text);
        try fillRect(ctx, cursor_x, prompt_h * 0.2, @max(1.0, 2 * scale), prompt_h * 0.6);
        ctx.resetPath();
        return;
    }

    const cursor_x = @floor(text_x);
    ctx.setSourceToPixel(theme.text);
    try fillRect(ctx, cursor_x, prompt_h * 0.2, @max(1.0, 2 * scale), prompt_h * 0.6);
    ctx.resetPath();
}

fn drawTabs(ctx: *z2d.Context, theme: *const Theme, width: f64, padding: f64, prompt_h: f64, scale: f64) !void {
    const labels = [_][]const u8{ "Apps", "Run", "Windows" };
    const chip_fs = theme.mode_chip_font_size * scale;
    const chip_char_w = Theme.charWidth(chip_fs);
    const chip_pad_x = theme.mode_chip_pad_x * scale;
    const chip_h = theme.mode_chip_height * scale;
    const track_pad = theme.mode_track_pad * scale;
    ctx.setFontSize(chip_fs);

    var chip_widths: [labels.len]f64 = undefined;
    var total_w: f64 = 0;
    for (labels, 0..) |l, i| {
        chip_widths[i] = @as(f64, @floatFromInt(l.len)) * chip_char_w + chip_pad_x * 2;
        total_w += chip_widths[i];
    }

    const track_w = total_w + track_pad * 2;
    const track_h = chip_h + track_pad * 2;
    const track_x = width - padding - track_w;
    const track_y = (prompt_h - track_h) / 2;

    ctx.setSourceToPixel(theme.chip_track);
    try roundedRect(ctx, track_x, track_y, track_w, track_h, theme.mode_track_radius * scale);
    try ctx.fill();
    ctx.resetPath();

    const active_idx: usize = switch (theme.active_tab) {
        .apps => 0,
        .run => 1,
        .windows => 2,
    };

    var cx = track_x + track_pad;
    for (labels, 0..) |l, i| {
        const cw = chip_widths[i];
        const chip_y = track_y + track_pad;
        if (i == active_idx) {
            ctx.setSourceToPixel(theme.chip_on);
            try roundedRect(ctx, cx, chip_y, cw, chip_h, theme.mode_chip_radius * scale);
            try ctx.fill();
            ctx.resetPath();
        }
        ctx.setSourceToPixel(if (i == active_idx) theme.text else theme.dim);
        const ly = chip_y + (chip_h - chip_fs) / 2;
        try ctx.showText(l, cx + chip_pad_x, ly);
        ctx.resetPath();
        cx += cw;
    }
}

fn drawRows(ctx: *z2d.Context, surface: *z2d.Surface, theme: *const Theme, state: *State, width: f64, padding: f64, rows_top: f64, scale: f64, icon_cache: ?*icon_mod.Cache) !void {
    const row_h = theme.rowHeight() * scale;
    const row_gap = theme.list_row_gap * scale;
    const row_pad_x = theme.row_pad_x * scale;
    const row_radius = theme.row_radius * scale;
    const font_size = theme.rowFontSize() * scale;
    const char_w = Theme.charWidth(font_size);
    const visible = @min(theme.visibleRows(), state.results.items.len -| state.scroll);

    for (0..visible) |row_i| {
        const result_i = state.scroll + row_i;
        const result = state.results.items[result_i];
        const entry = state.entryAt(result.index);
        const row_y = rows_top + @as(f64, @floatFromInt(row_i)) * (row_h + row_gap);
        const selected = result_i == state.selected;

        if (selected) {
            ctx.setSourceToPixel(theme.selected);
            try roundedRect(ctx, padding * 0.5, row_y, width - padding, row_h, row_radius);
            try ctx.fill();
            ctx.resetPath();
        }

        if (theme.compact_rows) {
            try drawCompactRow(ctx, theme, state, entry, result.index, row_y, row_h, width, padding, row_pad_x, font_size, char_w, selected, scale);
        } else {
            try drawTallRow(ctx, surface, theme, state, entry, result.index, row_y, row_h, width, padding, row_pad_x, font_size, char_w, scale, selected, icon_cache);
        }
    }
}

fn drawTallRow(
    ctx: *z2d.Context,
    surface: *z2d.Surface,
    theme: *const Theme,
    state: *State,
    entry: state_mod.Entry,
    entry_index: usize,
    row_y: f64,
    row_h: f64,
    width: f64,
    padding: f64,
    row_pad_x: f64,
    name_fs: f64,
    char_w: f64,
    scale: f64,
    selected: bool,
    icon_cache: ?*icon_mod.Cache,
) !void {
    ctx.setFontSize(name_fs);

    const tile_size = theme.icon_tile_size * scale;
    const tile_x = padding * 0.5 + row_pad_x;
    const tile_y = row_y + (row_h - tile_size) / 2;

    const real_icon: ?icon_mod.Icon = blk: {
        const cache = icon_cache orelse break :blk null;
        const name = entry.icon_name orelse break :blk null;
        break :blk cache.get(name);
    };

    if (real_icon) |img| {
        blitIcon(surface, img, tile_x, tile_y, tile_size);
    } else {
        const tile_color = theme_mod.icon_palette[entry_index % theme_mod.icon_palette.len];
        ctx.setSourceToPixel(tile_color);
        try roundedRect(ctx, tile_x, tile_y, tile_size, tile_size, theme.icon_tile_radius * scale);
        try ctx.fill();
        ctx.resetPath();

        if (entry.label.len > 0) {
            const letter_fs = theme.icon_letter_size * scale;
            ctx.setFontSize(letter_fs);
            ctx.setSourceToPixel(.{ .rgba = (z2d.pixel.RGBA{ .r = 255, .g = 255, .b = 255, .a = 255 }).multiply() });
            var upper_buf: [4]u8 = undefined;
            const first_len = std.unicode.utf8ByteSequenceLength(entry.label[0]) catch 1;
            const letter = std.ascii.upperString(&upper_buf, entry.label[0..@min(first_len, entry.label.len)]);
            const letter_char_w = Theme.charWidth(letter_fs);
            const lx = tile_x + (tile_size - letter_char_w) / 2;
            const ly = tile_y + (tile_size - letter_fs) / 2;
            try ctx.showText(letter, lx, ly);
            ctx.resetPath();
            ctx.setFontSize(name_fs);
        }
    }

    const text_x = tile_x + tile_size + row_pad_x * 0.7;
    const has_subtitle = entry.subtitle != null;
    const name_y = if (has_subtitle) row_y + row_h * 0.18 else row_y + (row_h - name_fs) / 2;

    const max_chars: usize = blk: {
        const avail = width - padding - row_pad_x - text_x;
        break :blk if (char_w > 0) @intFromFloat(@max(0.0, avail / char_w)) else 0;
    };
    try drawMatchedName(ctx, theme, state, entry.label, text_x, name_y, char_w, max_chars);

    if (entry.subtitle) |sub| {
        const sub_fs = theme.subtitle_font_size * scale;
        ctx.setFontSize(sub_fs);
        ctx.setSourceToPixel(theme.dim);
        const sub_y = row_y + row_h * 0.55;
        try ctx.showText(sub, text_x, sub_y);
        ctx.resetPath();
        ctx.setFontSize(name_fs);
    }

    if (selected) try drawEnterCap(ctx, theme, width, padding, row_y, row_h, scale);
}

fn drawCompactRow(
    ctx: *z2d.Context,
    theme: *const Theme,
    state: *State,
    entry: state_mod.Entry,
    entry_index: usize,
    row_y: f64,
    row_h: f64,
    width: f64,
    padding: f64,
    row_pad_x: f64,
    font_size: f64,
    char_w: f64,
    selected: bool,
    scale: f64,
) !void {
    _ = entry_index;
    ctx.setFontSize(font_size);
    const text_x = padding * 0.5 + row_pad_x;
    const name_y = row_y + (row_h - font_size) / 2;

    // Reserved on every row, not just the selected one, so the right-aligned
    // path doesn't shift (and overlap the badge) as the selection moves.
    const right_boundary = width - padding * 0.5 - row_pad_x - enterCapReservedWidth(theme, scale);

    var right_text: ?[]const u8 = null;
    if (entry.action) |a| {
        if (!std.mem.eql(u8, a, entry.label)) right_text = a;
    }
    // Values sourced from e.g. dmenu's `-display-columns` may still carry
    // the raw separator (a tab), which has no glyph in the monospace font
    // and renders as a tofu box -- fold whitespace controls to a space.
    var sanitize_buf: [512]u8 = undefined;
    if (right_text) |r| {
        if (std.mem.indexOfAny(u8, r, "\t\n\r") != null) {
            const n = @min(r.len, sanitize_buf.len);
            @memcpy(sanitize_buf[0..n], r[0..n]);
            for (sanitize_buf[0..n]) |*b| {
                if (b.* == '\t' or b.* == '\n' or b.* == '\r') b.* = ' ';
            }
            right_text = sanitize_buf[0..n];
        }
    }
    var right_chars: usize = if (right_text) |r| std.unicode.utf8CountCodepoints(r) catch r.len else 0;
    const right_max_chars: usize = blk: {
        const avail = right_boundary - text_x - row_pad_x;
        break :blk if (char_w > 0) @intFromFloat(@max(0.0, avail * 0.4 / char_w)) else 0;
    };
    if (right_text != null and right_chars > right_max_chars and right_max_chars > 1) {
        // Keep the tail (the binary name), truncate the front (the dir).
        var skip = right_chars - (right_max_chars - 1);
        var start: usize = 0;
        const r = right_text.?;
        while (skip > 0) : (skip -= 1) start += std.unicode.utf8ByteSequenceLength(r[start]) catch 1;
        right_text = r[start..];
        right_chars = right_max_chars - 1;
    }
    const right_w: f64 = if (right_text != null) @as(f64, @floatFromInt(right_chars)) * char_w + row_pad_x else 0;

    const max_chars: usize = blk: {
        const avail = right_boundary - right_w - text_x;
        break :blk if (char_w > 0) @intFromFloat(@max(0.0, avail / char_w)) else 0;
    };
    try drawMatchedName(ctx, theme, state, entry.label, text_x, name_y, char_w, max_chars);

    if (right_text) |r| {
        ctx.setSourceToPixel(theme.dim);
        if (right_chars < (std.unicode.utf8CountCodepoints(entry.action.?) catch 0)) {
            try ctx.showText("\xE2\x80\xA6", right_boundary - @as(f64, @floatFromInt(right_chars)) * char_w - char_w, name_y); // "…"
            ctx.resetPath();
        }
        try ctx.showText(r, right_boundary - @as(f64, @floatFromInt(right_chars)) * char_w, name_y);
        ctx.resetPath();
    }

    if (selected) try drawEnterCap(ctx, theme, width, padding, row_y, row_h, scale);
}

const enter_cap_label = "Enter";

/// Width `drawEnterCap` will occupy, including its right margin -- callers
/// laying out row content (e.g. compact rows' right-aligned path) must
/// reserve this on every row, not just the selected one, or that content
/// shifts and can overlap the badge when the selection moves onto it.
fn enterCapReservedWidth(theme: *const Theme, scale: f64) f64 {
    const cap_fs = theme.footer_cap_font_size * scale;
    const cap_char_w = Theme.charWidth(cap_fs);
    const cap_pad_x: f64 = 6 * scale;
    const cap_w = @as(f64, @floatFromInt(enter_cap_label.len)) * cap_char_w + cap_pad_x * 2;
    return cap_w + 10 * scale;
}

fn drawEnterCap(ctx: *z2d.Context, theme: *const Theme, width: f64, padding: f64, row_y: f64, row_h: f64, scale: f64) !void {
    const label = enter_cap_label;
    const cap_fs = theme.footer_cap_font_size * scale;
    ctx.setFontSize(cap_fs);
    const cap_char_w = Theme.charWidth(cap_fs);
    const cap_pad_x: f64 = 6 * scale;
    const cap_w = @as(f64, @floatFromInt(label.len)) * cap_char_w + cap_pad_x * 2;
    const cap_h = cap_fs + 6 * scale;
    const cap_x = width - padding * 0.5 - 10 * scale - cap_w;
    const cap_y = row_y + (row_h - cap_h) / 2;

    ctx.setSourceToPixel(theme.chip_track);
    try roundedRect(ctx, cap_x, cap_y, cap_w, cap_h, 4 * scale);
    try ctx.fill();
    ctx.resetPath();
    ctx.setSourceToPixel(theme.dim);
    try ctx.showText(label, cap_x + cap_pad_x, cap_y + (cap_h - cap_fs) / 2);
    ctx.resetPath();
}

fn drawMatchedName(
    ctx: *z2d.Context,
    theme: *const Theme,
    state: *State,
    full_label: []const u8,
    x: f64,
    y: f64,
    char_w: f64,
    max_chars: usize,
) !void {
    var label = full_label;
    var truncated = false;
    if (max_chars > 1 and label.len > max_chars) {
        label = label[0 .. max_chars - 1];
        truncated = true;
    }

    var positions_buf: [256]usize = undefined;
    var positions: []const usize = &.{};
    if (state.query.items.len > 0 and state.query.items.len <= positions_buf.len) {
        const s = fuzzy.scoreWithPositions(&state.scratch, state.query.items, full_label, positions_buf[0..state.query.items.len]) catch fuzzy.SCORE_MIN;
        if (s > fuzzy.SCORE_MIN) positions = positions_buf[0..state.query.items.len];
    }

    var cx = x;
    var byte_i: usize = 0;
    while (byte_i < label.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(label[byte_i]) catch 1;
        const end = @min(byte_i + cp_len, label.len);
        ctx.setSourceToPixel(if (containsPos(positions, byte_i)) theme.accent else theme.text);
        try ctx.showText(label[byte_i..end], cx, y);
        ctx.resetPath();
        cx += char_w;
        byte_i = end;
    }
    if (truncated) {
        ctx.setSourceToPixel(theme.faint);
        try ctx.showText("\xE2\x80\xA6", cx, y); // "…"
        ctx.resetPath();
    }
}

fn containsPos(positions: []const usize, byte_pos: usize) bool {
    for (positions) |p| {
        if (p == byte_pos) return true;
    }
    return false;
}

fn drawFooter(ctx: *z2d.Context, theme: *const Theme, state: *State, width: f64, padding: f64, footer_y: f64, footer_h: f64, scale: f64) !void {
    const fs = theme.footer_font_size * scale;
    const pad_x = theme.footer_pad_x * scale;
    ctx.setFontSize(fs);

    var buf: [64]u8 = undefined;
    const noun = if (theme.compact_rows) "commands" else "apps";
    const status = if (state.query.items.len == 0)
        std.fmt.bufPrint(&buf, "{d} {s} \xC2\xB7 most used first", .{ state.entries.len, noun }) catch "" // "·"
    else
        std.fmt.bufPrint(&buf, "{d} of {d} {s}", .{ state.results.items.len, state.entries.len, noun }) catch "";

    ctx.setSourceToPixel(theme.faint);
    const text_y = footer_y + (footer_h - fs) / 2;
    try ctx.showText(status, pad_x, text_y);
    ctx.resetPath();

    const cap_fs = theme.footer_cap_font_size * scale;
    ctx.setFontSize(cap_fs);
    const cap_char_w = Theme.charWidth(cap_fs);
    const gap = theme.footer_caps_gap * scale;

    const Cap = struct { key: []const u8, label: []const u8 };
    const caps = [_]Cap{
        .{ .key = "Esc", .label = "close" },
        .{ .key = "Tab", .label = "mode" },
        .{ .key = "Enter", .label = "open" },
    };

    var cx = width - padding * 0.5 - pad_x;
    for (caps) |cap| {
        const label_w = @as(f64, @floatFromInt(cap.label.len)) * cap_char_w;
        cx -= label_w;
        ctx.setSourceToPixel(theme.faint);
        try ctx.showText(cap.label, cx, text_y);
        ctx.resetPath();
        cx -= 6 * scale;

        const key_pad: f64 = 5 * scale;
        const key_w = @as(f64, @floatFromInt(cap.key.len)) * cap_char_w + key_pad * 2;
        const key_h = cap_fs + 6 * scale;
        const key_x = cx - key_w;
        const key_y = footer_y + (footer_h - key_h) / 2;
        ctx.setSourceToPixel(theme.chip_track);
        try roundedRect(ctx, key_x, key_y, key_w, key_h, 4 * scale);
        try ctx.fill();
        ctx.resetPath();
        ctx.setSourceToPixel(theme.dim);
        try ctx.showText(cap.key, key_x + key_pad, key_y + (key_h - cap_fs) / 2);
        ctx.resetPath();

        cx = key_x - gap;
    }
}

/// Composites a decoded icon into a `size` x `size` square at `(x, y)`,
/// nearest-neighbor sampled. Bypasses the Context/Pattern vector pipeline
/// entirely (z2d has no image/bitmap pattern to fill a shape with) by
/// writing straight to the surface's pixel buffer, alpha-blended with
/// whatever's already there.
fn blitIcon(surface: *z2d.Surface, img: icon_mod.Icon, x: f64, y: f64, tile_size: f64) void {
    const x0: i32 = @intFromFloat(@round(x));
    const y0: i32 = @intFromFloat(@round(y));
    const n: i32 = @intFromFloat(@round(tile_size));
    if (n <= 0) return;

    var row: i32 = 0;
    while (row < n) : (row += 1) {
        const v = (@as(f64, @floatFromInt(row)) + 0.5) / tile_size;
        var col: i32 = 0;
        while (col < n) : (col += 1) {
            const u = (@as(f64, @floatFromInt(col)) + 0.5) / tile_size;
            const px = img.sample(u, v);
            surface.compositeStride(x0 + col, y0 + row, 1, .{ .argb = px }, .src_over, 255);
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
    const rr = @max(0.0, @min(r, @min(w, h) / 2));
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
