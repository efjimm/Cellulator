const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "cellulator",
        .root_source_file = .{ .path = "src/main.zig" },
        .target = target,
        .optimize = optimize,
    });

    const spoon_pkg = b.dependency("spoon", .{});
    const spoon = spoon_pkg.module("spoon");
    const wcwidth = b.dependency("wcwidth", .{}).module("wcwidth");
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



    const tests = b.addTest(.{
    	.root_source_file = .{ .path = "src/main.zig" },
    	.target = target,
    	.optimize = optimize,
    });

    tests.addModule("spoon", spoon);
    tests.addModule("wcwidth", wcwidth);

    const run_tests = b.addRunArtifact(tests);

	const test_step = b.step("test", "Run all unit tests");
	test_step.dependOn(&run_tests.step);
}
