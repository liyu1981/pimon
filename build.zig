const std = @import("std");

const Gui = enum { sdl, fb };
const SdlMode = enum { zig, system };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const gui = b.option(Gui, "gui", "Display backend: sdl (KMSDRM/GLES2, default) or fb (software /dev/fb0)") orelse .sdl;
    const sdl_mode = b.option(SdlMode, "sdl2", "SDL2 for the sdl backend: zig (build from vendored source, default) or system (link the system libSDL2)") orelse .zig;
    const x11 = b.option(bool, "x11", "when building SDL2 from source, also enable the X11 video driver (desktop testing)") orelse false;

    var backend_module: ?*std.Build.Module = null;

    // The default build uses whatever target `-Dtarget` selects (so on the Pi
    // it is armv7), and installs under a backend-specific name so the SDL2 and
    // software versions can coexist.
    const exe = switch (gui) {
        .sdl => buildSdl(b, target, optimize, sdl_mode, x11),
        .fb => blk: {
            const result = buildFb(b, target, optimize);
            backend_module = result.backend;
            break :blk result.exe;
        },
    };
    const suffix = if (gui == .sdl) "sdl" else "fb";
    b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{ .dest_sub_path = b.fmt("pimon-{s}", .{suffix}) }).step);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();
    const run_step = b.step("run", "Run pimon");
    run_step.dependOn(&run_cmd.step);

    if (backend_module) |mod| {
        const unit_tests = b.addTest(.{ .root_module = mod });
        const run_unit_tests = b.addRunArtifact(unit_tests);
        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_unit_tests.step);
    }

    // --- Raspberry Pi 2 (ARMv7) targets -----------------------------------
    //
    // `pi2` builds *both* variants in one go:
    //   * pimon-pi2-sdl : SDL2 + KMSDRM/GLES2, dynamically linked against the
    //                     system SDL2 (build this on the Pi)
    //   * pimon-pi2-fb  : software rasterizer, fully static (musl)
    const pi2_gnu = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .linux,
        .abi = .gnueabihf,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a7 },
    });
    const pi2_musl = b.resolveTargetQuery(.{
        .cpu_arch = .arm,
        .os_tag = .linux,
        .abi = .musleabihf,
        .cpu_model = .{ .explicit = &std.Target.arm.cpu.cortex_a7 },
    });

    const sdl_step = b.step("pi2-sdl", "Pi 2 (ARMv7) SDL2 + KMSDRM/GLES2 build");
    const sdl_exe = buildSdl(b, pi2_gnu, .ReleaseFast, sdl_mode, x11);
    sdl_step.dependOn(&b.addInstallArtifact(sdl_exe, .{ .dest_sub_path = "pimon-pi2-sdl" }).step);

    const fb_step = b.step("pi2-fb", "Pi 2 (ARMv7) software framebuffer build");
    const fb_exe = buildFb(b, pi2_musl, .ReleaseFast).exe;
    fb_step.dependOn(&b.addInstallArtifact(fb_exe, .{ .dest_sub_path = "pimon-pi2-fb" }).step);

    const pi2_step = b.step("pi2", "Pi 2 (ARMv7): build both the SDL2 and software-framebuffer binaries");
    pi2_step.dependOn(sdl_step);
    pi2_step.dependOn(fb_step);
}

/// DVUI's SDL2 backend + our dashboard.
///
/// By default this builds SDL2 from the vendored source in `vendor/sdl2` with
/// the KMSDRM video driver and OpenGL ES2 renderer enabled, so it needs no
/// system SDL2 and cross-compiles cleanly.  Pass `-Dsdl2=system` to link the
/// host's libSDL2 instead.
fn buildSdl(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, sdl_mode: SdlMode, x11: bool) *std.Build.Step.Compile {
    // Ask DVUI for the plain `dvui` module (custom backend) plus its SDL2
    // backend source; we wire the backend module up to our own SDL2 below.
    const dvui_dep = dvui(b, target, optimize, .custom);
    const dvui_mod = dvui_dep.module("dvui");

    const sdl_mod = b.createModule(.{
        .root_source_file = dvui_dep.path("src/backends/sdl.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // dvui's sdl.zig needs the translated SDL2 headers and a version marker.
    const sdl2_c = b.addTranslateC(.{
        .root_source_file = dvui_dep.path("src/backends/sdl2-c.h"),
        .target = target,
        .optimize = optimize,
    });

    const sdl_options = b.addOptions();

    if (sdl_mode == .zig) {
        // Build SDL2 from our vendored source (KMSDRM + GLES2, X11/pulse off).
        const sdl2_dep = b.dependency("sdl2", .{ .target = target, .optimize = optimize, .video_driver_x11 = x11 });
        const sdl2_lib = sdl2_dep.artifact("SDL2");
        const sdl2_inc = sdl2_lib.getEmittedIncludeTree();

        sdl2_c.addIncludePath(sdl2_inc);
        sdl_mod.addIncludePath(sdl2_inc);
        sdl_mod.linkLibrary(sdl2_lib);
        sdl_options.addOption(std.SemanticVersion, "version", .{ .major = 2, .minor = 32, .patch = 10 });
    } else {
        _ = b.systemIntegrationOption("sdl2", .{ .default = true });
        sdl_mod.linkSystemLibrary("SDL2", .{});
        sdl_options.addOption(std.SemanticVersion, "version", .{ .major = 2, .minor = 0, .patch = 0 });
    }

    sdl_mod.addImport("sdl2-c", sdl2_c.createModule());
    sdl_mod.addImport("sdl_options", sdl_options.createModule());
    sdl_mod.addImport("dvui", dvui_mod);
    // dvui's `dvui` module imports "backend"; point it at our SDL2 backend.
    dvui_mod.addImport("backend", sdl_mod);

    const dashboard_mod = b.createModule(.{
        .root_source_file = b.path("src/dashboard.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "dvui", .module = dvui_mod }},
    });

    return b.addExecutable(.{
        .name = "pimon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "dvui", .module = dvui_mod },
                .{ .name = "dashboard", .module = dashboard_mod },
                .{ .name = "sdl-backend", .module = sdl_mod },
            },
        }),
    });
}

const Fb = struct { exe: *std.Build.Step.Compile, backend: *std.Build.Module };

fn buildFb(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) Fb {
    const dvui_dep = dvui(b, target, optimize, .custom);
    const dvui_mod = dvui_dep.module("dvui");

    const backend_mod = b.createModule(.{
        .root_source_file = b.path("src/backend.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    backend_mod.addImport("dvui", dvui_mod);
    dvui_mod.addImport("backend", backend_mod);

    const dashboard_mod = b.createModule(.{
        .root_source_file = b.path("src/dashboard.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "dvui", .module = dvui_mod }},
    });

    const exe = b.addExecutable(.{
        .name = "pimon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_fb.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "dvui", .module = dvui_mod },
                .{ .name = "dashboard", .module = dashboard_mod },
                .{ .name = "backend", .module = backend_mod },
            },
        }),
    });

    return .{ .exe = exe, .backend = backend_mod };
}

fn dvui(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, backend: anytype) *std.Build.Dependency {
    return b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = backend,
        .libc = true,
        .freetype = false,
        .@"stb-image" = true,
        .@"tree-sitter" = false,
        .@"tiny-file-dialogs" = false,
        .tvg = false,
    });
}
