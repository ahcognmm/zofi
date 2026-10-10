//! drun mode on macOS: `.app` bundles from the standard application
//! folders, plus one level of subfolder (`/Applications/Utilities`,
//! nix-darwin's `/Applications/Nix Apps`, ...). First bundle with a given
//! name wins, in `appDirs` order.
const std = @import("std");
const Io = std.Io;
const Entry = @import("../state.zig").Entry;

fn appDirs(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![][]const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;
    if (environ.get("HOME")) |home| {
        try dirs.append(allocator, try std.fs.path.join(allocator, &.{ home, "Applications" }));
    }
    try dirs.appendSlice(allocator, &.{ "/Applications", "/System/Applications" });
    return dirs.toOwnedSlice(allocator);
}

pub fn scan(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) ![]Entry {
    return scanDirs(allocator, io, try appDirs(allocator, environ));
}

fn scanDirs(allocator: std.mem.Allocator, io: Io, dirs: []const []const u8) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(allocator);

    for (dirs) |dir_path| {
        try scanDir(allocator, io, dir_path, 1, &entries, &seen);
    }

    // Directory order isn't meaningful (APFS doesn't return names sorted),
    // so give the unfiltered list a predictable order instead.
    std.mem.sort(Entry, entries.items, {}, labelLessThan);
    return entries.toOwnedSlice(allocator);
}

fn scanDir(
    allocator: std.mem.Allocator,
    io: Io,
    dir_path: []const u8,
    depth: u8,
    entries: *std.ArrayList(Entry),
    seen: *std.StringHashMapUnmanaged(void),
) !void {
    if (!std.fs.path.isAbsolute(dir_path)) return;
    var dir = Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        // Bundles are directories; nix-darwin and Home Manager link them in
        // as symlinks instead.
        if (entry.kind != .directory and entry.kind != .sym_link) continue;
        if (entry.name.len == 0 or entry.name[0] == '.') continue;

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });

        if (!std.mem.endsWith(u8, entry.name, ".app")) {
            defer allocator.free(full_path);
            if (depth > 0) try scanDir(allocator, io, full_path, depth - 1, entries, seen);
            continue;
        }

        const name = entry.name[0 .. entry.name.len - ".app".len];
        if (name.len == 0 or seen.contains(name)) {
            allocator.free(full_path);
            continue;
        }
        const label = try allocator.dupe(u8, name);
        try seen.put(allocator, label, {});
        try entries.append(allocator, .{
            .label = label,
            .action = try openCommand(allocator, full_path),
        });
        allocator.free(full_path);
    }
}

/// `open -a` rather than exec'ing the bundle's binary, so the app starts
/// through LaunchServices exactly as a Finder/Dock click would (and an
/// already-running app is just brought forward).
fn openCommand(allocator: std.mem.Allocator, app_path: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "open -a '");
    for (app_path) |ch| {
        if (ch == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, ch);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

fn labelLessThan(_: void, a: Entry, b: Entry) bool {
    return std.ascii.lessThanIgnoreCase(a.label, b.label);
}

test "scanDirs finds bundles one folder deep, first dir wins, sorted by label" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "user/Zed.app/Contents");
    try tmp.dir.createDirPath(io, "system/Zed.app");
    try tmp.dir.createDirPath(io, "system/Safari.app");
    try tmp.dir.createDirPath(io, "system/Utilities/Terminal.app");
    try tmp.dir.createDirPath(io, "system/Utilities/Nested/TooDeep.app");
    try tmp.dir.writeFile(io, .{ .sub_path = "system/NotABundle.app", .data = "" });

    const root = try tmp.dir.realPathFileAlloc(io, ".", arena);
    const user_dir = try std.fs.path.join(arena, &.{ root, "user" });
    const system_dir = try std.fs.path.join(arena, &.{ root, "system" });

    const entries = try scanDirs(arena, io, &.{ user_dir, system_dir });
    try std.testing.expectEqual(@as(usize, 3), entries.len);
    try std.testing.expectEqualStrings("Safari", entries[0].label);
    try std.testing.expectEqualStrings("Terminal", entries[1].label);
    try std.testing.expectEqualStrings("Zed", entries[2].label);

    const expected_zed = try std.fmt.allocPrint(arena, "open -a '{s}/Zed.app'", .{user_dir});
    try std.testing.expectEqualStrings(expected_zed, entries[2].action.?);
}

test "openCommand single-quotes the path for sh" {
    const cmd = try openCommand(std.testing.allocator, "/Applications/Bob's App.app");
    defer std.testing.allocator.free(cmd);
    try std.testing.expectEqualStrings("open -a '/Applications/Bob'\\''s App.app'", cmd);
}
