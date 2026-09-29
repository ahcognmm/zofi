//! SQLite-backed clipboard history: shared by the clipboard daemon (writer,
//! see `wayland_backend.runClipboardDaemon`), the clipboard tab's entry
//! source (`sources/clipboard.zig`), the split-pane preview
//! (`render.zig`'s `drawClipboardSplit`, via `PreviewCache`), and the
//! accept-time write-back (`copyToClipboard`, called from `main.zig` when a
//! clipboard-tab entry is chosen). Platform-independent: no Wayland here,
//! just the DB, image decoding and a `wl-copy` subprocess.
const std = @import("std");
const Io = std.Io;
const z2d = @import("z2d");
const zigimg = @import("zigimg");
const icon_mod = @import("icon.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
});

/// Evict oldest entries once total stored content exceeds this.
pub const cap_bytes: i64 = 50 * 1024 * 1024;

pub const Db = struct {
    handle: *c.sqlite3,

    pub fn close(self: *Db) void {
        _ = c.sqlite3_close(self.handle);
    }
};

pub const Row = struct {
    id: i64,
    preview: []const u8,
};

pub const Content = struct {
    mime: []const u8,
    bytes: []const u8,
    size: i64,
    created_at: i64,
};

fn cacheDir(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("XDG_CACHE_HOME")) |dir| return std.fs.path.join(allocator, &.{ dir, "zofi" });
    const home = environ.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(allocator, &.{ home, ".cache", "zofi" });
}

const schema =
    \\CREATE TABLE IF NOT EXISTS entries (
    \\  id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\  mime TEXT NOT NULL,
    \\  hash BLOB NOT NULL,
    \\  content BLOB NOT NULL,
    \\  preview TEXT NOT NULL,
    \\  size INTEGER NOT NULL,
    \\  created_at INTEGER NOT NULL
    \\);
;

fn ensureSchema(db: Db) !void {
    if (c.sqlite3_exec(db.handle, schema, null, null, null) != c.SQLITE_OK) return error.SqliteSchemaFailed;
}

/// Opens (creating if needed) the sqlite file at the exact given `path` and
/// ensures the schema exists. Split out from `open` so tooling (the
/// snapshot renderer) can point at an isolated throwaway db instead of the
/// real `$XDG_CACHE_HOME/zofi/clipboard.db` -- inserting synthetic preview
/// rows into a user's actual clipboard history would be a bug, not a
/// convenience.
pub fn openAt(allocator: std.mem.Allocator, io: Io, path: []const u8) !Db {
    if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    const path_z = try allocator.dupeZ(u8, path);

    var handle: ?*c.sqlite3 = null;
    if (c.sqlite3_open(path_z.ptr, &handle) != c.SQLITE_OK) return error.SqliteOpenFailed;
    const db: Db = .{ .handle = handle.? };
    try ensureSchema(db);
    return db;
}

/// Opens (creating if needed) `$XDG_CACHE_HOME/zofi/clipboard.db`. Safe to
/// call from multiple processes concurrently (the daemon and any number of
/// short-lived `zofi -show clipboard` launches) -- SQLite handles that
/// itself.
pub fn open(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) !Db {
    const dir = try cacheDir(allocator, environ);
    const path = try std.fs.path.join(allocator, &.{ dir, "clipboard.db" });
    return openAt(allocator, io, path);
}

