//! Panel geometry, colors and font, matching the formal UI spec (dark
//! theme token values below; light theme is a follow-up). All sizes are
//! logical (pre-scale); the renderer multiplies everything by the caller's
//! scale factor.
const z2d = @import("z2d");

fn rgba(r: u8, g: u8, b: u8, a: u8) z2d.Pixel {
    return .{ .rgba = (z2d.pixel.RGBA{ .r = r, .g = g, .b = b, .a = a }).multiply() };
}

fn hex(comptime h: u24) z2d.Pixel {
    return rgba((h >> 16) & 0xFF, (h >> 8) & 0xFF, h & 0xFF, 0xFF);
}

/// Icon tile background colors, cycled by an entry's stable original index
/// (not its filtered/sorted position, so a given app's tile color doesn't
/// jump around as the query changes).
pub const icon_palette = [_]z2d.Pixel{
    hex(0x3D5F8F), // blue
    hex(0x2F6B66), // teal
    hex(0x6A4A7E), // purple
    hex(0x8A4F35), // orange/brown
    hex(0x56662F), // olive
    hex(0x4A5260), // slate
    hex(0x7A3F55), // maroon/rose
};

pub const Tab = enum { apps, run, windows, clipboard };

pub const Theme = struct {
    // Mode chrome (not shown in dmenu mode)
    show_tabs: bool = false,
    active_tab: Tab = .apps,
    /// Dim placeholder shown in the query field when empty.
    placeholder: []const u8 = "Search",
    /// dmenu's `-p PROMPT`: replaces the search icon with this label in
    /// the prompt's accent color. `show_tabs` should be false whenever
    /// this is set.
    dmenu_prompt: ?[]const u8 = null,
    /// Binary name used to open a URL-shaped query (see `state.zig`'s
    /// synthetic "open in browser" entry). Also used as the freedesktop
    /// icon name for that row's tile. Override with `$ZOFI_BROWSER`.
    browser_cmd: []const u8 = "firefox",
    /// Bare `zofi` (no `-show`/`-dmenu`): shows the idle dashboard (clock,
    /// calendar, recent apps) in place of the row list whenever the query
    /// is empty. `-show drun` etc. never sets this, so their behavior is
    /// unchanged.
    dashboard_enabled: bool = false,

    // Panel
    panel_width: f64 = 640,
    panel_height: f64 = 516, // fixed, never jumps regardless of result count
    corner_radius: f64 = 14,
    border_width: f64 = 1,
    panel_padding: f64 = 18,

    // Prompt row
    prompt_row_height: f64 = 52,
    prompt_icon_size: f64 = 18,
    prompt_gap: f64 = 12,
    query_font_size: f64 = 18,

    // Mode switch (Apps/Run/Windows tabs, top-right of the prompt row)
    mode_track_pad: f64 = 3,
    mode_track_radius: f64 = 9,
    mode_chip_height: f64 = 28,
    mode_chip_radius: f64 = 6,
    mode_chip_pad_x: f64 = 10,
    mode_chip_font_size: f64 = 12,

    // Divider between prompt row and the list
    divider_inset: f64 = 6,

    // List
    list_height: f64 = 398,
    list_padding: f64 = 6,
    list_row_gap: f64 = 2,
    row_radius: f64 = 8,
    row_pad_x: f64 = 12,
    /// Tall rows (icon tile + name + subtitle) for Apps/Windows; compact
    /// single-line rows for Run/dmenu.
    compact_rows: bool = false,
    row_height_tall: f64 = 48,
    row_height_compact: f64 = 36,
    name_font_size: f64 = 15,
    subtitle_font_size: f64 = 12.5,
    compact_font_size: f64 = 14,

    // Dashboard (idle default view: clock/date, calendar, recent apps).
    // Numbers below are lifted 1:1 from the exported `zofi-home.html`
    // design spec (same 640-wide unit system as `panel_width`).
    dash_pad_top: f64 = 10, // .home padding-top
    dash_pad_bottom: f64 = 6, // .home padding-bottom
    dash_gap: f64 = 12, // .home gap (between .top and .recent)
    dash_top_h: f64 = 290, // .top height (fixed, not proportional)
    dash_col_gap: f64 = 12, // .top gap (left column <-> calendar)
    dash_left_gap: f64 = 14, // .left gap (clock block <-> weather card)

    dash_card_radius: f64 = 10,
    dash_card_bg: z2d.Pixel = hex(0x1F2024), // --card (distinct from chip_track)

    dash_clock_pad: f64 = 8, // .clock padding (left/right/top; bottom 0)
    dash_clock_font_size: f64 = 60,
    dash_clock_gap: f64 = 10, // gap between time and date
    dash_date_font_size: f64 = 15,

    dash_weather_pad_top: f64 = 14,
    dash_weather_pad_x: f64 = 16,
    dash_weather_pad_bottom: f64 = 12,
    dash_weather_icon_size: f64 = 44,
    dash_weather_now_gap: f64 = 14, // gap between icon/temp/condition block
    dash_temp_font_size: f64 = 34,
    dash_cond_font_size: f64 = 14, // condition name, e.g. "Partly cloudy"
    dash_cond_gap: f64 = 3, // gap between condition name and location line
    dash_loc_font_size: f64 = 12.5, // "Lisbon · H 23° L 15°"
    dash_forecast_gap_top: f64 = 10,
    dash_forecast_col_gap: f64 = 4,
    dash_forecast_icon_size: f64 = 20,
    dash_forecast_slot_gap: f64 = 5, // vertical gap within one forecast slot
    dash_forecast_time_font_size: f64 = 11.5,
    dash_forecast_temp_font_size: f64 = 13,

    dash_calendar_width: f64 = 272, // fixed, not proportional
    dash_calendar_pad_top: f64 = 14,
    dash_calendar_pad_x: f64 = 14,
    dash_calendar_pad_bottom: f64 = 10,
    dash_calendar_gap: f64 = 8, // gap between cal-head and the day grid
    dash_cal_title_font_size: f64 = 14,
    dash_cal_week_font_size: f64 = 12,
    dash_cal_wd_font_size: f64 = 11, // weekday header row (Mo Tu We...)
    dash_cal_day_font_size: f64 = 13,
    dash_cal_row_h: f64 = 30,
    dash_cal_col_gap: f64 = 2,

    dash_recent_gap: f64 = 18, // between "RECENT" label and the tile row
    dash_recent_label_font_size: f64 = 11.5,
    dash_recent_label_pad_x: f64 = 8,
    dash_recent_name_font_size: f64 = 13.5,

    // Icon tile
    icon_tile_size: f64 = 28,
    icon_tile_radius: f64 = 7,
    icon_letter_size: f64 = 13,

    // Clipboard tab: split list + preview pane (zofi-clipboard.html).
    // Rows reuse `row_height_tall`/`icon_tile_size` above (the mockup's
    // 48px row height and 28px tile match those exactly); these are the
    // pane-specific numbers on top of that.
    clip_list_w: f64 = 300, // .list width
    clip_gap: f64 = 12, // gap either side of the vertical rule
    clip_stage_h: f64 = 196, // .stage height
    clip_preview_gap: f64 = 14, // .preview gap (between stage and meta list)
    clip_meta_gap: f64 = 8, // .meta gap (between dt/dd rows)
    clip_meta_font_size: f64 = 12.5,

    // Footer
    footer_height: f64 = 34,
    footer_pad_x: f64 = 12,
    footer_caps_gap: f64 = 14,
    footer_font_size: f64 = 12,
    footer_cap_font_size: f64 = 11,

    // Color tokens
    panel_bg: z2d.Pixel = hex(0x17181B),
    border: z2d.Pixel = hex(0x2D2F35),
    text: z2d.Pixel = hex(0xECECEC),
    dim: z2d.Pixel = hex(0xA0A2A9),
    faint: z2d.Pixel = hex(0x8A8C94),
    selected: z2d.Pixel = hex(0x26282D),
    chip_track: z2d.Pixel = hex(0x202226),
    chip_on: z2d.Pixel = hex(0x34373D),
    accent: z2d.Pixel = hex(0xF0B44C),

    /// Path to a monospace TrueType/OpenType font, used for everything:
    /// query, row names/subtitles, footer. Populated by `core/font.zig`
    /// discovery before the first render. Deliberately not the spec's
    /// proportional Sans -- z2d has no text-measurement API, and matched-
    /// character highlighting draws a row's name as several sequential
    /// `showText` calls positioned by estimated advance. With a
    /// proportional font that estimate drifts (the same bug class fixed
    /// earlier for the query cursor); with a real monospace font the
    /// per-char advance is exact, so runs butt together correctly.
    font_path: ?[]const u8 = null,

    /// How many result rows fit in the fixed-height list for the active
    /// row style (8 for tall rows, 10 for compact -- matches the spec).
    pub fn visibleRows(self: Theme) usize {
        const row_h = self.rowHeight() + self.list_row_gap;
        return @intFromFloat(@max(1.0, @floor((self.list_height + self.list_row_gap) / row_h)));
    }

    pub fn rowHeight(self: Theme) f64 {
        return if (self.compact_rows) self.row_height_compact else self.row_height_tall;
    }

    pub fn rowFontSize(self: Theme) f64 {
        return if (self.compact_rows) self.compact_font_size else self.name_font_size;
    }

    /// Per-character advance at the given font size. Exact, not
    /// estimated, when `font_path` resolved to a genuinely monospace font
    /// (measured empirically: DejaVu Sans Mono advances at exactly
    /// 0.6 * font_size). This is what makes cursor placement, query
    /// viewport scrolling, and multi-run matched-character highlighting
    /// all positionable without z2d's (nonexistent) text-measurement API.
    pub fn charWidth(font_size: f64) f64 {
        return font_size * 0.6;
    }
};
