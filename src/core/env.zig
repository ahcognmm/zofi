//! Numeric settings read from the environment (`ZOFI_*`). A value that's
//! missing or doesn't parse falls back to the default; one outside the
//! allowed range is clamped to it, so a typo can't make zofi misbehave.
const std = @import("std");

pub fn int(
    comptime T: type,
    environ: *const std.process.Environ.Map,
    name: []const u8,
    default: T,
    min: T,
    max: T,
) T {
    const raw = environ.get(name) orelse return default;
    const value = std.fmt.parseInt(T, std.mem.trim(u8, raw, " \t"), 10) catch return default;
    return std.math.clamp(value, min, max);
}

test "int: default, parse, clamp" {
    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();

    try std.testing.expectEqual(@as(u32, 500), int(u32, &environ, "ZOFI_X", 500, 100, 10_000));
    try environ.put("ZOFI_X", "250");
    try std.testing.expectEqual(@as(u32, 250), int(u32, &environ, "ZOFI_X", 500, 100, 10_000));
    try environ.put("ZOFI_X", "5");
    try std.testing.expectEqual(@as(u32, 100), int(u32, &environ, "ZOFI_X", 500, 100, 10_000));
    try environ.put("ZOFI_X", "99999");
    try std.testing.expectEqual(@as(u32, 10_000), int(u32, &environ, "ZOFI_X", 500, 100, 10_000));
    try environ.put("ZOFI_X", "fast");
    try std.testing.expectEqual(@as(u32, 500), int(u32, &environ, "ZOFI_X", 500, 100, 10_000));
}
