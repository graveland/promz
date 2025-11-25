const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("promz", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

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
