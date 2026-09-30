//! Idle-state dashboard: clock, date, calendar and (soon) weather/recent
//! apps, shown instead of the row list when the query is empty and
//! `theme.dashboard_enabled` is set (bare `zofi`, no `-show`/`-dmenu`).
//! Calendar math goes through libc's time.h rather than reimplementing a
//! timezone-aware calendar (leap years, DST, $TZ, /etc/localtime) from
//! scratch -- this project already links libc via `core_mod.link_libc`.
const std = @import("std");
const c = @cImport({
    @cInclude("time.h");
});

pub const CalendarDay = struct {
    /// 0 means "no day in this grid cell" (padding before the 1st / after
    /// the last day of the month).
    day: u8 = 0,
    is_today: bool = false,
};

pub const Dashboard = struct {
    hour: u8,
    minute: u8,
    /// e.g. "Friday, 25 September 2026".
    weekday_date: []const u8,
    /// e.g. "September 2026".
    month_label: []const u8,
    iso_week: u8,
    /// Row-major, Mo..Su columns, up to 6 rows. `day_rows` says how many
    /// rows are actually populated.
    days: [42]CalendarDay = [_]CalendarDay{.{}} ** 42,
    day_rows: usize,
};

pub fn build(allocator: std.mem.Allocator) !Dashboard {
    var tt: c.time_t = c.time(null);
    var tm: c.struct_tm = undefined;
    _ = c.localtime_r(&tt, &tm);

    var date_buf: [64]u8 = undefined;
    const date_len = c.strftime(&date_buf, date_buf.len, "%A, %d %B %Y", &tm);
    const weekday_date = try allocator.dupe(u8, date_buf[0..date_len]);

    var month_buf: [32]u8 = undefined;
    const month_len = c.strftime(&month_buf, month_buf.len, "%B %Y", &tm);
    const month_label = try allocator.dupe(u8, month_buf[0..month_len]);

    var week_buf: [8]u8 = undefined;
    const week_len = c.strftime(&week_buf, week_buf.len, "%V", &tm);
    const iso_week = std.fmt.parseInt(u8, week_buf[0..week_len], 10) catch 0;

    // tm_wday is Sun=0..Sat=6; the header row is Mo..Su, so remap to Mon=0.
    var first_tm = tm;
    first_tm.tm_mday = 1;
    first_tm.tm_hour = 12; // noon: sidesteps any DST-transition-at-midnight edge case
    _ = c.mktime(&first_tm); // normalizes tm_wday for the 1st of the month
    const first_wday_mo0: usize = @intCast(@mod(@as(i32, first_tm.tm_wday) + 6, 7));

    const year: i32 = @as(i32, first_tm.tm_year) + 1900;
    const month: u4 = @intCast(first_tm.tm_mon + 1);
    const days_in_month = daysInMonth(year, month);
    const today: u8 = @intCast(tm.tm_mday);

    var days: [42]CalendarDay = [_]CalendarDay{.{}} ** 42;
    var d: u8 = 1;
    var idx: usize = first_wday_mo0;
    while (d <= days_in_month) : (d += 1) {
        days[idx] = .{ .day = d, .is_today = d == today };
        idx += 1;
    }
    const day_rows = (first_wday_mo0 + days_in_month + 6) / 7;

    return .{
        .hour = @intCast(tm.tm_hour),
        .minute = @intCast(tm.tm_min),
        .weekday_date = weekday_date,
        .month_label = month_label,
        .iso_week = iso_week,
        .days = days,
        .day_rows = day_rows,
    };
}

fn daysInMonth(year: i32, month: u4) u8 {
    const lengths = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (month == 2 and isLeap(year)) return 29;
    return lengths[month - 1];
}

fn isLeap(year: i32) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

test "build produces a populated calendar for the current month" {
    const dash = try build(std.testing.allocator);
    defer std.testing.allocator.free(dash.weekday_date);
    defer std.testing.allocator.free(dash.month_label);

    try std.testing.expect(dash.hour < 24);
    try std.testing.expect(dash.minute < 60);
    try std.testing.expect(dash.day_rows >= 4 and dash.day_rows <= 6);

    var today_count: usize = 0;
    var max_day: u8 = 0;
    for (dash.days) |cell| {
        if (cell.day > max_day) max_day = cell.day;
        if (cell.is_today) today_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), today_count);
    try std.testing.expect(max_day >= 28 and max_day <= 31);
}

test "daysInMonth handles leap years" {
    try std.testing.expectEqual(@as(u8, 29), daysInMonth(2024, 2));
    try std.testing.expectEqual(@as(u8, 28), daysInMonth(2023, 2));
    try std.testing.expectEqual(@as(u8, 28), daysInMonth(1900, 2)); // divisible by 100, not 400
    try std.testing.expectEqual(@as(u8, 29), daysInMonth(2000, 2)); // divisible by 400
}
