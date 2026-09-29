//! SQLite-backed clipboard history: shared by the clipboard daemon (writer,
//! see `wayland_backend.runClipboardDaemon`), the clipboard tab's entry
//! source (`sources/clipboard.zig`), and the accept-time write-back
//! (`copyToClipboard`, called from `main.zig` when a clipboard-tab entry is
//! chosen). Platform-independent: no Wayland here, just the DB and a
//! `wl-copy` subprocess.
const std = @import("std");
const Io = std.Io;
const zigimg = @import("zigimg");

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
};

fn cacheDir(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![]const u8 {
    if (environ.get("XDG_CACHE_HOME")) |dir| return std.fs.path.join(allocator, &.{ dir, "zofi" });
    const home = environ.get("HOME") orelse return error.NoHome;
    return std.fs.path.join(allocator, &.{ home, ".cache", "zofi" });
}

/// Opens (creating if needed) `$XDG_CACHE_HOME/zofi/clipboard.db` and
/// ensures the schema exists. Safe to call from multiple processes
/// concurrently (the daemon and any number of short-lived `zofi -show
/// clipboard` launches) -- SQLite handles that itself.
pub fn open(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map) !Db {
    const dir = try cacheDir(allocator, environ);
    try Io.Dir.cwd().createDirPath(io, dir);
    const path = try std.fs.path.join(allocator, &.{ dir, "clipboard.db" });
    const path_z = try allocator.dupeZ(u8, path);

    var handle: ?*c.sqlite3 = null;
    if (c.sqlite3_open(path_z.ptr, &handle) != c.SQLITE_OK) return error.SqliteOpenFailed;
    const db: Db = .{ .handle = handle.? };

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
    if (c.sqlite3_exec(db.handle, schema, null, null, null) != c.SQLITE_OK) return error.SqliteSchemaFailed;
    return db;
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

fn mimeShortName(mime: []const u8) []const u8 {
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

/// Full mime + content bytes for one entry, for write-back to the
/// clipboard (`copyToClipboard`) -- deliberately separate from `list`,
/// which never loads the (potentially large, e.g. image) blob column.
pub fn fetchContent(allocator: std.mem.Allocator, db: Db, id: i64) !Content {
    var stmt: ?*c.sqlite3_stmt = null;
    const sql = "SELECT mime, content FROM entries WHERE id = ?";
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

    return .{ .mime = mime, .bytes = bytes };
}

/// Parses a clipboard-tab `Entry.action` marker (`"clipboard:<id>"`, see
/// `sources/clipboard.zig`), fetches that entry's full content, and copies
/// it back onto the Wayland clipboard by piping it into `wl-copy`.
/// `wl-copy` forks itself into the background to keep serving the
/// selection after it reads EOF on stdin (its default behavior; see
/// `wl-copy --help`), so this doesn't need to stay alive or implement
/// `zwlr_data_control_source_v1` itself -- deliberately the simpler of the
/// two options for writing a selection back, since a real Wayland clipboard
/// source would need its own event loop just to serve one paste.
///
/// Waiting for `wl-copy`'s own process to exit is load-bearing, not just
/// cleanup: if this process exits first (e.g. right after closing stdin),
/// wl-copy's own fork-to-background sequence can lose the race against
/// session teardown and never make it to a detached background daemon --
/// confirmed empirically, not a hypothetical (the copy silently vanished
/// without this).
pub fn copyToClipboard(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, marker: []const u8) !void {
    const prefix = "clipboard:";
    if (!std.mem.startsWith(u8, marker, prefix)) return error.BadMarker;
    const id = try std.fmt.parseInt(i64, marker[prefix.len..], 10);

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
