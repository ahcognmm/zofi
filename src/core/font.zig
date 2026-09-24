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
                    return try std.fs.path.join(allocator, &.{ dir_path, entry.path });
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
            return try std.fs.path.join(allocator, &.{ dir_path, entry.path });
        }
    }
    return null;
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

    if (result.term != .exited or result.term.exited != 0 or result.stdout.len == 0 or !hasFontExt(result.stdout)) {
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
    var font = try z2d.Font.loadFile(io, allocator, path);
    font.deinit(allocator);
}
