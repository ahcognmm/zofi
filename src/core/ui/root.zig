//! Reusable UI building blocks, separate from `layout.zig`'s pure
//! position-solving: each widget here knows how to size and/or draw
//! itself into a resolved `layout.Rect`. Scaffolding for future views
//! (e.g. a file-preview screen) -- existing screens in `render.zig`
//! predate this directory and haven't been migrated onto it (deliberate,
//! see the project's recent history: migrating verified, working UI is
//! its own risk, separate from adding new capability).
pub const layout = @import("layout.zig");
pub const shapes = @import("shapes.zig");
pub const text = @import("text.zig");
pub const image = @import("image.zig");
pub const button = @import("button.zig");

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
}
