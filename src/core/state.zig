//! Query, filtered/sorted results, selection and key handling. Platform-
//! independent: nothing here knows about windows, pixels or Wayland/AppKit.
const std = @import("std");
const fuzzy = @import("fuzzy.zig");

pub const Entry = struct {
    label: []const u8,
    /// What to hand back on accept, if different from `label`. Also shown
    /// as right-aligned secondary text in compact (Run/dmenu) rows when it
    /// differs from `label`.
    action: ?[]const u8 = null,
    /// Shown below the name in tall (Apps/Windows) rows, e.g. "Web Browser".
    subtitle: ?[]const u8 = null,
    /// Freedesktop icon name (the `.desktop` file's `Icon=`), resolved and
    /// decoded lazily by `core.icon.Cache`. Falls back to the colored
    /// letter tile when null or unresolvable.
    icon_name: ?[]const u8 = null,
};

pub const Result = struct {
    index: usize,
    score: fuzzy.Score,
};

pub const NamedKey = enum {
    escape,
    enter,
    backspace,
    left,
    right,
    up,
    down,
    page_up,
    page_down,
    home,
    end,
    tab,
};

pub const CtrlKey = enum { w, u, n, p };

pub const KeyEvent = union(enum) {
    named: NamedKey,
    ctrl: CtrlKey,
    /// UTF-8 text to insert at the cursor.
    text: []const u8,
};

pub const Action = enum { nothing, redraw, accept, cancel };

pub const State = struct {
    allocator: std.mem.Allocator,
    entries: []const Entry,
    query: std.ArrayList(u8) = .empty,
    /// Byte offset into `query.items`, always on a UTF-8 boundary. Where
    /// text gets inserted and what backspace/Ctrl+W delete.
    cursor: usize = 0,
    results: std.ArrayList(Result) = .empty,
    selected: usize = 0,
    scroll: usize = 0,
    visible_rows: usize = 10,
    scratch: fuzzy.Scratch,

    pub fn init(allocator: std.mem.Allocator, entries: []const Entry) !State {
        var self: State = .{
            .allocator = allocator,
            .entries = entries,
            .scratch = fuzzy.Scratch.init(allocator),
        };
        try self.rescore();
        return self;
    }

    pub fn deinit(self: *State) void {
        self.query.deinit(self.allocator);
        self.results.deinit(self.allocator);
        self.scratch.deinit();
        self.* = undefined;
    }

    pub fn setQuery(self: *State, text: []const u8) !void {
        self.query.clearRetainingCapacity();
        try self.query.appendSlice(self.allocator, text);
        self.cursor = self.query.items.len;
        try self.rescore();
    }

    pub fn selectedEntry(self: *const State) ?Entry {
        if (self.results.items.len == 0) return null;
        return self.entries[self.results.items[self.selected].index];
    }

    pub fn handleKey(self: *State, ev: KeyEvent) !Action {
        switch (ev) {
            .named => |k| switch (k) {
                .escape => {
                    if (self.query.items.len == 0) return .cancel;
                    self.query.clearRetainingCapacity();
                    self.cursor = 0;
                    try self.rescore();
                    return .redraw;
                },
                .enter => return .accept,
                .backspace => {
                    if (self.cursor == 0) return .nothing;
                    const start = prevUtf8Boundary(self.query.items[0..self.cursor]);
                    self.query.replaceRangeAssumeCapacity(start, self.cursor - start, &.{});
                    self.cursor = start;
                    try self.rescore();
                    return .redraw;
                },
                .left => {
                    if (self.cursor == 0) return .nothing;
                    self.cursor = prevUtf8Boundary(self.query.items[0..self.cursor]);
                    return .redraw;
                },
                .right => {
                    if (self.cursor >= self.query.items.len) return .nothing;
                    self.cursor += std.unicode.utf8ByteSequenceLength(self.query.items[self.cursor]) catch 1;
                    return .redraw;
                },
                .up => {
                    self.moveSelection(-1);
                    return .redraw;
                },
                .down => {
                    self.moveSelection(1);
                    return .redraw;
                },
                .page_up => {
                    self.moveSelection(-@as(isize, @intCast(self.visible_rows)));
                    return .redraw;
                },
                .page_down => {
                    self.moveSelection(@as(isize, @intCast(self.visible_rows)));
                    return .redraw;
                },
                .home => {
                    if (self.cursor == 0) return .nothing;
                    self.cursor = 0;
                    return .redraw;
                },
                .end => {
                    if (self.cursor >= self.query.items.len) return .nothing;
                    self.cursor = self.query.items.len;
                    return .redraw;
                },
                .tab => return .nothing,
            },
            .ctrl => |c| switch (c) {
                .w => {
                    self.deleteWordBeforeCursor();
                    try self.rescore();
                    return .redraw;
                },
                .u => {
                    self.query.clearRetainingCapacity();
                    self.cursor = 0;
                    try self.rescore();
                    return .redraw;
                },
                .n => {
                    self.moveSelection(1);
                    return .redraw;
                },
                .p => {
                    self.moveSelection(-1);
                    return .redraw;
                },
            },
            .text => |bytes| {
                if (bytes.len == 0) return .nothing;
                try self.query.insertSlice(self.allocator, self.cursor, bytes);
                self.cursor += bytes.len;
                try self.rescore();
                return .redraw;
            },
        }
    }

    fn rescore(self: *State) !void {
        self.results.clearRetainingCapacity();
        const q = self.query.items;

        if (q.len == 0) {
            try self.results.ensureTotalCapacity(self.allocator, self.entries.len);
            for (self.entries, 0..) |_, i| {
                self.results.appendAssumeCapacity(.{ .index = i, .score = fuzzy.SCORE_MAX });
            }
        } else {
            for (self.entries, 0..) |e, i| {
                const s = try fuzzy.score(&self.scratch, q, e.label);
                if (s > fuzzy.SCORE_MIN) {
                    try self.results.append(self.allocator, .{ .index = i, .score = s });
                }
            }
            std.mem.sort(Result, self.results.items, self.entries, lessThan);
        }

        self.selected = 0;
        self.scroll = 0;
    }

    fn lessThan(entries: []const Entry, a: Result, b: Result) bool {
        if (a.score != b.score) return a.score > b.score;
        const la = entries[a.index].label.len;
        const lb = entries[b.index].label.len;
        if (la != lb) return la < lb;
        return a.index < b.index;
    }

    fn moveSelection(self: *State, delta: isize) void {
        if (self.results.items.len == 0) return;
        const len: isize = @intCast(self.results.items.len);
        var sel: isize = @intCast(self.selected);
        sel += delta;
        if (sel < 0) sel = 0;
        if (sel >= len) sel = len - 1;
        self.selected = @intCast(sel);
        self.fixScroll();
    }

    fn fixScroll(self: *State) void {
        if (self.selected < self.scroll) self.scroll = self.selected;
        if (self.visible_rows > 0 and self.selected >= self.scroll + self.visible_rows) {
            self.scroll = self.selected - self.visible_rows + 1;
        }
    }

    fn deleteWordBeforeCursor(self: *State) void {
        var start = self.cursor;
        while (start > 0 and self.query.items[start - 1] == ' ') start -= 1;
        while (start > 0 and self.query.items[start - 1] != ' ') start -= 1;
        self.query.replaceRangeAssumeCapacity(start, self.cursor - start, &.{});
        self.cursor = start;
    }
};

