//! A tiny flexbox-lite layout solver -- the "build our own Yoga" answer to
//! not wanting a vendored C++ dependency (Yoga's public API is C-ABI, but
//! its implementation is ~20 C++ files needing libc++/libstdc++ linking
//! and isn't in nixpkgs, so vendoring it is real toolchain risk for what
//! this project actually needs: row/column flex, gap, padding, fixed vs.
//! flex sizing, and start/center/end/space-between justification -- no
//! wrapping, no intrinsic content measurement, no aspect-ratio).
//!
//! Text nodes have no measurement API here (z2d has none either -- see
//! `theme.zig`'s `charWidth`), so leaves need an explicit fixed size on
//! whichever axis isn't `stretch`ed by the parent; there is no "hug
//! content" for text.
//!
//! Usage: build a `Node` tree as named stack variables, wire them together
//! with `children: []*Node` (pointers, not values -- an array-of-values
//! would copy each child in, and `layout()`'s writes would land in that
//! copy instead of the variable you read back from), call `layout()` once
//! with the root's outer box, then read each node's `.result` rect back
//! while drawing -- mirrors how Yoga's `YGNodeLayoutGetLeft/Top/Width/
//! Height` work after `YGNodeCalculateLayout`. No allocation happens in
//! this module.
const std = @import("std");

pub const Axis = enum { row, column };
pub const Align = enum { start, center, end, stretch };
pub const Justify = enum { start, center, end, space_between };

pub const Size = union(enum) {
    /// Exact size in the theme's logical (pre-scale) units.
    fixed: f64,
    /// Shares the main axis's remaining space (after fixed siblings and
    /// gaps) proportionally to this weight among all `flex` siblings.
    flex: f64,
    /// Cross-axis: fills whatever `align_items: stretch` gives it (the
    /// default). Main-axis: resolves to 0 -- there's no content
    /// measurement to hug, so an `auto` main-axis size is almost always a
    /// mistake; give it `fixed` or `flex` instead.
    auto,
};

pub const Padding = struct {
    top: f64 = 0,
    right: f64 = 0,
    bottom: f64 = 0,
    left: f64 = 0,

    pub fn all(v: f64) Padding {
        return .{ .top = v, .right = v, .bottom = v, .left = v };
    }

    pub fn symmetric(x: f64, y: f64) Padding {
        return .{ .top = y, .right = x, .bottom = y, .left = x };
    }
};

pub const Rect = struct { x: f64 = 0, y: f64 = 0, w: f64 = 0, h: f64 = 0 };

pub const Node = struct {
    axis: Axis = .row,
    justify: Justify = .start,
    align_items: Align = .stretch,
    /// Gap between children along the main axis. Ignored (has no effect)
    /// when `justify == .space_between`, which computes its own spacing.
    gap: f64 = 0,
    padding: Padding = .{},
    width: Size = .auto,
    height: Size = .auto,
    children: []const *Node = &.{},

    /// Filled in by `layout()`: this node's absolute box (not relative to
    /// its parent). Read after `layout()` returns.
    result: Rect = .{},
};

/// Resolves `node.result` and every descendant's `.result`, given the
/// outer box the caller wants `node` to occupy.
pub fn layout(node: *Node, outer: Rect) void {
    node.result = outer;
    if (node.children.len == 0) return;

    const content_x = outer.x + node.padding.left;
    const content_y = outer.y + node.padding.top;
    const content_w = @max(0.0, outer.w - node.padding.left - node.padding.right);
    const content_h = @max(0.0, outer.h - node.padding.top - node.padding.bottom);

    const main_size = if (node.axis == .row) content_w else content_h;
    const cross_size = if (node.axis == .row) content_h else content_w;

    var fixed_total: f64 = 0;
    var flex_total: f64 = 0;
    for (node.children) |child| {
        const sz = if (node.axis == .row) child.width else child.height;
        switch (sz) {
            .fixed => |v| fixed_total += v,
            .flex => |weight| flex_total += weight,
            .auto => {},
        }
    }

    const n: f64 = @floatFromInt(node.children.len);
    const base_gap = if (node.justify == .space_between) 0 else node.gap;
    const gaps_total = base_gap * @max(0.0, n - 1);
    const free_space = @max(0.0, main_size - fixed_total - gaps_total);
    const extra_gap = if (node.justify == .space_between and node.children.len > 1)
        @max(0.0, main_size - fixed_total) / (n - 1)
    else
        base_gap;

    var leading: f64 = 0;
    switch (node.justify) {
        .start, .space_between => {},
        .center => leading = if (flex_total == 0) free_space / 2 else 0,
        .end => leading = if (flex_total == 0) free_space else 0,
    }

    var main_cursor: f64 = leading;
    for (node.children) |child| {
        const main_sz = if (node.axis == .row) child.width else child.height;
        const resolved_main: f64 = switch (main_sz) {
            .fixed => |v| v,
            .flex => |weight| if (flex_total > 0) free_space * (weight / flex_total) else 0,
            .auto => 0,
        };

        // `align_items` applies to the child's resolved cross size
        // regardless of *how* that size was resolved (fixed, flex, or
        // auto) -- CSS doesn't special-case explicit sizes out of
        // alignment, and neither should this.
        const cross_sz = if (node.axis == .row) child.height else child.width;
        const resolved_cross: f64 = switch (cross_sz) {
            .fixed => |v| v,
            .flex => |weight| weight * cross_size, // rare: treated as a fraction of cross_size
            .auto => if (node.align_items == .stretch) cross_size else 0,
        };

        var cross_offset: f64 = 0;
        switch (node.align_items) {
            .start, .stretch => cross_offset = 0,
            .center => cross_offset = (cross_size - resolved_cross) / 2,
            .end => cross_offset = cross_size - resolved_cross,
        }

        const child_rect: Rect = if (node.axis == .row)
            .{ .x = content_x + main_cursor, .y = content_y + cross_offset, .w = resolved_main, .h = resolved_cross }
        else
            .{ .x = content_x + cross_offset, .y = content_y + main_cursor, .w = resolved_cross, .h = resolved_main };

        layout(child, child_rect);
        main_cursor += resolved_main + extra_gap;
    }
}

