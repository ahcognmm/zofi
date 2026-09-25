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

pub const sources = struct {
    pub const stdin = @import("sources/stdin.zig");
    pub const desktop = @import("sources/desktop.zig");
    pub const path = @import("sources/path.zig");
};
