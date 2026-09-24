//! Wayland backend: wlr-layer-shell (falling back to plain xdg_toplevel),
//! wl_shm double buffering, and xkbcommon-driven keyboard input with
//! software key repeat via timerfd. Links libwayland-client + libxkbcommon
//! (see build.zig's `addWaylandBackend`) rather than speaking the wire
//! protocol directly -- the plan's stated fallback for getting a real
//! window working first.
const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Io = std.Io;
const core = @import("core");

pub const c = @cImport({
    @cInclude("wayland-client.h");
    @cInclude("xdg-shell-client-protocol.h");
    @cInclude("wlr-layer-shell-unstable-v1-client-protocol.h");
    @cInclude("xkbcommon/xkbcommon.h");
});

const Buffer = struct {
    wl_buffer: ?*c.wl_buffer = null,
    pixels: []core_z2d.pixel.ARGB = &.{},
    busy: bool = false,
};

const core_z2d = @import("z2d");

pub const App = struct {
    allocator: std.mem.Allocator,
    io: Io,

    display: *c.wl_display,
    registry: *c.wl_registry,

    compositor: ?*c.wl_compositor = null,
    shm: ?*c.wl_shm = null,
    seat: ?*c.wl_seat = null,
    layer_shell: ?*c.zwlr_layer_shell_v1 = null,
    xdg_wm_base: ?*c.xdg_wm_base = null,

    surface: ?*c.wl_surface = null,
    layer_surface: ?*c.zwlr_layer_surface_v1 = null,
    xdg_surface: ?*c.xdg_surface = null,
    xdg_toplevel: ?*c.xdg_toplevel = null,

    keyboard: ?*c.wl_keyboard = null,
    xkb_context: ?*c.xkb_context = null,
    xkb_keymap: ?*c.xkb_keymap = null,
    xkb_state: ?*c.xkb_state = null,

    repeat_rate: i32 = 25,
    repeat_delay: i32 = 600,
    repeat_keycode: u32 = 0,
    timer_fd: i32 = -1,

    configured: bool = false,
    width: i32 = 0,
    height: i32 = 0,
    pool_map: []align(std.heap.page_size_min) u8 = &.{},

    buffers: [2]Buffer = .{ .{}, .{} },
    cur_buffer: usize = 0,

    theme: core.theme.Theme,
    state: core.state.State,
    need_redraw: bool = true,

    running: bool = true,
    accepted: ?core.state.Entry = null,
};

const registry_listener: c.wl_registry_listener = .{
    .global = registryGlobal,
    .global_remove = registryGlobalRemove,
};

fn registryGlobal(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32, interface: [*c]const u8, version: u32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    const iface = std.mem.span(interface);

    if (std.mem.eql(u8, iface, std.mem.span(c.wl_compositor_interface.name))) {
        app.compositor = @ptrCast(@alignCast(c.wl_registry_bind(registry, name, &c.wl_compositor_interface, @min(version, 4)).?));
    } else if (std.mem.eql(u8, iface, std.mem.span(c.wl_shm_interface.name))) {
        app.shm = @ptrCast(@alignCast(c.wl_registry_bind(registry, name, &c.wl_shm_interface, 1).?));
    } else if (std.mem.eql(u8, iface, std.mem.span(c.wl_seat_interface.name))) {
        app.seat = @ptrCast(@alignCast(c.wl_registry_bind(registry, name, &c.wl_seat_interface, @min(version, 7)).?));
        _ = c.wl_seat_add_listener(app.seat, &seat_listener, app);
    } else if (std.mem.eql(u8, iface, std.mem.span(c.zwlr_layer_shell_v1_interface.name))) {
        app.layer_shell = @ptrCast(@alignCast(c.wl_registry_bind(registry, name, &c.zwlr_layer_shell_v1_interface, @min(version, 4)).?));
    } else if (std.mem.eql(u8, iface, std.mem.span(c.xdg_wm_base_interface.name))) {
        app.xdg_wm_base = @ptrCast(@alignCast(c.wl_registry_bind(registry, name, &c.xdg_wm_base_interface, @min(version, 6)).?));
        _ = c.xdg_wm_base_add_listener(app.xdg_wm_base, &wm_base_listener, app);
    }
}

fn registryGlobalRemove(data: ?*anyopaque, registry: ?*c.wl_registry, name: u32) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = name;
}

const wm_base_listener: c.xdg_wm_base_listener = .{ .ping = wmBasePing };

