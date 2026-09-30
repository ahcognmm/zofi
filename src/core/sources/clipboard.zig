//! Clipboard tab: turns the daemon-populated SQLite history
//! (`core.clipboard`) into rows. Selecting one doesn't run a command --
//! `Entry.action` carries a `"clipboard:<id>"` marker that `main.zig`
//! hands to `core.clipboard.copyToClipboard` on accept instead of calling
//! `core.launch.launch`.
const std = @import("std");
const Io = std.Io;
const clipboard = @import("../clipboard.zig");
const Entry = @import("../state.zig").Entry;

pub fn toEntries(arena: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) ![]Entry {
    var db = clipboard.open(arena, io, environ) catch return &.{};
    defer db.close();

    const rows = clipboard.list(arena, db) catch return &.{};
    var out = try arena.alloc(Entry, rows.len);
    for (rows, 0..) |row, i| {
        out[i] = .{
            .label = row.preview,
            .action = try std.fmt.allocPrint(arena, "clipboard:{d}", .{row.id}),
            .is_clipboard_marker = true,
        };
    }
    return out;
}