fn lastHash(db: Db) !?[20]u8 {
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT hash FROM entries ORDER BY id DESC LIMIT 1";
    if (c.sqlite3_prepare_v2(db.handle, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SqlitePrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);

    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return null;
    const blob = c.sqlite3_column_blob(stmt, 0);
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
    if (len != 20 or blob == null) return null;

    var out: [20]u8 = undefined;
    @memcpy(&out, @as([*]const u8, @ptrCast(blob.?))[0..20]);
    return out;
}

/// Inserts `content` under `mime`, unless it's byte-identical to the most
/// recently inserted entry -- both ordinary apps re-setting the same
/// selection redundantly, and the no-op of re-copying the current newest
/// history entry back onto the clipboard from the clipboard tab, would
/// otherwise spam consecutive duplicates. Building the preview (including
/// decoding image dimensions) happens here so the daemon and any other
/// writer never have to duplicate that logic.
pub fn insert(allocator: std.mem.Allocator, db: Db, mime: []const u8, content: []const u8) !void {
    if (content.len == 0) return;

    var hash: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(content, &hash, .{});

    if (try lastHash(db)) |last| {
        if (std.mem.eql(u8, &last, &hash)) return;
    }

    const preview = try buildPreview(allocator, mime, content);
    defer allocator.free(preview);

    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "INSERT INTO entries (mime, hash, content, preview, size, created_at) VALUES (?, ?, ?, ?, ?, ?)";
    if (c.sqlite3_prepare_v2(db.handle, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SqlitePrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);

    // Passing `null` as the destructor (SQLITE_STATIC) tells SQLite these
    // pointers are only guaranteed valid until the next call, which is
    // exactly true here -- everything stays in scope through `step` below.
    _ = c.sqlite3_bind_text(stmt, 1, mime.ptr, @intCast(mime.len), null);
    _ = c.sqlite3_bind_blob(stmt, 2, &hash, hash.len, null);
    _ = c.sqlite3_bind_blob(stmt, 3, content.ptr, @intCast(content.len), null);
    _ = c.sqlite3_bind_text(stmt, 4, preview.ptr, @intCast(preview.len), null);
    _ = c.sqlite3_bind_int64(stmt, 5, @intCast(content.len));
    const time_c = @cImport({
        @cInclude("time.h");
    });
    _ = c.sqlite3_bind_int64(stmt, 6, @intCast(time_c.time(null)));

    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteInsertFailed;

    try enforceCap(db);
}

fn buildPreview(allocator: std.mem.Allocator, mime: []const u8, content: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, mime, "image/")) {
        var img = zigimg.Image.fromMemory(allocator, content) catch {
            return std.fmt.allocPrint(allocator, "[image] {s}, {d} KB", .{ mime, content.len / 1024 });
        };
        defer img.deinit(allocator);
        return std.fmt.allocPrint(allocator, "[image] {d}x{d} {s}, {d} KB", .{ img.width, img.height, mimeShortName(mime), content.len / 1024 });
    }

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    for (content) |ch| {
        if (buf.items.len >= 200) break;
        try buf.append(allocator, if (ch == '\n' or ch == '\r' or ch == '\t') ' ' else ch);
    }
    return allocator.dupe(u8, buf.items);
}

/// "PNG"/"JPEG" for the preview pane's Format field; falls back to the raw
/// mime string for anything else.
pub fn mimeShortName(mime: []const u8) []const u8 {
    if (std.mem.eql(u8, mime, "image/png")) return "PNG";
    if (std.mem.eql(u8, mime, "image/jpeg")) return "JPEG";
    return mime;
}

/// Deletes oldest-first until total stored `size` is back under
/// `cap_bytes`.
fn enforceCap(db: Db) !void {
    while (true) {
        var sum_stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(db.handle, "SELECT COALESCE(SUM(size), 0) FROM entries", -1, &sum_stmt, null) != c.SQLITE_OK) return error.SqlitePrepareFailed;
        _ = c.sqlite3_step(sum_stmt);
        const total = c.sqlite3_column_int64(sum_stmt, 0);
        _ = c.sqlite3_finalize(sum_stmt);

        if (total <= cap_bytes) return;

        if (c.sqlite3_exec(db.handle, "DELETE FROM entries WHERE id = (SELECT MIN(id) FROM entries)", null, null, null) != c.SQLITE_OK) {
            return error.SqliteDeleteFailed;
        }
    }
}

/// Newest first, for the clipboard tab's row list.
pub fn list(allocator: std.mem.Allocator, db: Db) ![]Row {
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT id, preview FROM entries ORDER BY id DESC";
    if (c.sqlite3_prepare_v2(db.handle, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SqlitePrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);

    var out: std.ArrayList(Row) = .empty;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const id = c.sqlite3_column_int64(stmt, 0);
        const preview_ptr = c.sqlite3_column_text(stmt, 1);
        const preview_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
        const preview = try allocator.dupe(u8, @as([*]const u8, @ptrCast(preview_ptr))[0..preview_len]);
        try out.append(allocator, .{ .id = id, .preview = preview });
    }
    return out.toOwnedSlice(allocator);
}

