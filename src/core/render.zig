//! Draws the whole UI into a z2d surface at a given scale. Knows about
//! queries, entries and scores; backends only call `render` and copy pixels.
//! Positioning goes through `ui/layout.zig`; content drawing goes through
//! the widgets in `ui/` (Label, Image, Button, IconTile, MatchedLabel,
//! WeatherIcon, SearchIcon) -- this file is the app-specific screens built
//! from them, not a place that reaches for raw z2d calls anymore except
//! where a screen's own bespoke behavior (the query's scrolling viewport,
//! the compact row's front-truncated path) genuinely isn't a generic widget.
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
const ui = @import("ui/root.zig");
const L = ui.layout;
const shapes = ui.shapes;
const Label = ui.text.Label;
const Image = ui.image.Image;
const Button = ui.button.Button;
const IconTile = ui.icon_tile.IconTile;
const MatchedLabel = ui.matched_text.MatchedLabel;
const WeatherIcon = ui.weather_icon.WeatherIcon;
const SearchIcon = ui.search_icon.SearchIcon;

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
    try shapes.fillRect(&ctx, inset, sep_y, width - inset * 2, @max(1.0, scale));
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
    try shapes.roundedRect(ctx, 0, 0, width, height, radius);
    try ctx.fill();
    ctx.resetPath();

    ctx.setSourceToPixel(theme.border);
    ctx.setLineWidth(border_w);
    try shapes.roundedRect(ctx, border_w * 0.5, border_w * 0.5, width - border_w, height - border_w, @max(0.0, radius - border_w * 0.5));
    try ctx.stroke();
    ctx.resetPath();
}

fn drawPrompt(ctx: *z2d.Context, theme: *const Theme, state: *State, width: f64, padding: f64, prompt_h: f64, scale: f64) !void {
    const query_fs = theme.query_font_size * scale;
    const char_w = Theme.charWidth(query_fs);
    const icon_size = theme.prompt_icon_size * scale;
    const gap = theme.prompt_gap * scale;

    // The leading slot is either the search icon or the dmenu `-p` label;
    // whichever it is, the query text area takes up all the row space
    // that's left (`flex: 1`) -- computing that via layout means the
    // query's available width doesn't need re-deriving from `text_x`.
    const lead_w: f64 = if (theme.dmenu_prompt) |p|
        (Label{ .text = p, .font_size = query_fs, .color = theme.accent }).width()
    else
        icon_size;

    var lead_node: L.Node = .{ .width = .{ .fixed = lead_w }, .height = .{ .fixed = prompt_h } };
    var query_node: L.Node = .{ .width = .{ .flex = 1 }, .height = .{ .fixed = prompt_h } };
    var row: L.Node = .{
        .axis = .row,
        .gap = gap,
        .padding = .{ .left = padding, .right = padding },
        .children = &.{ &lead_node, &query_node },
    };
    L.layout(&row, .{ .x = 0, .y = 0, .w = width, .h = prompt_h });

    const text_y = (prompt_h - query_fs) / 2;
    if (theme.dmenu_prompt) |p| {
        try (Label{ .text = p, .font_size = query_fs, .color = theme.accent }).draw(ctx, .{ .x = lead_node.result.x, .y = text_y });
    } else {
        try (SearchIcon{ .color = theme.dim }).draw(ctx, lead_node.result.x, prompt_h / 2, icon_size, scale);
    }

    const text_x = query_node.result.x;
    const total_chars = std.unicode.utf8CountCodepoints(state.query.items) catch state.query.items.len;
    const cursor_char = std.unicode.utf8CountCodepoints(state.query.items[0..state.cursor]) catch state.cursor;

    if (total_chars == 0) {
        try (Label{ .text = theme.placeholder, .font_size = query_fs, .color = theme.faint }).draw(ctx, .{ .x = text_x, .y = text_y });

        const cursor_x = @floor(text_x);
        ctx.setSourceToPixel(theme.text);
        try shapes.fillRect(ctx, cursor_x, prompt_h * 0.2, @max(1.0, 2 * scale), prompt_h * 0.6);
        ctx.resetPath();
        return;
    }

    // The query has no natural truncation point like a label does (the
    // cursor can be anywhere in it, and that's the part the user needs
    // to see), so instead of cutting it off, slide a window of visible
    // codepoints so it always contains the cursor -- like a shell
    // prompt scrolling to keep up with where you're typing. Not a
    // generic widget: this scrolling-viewport behavior is specific to
    // an editable query field, not reusable label truncation.
    const query_avail_px = query_node.result.w;
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

    try (Label{ .text = display_query, .font_size = query_fs, .color = theme.text }).draw(ctx, .{ .x = text_x, .y = text_y });

    // Hairline strokes centered on a coordinate that lands exactly
    // between two pixel rows/columns split their antialiased coverage
    // ~50/50 across both, which can wash out to nothing after any
    // recompression. A filled, pixel-snapped rect sidesteps that.
    const cursor_x = @floor(text_x + @as(f64, @floatFromInt(cursor_char - view_start_char)) * char_w);
    ctx.setSourceToPixel(theme.text);
    try shapes.fillRect(ctx, cursor_x, prompt_h * 0.2, @max(1.0, 2 * scale), prompt_h * 0.6);
    ctx.resetPath();
}

