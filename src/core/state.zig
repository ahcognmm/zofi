//! Query, filtered/sorted results, selection and key handling. Platform-
//! independent: nothing here knows about windows, pixels or Wayland/AppKit.
const std = @import("std");
const fuzzy = @import("fuzzy.zig");

pub const Entry = struct {
    label: []const u8,
    /// What to hand back on accept, if different from `label`.
    action: ?[]const u8 = null,
};

pub const Result = struct {
    index: usize,
    score: fuzzy.Score,
};

pub const NamedKey = enum {
    escape,
    enter,
    backspace,
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
        try self.rescore();
    }

    pub fn selectedEntry(self: *const State) ?Entry {
        if (self.results.items.len == 0) return null;
        return self.entries[self.results.items[self.selected].index];
    }

    pub fn handleKey(self: *State, ev: KeyEvent) !Action {
        switch (ev) {
            .named => |k| switch (k) {
                .escape => return .cancel,
                .enter => return .accept,
                .backspace => {
                    if (self.query.items.len == 0) return .nothing;
                    self.query.shrinkRetainingCapacity(prevUtf8Boundary(self.query.items));
                    try self.rescore();
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
                    self.selected = 0;
                    self.fixScroll();
                    return .redraw;
                },
                .end => {
                    if (self.results.items.len > 0) self.selected = self.results.items.len - 1;
                    self.fixScroll();
                    return .redraw;
                },
                .tab => return .nothing,
            },
            .ctrl => |c| switch (c) {
                .w => {
                    self.deleteTrailingWord();
                    try self.rescore();
                    return .redraw;
                },
                .u => {
                    self.query.clearRetainingCapacity();
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
                try self.query.appendSlice(self.allocator, bytes);
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

    fn deleteTrailingWord(self: *State) void {
        var end = self.query.items.len;
        while (end > 0 and self.query.items[end - 1] == ' ') end -= 1;
        while (end > 0 and self.query.items[end - 1] != ' ') end -= 1;
        self.query.shrinkRetainingCapacity(end);
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
    _ = try s.handleKey(.{ .named = .end });
    try std.testing.expectEqual(@as(usize, 3), s.selected);
    _ = try s.handleKey(.{ .named = .down });
    try std.testing.expectEqual(@as(usize, 3), s.selected);
    _ = try s.handleKey(.{ .named = .home });
    try std.testing.expectEqual(@as(usize, 0), s.selected);
}

test "enter and escape report accept/cancel" {
    var s = try State.init(std.testing.allocator, testEntries());
    defer s.deinit();
    try std.testing.expectEqual(Action.accept, try s.handleKey(.{ .named = .enter }));
    try std.testing.expectEqual(Action.cancel, try s.handleKey(.{ .named = .escape }));
}
