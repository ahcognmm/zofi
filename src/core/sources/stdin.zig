//! Reads newline-separated entries from an `Io.Reader` (normally stdin).
//! Each line becomes one entry; the line itself is both the label and the
//! value handed back to the caller on accept.
const std = @import("std");
const Io = std.Io;
const Entry = @import("../state.zig").Entry;

/// `-display-columns`/`-display-column-separator`: rofi's dmenu contract
/// where only selected columns are shown/filtered, but the full original
/// line is still the value returned on accept.
pub const ColumnOptions = struct {
    display_columns: ?[]const usize = null, // 1-indexed
    separator: []const u8 = "\t",
};

pub fn readEntries(allocator: std.mem.Allocator, reader: *Io.Reader) ![]Entry {
    return readEntriesWithColumns(allocator, reader, .{});
}

pub fn readEntriesWithColumns(allocator: std.mem.Allocator, reader: *Io.Reader, opts: ColumnOptions) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer entries.deinit(allocator);

    while (try reader.takeDelimiter('\n')) |line| {
        const full = try allocator.dupe(u8, line);
        if (opts.display_columns) |cols| {
            var parts: std.ArrayList([]const u8) = .empty;
            defer parts.deinit(allocator);
            var it = std.mem.splitSequence(u8, line, opts.separator);
            while (it.next()) |part| try parts.append(allocator, part);

            var display: std.ArrayList(u8) = .empty;
            defer display.deinit(allocator);
            for (cols, 0..) |col_num, i| {
                if (i != 0) try display.append(allocator, ' ');
                if (col_num >= 1 and col_num <= parts.items.len) {
                    try display.appendSlice(allocator, parts.items[col_num - 1]);
                }
            }
            const label = try display.toOwnedSlice(allocator);
            try entries.append(allocator, .{ .label = label, .action = full });
        } else {
            try entries.append(allocator, .{ .label = full });
        }
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

test "readEntriesWithColumns filters the display label but keeps the full line as action" {
    var reader = Io.Reader.fixed("alice\t30\tengineer\nbob\t25\tdesigner");
    const entries = try readEntriesWithColumns(std.testing.allocator, &reader, .{
        .display_columns = &.{ 1, 3 },
        .separator = "\t",
    });
    defer {
        for (entries) |e| {
            std.testing.allocator.free(e.label);
            if (e.action) |a| std.testing.allocator.free(a);
        }
        std.testing.allocator.free(entries);
    }

    try std.testing.expectEqual(@as(usize, 2), entries.len);
    try std.testing.expectEqualStrings("alice engineer", entries[0].label);
    try std.testing.expectEqualStrings("alice\t30\tengineer", entries[0].action.?);
    try std.testing.expectEqualStrings("bob designer", entries[1].label);
    try std.testing.expectEqualStrings("bob\t25\tdesigner", entries[1].action.?);
}
