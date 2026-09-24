//! Reads newline-separated entries from an `Io.Reader` (normally stdin).
//! Each line becomes one entry; the line itself is both the label and the
//! value handed back to the caller on accept.
const std = @import("std");
const Io = std.Io;
const Entry = @import("../state.zig").Entry;

pub fn readEntries(allocator: std.mem.Allocator, reader: *Io.Reader) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(allocator);

    while (try reader.takeDelimiter('\n')) |line| {
        const label = try allocator.dupe(u8, line);
        try entries.append(allocator, .{ .label = label });
    }

    return entries.toOwnedSlice(allocator);
}

test "readEntries splits lines and trims the trailing newline" {
    var reader = Io.Reader.fixed("foo\nbar\nbaz");
    const entries = try readEntries(std.testing.allocator, &reader);
    defer {
        for (entries) |e| std.testing.allocator.free(e.label);
        std.testing.allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("foo", entries[0].label);
    try std.testing.expectEqualStrings("bar", entries[1].label);
    try std.testing.expectEqualStrings("baz", entries[2].label);
}

test "readEntries handles empty input" {
    var reader = Io.Reader.fixed("");
    const entries = try readEntries(std.testing.allocator, &reader);
    defer std.testing.allocator.free(entries);
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}
