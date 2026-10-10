//! Current weather + short hourly forecast for the dashboard's weather
//! card. Free, no-key APIs (ip-api.com for IP geolocation, open-meteo.com
//! for the forecast), shelled out to via `curl` -- consistent with how
//! this project already talks to `hyprctl` rather than linking an HTTP/TLS
//! client. Network calls never happen on the render path: `loadCached`
//! only ever reads a local file, and `maybeRefresh` kicks off a detached
//! self-reexec (`zofi --internal-refresh-weather`) that does the actual
//! fetching, so a stale or missing cache never adds latency to opening
//! the launcher.
const std = @import("std");
const Io = std.Io;

pub const HourForecast = struct {
    label: []const u8,
    code: i64,
    temp_c: f64,
};

pub const Weather = struct {
    temp_c: f64,
    code: i64,
    city: []const u8,
    high_c: f64,
    low_c: f64,
    hourly: []const HourForecast,

    pub fn condition(self: Weather) []const u8 {
        return conditionText(self.code);
    }
};

const refresh_interval_s: i64 = 30 * 60;
const location_refresh_interval_s: i64 = 30 * 24 * 60 * 60;

fn cacheDir(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ?[]const u8 {
    if (environ.get("XDG_CACHE_HOME")) |dir| {
        return std.fs.path.join(allocator, &.{ dir, "zofi" }) catch null;
    }
    const home = environ.get("HOME") orelse return null;
    return std.fs.path.join(allocator, &.{ home, ".cache", "zofi" }) catch null;
}

fn weatherPath(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ?[]const u8 {
    const dir = cacheDir(allocator, environ) orelse return null;
    return std.fs.path.join(allocator, &.{ dir, "weather.json" }) catch null;
}

fn locationPath(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ?[]const u8 {
    const dir = cacheDir(allocator, environ) orelse return null;
    return std.fs.path.join(allocator, &.{ dir, "location.json" }) catch null;
}

/// Reads the last fetched weather from cache. Never touches the network;
/// returns `null` if there's no cache yet (first run) or it's unreadable.
/// Stale data is still returned -- `maybeRefresh` is what decides whether
/// to kick off an update, not this.
pub fn loadCached(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) ?Weather {
    const path = weatherPath(allocator, environ) orelse return null;
    const contents = Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch return null;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch return null;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };

    const city = dupeJsonString(allocator, obj, "city") orelse "";
    const temp_c = jsonFloat(obj, "temp_c") orelse return null;
    const code = jsonInt(obj, "code") orelse 0;
    const high_c = jsonFloat(obj, "high_c") orelse temp_c;
    const low_c = jsonFloat(obj, "low_c") orelse temp_c;

    var hourly: std.ArrayList(HourForecast) = .empty;
    if (obj.get("hourly")) |h| if (h == .array) {
        for (h.array.items) |item| {
            if (item != .object) continue;
            const label = dupeJsonString(allocator, item.object, "label") orelse continue;
            const hcode = jsonInt(item.object, "code") orelse 0;
            const htemp = jsonFloat(item.object, "temp_c") orelse continue;
            hourly.append(allocator, .{ .label = label, .code = hcode, .temp_c = htemp }) catch continue;
        }
    };

    return .{
        .temp_c = temp_c,
        .code = code,
        .city = city,
        .high_c = high_c,
        .low_c = low_c,
        .hourly = hourly.items,
    };
}

fn jsonFloat(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

fn jsonInt(obj: std.json.ObjectMap, key: []const u8) ?i64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |n| n,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn dupeJsonString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .string => |s| allocator.dupe(u8, s) catch null,
        else => null,
    };
}

fn fileAgeSeconds(io: Io, path: []const u8) ?i64 {
    const stat = Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    const mtime_s: i64 = @intCast(@divTrunc(stat.mtime.nanoseconds, std.time.ns_per_s));
    const c = @cImport({
        @cInclude("time.h");
    });
    const now: i64 = @intCast(c.time(null));
    return now - mtime_s;
}

/// Kicks off a background refresh (detached re-exec of this same binary)
/// if the cache is missing or older than 30 minutes. Never blocks: the
/// *next* launch is what sees the updated data.
pub fn maybeRefresh(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) void {
    const path = weatherPath(allocator, environ) orelse return;
    const age = fileAgeSeconds(io, path);
    if (age) |a| if (a < refresh_interval_s) return;

    // Not "/proc/self/exe": macOS has no procfs.
    var exe_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const exe_len = std.process.executablePath(io, &exe_buf) catch return;

    _ = std.process.spawn(io, .{
        .argv = &.{ exe_buf[0..exe_len], "--internal-refresh-weather" },
        .environ_map = environ,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
}

/// Does the actual network fetch + cache write. Only ever called from the
/// hidden `--internal-refresh-weather` subprocess `maybeRefresh` spawns --
/// never on the interactive render path.
pub fn refreshNow(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) void {
    const dir = cacheDir(allocator, environ) orelse return;
    Io.Dir.cwd().createDirPath(io, dir) catch return;

    const loc = loadOrFetchLocation(allocator, io, environ) orelse return;

    const url = std.fmt.allocPrint(
        allocator,
        "https://api.open-meteo.com/v1/forecast?latitude={d:.4}&longitude={d:.4}&current_weather=true&hourly=temperature_2m,weathercode&daily=temperature_2m_max,temperature_2m_min&timezone=auto&forecast_days=1",
        .{ loc.lat, loc.lon },
    ) catch return;

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "curl", "-s", "--max-time", "5", url },
    }) catch return;
    if (result.term != .exited or result.term.exited != 0) return;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch return;
    const root = switch (parsed.value) {
        .object => |o| o,
        else => return,
    };
    const current = switch ((root.get("current_weather") orelse return)) {
        .object => |o| o,
        else => return,
    };
    const temp_c = jsonFloat(current, "temperature") orelse return;
    const code = jsonInt(current, "weathercode") orelse 0;
    const current_hour_iso = switch ((current.get("time") orelse return)) {
        .string => |s| s,
        else => return,
    };

    var high_c = temp_c;
    var low_c = temp_c;
    if (root.get("daily")) |d| if (d == .object) {
        if (d.object.get("temperature_2m_max")) |m| if (m == .array and m.array.items.len > 0) {
            high_c = jsonArrayFloat(m.array.items[0]) orelse high_c;
        };
        if (d.object.get("temperature_2m_min")) |m| if (m == .array and m.array.items.len > 0) {
            low_c = jsonArrayFloat(m.array.items[0]) orelse low_c;
        };
    };

    var hourly_json: std.ArrayList(u8) = .empty;
    hourly_json.append(allocator, '[') catch return;
    if (root.get("hourly")) |h| if (h == .object) {
        const times = switch ((h.object.get("time") orelse std.json.Value{ .null = {} })) {
            .array => |a| a.items,
            else => &.{},
        };
        const temps = switch ((h.object.get("temperature_2m") orelse std.json.Value{ .null = {} })) {
            .array => |a| a.items,
            else => &.{},
        };
        const codes = switch ((h.object.get("weathercode") orelse std.json.Value{ .null = {} })) {
            .array => |a| a.items,
            else => &.{},
        };

        // Find the first hourly slot at or after "now" (open-meteo's hourly
        // series starts at midnight local time, not the current hour).
        var start_idx: usize = 0;
        for (times, 0..) |t, i| {
            if (t == .string and std.mem.order(u8, t.string, current_hour_iso) != .lt) {
                start_idx = i;
                break;
            }
        }

        var written: usize = 0;
        var i = start_idx + 1; // skip the current hour itself; forecast row shows what's next
        while (i < times.len and written < 4) : (i += 1) {
            if (i >= temps.len or i >= codes.len or times[i] != .string) continue;
            const hour_label = hourLabel(times[i].string);
            const htemp = jsonArrayFloat(temps[i]) orelse continue;
            const hcode = switch (codes[i]) {
                .integer => |n| n,
                .float => |f| @as(i64, @intFromFloat(f)),
                else => 0,
            };
            if (written > 0) hourly_json.append(allocator, ',') catch return;
            hourly_json.print(allocator, "{{\"label\":\"{s}\",\"code\":{d},\"temp_c\":{d:.1}}}", .{ hour_label, hcode, htemp }) catch return;
            written += 1;
        }
    };
    hourly_json.append(allocator, ']') catch return;

    var out: std.ArrayList(u8) = .empty;
    out.print(allocator, "{{\"city\":\"{s}\",\"temp_c\":{d:.1},\"code\":{d},\"high_c\":{d:.1},\"low_c\":{d:.1},\"hourly\":{s}}}", .{
        loc.city, temp_c, code, high_c, low_c, hourly_json.items,
    }) catch return;

    const path = weatherPath(allocator, environ) orelse return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items }) catch return;
}