fn prevUtf8Boundary(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var i = bytes.len - 1;
    while (i > 0 and (bytes[i] & 0xC0) == 0x80) i -= 1;
    return i;
}

fn testEntries() []const Entry {
    return &.{
        .{ .label = "firefox" },
        .{ .label = "file-manager" },
        .{ .label = "vim" },
        .{ .label = "fire-extinguisher-simulator" },
    };
}

test "empty query keeps original order" {
    var s = try State.init(std.testing.allocator, testEntries());
    defer s.deinit();
    try std.testing.expectEqual(@as(usize, 4), s.results.items.len);
    for (s.results.items, 0..) |r, i| try std.testing.expectEqual(i, r.index);
}

test "typing narrows and ranks results" {
    var s = try State.init(std.testing.allocator, testEntries());
    defer s.deinit();
    _ = try s.handleKey(.{ .text = "fire" });
    try std.testing.expect(s.results.items.len >= 1);
    // "firefox" is an exact prefix match, should rank first.
    try std.testing.expectEqualStrings("firefox", s.selectedEntry().?.label);
}

test "backspace widens results again" {
    var s = try State.init(std.testing.allocator, testEntries());
    defer s.deinit();
    _ = try s.handleKey(.{ .text = "fire" });
    const narrowed = s.results.items.len;
    _ = try s.handleKey(.{ .named = .backspace });
    _ = try s.handleKey(.{ .named = .backspace });
    _ = try s.handleKey(.{ .named = .backspace });
    _ = try s.handleKey(.{ .named = .backspace });
    try std.testing.expectEqual(@as(usize, 4), s.results.items.len);
    try std.testing.expect(s.results.items.len >= narrowed);
}

