const std = @import("std");

fn getVersion(b: *std.Build) []const u8 {
    const src_dir = std.fs.path.dirname(@src().file) orelse ".";
    var exit_code: u8 = 0;
    const git_hash = b.runAllowFail(&[_][]const u8{
        "git", "-C", src_dir, "rev-parse", "HEAD",
    }, &exit_code, .Inherit) catch return "unknown";
    return std.mem.trim(u8, git_hash, &std.ascii.whitespace);
}

/// Creates the promz module with injected dependencies.
/// Use this when incorporating promz as a dependency to share modules with parent.
pub fn createModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    root_source_file: std.Build.LazyPath,
) *std.Build.Module {
    const mod = b.addModule("promz", .{
        .root_source_file = root_source_file,
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", getVersion(b));

    // Debug metrics: enabled by default only in Debug mode
    const enable_debug_metrics = b.option(
        bool,
        "enable_debug_metrics",
        "Enable debug metrics (default: true in Debug mode)",
    ) orelse (optimize == .Debug);
    options.addOption(bool, "enable_debug_metrics", enable_debug_metrics);

    mod.addOptions("build_options", options);

    return mod;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("promz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    const options = b.addOptions();
    options.addOption([]const u8, "version", getVersion(b));

    // Debug metrics: enabled by default only in Debug mode
    const enable_debug_metrics = b.option(
        bool,
        "enable_debug_metrics",
        "Enable debug metrics (default: true in Debug mode)",
    ) orelse (optimize == .Debug);
    options.addOption(bool, "enable_debug_metrics", enable_debug_metrics);

    mod.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "promz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "promz", .module = mod },
            },
        }),
    });
    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const mod_tests = b.addTest(.{ .root_module = mod });
    const run_mod_tests = b.addRunArtifact(mod_tests);

    const exe_tests = b.addTest(.{ .root_module = exe.root_module });
    const run_exe_tests = b.addRunArtifact(exe_tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // Examples
    inline for (.{
        .{ "complete", "examples/complete.zig", "Run complete example" },
        .{ "http_server", "examples/http_server.zig", "Run HTTP server example" },
        .{ "threadsafe", "examples/threadsafe.zig", "Run thread-safe metrics example" },
        .{ "benchmark", "examples/benchmark.zig", "Run performance benchmarks" },
    }) |example| {
        const example_exe = b.addExecutable(.{
            .name = example[0],
            .root_module = b.createModule(.{
                .root_source_file = b.path(example[1]),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "promz", .module = mod }},
            }),
        });
        b.installArtifact(example_exe);

        const run_example_step = b.step("run-" ++ example[0], example[2]);
        const run_example_cmd = b.addRunArtifact(example_exe);
        run_example_cmd.step.dependOn(b.getInstallStep());
        run_example_step.dependOn(&run_example_cmd.step);
    }
}
