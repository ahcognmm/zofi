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
const dashboard_mod = @import("dashboard.zig");
const history_mod = @import("history.zig");
const weather_mod = @import("weather.zig");

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
    environ: ?*const std.process.Environ.Map,
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
    const footer_y = height - theme.footer_height * scale;

    // Windows/Run tabs always show their real list -- the idle dashboard
    // (clock/calendar/recent apps) only makes sense as an Apps-tab landing
    // page, never a replacement for "here are your open windows".
    if (theme.dashboard_enabled and theme.active_tab == .apps and state.query.items.len == 0) {
        try drawDashboard(&ctx, surface, theme, io, alloc, environ, icon_cache, width, padding, rows_top, footer_y, scale);
    } else {
        try drawRows(&ctx, surface, theme, state, width, padding, rows_top, scale, icon_cache);
    }

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

/// Idle-state view shown instead of the row list: clock/date + weather on
/// the left, a calendar on the right, recently-launched apps along the
/// bottom. Occupies the same rect the row list would. Box model lifted
/// 1:1 from the exported `zofi-home.html` design spec.
fn drawDashboard(
    ctx: *z2d.Context,
    surface: *z2d.Surface,
    theme: *const Theme,
    io: Io,
    alloc: std.mem.Allocator,
    environ: ?*const std.process.Environ.Map,
    icon_cache: ?*icon_mod.Cache,
    width: f64,
    padding: f64,
    content_top: f64,
    content_bottom: f64,
    scale: f64,
) !void {
    const dash = dashboard_mod.build(alloc) catch return;

    const gap = theme.dash_gap * scale;
    const inner_top = content_top + theme.dash_pad_top * scale;
    const inner_bottom = content_bottom - theme.dash_pad_bottom * scale;

    const content_x = padding;
    const content_w = width - padding * 2;

    const top_h = theme.dash_top_h * scale;
    const recent_y = inner_top + top_h + gap;
    const recent_h = inner_bottom - recent_y;

    const col_gap = theme.dash_col_gap * scale;
    const cal_w = theme.dash_calendar_width * scale;
    const left_w = content_w - col_gap - cal_w;
    const right_x = content_x + left_w + col_gap;

    try drawClockAndWeather(ctx, theme, io, alloc, environ, dash, content_x, inner_top, left_w, top_h, scale);
    try drawCalendarCard(ctx, theme, dash, right_x, inner_top, cal_w, top_h, scale);
    try drawRecentSection(ctx, surface, theme, io, alloc, environ, icon_cache, content_x, recent_y, content_w, recent_h, scale);
}

/// Clips `text` to whatever whole number of characters fits in `avail_w`
/// at `char_w` per character (monospace, so this is exact). No ellipsis --
/// callers use this for supplementary text (weather condition/location)
/// where silent clipping reads better than "Ho Chi Minh Ci…" in a narrow
/// card.
fn truncateToWidth(text: []const u8, avail_w: f64, char_w: f64) []const u8 {
    if (char_w <= 0) return text;
    const max_chars: usize = @intFromFloat(@max(0.0, avail_w / char_w));
    return if (text.len > max_chars) text[0..max_chars] else text;
}

fn drawCard(ctx: *z2d.Context, theme: *const Theme, x: f64, y: f64, w: f64, h: f64, scale: f64) !void {
    ctx.setSourceToPixel(theme.dash_card_bg);
    try roundedRect(ctx, x, y, w, h, theme.dash_card_radius * scale);
    try ctx.fill();
    ctx.resetPath();
}

fn drawClockAndWeather(
    ctx: *z2d.Context,
    theme: *const Theme,
    io: Io,
    alloc: std.mem.Allocator,
    environ: ?*const std.process.Environ.Map,
    dash: dashboard_mod.Dashboard,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    scale: f64,
) !void {
    const clock_pad = theme.dash_clock_pad * scale;
    const clock_x = x + clock_pad;
    const clock_fs = theme.dash_clock_font_size * scale;
    ctx.setFontSize(clock_fs);
    ctx.setSourceToPixel(theme.text);
    var clock_buf: [8]u8 = undefined;
    const clock_str = std.fmt.bufPrint(&clock_buf, "{d:0>2}:{d:0>2}", .{ dash.hour, dash.minute }) catch "";
    try ctx.showText(clock_str, clock_x, y + clock_pad);
    ctx.resetPath();

    const date_fs = theme.dash_date_font_size * scale;
    ctx.setFontSize(date_fs);
    ctx.setSourceToPixel(theme.dim);
    const date_y = y + clock_pad + clock_fs + theme.dash_clock_gap * scale;
    try ctx.showText(dash.weekday_date, clock_x, date_y);
    ctx.resetPath();

    // .clock's own box (padding 8/8/0/8, i.e. no bottom padding) ends right
    // after the date line; .left's `gap: 14` then leads into the card.
    const card_y = date_y + date_fs + theme.dash_left_gap * scale;
    const card_h = (y + h) - card_y;
    if (card_h <= 0) return;

    const weather = if (environ) |e| weather_mod.loadCached(alloc, io, e) else null;
    try drawWeatherCard(ctx, theme, weather, x, card_y, w, card_h, scale);
}