test "ctrl+u clears the query" {
    var s = try State.init(std.testing.allocator, testEntries());
    defer s.deinit();
    _ = try s.handleKey(.{ .text = "fire" });
    _ = try s.handleKey(.{ .ctrl = .u });
    try std.testing.expectEqual(@as(usize, 0), s.query.items.len);
    try std.testing.expectEqual(@as(usize, 4), s.results.items.len);
}

test "ctrl+w deletes the trailing word" {
    var s = try State.init(std.testing.allocator, testEntries());
    defer s.deinit();
    _ = try s.handleKey(.{ .text = "foo bar" });
    _ = try s.handleKey(.{ .ctrl = .w });
    try std.testing.expectEqualStrings("foo ", s.query.items);
}

test "navigation clamps at the edges" {
    var s = try State.init(std.testing.allocator, testEntries());
    defer s.deinit();
    _ = try s.handleKey(.{ .named = .up });
    try std.testing.expectEqual(@as(usize, 0), s.selected);
    _ = try s.handleKey(.{ .named = .page_down });
    try std.testing.expectEqual(@as(usize, 3), s.selected);
    _ = try s.handleKey(.{ .named = .down });
    try std.testing.expectEqual(@as(usize, 3), s.selected);
    _ = try s.handleKey(.{ .named = .page_up });
    try std.testing.expectEqual(@as(usize, 0), s.selected);
}

test "left/right move the cursor, clamped at the edges" {
    var s = try State.init(std.testing.allocator, testEntries());
    defer s.deinit();
    try s.setQuery("abc");
    try std.testing.expectEqual(@as(usize, 3), s.cursor);
    _ = try s.handleKey(.{ .named = .right });
    try std.testing.expectEqual(@as(usize, 3), s.cursor); // already at end
    _ = try s.handleKey(.{ .named = .left });
    _ = try s.handleKey(.{ .named = .left });
    try std.testing.expectEqual(@as(usize, 1), s.cursor);
    _ = try s.handleKey(.{ .named = .left });
    _ = try s.handleKey(.{ .named = .left });
    try std.testing.expectEqual(@as(usize, 0), s.cursor); // clamped
}

test "home/end move the cursor to the start/end of the query" {
    var s = try State.init(std.testing.allocator, testEntries());
    defer s.deinit();
    try s.setQuery("abc");
    _ = try s.handleKey(.{ .named = .home });
    try std.testing.expectEqual(@as(usize, 0), s.cursor);
    _ = try s.handleKey(.{ .named = .end });
    try std.testing.expectEqual(@as(usize, 3), s.cursor);
}

test "text inserts at the cursor, not always at the end" {
    var s = try State.init(std.testing.allocator, testEntries());
    defer s.deinit();
    try s.setQuery("ac");
    _ = try s.handleKey(.{ .named = .left });
    _ = try s.handleKey(.{ .text = "b" });
    try std.testing.expectEqualStrings("abc", s.query.items);
    try std.testing.expectEqual(@as(usize, 2), s.cursor);
}

test "backspace deletes before the cursor, not always the last char" {
    var s = try State.init(std.testing.allocator, testEntries());
    defer s.deinit();
    try s.setQuery("abc");
    _ = try s.handleKey(.{ .named = .left });
    _ = try s.handleKey(.{ .named = .backspace });
    try std.testing.expectEqualStrings("ac", s.query.items);
    try std.testing.expectEqual(@as(usize, 1), s.cursor);
}

test "enter and escape report accept/cancel" {
    var s = try State.init(std.testing.allocator, testEntries());
    defer s.deinit();
    try std.testing.expectEqual(Action.accept, try s.handleKey(.{ .named = .enter }));
    try std.testing.expectEqual(Action.cancel, try s.handleKey(.{ .named = .escape }));
}

test "escape clears a non-empty query before it cancels" {
    var s = try State.init(std.testing.allocator, testEntries());
    defer s.deinit();
    _ = try s.handleKey(.{ .text = "fire" });

    try std.testing.expectEqual(Action.redraw, try s.handleKey(.{ .named = .escape }));
    try std.testing.expectEqual(@as(usize, 0), s.query.items.len);
    try std.testing.expectEqual(@as(usize, 0), s.cursor);
    try std.testing.expectEqual(@as(usize, 4), s.results.items.len); // back to unfiltered

    try std.testing.expectEqual(Action.cancel, try s.handleKey(.{ .named = .escape }));
}
