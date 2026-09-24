//! Detaches and runs a shell command so it survives zofi exiting.
const std = @import("std");
const Io = std.Io;

pub fn launch(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, action: []const u8) !void {
    const backgrounded = try std.fmt.allocPrint(allocator, "{s} &", .{action});
    defer allocator.free(backgrounded);

    // `sh` forks the `&` job and exits almost immediately; not waiting on
    // it here is deliberate -- the job must outlive this process.
    _ = try std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", backgrounded },
        .environ_map = environ,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}