fn wmBasePing(data: ?*anyopaque, wm_base: ?*c.xdg_wm_base, serial: u32) callconv(.c) void {
    _ = data;
    c.xdg_wm_base_pong(wm_base, serial);
}

const seat_listener: c.wl_seat_listener = .{
    .capabilities = seatCapabilities,
    .name = seatName,
};

fn seatCapabilities(data: ?*anyopaque, seat: ?*c.wl_seat, capabilities: u32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    const has_keyboard = capabilities & c.WL_SEAT_CAPABILITY_KEYBOARD != 0;
    if (has_keyboard and app.keyboard == null) {
        app.keyboard = c.wl_seat_get_keyboard(seat);
        _ = c.wl_keyboard_add_listener(app.keyboard, &keyboard_listener, app);
    }
}

fn seatName(data: ?*anyopaque, seat: ?*c.wl_seat, name: [*c]const u8) callconv(.c) void {
    _ = data;
    _ = seat;
    _ = name;
}

const keyboard_listener: c.wl_keyboard_listener = .{
    .keymap = keyboardKeymap,
    .enter = keyboardEnter,
    .leave = keyboardLeave,
    .key = keyboardKey,
    .modifiers = keyboardModifiers,
    .repeat_info = keyboardRepeatInfo,
};

fn keyboardKeymap(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, format: u32, fd: i32, size: u32) callconv(.c) void {
    _ = keyboard;
    const app: *App = @ptrCast(@alignCast(data.?));
    defer _ = linux.close(fd);

    if (format != c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) return;

    const map = posix.mmap(null, size, .{ .READ = true }, .{ .TYPE = .PRIVATE }, fd, 0) catch return;
    defer posix.munmap(map);

    if (app.xkb_context == null) app.xkb_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS);
    const context = app.xkb_context orelse return;

    if (app.xkb_keymap) |km| c.xkb_keymap_unref(km);
    app.xkb_keymap = c.xkb_keymap_new_from_string(
        context,
        @ptrCast(map.ptr),
        c.XKB_KEYMAP_FORMAT_TEXT_V1,
        c.XKB_KEYMAP_COMPILE_NO_FLAGS,
    );

    if (app.xkb_state) |st| c.xkb_state_unref(st);
    app.xkb_state = if (app.xkb_keymap) |km| c.xkb_state_new(km) else null;
}

fn keyboardEnter(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, serial: u32, surface: ?*c.wl_surface, keys: ?*c.wl_array) callconv(.c) void {
    _ = data;
    _ = keyboard;
    _ = serial;
    _ = surface;
    _ = keys;
}

fn keyboardLeave(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, serial: u32, surface: ?*c.wl_surface) callconv(.c) void {
    _ = keyboard;
    _ = serial;
    _ = surface;
    const app: *App = @ptrCast(@alignCast(data.?));
    disarmRepeat(app);
}

fn keyboardKey(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, serial: u32, time: u32, key: u32, state: u32) callconv(.c) void {
    _ = keyboard;
    _ = serial;
    _ = time;
    const app: *App = @ptrCast(@alignCast(data.?));
    const pressed = state == c.WL_KEYBOARD_KEY_STATE_PRESSED;

    if (pressed) {
        processKeycode(app, key) catch {};
        if (app.repeat_rate > 0) armRepeat(app, key);
    } else if (app.repeat_keycode == key) {
        disarmRepeat(app);
    }
}

fn keyboardModifiers(
    data: ?*anyopaque,
    keyboard: ?*c.wl_keyboard,
    serial: u32,
    mods_depressed: u32,
    mods_latched: u32,
    mods_locked: u32,
    group: u32,
) callconv(.c) void {
    _ = keyboard;
    _ = serial;
    const app: *App = @ptrCast(@alignCast(data.?));
    if (app.xkb_state) |st| {
        _ = c.xkb_state_update_mask(st, mods_depressed, mods_latched, mods_locked, 0, 0, group);
    }
}

fn keyboardRepeatInfo(data: ?*anyopaque, keyboard: ?*c.wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
    _ = keyboard;
    const app: *App = @ptrCast(@alignCast(data.?));
    app.repeat_rate = rate;
    app.repeat_delay = delay;
}

const layer_surface_listener: c.zwlr_layer_surface_v1_listener = .{
    .configure = layerSurfaceConfigure,
    .closed = layerSurfaceClosed,
};

