//! The `-show` launcher modes, cycled with Tab/Shift+Tab. Lives in core
//! (not a backend) so every platform backend shares one definition.
pub const LauncherMode = enum {
    drun,
    run,
    windows,
    clipboard,

    pub fn next(self: LauncherMode) LauncherMode {
        return switch (self) {
            .drun => .run,
            .run => .windows,
            .windows => .clipboard,
            .clipboard => .drun,
        };
    }

    pub fn prev(self: LauncherMode) LauncherMode {
        return switch (self) {
            .drun => .clipboard,
            .run => .drun,
            .windows => .run,
            .clipboard => .windows,
        };
    }
};
