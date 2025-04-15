const std = @import("std");

pub fn build(b: *std.Build) void {
    const use_llvm = !(b.option(bool, "no-llvm", "Use native codegen backends") orelse false);
    const logfile = b.option([]const u8, "logging", "File to log to");
    const log_level = b.option(std.log.Level, "log-level", "Logging level") orelse .debug;

    const opts = b.addOptions();
    opts.addOption(?[]const u8, "logfile_path", logfile);
    opts.addOption(std.log.Level, "log_level", log_level);

    const main_mod = configureMainModule(b);

    configureExe(b, main_mod, use_llvm);
    configureTests(b, main_mod, use_llvm, opts);
    configureBenchmarks(b, main_mod);

    main_mod.addOptions("build", opts);
}

fn configureMainModule(b: *std.Build) *std.Build.Module {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const shovel = b.dependency("shovel", .{
        .target = target,
        .optimize = optimize,
    }).module("shovel");

    const wcwidth = b.dependency("wcwidth", .{
        .target = target,
        .optimize = optimize,
    }).module("wcwidth");

    const zlua = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua54,
    }).module("zlua");

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    main_mod.addImport("zlua", zlua);
    main_mod.addImport("shovel", shovel);
    main_mod.addImport("wcwidth", wcwidth);

    return main_mod;
}

fn configureExe(
    b: *std.Build,
    main_mod: *std.Build.Module,
    use_llvm: bool,
) void {
    const exe = b.addExecutable(.{
        .name = "cellulator",
        .root_module = main_mod,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    const check_step = b.step("check", "");
    check_step.dependOn(&exe.step);

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the program");
    run_step.dependOn(&run_cmd.step);
}

fn configureTests(
    b: *std.Build,
    main_mod: *std.Build.Module,
    use_llvm: bool,
    opts: *std.Build.Step.Options,
) void {
    const fast_tests = b.option(bool, "fast-tests", "Skip slow tests") orelse false;
    const test_filter = b.option([]const u8, "test-filter", "Skip tests that do not match filter");
    const use_kcov = b.option(bool, "coverage", "Generate code coverage reports with kcov") orelse false;

    const tests = b.addTest(.{
        .root_module = main_mod,
        .filter = test_filter,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    opts.addOption([]const []const u8, "test_files", &.{
        "test/general.zc",
        "test/undo-redo.zc",
        "test/string.zc",
        "test/fill.zc",
        "test/binary-serialize.zc",
        "test/save-load.zc",
        "test/delete-cols.zc",
        "test/delete-rows.zc",
    });
    opts.addOption(bool, "fast_tests", fast_tests);

    // Create cache directory for temporarily storing files created by serialization tests
    const test_data_subpath = "tmp" ++ std.fs.path.sep_str ++ "test-data";
    b.cache_root.handle.makePath(test_data_subpath) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => |e| {
            std.debug.print("unable to make tmp path '{s}': {s}\n", .{
                test_data_subpath, @errorName(e),
            });
        },
    };
    const test_data_path = b.cache_root.join(b.allocator, &.{test_data_subpath}) catch @panic("OOM");

    opts.addOption([]const u8, "temp_dir", test_data_path);

    const test_exe_step = b.step("test-exe", "Install test executable");
    const install_step = b.addInstallArtifact(tests, .{});
    test_exe_step.dependOn(&install_step.step);

    const test_step = b.step("test", "Run all unit tests");

    const cleanup = b.addRemoveDirTree(.{ .cwd_relative = test_data_path });
    test_step.dependOn(&cleanup.step);

    if (use_kcov) {
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
        install_kcov_out.step.dependOn(&run_kcov.step);
        cleanup.step.dependOn(&install_kcov_out.step);
    } else {
        const run_tests = b.addRunArtifact(tests);
        cleanup.step.dependOn(&run_tests.step);
    }
}

fn configureBenchmarks(
    b: *std.Build,
    zc_mod: *std.Build.Module,
) void {
    const fill_exe = b.addExecutable(.{
        .root_source_file = b.path("bench/bench-fill.zig"),
        .name = "fill",
        .target = zc_mod.resolved_target,
        .optimize = zc_mod.optimize.?,
    });

    fill_exe.root_module.addImport("zc", zc_mod);

    const install_fill = b.addInstallArtifact(fill_exe, .{
        .dest_dir = .{ .override = .{ .custom = "bench" } },
    });

    const bench_step = b.step("bench", "Build benchmark executables");
    bench_step.dependOn(&install_fill.step);
}
