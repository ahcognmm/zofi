//! run mode: every executable found on `$PATH`, deduplicated by name (first
//! directory on `$PATH` wins, matching shell lookup order).
const std = @import("std");
const Io = std.Io;
const Entry = @import("../state.zig").Entry;

pub fn scan(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    const path_var = environ.get("PATH") orelse return entries.toOwnedSlice(allocator);
    var dirs = std.mem.tokenizeScalar(u8, path_var, ':');

    while (dirs.next()) |dir_path| {
        if (!std.fs.path.isAbsolute(dir_path)) continue;
        var dir = Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file and entry.kind != .sym_link) continue;
            if (seen.contains(entry.name)) continue;

            dir.access(io, entry.name, .{ .execute = true }) catch continue;

            const name = try allocator.dupe(u8, entry.name);
            try seen.put(allocator, name, {});
            const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
            try entries.append(allocator, .{ .label = name, .action = full_path });
        }
    }

    return entries.toOwnedSlice(allocator);
}
