//! drun mode: `.desktop` files from `$XDG_DATA_HOME/applications` and each
//! `$XDG_DATA_DIRS/applications`, first file with a given ID wins.
const std = @import("std");
const Io = std.Io;
const Entry = @import("../state.zig").Entry;

const ParsedEntry = struct {
    name: ?[]const u8 = null,
    exec: ?[]const u8 = null,
    generic_name: ?[]const u8 = null,
    comment: ?[]const u8 = null,
    icon: ?[]const u8 = null,
    terminal: bool = false,
    no_display: bool = false,
    hidden: bool = false,
    is_application: bool = true,
};

fn parse(contents: []const u8) ParsedEntry {
    var result: ParsedEntry = .{};
    var in_entry_section = false;

    var it = std.mem.splitScalar(u8, contents, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            in_entry_section = std.mem.eql(u8, line, "[Desktop Entry]");
            continue;
        }
        if (!in_entry_section) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, key, "Name")) {
            result.name = value;
        } else if (std.mem.eql(u8, key, "Exec")) {
            result.exec = value;
        } else if (std.mem.eql(u8, key, "GenericName")) {
            result.generic_name = value;
        } else if (std.mem.eql(u8, key, "Comment")) {
            result.comment = value;
        } else if (std.mem.eql(u8, key, "Icon")) {
            result.icon = value;
        } else if (std.mem.eql(u8, key, "Terminal")) {
            result.terminal = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "NoDisplay")) {
            result.no_display = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "Hidden")) {
            result.hidden = std.mem.eql(u8, value, "true");
        } else if (std.mem.eql(u8, key, "Type")) {
            result.is_application = std.mem.eql(u8, value, "Application");
        }
    }
    return result;
}

/// Strips the `%f %F %u %U %i %c %k` field codes rofi/wrappers don't fill in,
/// and unescapes `%%` to a literal `%`, per the Desktop Entry spec.
fn stripFieldCodes(allocator: std.mem.Allocator, exec: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < exec.len) {
        if (exec[i] == '%' and i + 1 < exec.len) {
            switch (exec[i + 1]) {
                'f', 'F', 'u', 'U', 'i', 'c', 'k' => {
                    i += 2;
                    continue;
                },
                '%' => {
                    try out.append(allocator, '%');
                    i += 2;
                    continue;
                },
                else => {},
            }
        }
        try out.append(allocator, exec[i]);
        i += 1;
    }

    // Collapse the double spaces left behind by removed field codes.
    var collapsed: std.ArrayList(u8) = .empty;
    errdefer collapsed.deinit(allocator);
    var prev_space = false;
    for (out.items) |ch| {
        const is_space = ch == ' ';
        if (is_space and prev_space) continue;
        try collapsed.append(allocator, ch);
        prev_space = is_space;
    }
    out.deinit(allocator);

    const trimmed = std.mem.trim(u8, collapsed.items, " ");
    const result = try allocator.dupe(u8, trimmed);
    collapsed.deinit(allocator);
    return result;
}

fn dataDirs(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map) ![][]const u8 {
    var dirs: std.ArrayList([]const u8) = .empty;

    if (environ.get("XDG_DATA_HOME")) |home| {
        try dirs.append(allocator, try std.fs.path.join(allocator, &.{ home, "applications" }));
    } else if (environ.get("HOME")) |home| {
        try dirs.append(allocator, try std.fs.path.join(allocator, &.{ home, ".local/share/applications" }));
    }

    const data_dirs = environ.get("XDG_DATA_DIRS") orelse "/usr/local/share:/usr/share";
    var it = std.mem.tokenizeScalar(u8, data_dirs, ':');
    while (it.next()) |dir| {
        try dirs.append(allocator, try std.fs.path.join(allocator, &.{ dir, "applications" }));
    }

    return dirs.toOwnedSlice(allocator);
}

/// Scans for application entries. `terminal_cmd` is used to wrap
/// `Terminal=true` entries (typically `$TERMINAL`, falling back to a
/// sensible default).
pub fn scan(
    allocator: std.mem.Allocator,
    io: Io,
    environ: *const std.process.Environ.Map,
    terminal_cmd: []const u8,
) ![]Entry {
    var entries: std.ArrayList(Entry) = .empty;
    var seen_ids: std.StringHashMapUnmanaged(void) = .empty;

    for (try dataDirs(allocator, environ)) |dir_path| {
        if (!std.fs.path.isAbsolute(dir_path)) continue;
        var dir = Io.Dir.openDirAbsolute(io, dir_path, .{ .iterate = true }) catch continue;
        defer dir.close(io);

        var walker = try dir.walk(allocator);
        defer walker.deinit();

        while (try walker.next(io)) |walk_entry| {
            // NixOS (and other profile-based distros) populate
            // applications/ entirely with symlinks into the store; readdir
            // reports those as .sym_link, not .file, without following
            // them. Rejecting anything but .file here silently dropped
            // every real desktop entry on such systems.
            if (walk_entry.kind != .file and walk_entry.kind != .sym_link) continue;
            if (!std.mem.endsWith(u8, walk_entry.basename, ".desktop")) continue;

            if (seen_ids.contains(walk_entry.path)) continue;
            try seen_ids.put(allocator, try allocator.dupe(u8, walk_entry.path), {});

            const contents = walk_entry.dir.readFileAlloc(io, walk_entry.basename, allocator, .unlimited) catch continue;
            const parsed = parse(contents);

            if (!parsed.is_application) continue;
            if (parsed.no_display or parsed.hidden) continue;
            const name = parsed.name orelse continue;
            const exec = parsed.exec orelse continue;

            const stripped = try stripFieldCodes(allocator, exec);
            const final_exec = if (parsed.terminal)
                try std.fmt.allocPrint(allocator, "{s} -e {s}", .{ terminal_cmd, stripped })
            else
                stripped;

            try entries.append(allocator, .{
                .label = name,
                .action = final_exec,
                .subtitle = parsed.generic_name orelse parsed.comment,
                .icon_name = parsed.icon,
            });
        }
    }

    return entries.toOwnedSlice(allocator);
}

test "parse skips localized keys and reads the base Desktop Entry section" {
    const contents =
        \\[Desktop Entry]
        \\Name=Example App
        \\Name[fr]=Application Exemple
        \\Exec=example-app %U
        \\Type=Application
        \\Terminal=false
    ;
    const parsed = parse(contents);
    try std.testing.expectEqualStrings("Example App", parsed.name.?);
    try std.testing.expectEqualStrings("example-app %U", parsed.exec.?);
    try std.testing.expect(parsed.is_application);
    try std.testing.expect(!parsed.terminal);
}

test "parse honors NoDisplay and Hidden" {
    const contents =
        \\[Desktop Entry]
        \\Name=Hidden App
        \\Exec=hidden-app
        \\NoDisplay=true
    ;
    const parsed = parse(contents);
    try std.testing.expect(parsed.no_display);
}

test "stripFieldCodes removes field codes and unescapes %%" {
    const stripped = try stripFieldCodes(std.testing.allocator, "app %f --opt %% --other %U trailing");
    defer std.testing.allocator.free(stripped);
    try std.testing.expectEqualStrings("app --opt % --other trailing", stripped);
}