fn drawWeatherCard(ctx: *z2d.Context, theme: *const Theme, weather: ?weather_mod.Weather, x: f64, y: f64, w: f64, h: f64, scale: f64) !void {
    try drawCard(ctx, theme, x, y, w, h, scale);

    const pad_top = theme.dash_weather_pad_top * scale;
    const pad_x = theme.dash_weather_pad_x * scale;
    const pad_bottom = theme.dash_weather_pad_bottom * scale;

    const wx = weather orelse {
        ctx.setFontSize(theme.dash_cond_font_size * scale);
        ctx.setSourceToPixel(theme.faint);
        try ctx.showText("Weather unavailable", x + pad_x, y + pad_top);
        ctx.resetPath();
        return;
    };

    const icon_size = theme.dash_weather_icon_size * scale;
    const temp_fs = theme.dash_temp_font_size * scale;
    const cond_fs = theme.dash_cond_font_size * scale;
    const loc_fs = theme.dash_loc_font_size * scale;
    const now_gap = theme.dash_weather_now_gap * scale;
    const cond_gap = theme.dash_cond_gap * scale;

    // "now" row (icon, temp, condition/location) pinned to the card's top;
    // the forecast row (below) is pinned to its bottom -- `justify-content:
    // space-between` in the original design -- with whatever's left as
    // plain empty card between them, not a broken-looking half-empty box.
    const row_top = y + pad_top;
    const row_h = @max(icon_size, cond_fs + cond_gap + loc_fs);
    const row_cy = row_top + row_h / 2;

    const icon_x = x + pad_x;
    try drawWeatherIcon(ctx, theme, weather_mod.iconFor(wx.code), icon_x, row_cy - icon_size / 2, icon_size, scale);

    const temp_x = icon_x + icon_size + now_gap;
    ctx.setFontSize(temp_fs);
    ctx.setSourceToPixel(theme.text);
    var temp_buf: [16]u8 = undefined;
    const temp_str = std.fmt.bufPrint(&temp_buf, "{d:.0}\xC2\xB0", .{wx.temp_c}) catch ""; // "°"
    try ctx.showText(temp_str, temp_x, row_cy - temp_fs / 2);
    ctx.resetPath();

    const cond_x = temp_x + @as(f64, @floatFromInt(temp_str.len)) * Theme.charWidth(temp_fs) + now_gap;
    const cond_avail_w = (x + w - pad_x) - cond_x;
    const cond_block_h = cond_fs + cond_gap + loc_fs;
    const cond_y = row_cy - cond_block_h / 2;
    ctx.setFontSize(cond_fs);
    ctx.setSourceToPixel(theme.text);
    try ctx.showText(truncateToWidth(wx.condition(), cond_avail_w, Theme.charWidth(cond_fs)), cond_x, cond_y);
    ctx.resetPath();

    ctx.setFontSize(loc_fs);
    ctx.setSourceToPixel(theme.dim);
    var loc_buf: [96]u8 = undefined;
    const loc_str = std.fmt.bufPrint(&loc_buf, "{s} \xC2\xB7 H {d:.0}\xC2\xB0 L {d:.0}\xC2\xB0", .{ wx.city, wx.high_c, wx.low_c }) catch "";
    try ctx.showText(truncateToWidth(loc_str, cond_avail_w, Theme.charWidth(loc_fs)), cond_x, cond_y + cond_fs + cond_gap);
    ctx.resetPath();

    if (wx.hourly.len == 0) return;

    const time_fs = theme.dash_forecast_time_font_size * scale;
    const val_fs = theme.dash_forecast_temp_font_size * scale;
    const forecast_icon_size = theme.dash_forecast_icon_size * scale;
    const slot_gap = theme.dash_forecast_slot_gap * scale;
    const forecast_h = time_fs + slot_gap + forecast_icon_size + slot_gap + val_fs;

    const rule_y = (y + h) - pad_bottom - forecast_h - theme.dash_forecast_gap_top * scale;
    ctx.setSourceToPixel(theme.border);
    try fillRect(ctx, x + pad_x, rule_y, w - pad_x * 2, @max(1.0, scale));
    ctx.resetPath();

    const forecast_top = rule_y + theme.dash_forecast_gap_top * scale;
    const col_gap = theme.dash_forecast_col_gap * scale;
    const slot_w = (w - pad_x * 2 - col_gap * @as(f64, @floatFromInt(wx.hourly.len - 1))) / @as(f64, @floatFromInt(wx.hourly.len));
    var i: usize = 0;
    while (i < wx.hourly.len) : (i += 1) {
        const hf = wx.hourly[i];
        const slot_x = x + pad_x + (slot_w + col_gap) * @as(f64, @floatFromInt(i));
        const slot_cx = slot_x + slot_w / 2;

        ctx.setFontSize(time_fs);
        ctx.setSourceToPixel(theme.faint);
        const time_w = @as(f64, @floatFromInt(hf.label.len)) * Theme.charWidth(time_fs);
        try ctx.showText(hf.label, slot_cx - time_w / 2, forecast_top);
        ctx.resetPath();

        const hi_y = forecast_top + time_fs + slot_gap;
        try drawWeatherIcon(ctx, theme, weather_mod.iconFor(hf.code), slot_cx - forecast_icon_size / 2, hi_y, forecast_icon_size, scale);

        var htemp_buf: [16]u8 = undefined;
        const htemp_str = std.fmt.bufPrint(&htemp_buf, "{d:.0}\xC2\xB0", .{hf.temp_c}) catch "";
        ctx.setFontSize(val_fs);
        ctx.setSourceToPixel(theme.text);
        const val_w = @as(f64, @floatFromInt(htemp_str.len)) * Theme.charWidth(val_fs);
        try ctx.showText(htemp_str, slot_cx - val_w / 2, hi_y + forecast_icon_size + slot_gap);
        ctx.resetPath();
    }
}

