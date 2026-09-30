const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Debug mode crashes the Zig 0.16.0 compiler itself when zigimg (PNG
    // icon decoding) is in the build -- confirmed with a minimal
    // reproduction outside this project entirely, so it's an upstream
    // compiler/library interaction, not fixable here. ReleaseSafe doesn't
    // trip it, and it's also just the right default for a launcher whose
    // main requirement is fast startup. Override with -Doptimize=Debug if
    // you ever need to and zigimg isn't the thing you're debugging.
    // (standardOptimizeOption's `preferred_optimize_mode` doesn't actually
    // change the bare `zig build` default -- it only changes what
    // `--release` resolves to -- so it's not used here.)
    const optimize = b.option(
        std.builtin.OptimizeMode,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .ReleaseSafe;

    const z2d = b.dependency("z2d", .{
        .target = target,
        .optimize = optimize,
    });
    const zigimg = b.dependency("zigimg", .{
        .target = target,
        .optimize = optimize,
    });

    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        // dashboard.zig's calendar math goes through libc's time.h
        // (localtime_r/strftime/mktime) rather than reimplementing a
        // timezone-aware calendar from scratch.
        .link_libc = true,
        .imports = &.{
            .{ .name = "z2d", .module = z2d.module("z2d") },
            .{ .name = "zigimg", .module = zigimg.module("zigimg") },
        },
    });
    // clipboard.zig's SQLite storage, shared by the daemon and the
    // clipboard tab's entry source, lives in core -- needs its own
    // link/include setup since each Zig module resolves @cImport
    // separately (addWaylandBackend below only covers the exe module).
    // On macOS, sqlite3's header and library come with the SDK (and
    // pkg-config usually isn't installed at all).
    if (target.result.os.tag != .macos) addPkgConfigIncludes(b, core_mod, &.{"sqlite3"});
    core_mod.linkSystemLibrary("sqlite3", .{});

    const exe = b.addExecutable(.{
        .name = "zofi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "z2d", .module = z2d.module("z2d") },
                .{ .name = "core", .module = core_mod },
            },
        }),
    });

    // Must agree with the backend main.zig picks for the same target.
    if (target.result.os.tag == .macos) {
        addMacosBackend(b, exe.root_module);
    } else {
        addWaylandBackend(b, exe.root_module, target, optimize);
    }

    b.installArtifact(exe);

    const snapshot_exe = b.addExecutable(.{
        .name = "zofi-snapshot",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/snapshot.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "z2d", .module = z2d.module("z2d") },
                .{ .name = "core", .module = core_mod },
            },
        }),
    });
    b.installArtifact(snapshot_exe);

    const snapshot_step = b.step("snapshot", "Render mock state to PNGs at scale 1x/2x");
    const snapshot_cmd = b.addRunArtifact(snapshot_exe);
    snapshot_cmd.step.dependOn(b.getInstallStep());
    snapshot_step.dependOn(&snapshot_cmd.step);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const core_tests = b.addTest(.{
        .root_module = core_mod,
    });
    const run_core_tests = b.addRunArtifact(core_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_exe_tests.step);
    test_step.dependOn(&run_core_tests.step);
}

