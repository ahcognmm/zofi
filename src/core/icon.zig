//! Best-effort freedesktop icon lookup + decode, for real app icons in the
//! Apps/Windows row tiles (falls back to the colored-letter tile when an
//! icon can't be found or decoded -- most commonly because it's SVG-only;
//! z2d has no raster *or* vector image import, so only PNG-backed icons
//! (via zigimg, pure Zig) are supported for now).
const std = @import("std");
const Io = std.Io;
const z2d = @import("z2d");
const zigimg = @import("zigimg");

pub const Icon = struct {
    width: u32,
    height: u32,
    /// Premultiplied ARGB, row-major, matching `z2d.pixel.ARGB`'s memory
    /// layout so it can be composited straight into a render surface.
    pixels: []const z2d.pixel.ARGB,

    /// Nearest-neighbor sample at normalized [0,1) coordinates.
    pub fn sample(self: Icon, u: f64, v: f64) z2d.pixel.ARGB {
        const x: u32 = @intFromFloat(@min(@as(f64, @floatFromInt(self.width - 1)), u * @as(f64, @floatFromInt(self.width))));
        const y: u32 = @intFromFloat(@min(@as(f64, @floatFromInt(self.height - 1)), v * @as(f64, @floatFromInt(self.height))));
        return self.pixels[y * self.width + x];
    }
};

/// Lazily resolves, decodes and caches icons by name for the lifetime of
/// the cache (arena-backed; never evicts). One cache per running instance.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    io: Io,
    search_dirs: []const []const u8,
    entries: std.StringHashMapUnmanaged(?Icon) = .empty,

    pub fn init(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) !Cache {
        return .{ .allocator = allocator, .io = io, .search_dirs = try iconSearchDirs(allocator, environ) };
    }

    /// Returns the decoded icon for `name`, or `null` if it couldn't be
    /// found/decoded (caller should fall back to the letter tile).
    pub fn get(self: *Cache, name: []const u8) ?Icon {
        if (self.entries.get(name)) |cached| return cached;
        const icon = self.load(name) catch null;
        const key = self.allocator.dupe(u8, name) catch return icon;
        self.entries.put(self.allocator, key, icon) catch {};
        return icon;
    }

    fn load(self: *Cache, name: []const u8) !?Icon {
        const path = (try resolvePath(self.allocator, self.io, self.search_dirs, name)) orelse return null;

        var read_buffer: [64 * 1024]u8 = undefined;
        var image = zigimg.Image.fromFilePath(self.allocator, self.io, path, &read_buffer) catch return null;
        image.convert(self.allocator, .rgba32) catch return null;
        const src = image.pixels.rgba32;

        const pixels = try self.allocator.alloc(z2d.pixel.ARGB, src.len);
        for (src, 0..) |p, i| {
            const premult = (z2d.pixel.RGBA{ .r = p.r, .g = p.g, .b = p.b, .a = p.a }).multiply();
            pixels[i] = .{ .r = premult.r, .g = premult.g, .b = premult.b, .a = premult.a };
        }

        return Icon{ .width = @intCast(image.width), .height = @intCast(image.height), .pixels = pixels };
    }
};

const preferred_sizes = [_][]const u8{ "48x48", "64x64", "32x32", "128x128", "96x96", "256x256" };
const themes = [_][]const u8{ "hicolor", "Adwaita" };

fn resolvePath(allocator: std.mem.Allocator, io: Io, search_dirs: []const []const u8, name: []const u8) !?[]const u8 {
    if (std.fs.path.isAbsolute(name)) {
        return if (hasPngExt(name)) name else null;
    }

    for (search_dirs) |dir| {
        for (themes) |theme| {
            for (preferred_sizes) |size| {
                const candidate = try std.fs.path.join(allocator, &.{ dir, theme, size, "apps", try std.fmt.allocPrint(allocator, "{s}.png", .{name}) });
                if (fileExists(io, candidate)) return candidate;
            }
        }
        // Flat pixmaps directories, common for apps that don't use the
        // hicolor theme hierarchy at all.
        const flat = try std.fs.path.join(allocator, &.{ dir, try std.fmt.allocPrint(allocator, "{s}.png", .{name}) });
        if (fileExists(io, flat)) return flat;
    }
    return null;
}

fn hasPngExt(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.extension(path), ".png");
}

fn fileExists(io: Io, path: []const u8) bool {
    Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    return true;
}

fn iconSearchDirs(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![][]const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;

    if (environ.get("HOME")) |home| {
        try dirs.append(allocator, try std.fs.path.join(allocator, &.{ home, ".local/share/icons" }));
        try dirs.append(allocator, try std.fs.path.join(allocator, &.{ home, ".icons" }));
    }

    const data_dirs = environ.get("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var it = std.mem.tokenizeScalar(u8, data_dirs, ':');
    while (it.next()) |dir| {
        try dirs.append(allocator, try std.fs.path.join(allocator, &.{ dir, "icons" }));
    }
    try dirs.append(allocator, "/usr/share/pixmaps");

    return dirs.toOwnedSlice(allocator);
}
