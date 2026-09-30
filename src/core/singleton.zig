//! Single-instance guard. A second `zofi` launched while one is already
//! open (e.g. a keybind mashed twice, or fired again before the first
//! surface painted) would otherwise stack a second layer-shell surface on
//! top of the first with no way to tell them apart.
const std = @import("std");
const linux = std.os.linux;

const LOCK_EX: i32 = 2;
const LOCK_NB: i32 = 4;

/// Tries to become the one running instance. Returns `true` if this
/// process holds the lock (no other instance is running, or the lock
/// couldn't be checked at all -- failing open shouldn't block the user
/// over a `/tmp` permissions quirk). Returns `false` if another instance
/// already holds it.
///
/// The lock fd is deliberately never closed: it's held for the process's
/// entire lifetime and released by the kernel on exit -- including a
/// crash -- which is exactly the semantics wanted here.
pub fn acquire(environ: *const std.process.Environ.Map) bool {
    var path_buf: [256]u8 = undefined;
    const runtime_dir = environ.get("XDG_RUNTIME_DIR") orelse "/tmp";
    const path = std.fmt.bufPrintZ(&path_buf, "{s}/zofi.lock", .{runtime_dir}) catch return true;

    const fd_raw = linux.open(path, .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(fd_raw) != .SUCCESS) return true;
    const fd: i32 = @intCast(fd_raw);

    const rc = linux.flock(fd, LOCK_EX | LOCK_NB);
    return linux.errno(rc) == .SUCCESS;
}
