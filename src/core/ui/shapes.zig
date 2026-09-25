//! Bare z2d path helpers shared by the widgets in this directory.
//! render.zig has its own copies (predating this module) that existing
//! screens still use -- not touched here, see this directory's other
//! files' doc comments for why.
const std = @import("std");
const z2d = @import("z2d");

pub fn fillRect(ctx: *z2d.Context, x: f64, y: f64, w: f64, h: f64) !void {
    try ctx.moveTo(x, y);
    try ctx.lineTo(x + w, y);
    try ctx.lineTo(x + w, y + h);
    try ctx.lineTo(x, y + h);
    try ctx.closePath();
    try ctx.fill();
}

pub fn roundedRect(ctx: *z2d.Context, x: f64, y: f64, w: f64, h: f64, r: f64) !void {
    const rr = @max(0.0, @min(r, @min(w, h) / 2));
    const half_pi = std.math.pi / 2.0;
    try ctx.moveTo(x + rr, y);
    try ctx.lineTo(x + w - rr, y);
    try ctx.arc(x + w - rr, y + rr, rr, -half_pi, 0);
    try ctx.lineTo(x + w, y + h - rr);
    try ctx.arc(x + w - rr, y + h - rr, rr, 0, half_pi);
    try ctx.lineTo(x + rr, y + h);
    try ctx.arc(x + rr, y + h - rr, rr, half_pi, std.math.pi);
    try ctx.lineTo(x, y + rr);
    try ctx.arc(x + rr, y + rr, rr, std.math.pi, std.math.pi + half_pi);
    try ctx.closePath();
}
