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

const BrowserWindow = struct { address: []const u8, title: []const u8 };

/// Hyprland's `class` for a browser window isn't always its binary name
/// (Firefox: exactly "firefox"; Chromium-family browsers like Helium often
/// report a capitalized or suffixed variant) -- match case-insensitively,
/// either direction, rather than requiring an exact string.
fn classMatchesBrowser(class: []const u8, browser: []const u8) bool {
    var class_buf: [128]u8 = undefined;
    var browser_buf: [128]u8 = undefined;
    if (class.len > class_buf.len or browser.len > browser_buf.len) return false;
    const c = std.ascii.lowerString(class_buf[0..class.len], class);
    const b = std.ascii.lowerString(browser_buf[0..browser.len], browser);
    return std.mem.indexOf(u8, c, b) != null or std.mem.indexOf(u8, b, c) != null;
}

fn snapshotBrowserWindows(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, browser: []const u8) []const BrowserWindow {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "hyprctl", "-j", "clients" },
        .environ_map = environ,
    }) catch return &.{};
    if (result.term != .exited or result.term.exited != 0) return &.{};

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch return &.{};
    defer parsed.deinit();
    const clients = switch (parsed.value) {
        .array => |a| a.items,
        else => return &.{},
    };

    var out: std.ArrayList(BrowserWindow) = .empty;
    for (clients) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };
        const cl = obj.get("class") orelse continue;
        const addr = obj.get("address") orelse continue;
        const title = obj.get("title") orelse continue;
        if (cl != .string or addr != .string or title != .string) continue;
        if (!classMatchesBrowser(cl.string, browser)) continue;
        // Snapshots are compared byte-for-byte after this returns, so these
        // must survive `parsed.deinit()` above -- can't alias its strings.
        out.append(allocator, .{
            .address = allocator.dupe(u8, addr.string) catch continue,
            .title = allocator.dupe(u8, title.string) catch continue,
        }) catch continue;
    }
    return out.items;
}

/// Opens `url` in `browser` (a binary name, e.g. "firefox" or "helium"). If
/// that browser is already running, most browsers' remoting protocol makes
/// this open a new tab in the existing window instead of a second instance
/// -- no extra IPC needed on our end. Reusing a window this way doesn't map
/// a new toplevel, so the compositor's usual focus-new-window-on-map
/// behavior never fires; poll Hyprland afterward for whichever matching
/// window is new or changed title, and focus it directly. No-op beyond the
/// launch itself outside Hyprland.
pub fn launchUrl(allocator: std.mem.Allocator, io: Io, environ: *const std.process.Environ.Map, browser: []const u8, url: []const u8) !void {
    var quoted: std.ArrayList(u8) = .empty;
    defer quoted.deinit(allocator);
    try quoted.append(allocator, '\'');
    for (url) |c| {
        if (c == '\'') {
            try quoted.appendSlice(allocator, "'\\''");
        } else {
            try quoted.append(allocator, c);
        }
    }
    try quoted.append(allocator, '\'');

    const command = try std.fmt.allocPrint(allocator, "{s} {s}", .{ browser, quoted.items });
    defer allocator.free(command);

    const has_hypr = environ.get("HYPRLAND_INSTANCE_SIGNATURE") != null;
    const before = if (has_hypr) snapshotBrowserWindows(allocator, io, environ, browser) else &.{};

    try launch(allocator, io, environ, command);
    if (!has_hypr) return;

    var attempt: usize = 0;
    while (attempt < 20) : (attempt += 1) {
        try Io.sleep(io, .fromMilliseconds(150), .awake);
        const after = snapshotBrowserWindows(allocator, io, environ, browser);
        for (after) |w| {
            const unchanged = for (before) |b| {
                if (std.mem.eql(u8, b.address, w.address)) break std.mem.eql(u8, b.title, w.title);
            } else false;
            if (unchanged) continue;

            const target = std.fmt.allocPrint(allocator, "address:{s}", .{w.address}) catch return;
            _ = std.process.run(allocator, io, .{
                .argv = &.{ "hyprctl", "dispatch", "focuswindow", target },
                .environ_map = environ,
            }) catch {};
            return;
        }
    }
}