/// Small hand-drawn pictograms -- z2d has no image pattern to fill a shape
/// with (see `blitIcon`), and pulling in bitmap weather icon assets for
/// half a dozen glyphs isn't worth a new dependency.
fn drawWeatherIcon(ctx: *z2d.Context, theme: *const Theme, icon: weather_mod.Icon, x: f64, y: f64, icon_size: f64, scale: f64) !void {
    const cx = x + icon_size / 2;
    const cy = y + icon_size / 2;

    switch (icon) {
        .sun => {
            ctx.setSourceToPixel(theme.accent);
            const r = icon_size * 0.28;
            try ctx.arc(cx, cy, r, 0, std.math.pi * 2);
            try ctx.closePath();
            try ctx.fill();
            ctx.resetPath();
            ctx.setLineWidth(@max(1.0, 1.2 * scale));
            var ray: usize = 0;
            while (ray < 8) : (ray += 1) {
                const a = @as(f64, @floatFromInt(ray)) * (std.math.pi / 4.0);
                const x0 = cx + @cos(a) * r * 1.4;
                const y0 = cy + @sin(a) * r * 1.4;
                const x1 = cx + @cos(a) * r * 1.9;
                const y1 = cy + @sin(a) * r * 1.9;
                try ctx.moveTo(x0, y0);
                try ctx.lineTo(x1, y1);
                try ctx.stroke();
                ctx.resetPath();
            }
        },
        .cloud, .part_cloud, .fog, .rain, .snow, .thunder => {
            if (icon == .part_cloud) {
                ctx.setSourceToPixel(theme.accent);
                const r = icon_size * 0.22;
                try ctx.arc(cx - icon_size * 0.18, cy - icon_size * 0.18, r, 0, std.math.pi * 2);
                try ctx.closePath();
                try ctx.fill();
                ctx.resetPath();
            }
            ctx.setSourceToPixel(theme.dim);
            const body_y = cy + icon_size * 0.08;
            try ctx.arc(cx - icon_size * 0.16, body_y, icon_size * 0.2, std.math.pi * 0.5, std.math.pi * 1.75);
            try ctx.arc(cx + icon_size * 0.08, body_y - icon_size * 0.1, icon_size * 0.24, std.math.pi * 1.15, std.math.pi * 2.15);
            try ctx.lineTo(cx + icon_size * 0.34, body_y + icon_size * 0.22);
            try ctx.lineTo(cx - icon_size * 0.16, body_y + icon_size * 0.22);
            try ctx.closePath();
            try ctx.fill();
            ctx.resetPath();

            switch (icon) {
                .rain => {
                    ctx.setSourceToPixel(theme.faint);
                    ctx.setLineWidth(@max(1.0, 1.2 * scale));
                    var d: usize = 0;
                    while (d < 3) : (d += 1) {
                        const dx = cx - icon_size * 0.12 + @as(f64, @floatFromInt(d)) * icon_size * 0.16;
                        try ctx.moveTo(dx, body_y + icon_size * 0.3);
                        try ctx.lineTo(dx - icon_size * 0.05, body_y + icon_size * 0.46);
                        try ctx.stroke();
                        ctx.resetPath();
                    }
                },
                .snow => {
                    ctx.setSourceToPixel(theme.faint);
                    var d: usize = 0;
                    while (d < 3) : (d += 1) {
                        const dx = cx - icon_size * 0.12 + @as(f64, @floatFromInt(d)) * icon_size * 0.16;
                        const dy = body_y + icon_size * 0.38;
                        try ctx.arc(dx, dy, @max(0.8 * scale, icon_size * 0.03), 0, std.math.pi * 2);
                        try ctx.closePath();
                        try ctx.fill();
                        ctx.resetPath();
                    }
                },
                .fog => {
                    ctx.setSourceToPixel(theme.faint);
                    ctx.setLineWidth(@max(1.0, 1.2 * scale));
                    var d: usize = 0;
                    while (d < 2) : (d += 1) {
                        const dy = body_y + icon_size * 0.3 + @as(f64, @floatFromInt(d)) * icon_size * 0.14;
                        try ctx.moveTo(cx - icon_size * 0.22, dy);
                        try ctx.lineTo(cx + icon_size * 0.22, dy);
                        try ctx.stroke();
                        ctx.resetPath();
                    }
                },
                .thunder => {
                    ctx.setSourceToPixel(theme.accent);
                    try ctx.moveTo(cx + icon_size * 0.02, body_y + icon_size * 0.24);
                    try ctx.lineTo(cx - icon_size * 0.1, body_y + icon_size * 0.46);
                    try ctx.lineTo(cx + icon_size * 0.02, body_y + icon_size * 0.46);
                    try ctx.lineTo(cx - icon_size * 0.08, body_y + icon_size * 0.68);
                    try ctx.lineTo(cx + icon_size * 0.16, body_y + icon_size * 0.4);
                    try ctx.lineTo(cx + icon_size * 0.04, body_y + icon_size * 0.4);
                    try ctx.closePath();
                    try ctx.fill();
                    ctx.resetPath();
                },
                else => {},
            }
        },
    }
}