/// Full mime + content bytes (+ size/created_at) for one entry -- for
/// write-back to the clipboard (`copyToClipboard`) and for the preview
/// pane (`loadPreview`). Deliberately separate from `list`, which never
/// loads the (potentially large, e.g. image) blob column.
pub fn fetchContent(allocator: std.mem.Allocator, db: Db, id: i64) !Content {
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT mime, content, size, created_at FROM entries WHERE id = ?";
    if (c.sqlite3_prepare_v2(db.handle, sql, -1, &stmt, null) != c.SQLITE_OK) return error.SqlitePrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, id);

    if (c.sqlite3_step(stmt) != c.SQLITE_ROW) return error.NotFound;

    const mime_ptr = c.sqlite3_column_text(stmt, 0);
    const mime_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 0));
    const mime = try allocator.dupe(u8, @as([*]const u8, @ptrCast(mime_ptr))[0..mime_len]);

    const blob = c.sqlite3_column_blob(stmt, 1);
    const blob_len: usize = @intCast(c.sqlite3_column_bytes(stmt, 1));
    const bytes = if (blob_len == 0) &[_]u8{} else try allocator.dupe(u8, @as([*]const u8, @ptrCast(blob.?))[0..blob_len]);

    const size = c.sqlite3_column_int64(stmt, 2);
    const created_at = c.sqlite3_column_int64(stmt, 3);

    return .{ .mime = mime, .bytes = bytes, .size = size, .created_at = created_at };
}

/// Deletes one entry (the clipboard tab's Del key). No-op (not an error)
/// if `id` is already gone.
pub fn deleteEntry(db: Db, id: i64) !void {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(db.handle, "DELETE FROM entries WHERE id = ?", -1, &stmt, null) != c.SQLITE_OK) return error.SqlitePrepareFailed;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_int64(stmt, 1, id);
    if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return error.SqliteDeleteFailed;
}

/// Parses a clipboard-tab `Entry.action` marker (`"clipboard:<id>"`, see
/// `sources/clipboard.zig`).
pub fn parseMarker(marker: []const u8) !i64 {
    const prefix = "clipboard:";
    if (!std.mem.startsWith(u8, marker, prefix)) return error.BadMarker;
    return std.fmt.parseInt(i64, marker[prefix.len..], 10);
}

/// Fetches that entry's full content and copies it back onto the Wayland
/// clipboard by piping it into `wl-copy`. `wl-copy` forks itself into the
/// background to keep serving the selection after it reads EOF on stdin
/// (its default behavior; see `wl-copy --help`), so this doesn't need to
/// stay alive or implement `zwlr_data_control_source_v1` itself --
/// deliberately the simpler of the two options for writing a selection
/// back, since a real Wayland clipboard source would need its own event
/// loop just to serve one paste.
///
/// Waiting for `wl-copy`'s own process to exit is load-bearing, not just
/// cleanup: if this process exits first (e.g. right after closing stdin),
/// wl-copy's own fork-to-background sequence can lose the race against
/// session teardown and never make it to a detached background daemon --
/// confirmed empirically, not a hypothetical (the copy silently vanished
/// without this).
pub fn copyToClipboard(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, marker: []const u8) !void {
    const id = try parseMarker(marker);

    var db = try open(allocator, io, environ);
    defer db.close();
    const content = try fetchContent(allocator, db, id);

    var child = try std.process.spawn(io, .{
        .argv = &.{ "wl-copy", "--type", content.mime },
        .environ_map = environ,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    if (child.stdin) |stdin_file| {
        var buf: [4096]u8 = undefined;
        var w = stdin_file.writer(io, &buf);
        try w.interface.writeAll(content.bytes);
        try w.interface.flush();
        stdin_file.close(io);
    }
    _ = try child.wait(io);
}

// ---------------------------------------------------------------------
// Preview pane (split-pane clipboard tab, see render.zig's
// drawClipboardSplit / zofi-clipboard.html)
// ---------------------------------------------------------------------

/// What the preview pane's "stage" box shows for an entry. Collapsed from
/// the design mockup's five categories (image/text/code/link/color) to
/// four: this renderer has no proportional-font support (see theme.zig's
/// doc comment -- z2d has no text-measurement API, everything is a real
/// monospace font), so "code" and "text" would render pixel-identically
/// here; keeping them as one kind avoids a classification with no visible
/// effect.
pub const Kind = enum { image, color, link, text };

fn hexDigit(ch: u8) ?u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        'A'...'F' => ch - 'A' + 10,
        else => null,
    };
}

