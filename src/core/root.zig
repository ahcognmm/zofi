//! Aggregates the platform-independent core so both the `zofi` binary and
//! dev tools (snapshot, future test harnesses) can import it as one module.
pub const fuzzy = @import("fuzzy.zig");
pub const state = @import("state.zig");
pub const theme = @import("theme.zig");
pub const render = @import("render.zig");
pub const font = @import("font.zig");
pub const icon = @import("icon.zig");
pub const launch = @import("launch.zig");
pub const mode = @import("mode.zig");

pub const sources = struct {
    pub const stdin = @import("sources/stdin.zig");
    pub const desktop = @import("sources/desktop.zig");
    pub const macapps = @import("sources/macapps.zig");
    pub const path = @import("sources/path.zig");
};

// Without a test block here, `zig build test` compiled none of these
// files' tests at all.
test {
    _ = fuzzy;
    _ = state;
    _ = theme;
    _ = render;
    _ = font;
    _ = icon;
    _ = launch;
    _ = mode;
    _ = sources.stdin;
    _ = sources.desktop;
    _ = sources.macapps;
    _ = sources.path;
}
