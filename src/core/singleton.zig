//! Single-instance guard. A second `zofi` launched while one is already
//! open (e.g. a keybind mashed twice, or fired again before the first
//! surface painted) would otherwise stack a second layer-shell surface on
//! top of the first with no way to tell them apart.
const std = @import("std");
const Io = std.Io;

/// Tries to become the one running instance. Returns `true` if this
/// process holds the lock (no other instance is running, or the lock
/// couldn't be checked at all -- failing open shouldn't block the user
/// over a `/tmp` permissions quirk). Returns `false` if another instance
/// already holds it.
///
/// The lock file is deliberately never closed: it's held for the process's
/// entire lifetime and released by the kernel on exit -- including a
/// crash -- which is exactly the semantics wanted here. (Zig opens it
/// close-on-exec, so launched apps don't inherit the lock.)
pub fn acquire(io: Io, environ: *const std.process.Environ.Map) bool {
    var path_buf: [256]u8 = undefined;
    // macOS has no XDG_RUNTIME_DIR, but gives every user a private
    // $TMPDIR instead of a shared /tmp.
    const runtime_dir = environ.get("XDG_RUNTIME_DIR") orelse environ.get("TMPDIR") orelse "/tmp";
    const path = std.fmt.bufPrint(&path_buf, "{s}/zofi.lock", .{std.mem.trimEnd(u8, runtime_dir, "/")}) catch return true;

    _ = Io.Dir.createFileAbsolute(io, path, .{
        .truncate = false,
        .lock = .exclusive,
        .lock_nonblocking = true,
        .permissions = .fromMode(0o600),
    }) catch |err| return err != error.WouldBlock;
    return true;
}

test "a second acquire in the same runtime dir is refused" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);

    var environ: std.process.Environ.Map = .init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("XDG_RUNTIME_DIR", dir);

    try std.testing.expect(acquire(io, &environ));
    try std.testing.expect(!acquire(io, &environ));
}