fn drawTabs(ctx: *z2d.Context, theme: *const Theme, width: f64, padding: f64, prompt_h: f64, scale: f64) !void {
    const labels = [_][]const u8{ "Apps", "Run", "Windows", "Clipboard" };
    const chip_fs = theme.mode_chip_font_size * scale;
    const chip_pad_x = theme.mode_chip_pad_x * scale;
    const chip_h = theme.mode_chip_height * scale;
    const track_pad = theme.mode_track_pad * scale;

    var chip_nodes: [labels.len]L.Node = undefined;
    var chip_ptrs: [labels.len]*L.Node = undefined;
    var total_w: f64 = 0;
    for (labels, 0..) |l, i| {
        const cw = (Label{ .text = l, .font_size = chip_fs, .color = undefined }).width() + chip_pad_x * 2;
        chip_nodes[i] = .{ .width = .{ .fixed = cw }, .height = .{ .fixed = chip_h } };
        chip_ptrs[i] = &chip_nodes[i];
        total_w += cw;
    }

    const track_w = total_w + track_pad * 2;
    const track_h = chip_h + track_pad * 2;
    const track_x = width - padding - track_w;
    const track_y = (prompt_h - track_h) / 2;

    var track: L.Node = .{ .axis = .row, .padding = L.Padding.all(track_pad), .children = &chip_ptrs };
    L.layout(&track, .{ .x = track_x, .y = track_y, .w = track_w, .h = track_h });

    ctx.setSourceToPixel(theme.chip_track);
    try shapes.roundedRect(ctx, track_x, track_y, track_w, track_h, theme.mode_track_radius * scale);
    try ctx.fill();
    ctx.resetPath();

    const active_idx: usize = switch (theme.active_tab) {
        .apps => 0,
        .run => 1,
        .windows => 2,
        .clipboard => 3,
    };

    for (labels, 0..) |l, i| {
        const active = i == active_idx;
        const btn: Button = .{
            .label = .{ .text = l, .font_size = chip_fs, .color = if (active) theme.text else theme.dim },
            .bg = if (active) theme.chip_on else null,
            .radius = theme.mode_chip_radius * scale,
        };
        try btn.draw(ctx, chip_nodes[i].result);
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

    // Not modeled as a `layout.zig` column: fixed row height + fixed gap
    // is plain pagination arithmetic, not a flex/justify decision --
    // layout.zig earns its keep where sizes are mixed fixed/flex or need
    // justify/align, which this loop never does.
    for (0..visible) |row_i| {
        const result_i = state.scroll + row_i;
        const result = state.results.items[result_i];
        const entry = state.entryAt(result.index);
        const row_y = rows_top + @as(f64, @floatFromInt(row_i)) * (row_h + row_gap);
        const selected = result_i == state.selected;

        if (selected) {
            ctx.setSourceToPixel(theme.selected);
            try shapes.roundedRect(ctx, padding * 0.5, row_y, width - padding, row_h, row_radius);
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

    // Mirrors `zofi-home.html`'s `.home > .top(.left, .calendar), .recent`
    // box model directly: `left`/`recent` are `flex: 1` in CSS, `calendar`
    // is a fixed width, `.top` is a fixed height.
    var left: L.Node = .{ .width = .{ .flex = 1 } };
    var calendar: L.Node = .{ .width = .{ .fixed = theme.dash_calendar_width * scale } };
    var top: L.Node = .{
        .axis = .row,
        .gap = theme.dash_col_gap * scale,
        .height = .{ .fixed = theme.dash_top_h * scale },
        .children = &.{ &left, &calendar },
    };
    var recent: L.Node = .{ .height = .{ .flex = 1 } };
    var home: L.Node = .{
        .axis = .column,
        .gap = theme.dash_gap * scale,
        .padding = .{ .top = theme.dash_pad_top * scale, .bottom = theme.dash_pad_bottom * scale },
        .children = &.{ &top, &recent },
    };
    L.layout(&home, .{ .x = padding, .y = content_top, .w = width - padding * 2, .h = content_bottom - content_top });

    try drawClockAndWeather(ctx, theme, io, alloc, environ, dash, left.result, scale);
    try drawCalendarCard(ctx, theme, dash, calendar.result, scale);
    try drawRecentSection(ctx, surface, theme, io, alloc, environ, icon_cache, recent.result, scale);
}

fn drawCard(ctx: *z2d.Context, theme: *const Theme, x: f64, y: f64, w: f64, h: f64, scale: f64) !void {
    ctx.setSourceToPixel(theme.dash_card_bg);
    try shapes.roundedRect(ctx, x, y, w, h, theme.dash_card_radius * scale);
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
    outer: L.Rect,
    scale: f64,
) !void {
    // `.clock`'s own box (padding 8/8/0/8) sized to exactly fit its two
    // fixed-size text lines; `.left`'s `gap: 14` then leads into the card,
    // which takes whatever's left (`flex: 1` in the original CSS).
    const clock_pad = theme.dash_clock_pad * scale;
    const clock_fs = theme.dash_clock_font_size * scale;
    const date_fs = theme.dash_date_font_size * scale;
    const clock_h = clock_pad + clock_fs + theme.dash_clock_gap * scale + date_fs;

    var clock_line: L.Node = .{ .height = .{ .fixed = clock_fs } };
    var date_line: L.Node = .{ .height = .{ .fixed = date_fs } };
    var clock_block: L.Node = .{
        .axis = .column,
        .gap = theme.dash_clock_gap * scale,
        .padding = .{ .top = clock_pad, .left = clock_pad, .right = clock_pad },
        .height = .{ .fixed = clock_h },
        .children = &.{ &clock_line, &date_line },
    };
    var weather_card: L.Node = .{ .height = .{ .flex = 1 } };
    var left: L.Node = .{
        .axis = .column,
        .gap = theme.dash_left_gap * scale,
        .children = &.{ &clock_block, &weather_card },
    };
    L.layout(&left, outer);

    var clock_buf: [8]u8 = undefined;
    const clock_str = std.fmt.bufPrint(&clock_buf, "{d:0>2}:{d:0>2}", .{ dash.hour, dash.minute }) catch "";
    try (Label{ .text = clock_str, .font_size = clock_fs, .color = theme.text }).draw(ctx, clock_line.result);
    try (Label{ .text = dash.weekday_date, .font_size = date_fs, .color = theme.dim }).draw(ctx, date_line.result);

    if (weather_card.result.h <= 0) return;
    const weather = if (environ) |e| weather_mod.loadCached(alloc, io, e) else null;
    try drawWeatherCard(ctx, theme, weather, weather_card.result, scale);
}

fn drawWeatherCard(ctx: *z2d.Context, theme: *const Theme, weather: ?weather_mod.Weather, outer: L.Rect, scale: f64) !void {
    try drawCard(ctx, theme, outer.x, outer.y, outer.w, outer.h, scale);
    const pad_x = theme.dash_weather_pad_x * scale;

    const wx = weather orelse {
        try (Label{ .text = "Weather unavailable", .font_size = theme.dash_cond_font_size * scale, .color = theme.faint })
            .draw(ctx, .{ .x = outer.x + pad_x, .y = outer.y + theme.dash_weather_pad_top * scale });
        return;
    };

    const icon_size = theme.dash_weather_icon_size * scale;
    const temp_fs = theme.dash_temp_font_size * scale;
    const cond_fs = theme.dash_cond_font_size * scale;
    const loc_fs = theme.dash_loc_font_size * scale;
    const now_gap = theme.dash_weather_now_gap * scale;
    const cond_gap = theme.dash_cond_gap * scale;

    var temp_buf: [16]u8 = undefined;
    const temp_str = std.fmt.bufPrint(&temp_buf, "{d:.0}\xC2\xB0", .{wx.temp_c}) catch ""; // "°"
    const temp_label: Label = .{ .text = temp_str, .font_size = temp_fs, .color = theme.text };

    const time_fs = theme.dash_forecast_time_font_size * scale;
    const val_fs = theme.dash_forecast_temp_font_size * scale;
    const forecast_icon_size = theme.dash_forecast_icon_size * scale;
    const slot_gap = theme.dash_forecast_slot_gap * scale;
    const has_forecast = wx.hourly.len > 0;
    const forecast_h = if (has_forecast) time_fs + slot_gap + forecast_icon_size + slot_gap + val_fs else 0;

    // "now" row (icon, temp, condition/location) pinned to the card's top;
    // the forecast row (below) is pinned to its bottom -- `justify-content:
    // space-between` in the original design -- with whatever's left as
    // plain empty card between them, not a broken-looking half-empty box.
    var icon_node: L.Node = .{ .width = .{ .fixed = icon_size }, .height = .{ .fixed = icon_size } };
    var temp_node: L.Node = .{ .width = .{ .fixed = temp_label.width() }, .height = .{ .fixed = temp_fs } };
    var cond_line: L.Node = .{ .height = .{ .fixed = cond_fs } };
    var loc_line: L.Node = .{ .height = .{ .fixed = loc_fs } };
    var cond_block: L.Node = .{
        .axis = .column,
        .gap = cond_gap,
        .width = .{ .flex = 1 },
        .height = .{ .fixed = cond_fs + cond_gap + loc_fs },
        .children = &.{ &cond_line, &loc_line },
    };
    var now_row: L.Node = .{
        .axis = .row,
        .gap = now_gap,
        .align_items = .center,
        .height = .{ .fixed = @max(icon_size, cond_fs + cond_gap + loc_fs) },
        .children = &.{ &icon_node, &temp_node, &cond_block },
    };
    var forecast_row: L.Node = .{ .height = .{ .fixed = forecast_h } };
    var card_content: L.Node = .{
        .axis = .column,
        .justify = .space_between,
        .padding = .{ .top = theme.dash_weather_pad_top * scale, .left = pad_x, .right = pad_x, .bottom = theme.dash_weather_pad_bottom * scale },
        .children = if (has_forecast) &.{ &now_row, &forecast_row } else &.{&now_row},
    };
    L.layout(&card_content, outer);

    try (WeatherIcon{ .kind = weather_mod.iconFor(wx.code), .accent = theme.accent, .dim = theme.dim, .faint = theme.faint })
        .draw(ctx, icon_node.result.x, icon_node.result.y, icon_size, scale);
    try temp_label.draw(ctx, temp_node.result);

    const cond_label: Label = .{ .text = wx.condition(), .font_size = cond_fs, .color = theme.text };
    try cond_label.drawClipped(ctx, cond_line.result);

    var loc_buf: [96]u8 = undefined;
    const loc_str = std.fmt.bufPrint(&loc_buf, "{s} \xC2\xB7 H {d:.0}\xC2\xB0 L {d:.0}\xC2\xB0", .{ wx.city, wx.high_c, wx.low_c }) catch "";
    const loc_label: Label = .{ .text = loc_str, .font_size = loc_fs, .color = theme.dim };
    try loc_label.drawClipped(ctx, loc_line.result);

    if (!has_forecast) return;

    const rule_y = forecast_row.result.y - theme.dash_forecast_gap_top * scale;
    ctx.setSourceToPixel(theme.border);
    try shapes.fillRect(ctx, outer.x + pad_x, rule_y, outer.w - pad_x * 2, @max(1.0, scale));
    ctx.resetPath();

    var slot_nodes: [4]L.Node = undefined;
    var slot_ptrs: [4]*L.Node = undefined;
    for (0..wx.hourly.len) |i| {
        slot_nodes[i] = .{ .width = .{ .flex = 1 } };
        slot_ptrs[i] = &slot_nodes[i];
    }
    var forecast_slots: L.Node = .{
        .axis = .row,
        .gap = theme.dash_forecast_col_gap * scale,
        .children = slot_ptrs[0..wx.hourly.len],
    };
    L.layout(&forecast_slots, forecast_row.result);

    for (wx.hourly, 0..) |hf, i| {
        const slot = slot_nodes[i].result;
        const slot_cx = slot.x + slot.w / 2;

        const time_label: Label = .{ .text = hf.label, .font_size = time_fs, .color = theme.faint };
        try time_label.draw(ctx, .{ .x = slot_cx - time_label.width() / 2, .y = slot.y });

        const hi_y = slot.y + time_fs + slot_gap;
        try (WeatherIcon{ .kind = weather_mod.iconFor(hf.code), .accent = theme.accent, .dim = theme.dim, .faint = theme.faint })
            .draw(ctx, slot_cx - forecast_icon_size / 2, hi_y, forecast_icon_size, scale);

        var htemp_buf: [16]u8 = undefined;
        const htemp_str = std.fmt.bufPrint(&htemp_buf, "{d:.0}\xC2\xB0", .{hf.temp_c}) catch "";
        const htemp_label: Label = .{ .text = htemp_str, .font_size = val_fs, .color = theme.text };
        try htemp_label.draw(ctx, .{ .x = slot_cx - htemp_label.width() / 2, .y = hi_y + forecast_icon_size + slot_gap });
    }
}

fn drawCalendarCard(ctx: *z2d.Context, theme: *const Theme, dash: dashboard_mod.Dashboard, outer: L.Rect, scale: f64) !void {
    try drawCard(ctx, theme, outer.x, outer.y, outer.w, outer.h, scale);

    const title_fs = theme.dash_cal_title_font_size * scale;
    const week_fs = theme.dash_cal_week_font_size * scale;
    var week_buf: [16]u8 = undefined;
    const week_str = std.fmt.bufPrint(&week_buf, "Week {d}", .{dash.iso_week}) catch "";

    const title_label: Label = .{ .text = dash.month_label, .font_size = title_fs, .color = theme.text };
    const week_label: Label = .{ .text = week_str, .font_size = week_fs, .color = theme.faint };

    // `.cal-head { justify-content: space-between }`: title pinned left,
    // "Week N" pinned right.
    var title_node: L.Node = .{ .width = .{ .fixed = title_label.width() }, .height = .{ .fixed = title_fs } };
    var week_node: L.Node = .{ .width = .{ .fixed = week_label.width() }, .height = .{ .fixed = week_fs } };
    // `.cal-head { align-items: baseline }`: approximated by bottom-
    // aligning the smaller "Week N" label against the title's box.
    var cal_head: L.Node = .{ .axis = .row, .justify = .space_between, .align_items = .end, .height = .{ .fixed = title_fs }, .children = &.{ &title_node, &week_node } };

    const wd_fs = theme.dash_cal_wd_font_size * scale;
    var wd_slots: [7]L.Node = undefined;
    var wd_ptrs: [7]*L.Node = undefined;
    for (0..7) |i| {
        wd_slots[i] = .{ .width = .{ .flex = 1 }, .height = .{ .fixed = wd_fs } };
        wd_ptrs[i] = &wd_slots[i];
    }
    var wd_row: L.Node = .{ .axis = .row, .gap = theme.dash_cal_col_gap * scale, .height = .{ .fixed = wd_fs }, .children = &wd_ptrs };

    const row_h = theme.dash_cal_row_h * scale;
    var day_slots: [7]L.Node = undefined;
    var day_ptrs: [7]*L.Node = undefined;
    for (0..7) |i| {
        day_slots[i] = .{ .width = .{ .flex = 1 }, .height = .{ .fixed = row_h } };
        day_ptrs[i] = &day_slots[i];
    }
    var day_col_row: L.Node = .{ .axis = .row, .gap = theme.dash_cal_col_gap * scale, .height = .{ .fixed = row_h }, .children = &day_ptrs };

    var grid: L.Node = .{ .height = .{ .fixed = row_h * @as(f64, @floatFromInt(dash.day_rows)) } };
    var card: L.Node = .{
        .axis = .column,
        .gap = theme.dash_calendar_gap * scale,
        .padding = .{ .top = theme.dash_calendar_pad_top * scale, .left = theme.dash_calendar_pad_x * scale, .right = theme.dash_calendar_pad_x * scale, .bottom = theme.dash_calendar_pad_bottom * scale },
        .children = &.{ &cal_head, &wd_row, &grid },
    };
    L.layout(&card, outer);
    // Column x/w are shared by the weekday header and every day row --
    // resolve them once against the grid's width, independent of `wd_row`
    // (which sits in `card`'s flow, one row above).
    L.layout(&day_col_row, .{ .x = grid.result.x, .y = grid.result.y, .w = grid.result.w, .h = row_h });

    try title_label.draw(ctx, title_node.result);
    try week_label.draw(ctx, week_node.result);

    const weekday_labels = [_][]const u8{ "Mo", "Tu", "We", "Th", "Fr", "Sa", "Su" };
    for (weekday_labels, 0..) |lbl, i| {
        const slot = wd_slots[i].result;
        const label: Label = .{ .text = lbl, .font_size = wd_fs, .color = theme.faint };
        try label.draw(ctx, .{ .x = slot.x + (slot.w - label.width()) / 2, .y = slot.y });
    }

    const day_fs = theme.dash_cal_day_font_size * scale;

    for (dash.days, 0..) |cell, i| {
        if (cell.day == 0) continue;
        const row = i / 7;
        const col = i % 7;
        const col_slot = day_ptrs[col].result;
        const cell_y = grid.result.y + row_h * @as(f64, @floatFromInt(row));

        var day_buf: [4]u8 = undefined;
        const day_str = std.fmt.bufPrint(&day_buf, "{d}", .{cell.day}) catch "";

        if (cell.is_today) {
            ctx.setSourceToPixel(theme.accent);
            try shapes.roundedRect(ctx, col_slot.x, cell_y, col_slot.w, row_h, 7 * scale);
            try ctx.fill();
            ctx.resetPath();
        }

        const day_label: Label = .{ .text = day_str, .font_size = day_fs, .color = if (cell.is_today) theme.panel_bg else theme.text };
        try day_label.draw(ctx, .{
            .x = col_slot.x + (col_slot.w - day_label.width()) / 2,
            .y = cell_y + (row_h - day_fs) / 2,
        });
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
    outer: L.Rect,
    scale: f64,
) !void {
    const label_fs = theme.dash_recent_label_font_size * scale;
    const tile_size = theme.icon_tile_size * scale;

    var label_node: L.Node = .{ .height = .{ .fixed = label_fs } };
    var slots: [5]L.Node = undefined;
    var slot_ptrs: [5]*L.Node = undefined;
    for (0..5) |i| {
        slots[i] = .{ .width = .{ .flex = 1 } };
        slot_ptrs[i] = &slots[i];
    }
    // `height` is otherwise unread (only `.result.y`/slot `.result.x/.w`
    // matter to the drawing below, and `y` only depends on *preceding*
    // siblings' sizes, not this node's own) -- set anyway so this isn't a
    // landmine for whatever's added here next.
    var tiles_row: L.Node = .{ .axis = .row, .height = .{ .fixed = tile_size }, .children = &slot_ptrs };
    var section: L.Node = .{
        .axis = .column,
        .gap = theme.dash_recent_gap * scale,
        .padding = .{ .left = theme.dash_recent_label_pad_x * scale },
        .children = &.{ &label_node, &tiles_row },
    };
    L.layout(&section, outer);

    try (Label{ .text = "RECENT", .font_size = label_fs, .color = theme.faint }).draw(ctx, label_node.result);

    const environ_ref = environ orelse return;
    const recents = history_mod.loadRecent(alloc, io, environ_ref, 5);
    if (recents.len == 0) return;

    // Icon tile centered on top of each slot, name centered below it --
    // like an Apps-tab row's tile, not a side-by-side pill.
    const tiles_y = tiles_row.result.y;
    const name_fs = theme.dash_recent_name_font_size * scale;

    for (recents, 0..) |entry, i| {
        const slot = slots[i].result;
        const tile_x = slot.x + (slot.w - tile_size) / 2;

        const real_icon: ?icon_mod.Icon = blk: {
            const cache = icon_cache orelse break :blk null;
            const name = entry.icon_name orelse break :blk null;
            break :blk cache.get(name);
        };

        const tile: IconTile = .{
            .icon = real_icon,
            .label = entry.label,
            .color_index = i,
            .radius = theme.icon_tile_radius * scale,
            .letter_font_size = theme.icon_letter_size * scale,
        };
        try tile.draw(ctx, surface, .{ .x = tile_x, .y = tiles_y, .w = tile_size, .h = tile_size });

        const name_label: Label = .{ .text = entry.label, .font_size = name_fs, .color = theme.text };
        const clipped = clipCentered(name_label, slot.w);
        try clipped.draw(ctx, .{ .x = slot.x + @max(0.0, (slot.w - clipped.width()) / 2), .y = tiles_y + tile_size + 8 * scale });
    }
}

/// Truncates `label` to fit `avail_w`, keeping room for an ellipsis when
/// it doesn't -- used where a label needs centering *after* truncation
/// (so its width must be known first), unlike `Label.drawClipped`'s
/// left-aligned silent clip.
fn clipCentered(label: Label, avail_w: f64) Label {
    const char_w = Theme.charWidth(label.font_size);
    const max_chars: usize = if (char_w > 0) @intFromFloat(@max(0.0, avail_w / char_w)) else 0;
    if (max_chars > 1 and label.text.len > max_chars) {
        var clipped = label;
        clipped.text = label.text[0 .. max_chars - 1];
        return clipped;
    }
    return label;
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
    const tile_size = theme.icon_tile_size * scale;
    const tile_x = padding * 0.5 + row_pad_x;
    const tile_y = row_y + (row_h - tile_size) / 2;

    const real_icon: ?icon_mod.Icon = blk: {
        const cache = icon_cache orelse break :blk null;
        const name = entry.icon_name orelse break :blk null;
        break :blk cache.get(name);
    };

    const tile: IconTile = .{
        .icon = real_icon,
        .label = entry.label,
        .color_index = entry_index,
        .radius = theme.icon_tile_radius * scale,
        .letter_font_size = theme.icon_letter_size * scale,
    };
    try tile.draw(ctx, surface, .{ .x = tile_x, .y = tile_y, .w = tile_size, .h = tile_size });

    const text_x = tile_x + tile_size + row_pad_x * 0.7;
    const has_subtitle = entry.subtitle != null;
    const name_y = if (has_subtitle) row_y + row_h * 0.18 else row_y + (row_h - name_fs) / 2;

    const max_chars: usize = blk: {
        const avail = width - padding - row_pad_x - text_x;
        break :blk if (char_w > 0) @intFromFloat(@max(0.0, avail / char_w)) else 0;
    };
    var positions_buf: [256]usize = undefined;
    try matchedLabelFor(state, theme, entry.label, name_fs, &positions_buf).draw(ctx, text_x, name_y, char_w, max_chars);

    if (entry.subtitle) |sub| {
        const sub_fs = theme.subtitle_font_size * scale;
        try (Label{ .text = sub, .font_size = sub_fs, .color = theme.dim }).draw(ctx, .{ .x = text_x, .y = row_y + row_h * 0.55 });
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
    const text_x = padding * 0.5 + row_pad_x;
    const name_y = row_y + (row_h - font_size) / 2;

    // Reserved on every row, not just the selected one, so the right-aligned
    // path doesn't shift (and overlap the badge) as the selection moves.
    const right_boundary = width - padding * 0.5 - row_pad_x - enterCapReservedWidth(theme, scale);

    var right_text: ?[]const u8 = null;
    if (entry.action) |a| {
        if (!entry.is_clipboard_marker and !std.mem.eql(u8, a, entry.label)) right_text = a;
    }
    // Values sourced from e.g. dmenu's `-display-columns` may still carry
    // the raw separator (a tab), which has no glyph in the monospace font
    // and renders as a tofu box -- fold whitespace controls to a space.
    // Bespoke, not `Label.drawClipped`: this truncates from the *front*
    // (keeping the tail -- the binary name matters more than the dir),
    // which no generic widget here does.
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
    var positions_buf: [256]usize = undefined;
    try matchedLabelFor(state, theme, entry.label, font_size, &positions_buf).draw(ctx, text_x, name_y, char_w, max_chars);

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

/// Builds the fuzzy-match-highlighted label for a row name: scores
/// `full_label` against the live query and finds matched byte offsets,
/// then hands them to `MatchedLabel` for the actual drawing. The scoring
/// stays here (an app concern -- it needs `state.scratch`/`fuzzy.zig`);
/// only the "draw some codepoints in a highlight color" part is generic.
/// `positions_buf` is caller-owned (not a local here) on purpose: the
/// returned `MatchedLabel.positions` slices into it, and a buffer local to
/// this function would go out of scope the instant it returns, leaving
/// `.positions` dangling into a stack frame that's already been reused by
/// the time `.draw()` reads it (confirmed the hard way: only byte offset 0
/// kept "matching" -- whatever garbage happened to be left on the stack
/// read back as 0 there often enough to look like "only the first char
/// highlights").
fn matchedLabelFor(state: *State, theme: *const Theme, full_label: []const u8, font_size: f64, positions_buf: *[256]usize) MatchedLabel {
    var positions: []const usize = &.{};
    if (state.query.items.len > 0 and state.query.items.len <= positions_buf.len) {
        const s = fuzzy.scoreWithPositions(&state.scratch, state.query.items, full_label, positions_buf[0..state.query.items.len]) catch fuzzy.SCORE_MIN;
        if (s > fuzzy.SCORE_MIN) positions = positions_buf[0..state.query.items.len];
    }
    return .{
        .text = full_label,
        .positions = positions,
        .font_size = font_size,
        .color = theme.text,
        .highlight = theme.accent,
        .faint = theme.faint,
    };
}

const enter_cap_label = "Enter";

/// Width `drawEnterCap` will occupy, including its right margin -- callers
/// laying out row content (e.g. compact rows' right-aligned path) must
/// reserve this on every row, not just the selected one, or that content
/// shifts and can overlap the badge when the selection moves onto it.
fn enterCapReservedWidth(theme: *const Theme, scale: f64) f64 {
    const cap_fs = theme.footer_cap_font_size * scale;
    const cap_pad_x: f64 = 6 * scale;
    const cap_w = (Label{ .text = enter_cap_label, .font_size = cap_fs, .color = undefined }).width() + cap_pad_x * 2;
    return cap_w + 10 * scale;
}

fn drawEnterCap(ctx: *z2d.Context, theme: *const Theme, width: f64, padding: f64, row_y: f64, row_h: f64, scale: f64) !void {
    const cap_fs = theme.footer_cap_font_size * scale;
    const cap_pad_x: f64 = 6 * scale;
    const cap_w = (Label{ .text = enter_cap_label, .font_size = cap_fs, .color = undefined }).width() + cap_pad_x * 2;
    const cap_h = cap_fs + 6 * scale;
    const cap_x = width - padding * 0.5 - 10 * scale - cap_w;
    const cap_y = row_y + (row_h - cap_h) / 2;

    const btn: Button = .{
        .label = .{ .text = enter_cap_label, .font_size = cap_fs, .color = theme.dim },
        .bg = theme.chip_track,
        .radius = 4 * scale,
    };
    try btn.draw(ctx, .{ .x = cap_x, .y = cap_y, .w = cap_w, .h = cap_h });
}

fn drawFooter(ctx: *z2d.Context, theme: *const Theme, state: *State, width: f64, padding: f64, footer_y: f64, footer_h: f64, scale: f64) !void {
    const fs = theme.footer_font_size * scale;
    const pad_x = theme.footer_pad_x * scale;

    var buf: [64]u8 = undefined;
    const noun = if (theme.compact_rows) "commands" else "apps";
    const status = if (state.query.items.len == 0)
        std.fmt.bufPrint(&buf, "{d} {s} \xC2\xB7 most used first", .{ state.entries.len, noun }) catch "" // "·"
    else
        std.fmt.bufPrint(&buf, "{d} of {d} {s}", .{ state.results.items.len, state.entries.len, noun }) catch "";
    const status_label: Label = .{ .text = status, .font_size = fs, .color = theme.faint };

    const cap_fs = theme.footer_cap_font_size * scale;
    const key_pad: f64 = 5 * scale;
    const key_h = cap_fs + 6 * scale;
    const unit_gap = 6 * scale;

    // Visual left-to-right order (the original right-to-left placement
    // loop worked out to this order on screen).
    const Cap = struct { key: []const u8, label: []const u8 };
    const caps = [_]Cap{
        .{ .key = "Enter", .label = "open" },
        .{ .key = "Tab", .label = "mode" },
        .{ .key = "Esc", .label = "close" },
    };

    var label_nodes: [caps.len]L.Node = undefined;
    var key_nodes: [caps.len]L.Node = undefined;
    var unit_nodes: [caps.len]L.Node = undefined;
    var unit_ptrs: [caps.len]*L.Node = undefined;
    // Named per-unit storage for each unit's children slice -- an
    // anonymous `&.{ &label_nodes[i], &key_nodes[i] }` built fresh inside
    // this loop would alias a single reused temporary across iterations,
    // corrupting every unit but the last one (confirmed the hard way: the
    // footer's caps rendered overlapping near the top-left corner instead
    // of spread across the bottom-right, since `layout()` ended up
    // recursing into the same (last-iteration) label/key nodes for all
    // three units).
    var unit_children: [caps.len][2]*L.Node = undefined;
    const caps_gap = theme.footer_caps_gap * scale;
    var caps_row_w: f64 = 0;
    for (caps, 0..) |cap, i| {
        const label_w = (Label{ .text = cap.label, .font_size = fs, .color = undefined }).width();
        const key_w = (Label{ .text = cap.key, .font_size = cap_fs, .color = undefined }).width() + key_pad * 2;
        const unit_w = label_w + unit_gap + key_w;
        label_nodes[i] = .{ .height = .{ .fixed = fs }, .width = .{ .fixed = label_w } };
        key_nodes[i] = .{ .height = .{ .fixed = key_h }, .width = .{ .fixed = key_w } };
        unit_children[i] = .{ &key_nodes[i], &label_nodes[i] };
        unit_nodes[i] = .{
            .axis = .row,
            .gap = unit_gap,
            .align_items = .center,
            .width = .{ .fixed = unit_w },
            .height = .{ .fixed = footer_h },
            .children = &unit_children[i],
        };
        unit_ptrs[i] = &unit_nodes[i];
        caps_row_w += unit_w;
        if (i != 0) caps_row_w += caps_gap;
    }
    // `caps_row`'s own width must be explicit -- it's a `main`-axis child
    // of `footer_row` below, and an unset (`.auto`) main-axis size
    // resolves to 0 (see `layout.zig`'s doc comment), which pushed the
    // whole row off the right edge instead of flush against it.
    var caps_row: L.Node = .{ .axis = .row, .gap = caps_gap, .width = .{ .fixed = caps_row_w }, .height = .{ .fixed = footer_h }, .children = &unit_ptrs };

    var status_node: L.Node = .{ .width = .{ .fixed = status_label.width() }, .height = .{ .fixed = fs } };
    var footer_row: L.Node = .{
        .axis = .row,
        .justify = .space_between,
        .align_items = .center,
        .padding = .{ .left = pad_x, .right = padding * 0.5 + pad_x },
        .children = &.{ &status_node, &caps_row },
    };
    L.layout(&footer_row, .{ .x = 0, .y = footer_y, .w = width, .h = footer_h });

    try status_label.draw(ctx, status_node.result);

    for (caps, 0..) |cap, i| {
        try (Label{ .text = cap.label, .font_size = fs, .color = theme.faint }).draw(ctx, label_nodes[i].result);
        const btn: Button = .{
            .label = .{ .text = cap.key, .font_size = cap_fs, .color = theme.dim },
            .bg = theme.chip_track,
            .radius = 4 * scale,
        };
        try btn.draw(ctx, key_nodes[i].result);
    }
}