fn jsonArrayFloat(v: std.json.Value) ?f64 {
    return switch (v) {
        .float => |f| f,
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

/// open-meteo's hourly timestamps look like "2026-09-25T15:00"; render just
/// wants "15:00".
fn hourLabel(iso: []const u8) []const u8 {
    const t_idx = std.mem.indexOfScalar(u8, iso, 'T') orelse return iso;
    return iso[t_idx + 1 ..];
}

const Location = struct { lat: f64, lon: f64, city: []const u8 };

fn loadOrFetchLocation(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) ?Location {
    const path = locationPath(allocator, environ) orelse return null;
    if (fileAgeSeconds(io, path)) |age| if (age < location_refresh_interval_s) {
        if (parseLocationFile(allocator, io, path)) |loc| return loc;
    };

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "curl", "-s", "--max-time", "5", "http://ip-api.com/json/?fields=lat,lon,city" },
    }) catch return parseLocationFile(allocator, io, path);
    if (result.term != .exited or result.term.exited != 0) return parseLocationFile(allocator, io, path);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch return parseLocationFile(allocator, io, path);
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return parseLocationFile(allocator, io, path),
    };
    const lat = jsonFloat(obj, "lat") orelse return parseLocationFile(allocator, io, path);
    const lon = jsonFloat(obj, "lon") orelse return parseLocationFile(allocator, io, path);
    const city = dupeJsonString(allocator, obj, "city") orelse "";

    const dir = std.fs.path.dirname(path) orelse return .{ .lat = lat, .lon = lon, .city = city };
    Io.Dir.cwd().createDirPath(io, dir) catch {};
    const data = std.fmt.allocPrint(allocator, "{{\"lat\":{d:.4},\"lon\":{d:.4},\"city\":\"{s}\"}}", .{ lat, lon, city }) catch "";
    if (data.len > 0) Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data }) catch {};

    return .{ .lat = lat, .lon = lon, .city = city };
}

