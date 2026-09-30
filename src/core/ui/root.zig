//! Reusable UI building blocks, separate from `layout.zig`'s pure
//! position-solving: each widget here knows how to size and/or draw
//! itself into a resolved `layout.Rect`. Used by every screen in
//! `render.zig` (as of the full port -- see git history if you're
//! wondering what render.zig looked like with hand-derived arithmetic
//! duplicated per screen instead).
pub const layout = @import("layout.zig");
pub const shapes = @import("shapes.zig");
pub const text = @import("text.zig");
pub const image = @import("image.zig");
pub const button = @import("button.zig");
pub const icon_tile = @import("icon_tile.zig");
pub const matched_text = @import("matched_text.zig");
pub const weather_icon = @import("weather_icon.zig");
pub const search_icon = @import("search_icon.zig");

// See root.zig's test block (one directory up) for why this file needs
// its own explicit reference: `zig build test`'s discovery only walks
// `test` blocks reachable this way, not bare `pub const` re-exports --
// confirmed the hard way (a deliberately-broken assertion, and separately
// a deliberately-broken function body, both went uncaught by `zig build
// test` until wired in like this).
test {
    _ = layout;
    _ = shapes;
    _ = text;
    _ = image;
    _ = button;
    _ = icon_tile;
    _ = matched_text;
    _ = weather_icon;
    _ = search_icon;
}