fn layerSurfaceConfigure(data: ?*anyopaque, layer_surface: ?*c.zwlr_layer_surface_v1, serial: u32, width: u32, height: u32) callconv(.c) void {
    _ = width;
    _ = height;
    const app: *App = @ptrCast(@alignCast(data.?));
    c.zwlr_layer_surface_v1_ack_configure(layer_surface, serial);
    app.configured = true;
}

fn layerSurfaceClosed(data: ?*anyopaque, layer_surface: ?*c.zwlr_layer_surface_v1) callconv(.c) void {
    _ = layer_surface;
    const app: *App = @ptrCast(@alignCast(data.?));
    app.running = false;
}

const xdg_surface_listener: c.xdg_surface_listener = .{ .configure = xdgSurfaceConfigure };

fn xdgSurfaceConfigure(data: ?*anyopaque, xdg_surface: ?*c.xdg_surface, serial: u32) callconv(.c) void {
    const app: *App = @ptrCast(@alignCast(data.?));
    c.xdg_surface_ack_configure(xdg_surface, serial);
    app.configured = true;
}

const xdg_toplevel_listener: c.xdg_toplevel_listener = .{
    .configure = xdgToplevelConfigure,
    .close = xdgToplevelClose,
};

fn xdgToplevelConfigure(data: ?*anyopaque, toplevel: ?*c.xdg_toplevel, width: i32, height: i32, states: ?*c.wl_array) callconv(.c) void {
    _ = data;
    _ = toplevel;
    _ = width;
    _ = height;
    _ = states;
}

fn xdgToplevelClose(data: ?*anyopaque, toplevel: ?*c.xdg_toplevel) callconv(.c) void {
    _ = toplevel;
    const app: *App = @ptrCast(@alignCast(data.?));
    app.running = false;
}

const buffer_listener: c.wl_buffer_listener = .{ .release = bufferRelease };

fn bufferRelease(data: ?*anyopaque, wl_buffer: ?*c.wl_buffer) callconv(.c) void {
    _ = wl_buffer;
    const buf: *Buffer = @ptrCast(@alignCast(data.?));
    buf.busy = false;
}

/// Runs the launcher. On accept, returns the chosen entry (still owned by
/// the caller-supplied `entries` slice); on cancel/close, returns `null`.
pub fn run(
    allocator: std.mem.Allocator,
    io: Io,
    theme: core.theme.Theme,
    entries: []const core.state.Entry,
) !?core.state.Entry {
    const display = c.wl_display_connect(null) orelse return error.NoWaylandDisplay;
    defer c.wl_display_disconnect(display);

    const registry = c.wl_display_get_registry(display) orelse return error.NoRegistry;

    var app: App = .{
        .allocator = allocator,
        .io = io,
        .display = display,
        .registry = registry,
        .theme = theme,
        .state = try core.state.State.init(allocator, entries),
    };
    defer app.state.deinit();
    // State's scroll/paging math and render()'s row count must agree on the
    // same page size, or the highlighted row and what's actually painted
    // can disagree once a config lets these diverge.
    app.state.visible_rows = app.theme.visible_rows;

    _ = c.wl_registry_add_listener(registry, &registry_listener, &app);
    if (c.wl_display_roundtrip(display) == -1) return error.RoundtripFailed;
    // Second roundtrip so seat capabilities (bound during the first) resolve too.
    if (c.wl_display_roundtrip(display) == -1) return error.RoundtripFailed;

    const compositor = app.compositor orelse return error.NoCompositor;
    const shm = app.shm orelse return error.NoShm;
    _ = shm;

    app.surface = c.wl_compositor_create_surface(compositor) orelse return error.NoSurface;

    const sz = core.render.size(&app.theme);
    app.width = @intFromFloat(sz.width);
    app.height = @intFromFloat(sz.height);

    if (app.layer_shell) |layer_shell| {
        const ls = c.zwlr_layer_shell_v1_get_layer_surface(
            layer_shell,
            app.surface,
            null,
            c.ZWLR_LAYER_SHELL_V1_LAYER_OVERLAY,
            "zofi",
        ) orelse return error.NoLayerSurface;
        app.layer_surface = ls;
        c.zwlr_layer_surface_v1_set_size(ls, @intCast(app.width), @intCast(app.height));
        c.zwlr_layer_surface_v1_set_anchor(ls, 0);
        c.zwlr_layer_surface_v1_set_keyboard_interactivity(ls, c.ZWLR_LAYER_SURFACE_V1_KEYBOARD_INTERACTIVITY_EXCLUSIVE);
        _ = c.zwlr_layer_surface_v1_add_listener(ls, &layer_surface_listener, &app);
        c.wl_surface_commit(app.surface);
    } else if (app.xdg_wm_base) |wm_base| {
        const xsurface = c.xdg_wm_base_get_xdg_surface(wm_base, app.surface) orelse return error.NoXdgSurface;
        app.xdg_surface = xsurface;
        _ = c.xdg_surface_add_listener(xsurface, &xdg_surface_listener, &app);

        const toplevel = c.xdg_surface_get_toplevel(xsurface) orelse return error.NoXdgToplevel;
        app.xdg_toplevel = toplevel;
        c.xdg_toplevel_set_title(toplevel, "zofi");
        c.xdg_toplevel_set_app_id(toplevel, "zofi");
        _ = c.xdg_toplevel_add_listener(toplevel, &xdg_toplevel_listener, &app);
        c.wl_surface_commit(app.surface);
    } else {
        return error.NoShellProtocol;
    }

    while (!app.configured and app.running) {
        if (c.wl_display_dispatch(display) == -1) return error.DispatchFailed;
    }
    if (!app.running) return null;

    try createBuffers(&app);
    defer if (app.pool_map.len > 0) posix.munmap(app.pool_map);

    app.timer_fd = @intCast(linux.timerfd_create(.MONOTONIC, .{}));
    defer _ = linux.close(app.timer_fd);

    try eventLoop(&app);

    return app.accepted;
}

