const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_native_backend = b.option(bool, "native-backend", "Use Zig's native x86 backend for compilation") orelse false;

    const spoon = b.dependency("shovel", .{
        .target = target,
        .optimize = optimize,
    }).module("shovel");

    const wcwidth = b.dependency("wcwidth", .{
        .target = target,
        .optimize = optimize,
    }).module("wcwidth");

    const ziglua = b.dependency("ziglua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua54,
    }).module("ziglua");

    // Main executable
    {
        const exe = b.addExecutable(.{
            .name = "cellulator",
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .use_llvm = !use_native_backend,
            .use_lld = !use_native_backend,
        });

        exe.root_module.addImport("ziglua", ziglua);
        exe.root_module.addImport("spoon", spoon);
        exe.root_module.addImport("wcwidth", wcwidth);

        b.installArtifact(exe);

        const run_cmd = b.addRunArtifact(exe);

        run_cmd.step.dependOn(b.getInstallStep());

        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        const run_step = b.step("run", "Run the program");
        run_step.dependOn(&run_cmd.step);
    }

    // Tests
    {
        const test_filter = b.option([]const u8, "test-filter", "Skip tests that do not match filter");

        const tests = b.addTest(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .filter = test_filter,
            .use_llvm = !use_native_backend,
            .use_lld = !use_native_backend,
        });

        const fast_tests = b.option(bool, "fast-tests", "Skip slow tests") orelse false;
        const opts = b.addOptions();
        opts.addOption([]const []const u8, "test_files", &.{
            "test/general.zc",
            "test/undo-redo.zc",
            "test/string.zc",
            "test/fill.zc",
            // "test/binary-serialize.zc",
            "test/save-load.zc",
        });
        opts.addOption(bool, "fast_tests", fast_tests);

        const temp_dir = b.makeTempPath();
        opts.addOption([]const u8, "temp_dir", temp_dir);

        tests.root_module.addOptions("build", opts);
        tests.root_module.addImport("ziglua", ziglua);
        tests.root_module.addImport("spoon", spoon);
        tests.root_module.addImport("wcwidth", wcwidth);

        const run_tests = b.addRunArtifact(tests);

        const cleanup = b.addRemoveDirTree(.{ .cwd_relative = temp_dir });
        cleanup.step.dependOn(&run_tests.step);

        const test_step = b.step("test", "Run all unit tests");
        test_step.dependOn(&cleanup.step);

        const test_exe_step = b.step("test-exe", "Install test executable");
        const install_step = b.addInstallArtifact(tests, .{});
        test_exe_step.dependOn(&install_step.step);

        // Tests with coverage report
        const run_kcov = b.addSystemCommand(&.{"kcov"});
        const kcov_out = run_kcov.addOutputDirectoryArg("kcov-out");
        run_kcov.addArg("--include-path=src");
        run_kcov.addArtifactArg(tests);

        const install_kcov_out = b.addInstallDirectory(.{
            .source_dir = kcov_out,
            .install_dir = .{ .custom = "coverage" },
            .install_subdir = "",
        });

        const kcov_cleanup = b.addRemoveDirTree(.{ .cwd_relative = temp_dir });
        kcov_cleanup.step.dependOn(&run_kcov.step);

        const coverage_step = b.step("coverage", "Run tests and generate coverage report.");
        coverage_step.dependOn(&kcov_cleanup.step);
        coverage_step.dependOn(&install_kcov_out.step);
    }
}