fn drawCalendarCard(ctx: *z2d.Context, theme: *const Theme, dash: dashboard_mod.Dashboard, x: f64, y: f64, w: f64, h: f64, scale: f64) !void {
    try drawCard(ctx, theme, x, y, w, h, scale);

    const pad_top = theme.dash_calendar_pad_top * scale;
    const pad_x = theme.dash_calendar_pad_x * scale;
    const title_fs = theme.dash_cal_title_font_size * scale;
    const week_fs = theme.dash_cal_week_font_size * scale;

    ctx.setFontSize(title_fs);
    ctx.setSourceToPixel(theme.text);
    try ctx.showText(dash.month_label, x + pad_x, y + pad_top);
    ctx.resetPath();

    var week_buf: [16]u8 = undefined;
    const week_str = std.fmt.bufPrint(&week_buf, "Week {d}", .{dash.iso_week}) catch "";
    ctx.setFontSize(week_fs);
    ctx.setSourceToPixel(theme.faint);
    // `.cal-head { align-items: baseline }`: the smaller "Week N" label
    // sits on the title's baseline, not its top -- approximated here by
    // aligning the two text tops to the title's vertical center.
    try ctx.showText(week_str, x + w - pad_x - @as(f64, @floatFromInt(week_str.len)) * Theme.charWidth(week_fs), y + pad_top + (title_fs - week_fs) * 0.7);
    ctx.resetPath();

    const wd_fs = theme.dash_cal_wd_font_size * scale;
    const col_gap = theme.dash_cal_col_gap * scale;
    const col_w = (w - pad_x * 2 - col_gap * 6) / 7.0;
    const weekday_labels = [_][]const u8{ "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" };
    const header_y = y + pad_top + title_fs + theme.dash_calendar_gap * scale;
    ctx.setFontSize(wd_fs);
    ctx.setSourceToPixel(theme.faint);
    for (weekday_labels, 0..) |lbl, i| {
        const col_x = x + pad_x + (col_w + col_gap) * @as(f64, @floatFromInt(i));
        const label_w = @as(f64, @floatFromInt(lbl.len)) * Theme.charWidth(wd_fs);
        try ctx.showText(lbl, col_x + (col_w - label_w) / 2, header_y);
        ctx.resetPath();
    }

    const day_fs = theme.dash_cal_day_font_size * scale;
    const day_char_w = Theme.charWidth(day_fs);
    const row_h = theme.dash_cal_row_h * scale;
    const grid_top = header_y + wd_fs + 4 * scale;

    for (dash.days, 0..) |cell, i| {
        if (cell.day == 0) continue;
        const row = i / 7;
        const col = i % 7;
        const col_x = x + pad_x + (col_w + col_gap) * @as(f64, @floatFromInt(col));
        const cell_y = grid_top + row_h * @as(f64, @floatFromInt(row));
        const cy = cell_y + (row_h - day_fs) / 2;

        var day_buf: [4]u8 = undefined;
        const day_str = std.fmt.bufPrint(&day_buf, "{d}", .{cell.day}) catch "";
        const day_w = @as(f64, @floatFromInt(day_str.len)) * day_char_w;
        const cx = col_x + (col_w - day_w) / 2;

        if (cell.is_today) {
            ctx.setSourceToPixel(theme.accent);
            try roundedRect(ctx, col_x, cell_y, col_w, row_h, 7 * scale);
            try ctx.fill();
            ctx.resetPath();
            ctx.setSourceToPixel(theme.panel_bg);
        } else {
            ctx.setSourceToPixel(theme.text);
        }
        try ctx.showText(day_str, cx, cy);
        ctx.resetPath();
    }
}