fn createBuffers(app: *App) !void {
    const w: usize = @intCast(app.width);
    const h: usize = @intCast(app.height);
    const stride = w * 4;
    const single_size = stride * h;
    const pool_size = single_size * 2;

    const fd = try posix.memfd_create("zofi-shm", 0);
    defer _ = linux.close(fd);
    if (linux.ftruncate(@intCast(fd), @intCast(pool_size)) != 0) return error.TruncateFailed;

    const map = try posix.mmap(null, pool_size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, fd, 0);
    app.pool_map = map;

    const shm = app.shm orelse return error.NoShm;
    const pool = c.wl_shm_create_pool(shm, fd, @intCast(pool_size)) orelse return error.NoShmPool;
    defer c.wl_shm_pool_destroy(pool);

    const all_pixels = std.mem.bytesAsSlice(core_z2d.pixel.ARGB, map);
    const px_per_buf = single_size / 4;

    for (0..2) |i| {
        const offset = single_size * i;
        const wl_buffer = c.wl_shm_pool_create_buffer(
            pool,
            @intCast(offset),
            @intCast(app.width),
            @intCast(app.height),
            @intCast(stride),
            c.WL_SHM_FORMAT_ARGB8888,
        ) orelse return error.NoBuffer;

        app.buffers[i].wl_buffer = wl_buffer;
        app.buffers[i].pixels = all_pixels[px_per_buf * i .. px_per_buf * (i + 1)];
        _ = c.wl_buffer_add_listener(wl_buffer, &buffer_listener, &app.buffers[i]);
    }
}

/// Returns `true` if a frame was actually presented. Both buffers can be
/// busy at once under fast repeated input; the caller must keep
/// `need_redraw` set (not drop it) when this returns `false`, or the
/// display can go stale relative to `app.state`.
fn presentFrame(app: *App) !bool {
    const buf = &app.buffers[app.cur_buffer];
    if (buf.busy) return false; // still owned by the compositor; retry next loop

    var surface = core_z2d.Surface.initBuffer(.image_surface_argb, null, buf.pixels, app.width, app.height);
    try core.render.render(app.io, app.allocator, &surface, &app.theme, &app.state, 1.0);

    c.wl_surface_attach(app.surface, buf.wl_buffer, 0, 0);
    c.wl_surface_damage_buffer(app.surface, 0, 0, app.width, app.height);
    c.wl_surface_commit(app.surface);
    buf.busy = true;
    app.cur_buffer = 1 - app.cur_buffer;
    return true;
}

