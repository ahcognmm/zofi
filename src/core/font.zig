//! Font discovery: scan the standard font directories for a file whose name
//! contains one of the preferred family substrings (case-insensitive).
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const z2d = @import("z2d");

const standard_dirs = [_][]const u8{
    "/usr/share/fonts",
    "/usr/local/share/fonts",
    "/run/current-system/sw/share/fonts",
    // macOS (walked recursively, so this also covers .../Fonts/Supplemental)
    "/System/Library/Fonts",
    "/Library/Fonts",
};

/// Monospace fonts every macOS install ships as plain single-font `.ttf`
/// files, most preferred first. Menlo, the usual pick, only ships as a
/// `.ttc` collection, which z2d can't load (see `hasFontExt`).
const macos_monospace = [_][]const u8{ "Monaco", "SFNSMono", "Andale Mono", "Courier New" };

fn hasFontExt(name: []const u8) bool {
    // No ".ttc": z2d only loads single-font files, and a collection would
    // leave the UI with no text at all rather than falling back.
    const exts = [_][]const u8{ ".ttf", ".otf" };
    for (exts) |ext| {
        if (name.len >= ext.len and std.ascii.eqlIgnoreCase(name[name.len - ext.len ..], ext)) return true;
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Returns an allocator-owned absolute path to the first font file found
/// whose name matches one of `family_substrings`, or `null` if none is
/// found under any standard font directory.
pub fn find(allocator: std.mem.Allocator, io: Io, family_substrings: []const []const u8) !?[]u8 {
    for (standard_dirs) |dir_path| {
        var dir = Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!hasFontExt(entry.basename)) continue;

            for (family_substrings) |family| {
                if (containsIgnoreCase(entry.basename, family)) {
                    const path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
                    if (isLoadable(allocator, io, path)) return path;
                    allocator.free(path);
                    break;
                }
            }
        }
    }
    return null;
}

/// Returns the first font file found under any standard directory,
/// regardless of family name. Last-resort fallback so the UI always has
/// something to render text with.
pub fn findAny(allocator: std.mem.Allocator, io: Io) !?[]u8 {
    for (standard_dirs) |dir_path| {
        var dir = Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!hasFontExt(entry.basename)) continue;
            const path = try std.fs.path.join(allocator, &.{ dir_path, entry.path });
            if (isLoadable(allocator, io, path)) return path;
            allocator.free(path);
        }
    }
    return null;
}

/// Whether z2d can actually parse the font at `path`. A font that fails
/// here (a collection, CFF outlines, a table z2d rejects) would otherwise
/// be picked anyway and leave the UI with no text at all, so discovery
/// checks every candidate and moves on to the next one instead. Reads the
/// file itself rather than using `z2d.Font.loadFile`, which leaks its
/// buffer when parsing fails.
fn isLoadable(allocator: std.mem.Allocator, io: Io, path: []const u8) bool {
    if (!hasFontExt(path)) return false;
    const data = Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch return false;
    defer allocator.free(data);
    _ = z2d.Font.loadBuffer(data) catch return false;
    return true;
}

/// Asks fontconfig for a concrete file path for `family` (e.g. "sans-serif").
/// Needed on distros (NixOS chief among them) where fonts don't live under
/// any of `standard_dirs` and are only discoverable through fontconfig's own
/// config. Returns `null` if `fc-match` isn't installed or found nothing.
pub fn fcMatch(allocator: std.mem.Allocator, io: Io, family: []const u8) !?[]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "fc-match", "--format=%{file}", family },
    }) catch return null;
    defer allocator.free(result.stderr);

    if (result.term != .exited or result.term.exited != 0 or result.stdout.len == 0 or !isLoadable(allocator, io, result.stdout)) {
        allocator.free(result.stdout);
        return null;
    }
    return result.stdout;
}

/// The font `zofi` renders with unless configured otherwise: a real
/// monospace font first (see `Theme.font_path` for why), then any sans,
/// then anything at all, so the UI always has something to draw text with.
pub fn findDefault(allocator: std.mem.Allocator, io: Io) !?[]u8 {
    if (builtin.os.tag == .macos) {
        // One family per call: `find` returns the first match in directory
        // order, which would otherwise ignore this list's preference order.
        for (macos_monospace) |family| {
            if (try find(allocator, io, &.{family})) |path| return path;
        }
    }
    return (try fcMatch(allocator, io, "monospace")) orelse
        (try find(allocator, io, &.{ "DejaVuSansMono", "Mono", "Consolas", "Menlo" })) orelse
        (try find(allocator, io, &.{ "DejaVuSans", "Inter", "Noto", "Liberation" })) orelse
        (try fcMatch(allocator, io, "sans-serif")) orelse
        (try findAny(allocator, io));
}

test "findDefault picks a font z2d can actually load" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const path = (try findDefault(allocator, io)) orelse return error.SkipZigTest;
    defer allocator.free(path);
    try std.testing.expect(isLoadable(allocator, io, path));
}

test "isLoadable rejects a file z2d can't parse, without leaking" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A valid TrueType header declaring zero tables: z2d rejects it with
    // MissingRequiredTable, the same kind of error a real font it can't
    // handle produces.
    try tmp.dir.writeFile(io, .{ .sub_path = "Broken.ttf", .data = "\x00\x01\x00\x00" ++ "\x00" ** 8 });
    const path = try tmp.dir.realPathFileAlloc(io, "Broken.ttf", allocator);
    defer allocator.free(path);
    try std.testing.expect(!isLoadable(allocator, io, path));
}
