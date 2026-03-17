const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const logfile = b.option([]const u8, "logging", "File to log to");
    const log_level = b.option(std.log.Level, "log-level", "Logging level") orelse .debug;
    const use_llvm = b.option(bool, "llvm", "Use llvm for codegen");

    const opts = b.addOptions();
    opts.addOption(?[]const u8, "logfile_path", logfile);
    opts.addOption(std.log.Level, "log_level", log_level);

    const main_mod = configureMainModule(b, target, optimize);

    const exe = configureExe(b, main_mod, use_llvm);
    const tests = configureTests(b, main_mod, opts);
    configureBenchmarks(b, main_mod);

    const check_step = b.step("check", "");
    check_step.dependOn(&exe.step);
    check_step.dependOn(&tests.step);

    main_mod.addOptions("build", opts);

    configureFuzzing(b, target, optimize);
}

fn configureMainModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const shovel = b.dependency("shovel", .{
        .target = target,
        .optimize = optimize,
    }).module("shovel");

    const zlua = b.dependency("zlua", .{
        .target = target,
        .optimize = optimize,
        .lang = .lua54,
    }).module("zlua");

    const zg = b.dependency("zg", .{
        .target = target,
        .optimize = optimize,
    }).module("zg");

    const main_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zlua", .module = zlua },
            .{ .name = "shovel", .module = shovel },
            .{ .name = "zg", .module = zg },
        },
    });

    return main_mod;
}

// zig-afl-kit doesn't work on my machine due to symbol errors and I am way too lazy to fix it.
fn configureFuzzing(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const fuzz = b.step("fuzz", "");

    const afl_obj = b.addObject(.{
        .name = "fuzz_obj",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/Sheet.zig"),
            .target = target,
            .optimize = optimize,
            .fuzz = true,
            .stack_check = false,
        }),
        .use_llvm = true,
        .use_lld = true,
    });

    const run_afl_cc = b.addSystemCommand(&.{ "afl-cc", "-O3", "-o" });
    const afl_fuzz = run_afl_cc.addOutputFileArg(afl_obj.name);
    run_afl_cc.addFileArg(b.path("afl.c"));
    run_afl_cc.addFileArg(afl_obj.getEmittedLlvmBc());
    fuzz.dependOn(&b.addInstallBinFile(afl_fuzz, "myfuzz-afl").step);
}

fn configureExe(
    b: *std.Build,
    main_mod: *std.Build.Module,
    use_llvm: ?bool,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "cellulator",
        .root_module = main_mod,
        .use_llvm = use_llvm,
    });

    b.installArtifact(exe);
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the program");
    run_step.dependOn(&run_cmd.step);
    return exe;
}

fn configureTests(
    b: *std.Build,
    main_mod: *std.Build.Module,
    opts: *std.Build.Step.Options,
) *std.Build.Step.Compile {
    const test_filter = b.option([]const u8, "test-filter", "Skip tests that do not match filter");
    const use_kcov = b.option(bool, "coverage", "Generate code coverage reports with kcov") orelse false;

    const tests = b.addTest(.{
        .root_module = main_mod,
        .filters = &.{test_filter orelse ""},
    });

    // Cache directory for temporarily storing files created by serialization tests
    const write_files = b.addMutateFiles(b.path(".zig-cache/tmp/test-serialize-output-files"));
    const test_data_path = write_files.getDirectory();

    opts.addOptionPath("temp_dir", test_data_path);

    const test_exe_step = b.step("test-exe", "Install test executable");
    const install_step = b.addInstallArtifact(tests, .{});
    test_exe_step.dependOn(&install_step.step);

    const test_step = b.step("test", "Run all unit tests");

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
        test_step.dependOn(&install_kcov_out.step);
    } else {
        const run_tests = b.addRunArtifact(tests);
        test_step.dependOn(&run_tests.step);
    }

    return tests;
}

fn configureBenchmarks(
    b: *std.Build,
    zc_mod: *std.Build.Module,
) void {
    const bench_step = b.step("bench", "Build benchmark executables");

    const benchmarks = [_]struct { []const u8, []const u8 }{
        .{ "fill", "bench/fill.zig" },
        .{ "tui", "bench/tui.zig" },
    };

    for (benchmarks) |benchmark| {
        const name, const path = benchmark;
        const exe = b.addExecutable(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path(path),
                .target = zc_mod.resolved_target,
                .optimize = zc_mod.optimize.?,
            }),
        });
        var iter = zc_mod.import_table.iterator();
        while (iter.next()) |entry| {
            exe.root_module.addImport(entry.key_ptr.*, entry.value_ptr.*);
        }
        exe.root_module.addImport("zc", zc_mod);

        const install = b.addInstallArtifact(exe, .{
            .dest_dir = .{ .override = .{ .custom = "bench" } },
        });
        bench_step.dependOn(&install.step);
    }
}
