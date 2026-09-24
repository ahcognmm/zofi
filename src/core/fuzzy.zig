//! Port of fzy's fuzzy-matching algorithm.
//! https://github.com/jhawthorn/fzy/blob/master/ALGORITHM.md
const std = @import("std");

pub const Score = f64;

pub const SCORE_MAX: Score = std.math.inf(Score);
pub const SCORE_MIN: Score = -std.math.inf(Score);

const SCORE_GAP_LEADING: Score = -0.005;
const SCORE_GAP_TRAILING: Score = -0.005;
const SCORE_GAP_INNER: Score = -0.01;
const SCORE_MATCH_CONSECUTIVE: Score = 1.0;
const SCORE_MATCH_SLASH: Score = 0.9;
const SCORE_MATCH_WORD: Score = 0.8;
const SCORE_MATCH_CAPITAL: Score = 0.7;
const SCORE_MATCH_DOT: Score = 0.6;

fn lower(c: u8) u8 {
    return std.ascii.toLower(c);
}

/// Cheap subsequence pre-check, case-insensitive.
pub fn hasMatch(needle: []const u8, haystack: []const u8) bool {
    var hi: usize = 0;
    for (needle) |nc| {
        const nl = lower(nc);
        var found = false;
        while (hi < haystack.len) : (hi += 1) {
            if (lower(haystack[hi]) == nl) {
                found = true;
                hi += 1;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn bonusFor(prev: u8, cur: u8) Score {
    if (std.ascii.isLower(prev) and std.ascii.isUpper(cur)) return SCORE_MATCH_CAPITAL;
    if (prev == '/') return SCORE_MATCH_SLASH;
    if (prev == '-' or prev == '_' or prev == ' ') return SCORE_MATCH_WORD;
    if (prev == '.') return SCORE_MATCH_DOT;
    return 0;
}

/// Reusable scratch space so scoring a candidate never allocates.
/// Call `ensure` (or just `score`/`scoreWithPositions`, which call it for you)
/// with the largest needle/haystack lengths you expect, once, before the hot loop.
pub const Scratch = struct {
    allocator: std.mem.Allocator,
    d: []Score = &.{},
    m: []Score = &.{},
    bonus: []Score = &.{},
    cap_n: usize = 0,
    cap_h: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Scratch {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Scratch) void {
        self.allocator.free(self.d);
        self.allocator.free(self.m);
        self.allocator.free(self.bonus);
        self.* = undefined;
    }

    pub fn ensure(self: *Scratch, n: usize, h: usize) !void {
        if (n <= self.cap_n and h <= self.cap_h) return;
        const new_n = @max(n, self.cap_n);
        const new_h = @max(h, self.cap_h);
        const d = try self.allocator.alloc(Score, new_n * new_h);
        errdefer self.allocator.free(d);
        const m = try self.allocator.alloc(Score, new_n * new_h);
        errdefer self.allocator.free(m);
        const bonus = try self.allocator.alloc(Score, new_h);

        self.allocator.free(self.d);
        self.allocator.free(self.m);
        self.allocator.free(self.bonus);
        self.d = d;
        self.m = m;
        self.bonus = bonus;
        self.cap_n = new_n;
        self.cap_h = new_h;
    }
};

fn fillBonus(bonus: []Score, haystack: []const u8) void {
    var prev: u8 = '/';
    for (haystack, 0..) |ch, i| {
        bonus[i] = bonusFor(prev, ch);
        prev = ch;
    }
}

/// Fills scratch's D/M matrices for `needle` against `haystack`. Both must
/// already fit within scratch's capacity (call `ensure` first).
fn compute(scratch: *Scratch, needle: []const u8, haystack: []const u8) void {
    const n = needle.len;
    const m = haystack.len;
    fillBonus(scratch.bonus[0..m], haystack);

    const d = scratch.d;
    const mat = scratch.m;
    const stride = scratch.cap_h;

    for (0..n) |i| {
        var prev_score: Score = SCORE_MIN;
        const gap_score: Score = if (i == n - 1) SCORE_GAP_TRAILING else SCORE_GAP_INNER;
        const nl = lower(needle[i]);

        for (0..m) |j| {
            const row = i * stride;
            if (nl == lower(haystack[j])) {
                var s: Score = SCORE_MIN;
                if (i == 0) {
                    s = (@as(Score, @floatFromInt(j)) * SCORE_GAP_LEADING) + scratch.bonus[j];
                } else if (j > 0) {
                    const prev_row = (i - 1) * stride;
                    s = @max(
                        mat[prev_row + j - 1] + scratch.bonus[j],
                        d[prev_row + j - 1] + SCORE_MATCH_CONSECUTIVE,
                    );
                }
                d[row + j] = s;
                prev_score = @max(s, prev_score + gap_score);
                mat[row + j] = prev_score;
            } else {
                d[row + j] = SCORE_MIN;
                prev_score = prev_score + gap_score;
                mat[row + j] = prev_score;
            }
        }
    }
}

/// Scores `needle` against `haystack`. Empty needle scores `SCORE_MAX` (a
/// non-match against nothing is a perfect match); callers filtering on an
/// empty query should skip scoring entirely and keep original order.
pub fn score(scratch: *Scratch, needle: []const u8, haystack: []const u8) !Score {
    if (needle.len == 0) return SCORE_MAX;
    if (haystack.len == 0 or needle.len > haystack.len) return SCORE_MIN;
    if (!hasMatch(needle, haystack)) return SCORE_MIN;

    try scratch.ensure(needle.len, haystack.len);
    compute(scratch, needle, haystack);

    const stride = scratch.cap_h;
    return scratch.m[(needle.len - 1) * stride + (haystack.len - 1)];
}

/// Like `score`, but also fills `positions` (must have length >= needle.len)
/// with the matched byte index in `haystack` for each needle character.
pub fn scoreWithPositions(scratch: *Scratch, needle: []const u8, haystack: []const u8, positions: []usize) !Score {
    if (needle.len == 0) return SCORE_MAX;
    if (haystack.len == 0 or needle.len > haystack.len) return SCORE_MIN;
    if (!hasMatch(needle, haystack)) return SCORE_MIN;

    try scratch.ensure(needle.len, haystack.len);
    compute(scratch, needle, haystack);

    const n = needle.len;
    const m = haystack.len;
    const stride = scratch.cap_h;
    const d = scratch.d;
    const mat = scratch.m;

    var match_required = false;
    var j: usize = m - 1;
    var i: usize = n;
    while (i > 0) {
        i -= 1;
        while (true) {
            const row = i * stride;
            if (d[row + j] != SCORE_MIN and (match_required or d[row + j] == mat[row + j])) {
                match_required = i > 0 and j > 0 and
                    mat[row + j] == d[(i - 1) * stride + (j - 1)] + SCORE_MATCH_CONSECUTIVE;
                positions[i] = j;
                if (j == 0) break;
                j -= 1;
                break;
            }
            if (j == 0) break;
            j -= 1;
        }
    }

    return mat[(n - 1) * stride + (m - 1)];
}

test "hasMatch subsequence" {
    try std.testing.expect(hasMatch("fbr", "foo/bar"));
    try std.testing.expect(hasMatch("", "anything"));
    try std.testing.expect(!hasMatch("xyz", "foo/bar"));
    try std.testing.expect(hasMatch("FBR", "foo/bar"));
}

test "empty needle keeps order (scores as max)" {
    var scratch = Scratch.init(std.testing.allocator);
    defer scratch.deinit();
    try std.testing.expectEqual(SCORE_MAX, try score(&scratch, "", "whatever"));
}

test "exact match beats scattered match" {
    var scratch = Scratch.init(std.testing.allocator);
    defer scratch.deinit();
    const exact = try score(&scratch, "fire", "fire");
    const scattered = try score(&scratch, "fire", "f-i-r-e-extinguisher");
    try std.testing.expect(exact > scattered);
}

test "word start gets a bonus over mid-word match" {
    var scratch = Scratch.init(std.testing.allocator);
    defer scratch.deinit();
    // "app" matches the start of "app_launcher" (word-start bonus)
    // vs. inside "wrapper" (no boundary bonus before the 'a').
    const at_word_start = try score(&scratch, "app", "app_launcher");
    const mid_word = try score(&scratch, "app", "wrapper_app");
    try std.testing.expect(at_word_start > mid_word);
}

test "no match scores SCORE_MIN" {
    var scratch = Scratch.init(std.testing.allocator);
    defer scratch.deinit();
    try std.testing.expectEqual(SCORE_MIN, try score(&scratch, "xyz", "abc"));
}

test "scoreWithPositions finds matched indices" {
    var scratch = Scratch.init(std.testing.allocator);
    defer scratch.deinit();
    var positions: [3]usize = undefined;
    const s = try scoreWithPositions(&scratch, "fbr", "foo/bar", &positions);
    try std.testing.expect(s > SCORE_MIN);
    try std.testing.expectEqualSlices(usize, &.{ 0, 4, 6 }, &positions);
}

test "scratch is reused across many candidates without leaking" {
    var scratch = Scratch.init(std.testing.allocator);
    defer scratch.deinit();
    const haystacks = [_][]const u8{ "short", "a-medium-length-one", "s", "yet-another-candidate-string" };
    for (0..1000) |_| {
        for (haystacks) |h| {
            _ = try score(&scratch, "ae", h);
        }
    }
}
