const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const z2d = b.dependency("z2d", .{
        .target = target,
        .optimize = optimize,
    });

    const core_mod = b.addModule("core", .{
        .root_source_file = b.path("src/core/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "z2d", .module = z2d.module("z2d") },
        },
    });

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

    addWaylandBackend(b, exe.root_module, target, optimize);

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

    mod.addCSourceFile(.{ .file = xdg_shell.code, .flags = &.{} });
    mod.addCSourceFile(.{ .file = layer_shell.code, .flags = &.{} });
    mod.addIncludePath(xdg_shell.header.dirname());
    mod.addIncludePath(layer_shell.header.dirname());

    _ = target;
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