pub const Rgb = struct { r: u8, g: u8, b: u8 };

/// `#rgb`, `#rgba`, `#rrggbb` or `#rrggbbaa` -- alpha (if present) is
/// ignored, this only feeds the swatch fill and the Hex/RGB/HSL metadata.
pub fn parseHexColor(hex: []const u8) ?Rgb {
    if (hex.len == 0 or hex[0] != '#') return null;
    const d = hex[1..];
    var expanded: [6]u8 = undefined;
    if (d.len == 3 or d.len == 4) {
        for (0..3) |i| {
            expanded[i * 2] = d[i];
            expanded[i * 2 + 1] = d[i];
        }
    } else if (d.len == 6 or d.len == 8) {
        @memcpy(&expanded, d[0..6]);
    } else return null;

    var out: [3]u8 = undefined;
    for (0..3) |i| {
        const hi = hexDigit(expanded[i * 2]) orelse return null;
        const lo = hexDigit(expanded[i * 2 + 1]) orelse return null;
        out[i] = hi * 16 + lo;
    }
    return .{ .r = out[0], .g = out[1], .b = out[2] };
}

fn isHexColor(s: []const u8) bool {
    return parseHexColor(s) != null;
}

fn isSingleLineUrl(s: []const u8) bool {
    if (!std.mem.startsWith(u8, s, "http://") and !std.mem.startsWith(u8, s, "https://")) return false;
    return std.mem.indexOfAny(u8, s, " \t\n\r") == null;
}

pub fn detectKind(mime: []const u8, content: []const u8) Kind {
    if (std.mem.startsWith(u8, mime, "image/")) return .image;
    const trimmed = std.mem.trim(u8, content, " \t\r\n");
    if (isHexColor(trimmed)) return .color;
    if (isSingleLineUrl(trimmed)) return .link;
    return .text;
}

/// `r/g/b` in [0,255] -> hue in degrees, saturation/lightness in [0,1].
pub fn rgbToHsl(r: u8, g: u8, b: u8) struct { h: f64, s: f64, l: f64 } {
    const rf = @as(f64, @floatFromInt(r)) / 255.0;
    const gf = @as(f64, @floatFromInt(g)) / 255.0;
    const bf = @as(f64, @floatFromInt(b)) / 255.0;
    const max = @max(rf, @max(gf, bf));
    const min = @min(rf, @min(gf, bf));
    const l = (max + min) / 2;
    if (max == min) return .{ .h = 0, .s = 0, .l = l };

    const d = max - min;
    const s = if (l > 0.5) d / (2 - max - min) else d / (max + min);
    var h: f64 = if (max == rf)
        (gf - bf) / d + (if (gf < bf) @as(f64, 6) else 0)
    else if (max == gf)
        (bf - rf) / d + 2
    else
        (rf - gf) / d + 4;
    h *= 60;
    return .{ .h = h, .s = s, .l = l };
}

/// Strips a `http(s)://` scheme and everything from the first `/`, `?` or
/// `#` onward -- good enough for the preview pane's "Domain" field, not a
/// full URL parser.
pub fn urlDomain(url: []const u8) []const u8 {
    var s = url;
    if (std.mem.startsWith(u8, s, "https://")) s = s[8..] else if (std.mem.startsWith(u8, s, "http://")) s = s[7..];
    const end = std.mem.indexOfAny(u8, s, "/?#") orelse s.len;
    return s[0..end];
}