fn parseLocationFile(allocator: std.mem.Allocator, io: Io, path: []const u8) ?Location {
    const contents = Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch return null;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{}) catch return null;
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return null,
    };
    const lat = jsonFloat(obj, "lat") orelse return null;
    const lon = jsonFloat(obj, "lon") orelse return null;
    const city = dupeJsonString(allocator, obj, "city") orelse "";
    return .{ .lat = lat, .lon = lon, .city = city };
}

/// WMO weather interpretation codes (open-meteo docs): 0 clear, 1-3
/// (partly) cloudy, 45/48 fog, 51-67 drizzle/rain, 71-77 snow, 80-82
/// showers, 85-86 snow showers, 95-99 thunderstorm.
pub fn conditionText(code: i64) []const u8 {
    return switch (code) {
        0 => "Clear sky",
        1 => "Mostly clear",
        2 => "Partly cloudy",
        3 => "Overcast",
        45, 48 => "Foggy",
        51, 53, 55 => "Drizzle",
        56, 57 => "Freezing drizzle",
        61, 63, 65 => "Rain",
        66, 67 => "Freezing rain",
        71, 73, 75 => "Snow",
        77 => "Snow grains",
        80, 81, 82 => "Rain showers",
        85, 86 => "Snow showers",
        95 => "Thunderstorm",
        96, 99 => "Thunderstorm with hail",
        else => "Unknown",
    };
}

pub const Icon = enum { sun, cloud, part_cloud, fog, rain, snow, thunder };

pub fn iconFor(code: i64) Icon {
    return switch (code) {
        0 => .sun,
        1 => .sun,
        2 => .part_cloud,
        3 => .cloud,
        45, 48 => .fog,
        51, 53, 55, 56, 57, 61, 63, 65, 66, 67, 80, 81, 82 => .rain,
        71, 73, 75, 77, 85, 86 => .snow,
        95, 96, 99 => .thunder,
        else => .cloud,
    };
}
