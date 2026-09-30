//! Recently-launched apps, shown in the dashboard's "Recent" row. A small
//! flat file, read-modify-written in full on each launch -- capped at
//! `max_records` lines, so a full rewrite is cheap and there's no need for
//! append-mode semantics from `Io.File`.
const std = @import("std");
const Io = std.Io;
const Entry = @import("state.zig").Entry;
const c = @cImport({
    @cInclude("time.h");
});

const max_records: usize = 200;
const field_sep: u8 = 0x1F; // ASCII unit separator; won't collide with real text

fn historyPath(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ?[]const u8 {
    if (environ.get("XDG_STATE_HOME")) |dir| {
        return std.fs.path.join(allocator, &.{ dir, "zofi", "history" }) catch null;
    }
    const home = environ.get("HOME") orelse return null;
    return std.fs.path.join(allocator, &.{ home, ".local", "state", "zofi", "history" }) catch null;
}

/// Best-effort: a launch should never fail (or even slow down) because
/// history-writing hit an error, so every failure path here just gives up.
pub fn recordLaunch(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, entry: Entry) void {
    if (entry.is_url) return; // the synthetic browser row isn't a real app
    const label = entry.label;
    const action = entry.action orelse label;
    const icon_name = entry.icon_name orelse "";
    // These are '\n'-delimited records and '\x1f'-delimited fields; bail
    // rather than risk writing a line that can't be parsed back.
    if (std.mem.indexOfAny(u8, label, "\n\x1f") != null) return;
    if (std.mem.indexOfAny(u8, action, "\n\x1f") != null) return;
    if (std.mem.indexOfAny(u8, icon_name, "\n\x1f") != null) return;

    const path = historyPath(allocator, environ) orelse return;
    const dir = std.fs.path.dirname(path) orelse return;
    Io.Dir.cwd().createDirPath(io, dir) catch return;

    const existing = Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch "";

    var lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, existing, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        lines.append(allocator, line) catch continue;
    }

    var out: std.ArrayList(u8) = .empty;
    const keep_from = lines.items.len -| (max_records - 1);
    for (lines.items[keep_from..]) |line| {
        out.appendSlice(allocator, line) catch return;
        out.append(allocator, '\n') catch return;
    }
    out.print(allocator, "{d}{c}{s}{c}{s}{c}{s}\n", .{
        c.time(null),
        field_sep,
        label,
        field_sep,
        action,
        field_sep,
        icon_name,
    }) catch return;

    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items }) catch return;
}

/// Up to `max` most-recently-launched apps, newest first, deduplicated by
/// (label, action). Best-effort: returns an empty slice on any error
/// (no history yet is the common case, not a failure).
pub fn loadRecent(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, max: usize) []const Entry {
    const path = historyPath(allocator, environ) orelse return &.{};
    const contents = Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch return &.{};

    var raw_lines: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        raw_lines.append(allocator, line) catch continue;
    }

    var out: std.ArrayList(Entry) = .empty;
    var i = raw_lines.items.len;
    while (i > 0 and out.items.len < max) {
        i -= 1;
        var parts = std.mem.splitScalar(u8, raw_lines.items[i], field_sep);
        _ = parts.next() orelse continue; // timestamp, unused for plain "most recent" ordering
        const label = parts.next() orelse continue;
        const action = parts.next() orelse continue;
        const icon_name = parts.next() orelse "";

        var duplicate = false;
        for (out.items) |e| {
            if (std.mem.eql(u8, e.label, label) and std.mem.eql(u8, e.action.?, action)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;

        out.append(allocator, .{
            .label = label,
            .action = action,
            .icon_name = if (icon_name.len > 0) icon_name else null,
        }) catch continue;
    }
    return out.toOwnedSlice(allocator) catch &.{};
}