/// "2 min ago" / "1 h ago" / "yesterday" / "3 d ago" -- relative to `now`
/// (a unix timestamp; callers pass `time(null)` the same way `insert`
/// stamps `created_at`, so the two are always comparable).
pub fn formatAge(buf: []u8, now: i64, created_at: i64) []const u8 {
    const secs = @max(0, now - created_at);
    if (secs < 60) return "just now";
    if (secs < 3600) return std.fmt.bufPrint(buf, "{d} min ago", .{@divTrunc(secs, 60)}) catch "";
    if (secs < 86400) return std.fmt.bufPrint(buf, "{d} h ago", .{@divTrunc(secs, 3600)}) catch "";
    if (secs < 172800) return "yesterday";
    return std.fmt.bufPrint(buf, "{d} d ago", .{@divTrunc(secs, 86400)}) catch "";
}

pub const Preview = struct {
    kind: Kind,
    mime: []const u8,
    /// Full text content for color/link/text kinds; empty for image (use
    /// `image`/`img_width`/`img_height` instead).
    text: []const u8,
    size_bytes: i64,
    created_at: i64,
    img_width: u32 = 0,
    img_height: u32 = 0,
    /// Decoded pixels for `kind == .image`, ready for `ui.image.Image` to
    /// composite -- null if decoding failed (caller falls back to a plain
    /// label), same "best effort, never fatal" contract as `icon.zig`'s
    /// cache.
    image: ?icon_mod.Icon = null,
};

/// Fetches and classifies one entry's full content, decoding it to pixels
/// when it's an image. Not cheap (a blob fetch, and for images a full
/// decode) -- callers should go through `PreviewCache`, not call this on
/// every frame.
pub fn loadPreview(allocator: std.mem.Allocator, db: Db, id: i64) !Preview {
    const content = try fetchContent(allocator, db, id);
    const kind = detectKind(content.mime, content.bytes);

    var preview: Preview = .{
        .kind = kind,
        .mime = content.mime,
        .text = if (kind == .image) &[_]u8{} else content.bytes,
        .size_bytes = content.size,
        .created_at = content.created_at,
    };

    if (kind == .image) decode: {
        var img = zigimg.Image.fromMemory(allocator, content.bytes) catch break :decode;
        img.convert(allocator, .rgba32) catch break :decode;
        const src = img.pixels.rgba32;

        const pixels = allocator.alloc(z2d.pixel.ARGB, src.len) catch break :decode;
        for (src, 0..) |p, i| {
            const pm = (z2d.pixel.RGBA{ .r = p.r, .g = p.g, .b = p.b, .a = p.a }).multiply();
            pixels[i] = .{ .r = pm.r, .g = pm.g, .b = pm.b, .a = pm.a };
        }
        preview.image = .{ .width = @intCast(img.width), .height = @intCast(img.height), .pixels = pixels };
        preview.img_width = @intCast(img.width);
        preview.img_height = @intCast(img.height);
    }

    return preview;
}

/// Lazily opens its own db handle (kept open for reuse, same pattern as
/// `icon.zig`'s `Cache`) and caches the most recently loaded preview by
/// entry id -- selection moving between rows re-fetches, repeated
/// `render()` calls for the same selection don't. Zero-initializable
/// (`.{}`); tooling (the snapshot renderer) can bypass the lazy env-based
/// open by calling `attach` with an already-open (e.g. isolated temp) db.
pub const PreviewCache = struct {
    db: ?Db = null,
    loaded_id: ?i64 = null,
    preview: ?Preview = null,

    pub fn attach(self: *PreviewCache, db: Db) void {
        self.db = db;
    }

    /// Drops any cached preview for `id` (used after deleting `id`, so a
    /// reused autoincrement id -- however unlikely -- can't serve stale
    /// content).
    pub fn invalidate(self: *PreviewCache, id: i64) void {
        if (self.loaded_id == id) {
            self.loaded_id = null;
            self.preview = null;
        }
    }

    pub fn get(self: *PreviewCache, allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, id: i64) ?Preview {
        if (self.loaded_id == id) return self.preview;
        if (self.db == null) self.db = open(allocator, io, environ) catch return null;
        self.preview = loadPreview(allocator, self.db.?, id) catch null;
        self.loaded_id = id;
        return self.preview;
    }
};
