const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_x86_backend = b.option(bool, "native-backend", "Use Zig's native x86 backend for compilation") orelse false;

    const exe = b.addExecutable(.{
        .name = "cellulator",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
        .use_llvm = !use_x86_backend,
        .use_lld = !use_x86_backend,
    });

    const strip: ?bool = b.option(bool, "strip", "");
    exe.strip = strip;

    const spoon = b.dependency("spoon", .{
        .target = target,
        .optimize = optimize,
    }).module("spoon");
    const wcwidth = spoon.dependencies.get("wcwidth").?;
    const ziglua_dep = b.dependency("ziglua", .{
        .target = target,
        .optimize = optimize,
        .version = .lua_54,
    });
    exe.addModule("ziglua", ziglua_dep.module("ziglua"));
    exe.linkLibrary(ziglua_dep.artifact("lua"));
    exe.addModule("spoon", spoon);
    exe.addModule("wcwidth", wcwidth);

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
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
        .filter = filter,
        .use_llvm = !use_x86_backend,
        .use_lld = !use_x86_backend,
    });

    const fast_tests = b.option(bool, "fast-tests", "Skip slow tests") orelse false;
    const opts = b.addOptions();
    opts.addOption(bool, "fast_tests", fast_tests);
    tests.addOptions("compile_opts", opts);

    tests.addModule("ziglua", ziglua_dep.module("ziglua"));
    tests.linkLibrary(ziglua_dep.artifact("lua"));
    tests.addModule("spoon", spoon);
    tests.addModule("wcwidth", wcwidth);

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run all unit tests");
    test_step.dependOn(&run_tests.step);

    const test_exe_step = b.step("test-exe", "Build test executable");
    const install_step = b.addInstallArtifact(tests, .{});
    test_exe_step.dependOn(&install_step.step);
}