fn drawRecentSection(
    ctx: *z2d.Context,
    surface: *z2d.Surface,
    theme: *const Theme,
    io: Io,
    alloc: std.mem.Allocator,
    environ: ?*const std.process.Environ.Map,
    icon_cache: ?*icon_mod.Cache,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    scale: f64,
) !void {
    _ = h;
    const label_fs = theme.dash_recent_label_font_size * scale;
    ctx.setFontSize(label_fs);
    ctx.setSourceToPixel(theme.faint);
    const label_x = x + theme.dash_recent_label_pad_x * scale;
    try ctx.showText("RECENT", label_x, y);
    ctx.resetPath();

    const environ_ref = environ orelse return;
    const recents = history_mod.loadRecent(alloc, io, environ_ref, 5);
    if (recents.len == 0) return;

    // 5 evenly spaced slots, icon tile centered on top, name centered
    // below it -- like an Apps-tab row's tile, not a side-by-side pill.
    const tiles_y = y + label_fs + theme.dash_recent_gap * scale;
    const tile_size = theme.icon_tile_size * scale;
    const max_slots: f64 = 5;
    const slot_w = w / max_slots;
    const name_fs = theme.dash_recent_name_font_size * scale;
    const name_char_w = Theme.charWidth(name_fs);

    for (recents, 0..) |entry, i| {
        const slot_x = x + slot_w * @as(f64, @floatFromInt(i));
        const tile_x = slot_x + (slot_w - tile_size) / 2;

        const real_icon: ?icon_mod.Icon = blk: {
            const cache = icon_cache orelse break :blk null;
            const name = entry.icon_name orelse break :blk null;
            break :blk cache.get(name);
        };

        if (real_icon) |img| {
            blitIcon(surface, img, tile_x, tiles_y, tile_size);
        } else {
            ctx.setSourceToPixel(theme_mod.icon_palette[i % theme_mod.icon_palette.len]);
            try roundedRect(ctx, tile_x, tiles_y, tile_size, tile_size, theme.icon_tile_radius * scale);
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
                try ctx.showText(letter, tile_x + (tile_size - letter_char_w) / 2, tiles_y + (tile_size - letter_fs) / 2);
                ctx.resetPath();
            }
        }

        ctx.setFontSize(name_fs);
        ctx.setSourceToPixel(theme.text);
        const max_chars: usize = @intFromFloat(@max(0.0, slot_w / name_char_w));
        var label = entry.label;
        var truncated = false;
        if (max_chars > 1 and label.len > max_chars) {
            label = label[0 .. max_chars - 1];
            truncated = true;
        }
        const label_w_px = @as(f64, @floatFromInt(label.len)) * name_char_w + (if (truncated) name_char_w else 0);
        const lx = slot_x + @max(0.0, (slot_w - label_w_px) / 2);
        const ly = tiles_y + tile_size + 8 * scale;
        try ctx.showText(label, lx, ly);
        ctx.resetPath();
        if (truncated) {
            try ctx.showText("\xE2\x80\xA6", lx + @as(f64, @floatFromInt(label.len)) * name_char_w, ly);
            ctx.resetPath();
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
