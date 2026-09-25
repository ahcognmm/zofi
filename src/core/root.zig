//! Aggregates the platform-independent core so both the `zofi` binary and
//! dev tools (snapshot, future test harnesses) can import it as one module.
pub const fuzzy = @import("fuzzy.zig");
pub const state = @import("state.zig");
pub const theme = @import("theme.zig");
pub const render = @import("render.zig");
pub const font = @import("font.zig");
pub const icon = @import("icon.zig");
pub const launch = @import("launch.zig");
pub const singleton = @import("singleton.zig");
pub const dashboard = @import("dashboard.zig");
pub const history = @import("history.zig");
pub const weather = @import("weather.zig");
pub const ui = @import("ui/root.zig");

pub const sources = struct {
    pub const stdin = @import("sources/stdin.zig");
    pub const desktop = @import("sources/desktop.zig");
    pub const path = @import("sources/path.zig");
};

// `zig test`'s discovery only walks files reachable from *this* one via
// `test` blocks, not merely `pub const` re-exports -- without this, e.g.
// layout.zig's tests silently never run under `zig build test`, even
// though render.zig genuinely imports and calls it (confirmed by
// deliberately breaking an assertion in each and finding `zig build test`
// still exited 0 until its module was referenced here).
test {
    _ = fuzzy;
    _ = state;
    _ = theme;
    _ = render;
    _ = font;
    _ = icon;
    _ = launch;
    _ = singleton;
    _ = dashboard;
    _ = history;
    _ = weather;
    _ = ui;
    _ = sources.stdin;
    _ = sources.desktop;
    _ = sources.path;
}