fn eventLoop(app: *App) !void {
    while (app.running) {
        if (app.need_redraw) {
            app.need_redraw = !(try presentFrame(app));
        }

        while (c.wl_display_prepare_read(app.display) != 0) {
            _ = c.wl_display_dispatch_pending(app.display);
        }
        _ = c.wl_display_flush(app.display);

        var fds = [_]posix.pollfd{
            .{ .fd = c.wl_display_get_fd(app.display), .events = posix.POLL.IN, .revents = 0 },
            .{ .fd = app.timer_fd, .events = posix.POLL.IN, .revents = 0 },
        };
        _ = posix.poll(&fds, -1) catch {
            c.wl_display_cancel_read(app.display);
            return;
        };

        if (fds[0].revents & posix.POLL.IN != 0) {
            _ = c.wl_display_read_events(app.display);
        } else {
            c.wl_display_cancel_read(app.display);
        }
        _ = c.wl_display_dispatch_pending(app.display);

        if (fds[1].revents & posix.POLL.IN != 0) {
            var expirations: u64 = 0;
            _ = posix.read(app.timer_fd, std.mem.asBytes(&expirations)) catch {};
            processKeycode(app, app.repeat_keycode) catch {};
        }
    }
}

fn armRepeat(app: *App, keycode: u32) void {
    app.repeat_keycode = keycode;
    const rate: i64 = @max(1, app.repeat_rate);
    const interval_ns: i64 = @divTrunc(1_000_000_000, rate);
    const delay_ns: i64 = @as(i64, app.repeat_delay) * 1_000_000;

    const spec: linux.itimerspec = .{
        .it_interval = .{ .sec = @divTrunc(interval_ns, 1_000_000_000), .nsec = @mod(interval_ns, 1_000_000_000) },
        .it_value = .{ .sec = @divTrunc(delay_ns, 1_000_000_000), .nsec = @mod(delay_ns, 1_000_000_000) },
    };
    _ = linux.timerfd_settime(app.timer_fd, .{}, &spec, null);
}

fn disarmRepeat(app: *App) void {
    const zero: linux.itimerspec = .{ .it_interval = .{ .sec = 0, .nsec = 0 }, .it_value = .{ .sec = 0, .nsec = 0 } };
    _ = linux.timerfd_settime(app.timer_fd, .{}, &zero, null);
}

fn processKeycode(app: *App, wayland_keycode: u32) !void {
    const st = app.xkb_state orelse return;
    const xkb_keycode = wayland_keycode + 8;
    const sym = c.xkb_state_key_get_one_sym(st, xkb_keycode);

    const ctrl_active = c.xkb_state_mod_name_is_active(st, c.XKB_MOD_NAME_CTRL, c.XKB_STATE_MODS_EFFECTIVE) == 1;

    const event: ?core.state.KeyEvent = switch (sym) {
        c.XKB_KEY_Escape => .{ .named = .escape },
        c.XKB_KEY_Return, c.XKB_KEY_KP_Enter => .{ .named = .enter },
        c.XKB_KEY_BackSpace => .{ .named = .backspace },
        c.XKB_KEY_Up => .{ .named = .up },
        c.XKB_KEY_Down => .{ .named = .down },
        c.XKB_KEY_Prior => .{ .named = .page_up },
        c.XKB_KEY_Next => .{ .named = .page_down },
        c.XKB_KEY_Home => .{ .named = .home },
        c.XKB_KEY_End => .{ .named = .end },
        c.XKB_KEY_Tab => .{ .named = .tab },
        c.XKB_KEY_w, c.XKB_KEY_W => if (ctrl_active) core.state.KeyEvent{ .ctrl = .w } else null,
        c.XKB_KEY_u, c.XKB_KEY_U => if (ctrl_active) core.state.KeyEvent{ .ctrl = .u } else null,
        c.XKB_KEY_n, c.XKB_KEY_N => if (ctrl_active) core.state.KeyEvent{ .ctrl = .n } else null,
        c.XKB_KEY_p, c.XKB_KEY_P => if (ctrl_active) core.state.KeyEvent{ .ctrl = .p } else null,
        else => null,
    };

    const resolved = event orelse blk: {
        if (ctrl_active) break :blk null;
        var buf: [8]u8 = undefined;
        const n = c.xkb_state_key_get_utf8(st, xkb_keycode, &buf, buf.len);
        if (n <= 0) break :blk null;
        break :blk core.state.KeyEvent{ .text = try app.allocator.dupe(u8, buf[0..@intCast(n)]) };
    } orelse return;

    const action = try app.state.handleKey(resolved);
    switch (action) {
        .nothing => {},
        .redraw => app.need_redraw = true,
        .accept => {
            app.accepted = app.state.selectedEntry();
            app.running = false;
        },
        .cancel => app.running = false,
    }
}
