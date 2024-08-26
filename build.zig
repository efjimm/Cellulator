const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_native_backend = b.option(bool, "native-backend", "Use Zig's native x86 backend for compilation") orelse false;

    const exe = b.addExecutable(.{
        .name = "cellulator",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .use_llvm = !use_native_backend,
        .use_lld = !use_native_backend,
    });

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

    const filter = b.option([]const u8, "test-filter", "Skip tests that do not match filter");

    const tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .filter = filter,
        .use_llvm = !use_native_backend,
        .use_lld = !use_native_backend,
    });

    const fast_tests = b.option(bool, "fast-tests", "Skip slow tests") orelse false;
    const opts = b.addOptions();
    opts.addOption(bool, "fast_tests", fast_tests);
    tests.root_module.addOptions("compile_opts", opts);

    tests.root_module.addImport("ziglua", ziglua);
    tests.root_module.addImport("spoon", spoon);
    tests.root_module.addImport("wcwidth", wcwidth);

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_tests.step);

    const test_exe_step = b.step("test-exe", "Build test executable");
    const install_step = b.addInstallArtifact(tests, .{});
    test_exe_step.dependOn(&install_step.step);
}