test "row layout: fixed siblings plus one flex child fill the remainder" {
    var a: Node = .{ .width = .{ .fixed = 50 } };
    var b: Node = .{ .width = .{ .flex = 1 } };
    var c: Node = .{ .width = .{ .fixed = 30 } };
    var root: Node = .{ .axis = .row, .gap = 10, .children = &.{ &a, &b, &c } };
    layout(&root, .{ .x = 0, .y = 0, .w = 200, .h = 40 });

    try std.testing.expectEqual(@as(f64, 0), a.result.x);
    try std.testing.expectEqual(@as(f64, 50), a.result.w);
    try std.testing.expectEqual(@as(f64, 60), b.result.x); // 50 + gap(10)
    try std.testing.expectEqual(@as(f64, 100), b.result.w); // 200 - 50 - 30 - 2*10
    try std.testing.expectEqual(@as(f64, 170), c.result.x); // 60 + 100 + 10
    try std.testing.expectEqual(@as(f64, 30), c.result.w);
    // stretch is the default cross-axis alignment
    try std.testing.expectEqual(@as(f64, 40), a.result.h);
}

test "column layout with padding offsets children into the content box" {
    var a: Node = .{ .height = .{ .fixed = 20 } };
    var b: Node = .{ .height = .{ .fixed = 20 } };
    var root: Node = .{
        .axis = .column,
        .gap = 5,
        .padding = Padding.all(8),
        .children = &.{ &a, &b },
    };
    layout(&root, .{ .x = 100, .y = 100, .w = 60, .h = 100 });

    try std.testing.expectEqual(@as(f64, 108), a.result.x);
    try std.testing.expectEqual(@as(f64, 108), a.result.y);
    try std.testing.expectEqual(@as(f64, 44), a.result.w); // 60 - 2*8
    try std.testing.expectEqual(@as(f64, 133), b.result.y); // 108 + 20 + gap(5)
}

test "space_between pins the first and last child to the container's edges" {
    var a: Node = .{ .height = .{ .fixed = 30 } };
    var b: Node = .{ .height = .{ .fixed = 30 } };
    var root: Node = .{ .axis = .column, .justify = .space_between, .children = &.{ &a, &b } };
    layout(&root, .{ .x = 0, .y = 0, .w = 50, .h = 200 });

    try std.testing.expectEqual(@as(f64, 0), a.result.y);
    try std.testing.expectEqual(@as(f64, 170), b.result.y); // 200 - 30
}

test "align_items center centers a fixed-cross-size child" {
    var a: Node = .{ .width = .{ .fixed = 20 }, .height = .{ .fixed = 10 } };
    var root: Node = .{ .axis = .row, .align_items = .center, .children = &.{&a} };
    layout(&root, .{ .x = 0, .y = 0, .w = 20, .h = 40 });

    try std.testing.expectEqual(@as(f64, 15), a.result.y); // (40-10)/2
}

test "nested tree: results are read through the same pointers used to build it" {
    var leaf_a: Node = .{ .height = .{ .fixed = 10 } };
    var leaf_b: Node = .{ .height = .{ .fixed = 10 } };
    var inner: Node = .{ .axis = .column, .width = .{ .fixed = 40 }, .children = &.{ &leaf_a, &leaf_b } };
    var sibling: Node = .{ .width = .{ .flex = 1 } };
    var root: Node = .{ .axis = .row, .children = &.{ &inner, &sibling } };
    layout(&root, .{ .x = 0, .y = 0, .w = 100, .h = 30 });

    // A value-copying `[]Node` design would leave these at their zero
    // defaults, since layout()'s writes would land in a copy made when
    // the parent's children array was built, not in `leaf_a`/`leaf_b`.
    try std.testing.expectEqual(@as(f64, 40), inner.result.w);
    try std.testing.expectEqual(@as(f64, 0), leaf_a.result.y);
    try std.testing.expectEqual(@as(f64, 10), leaf_b.result.y);
    try std.testing.expectEqual(@as(f64, 60), sibling.result.w); // 100 - 40
}