/// Links libwayland-client + libxkbcommon (plan's stated fallback for the
/// Wayland wire protocol, rather than a pure-Zig client), and generates C
/// bindings for the xdg-shell and wlr-layer-shell extension protocols via
/// wayland-scanner. Requires pkg-config, wayland-scanner, wayland-protocols
/// and wlr-protocols to be available (see shell.nix).
fn addWaylandBackend(
    b: *std.Build,
    mod: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    _ = optimize;

    addPkgConfigIncludes(b, mod, &.{ "wayland-client", "xkbcommon" });
    mod.linkSystemLibrary("wayland-client", .{});
    mod.linkSystemLibrary("xkbcommon", .{});

    const scanner = b.findProgram(&.{"wayland-scanner"}, &.{}) catch
        @panic("wayland-scanner not found on PATH; run inside `nix-shell` (see shell.nix)");

    const xdg_shell = scanProtocol(b, scanner, b.path("protocols/xdg-shell.xml"), "xdg-shell");
    const layer_shell = scanProtocol(b, scanner, b.path("protocols/wlr-layer-shell-unstable-v1.xml"), "wlr-layer-shell-unstable-v1");
    const foreign_toplevel = scanProtocol(b, scanner, b.path("protocols/wlr-foreign-toplevel-management-unstable-v1.xml"), "wlr-foreign-toplevel-management-unstable-v1");
    const data_control = scanProtocol(b, scanner, b.path("protocols/wlr-data-control-unstable-v1.xml"), "wlr-data-control-unstable-v1");

    mod.addCSourceFile(.{ .file = xdg_shell.code, .flags = &.{} });
    mod.addCSourceFile(.{ .file = layer_shell.code, .flags = &.{} });
    mod.addCSourceFile(.{ .file = foreign_toplevel.code, .flags = &.{} });
    mod.addCSourceFile(.{ .file = data_control.code, .flags = &.{} });
    mod.addIncludePath(xdg_shell.header.dirname());
    mod.addIncludePath(layer_shell.header.dirname());
    mod.addIncludePath(foreign_toplevel.header.dirname());
    mod.addIncludePath(data_control.header.dirname());

    _ = target;
}

/// Compiles the AppKit glue (Objective-C, ARC) and links the system
/// frameworks it uses. Nothing to install beyond Zig itself and Xcode or
/// the Command Line Tools (`xcode-select --install`), which provide the
/// macOS SDK that Zig picks up automatically for native builds.
fn addMacosBackend(b: *std.Build, mod: *std.Build.Module) void {
    mod.link_libc = true;
    mod.addIncludePath(b.path("src/platform/macos"));
    mod.addCSourceFile(.{
        .file = b.path("src/platform/macos/window.m"),
        .flags = &.{ "-fobjc-arc", "-Wall", "-Wextra" },
    });
    mod.linkFramework("AppKit", .{});
    mod.linkFramework("QuartzCore", .{});
    mod.linkFramework("CoreGraphics", .{});
    mod.linkFramework("Foundation", .{});
    mod.linkFramework("CoreFoundation", .{});
    mod.linkSystemLibrary("objc", .{});
}

const ScannedProtocol = struct {
    header: std.Build.LazyPath,
    code: std.Build.LazyPath,
};

fn scanProtocol(b: *std.Build, scanner: []const u8, xml: std.Build.LazyPath, comptime basename: []const u8) ScannedProtocol {
    const header_run = b.addSystemCommand(&.{ scanner, "client-header" });
    header_run.addFileArg(xml);
    const header = header_run.addOutputFileArg(basename ++ "-client-protocol.h");

    const code_run = b.addSystemCommand(&.{ scanner, "private-code" });
    code_run.addFileArg(xml);
    const code = code_run.addOutputFileArg(basename ++ "-protocol.c");

    return .{ .header = header, .code = code };
}

/// Runs `pkg-config --cflags <libs>` and adds every `-I` path to `mod`.
/// Linking itself goes through `linkSystemLibrary`'s built-in pkg-config
/// support; this only covers the include paths that `@cImport` needs.
fn addPkgConfigIncludes(b: *std.Build, mod: *std.Build.Module, libs: []const []const u8) void {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(b.allocator, "pkg-config") catch @panic("OOM");
    argv.append(b.allocator, "--cflags") catch @panic("OOM");
    argv.appendSlice(b.allocator, libs) catch @panic("OOM");

    const output = b.run(argv.items);
    var it = std.mem.tokenizeAny(u8, output, " \n\t");
    while (it.next()) |tok| {
        if (std.mem.startsWith(u8, tok, "-I")) {
            mod.addIncludePath(.{ .cwd_relative = tok[2..] });
        }
    }
}
