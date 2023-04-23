const std = @import("std");
const builtin = @import("builtin");

const spoon = @import("spoon");
const Sheet = @import("Sheet.zig");
const Tui = @import("Tui.zig");
const ZC = @import("ZC.zig");

const Allocator = std.mem.Allocator;

var zc: ZC = undefined;

pub fn main() !void {
	if (builtin.mode == .Debug) {
		logfile = try std.fs.cwd().createFile("log.txt", .{});
	}
	defer if (builtin.mode == .Debug) logfile.close();

	var gpa = std.heap.GeneralPurposeAllocator(.{}){};
	defer _ = gpa.deinit();

	const allocator = gpa.allocator();

	zc = try ZC.init(allocator);
	defer zc.deinit();

	try zc.run();
}

pub fn panic(msg: []const u8, trace: ?*std.builtin.StackTrace, ret_addr: ?usize) noreturn {
    @setCold(true);
    zc.tui.term.cook() catch {};
    std.builtin.default_panic(msg, trace, ret_addr);
}

var logfile: std.fs.File = undefined;

pub const std_options = struct {
	// Set the log level to info
	pub const log_level = .info;
	// Define logFn to override the std implementation
	pub const logFn = myLogFn;
};

pub fn myLogFn(
	comptime level: std.log.Level,
	comptime scope: @TypeOf(.EnumLiteral),
	comptime format: []const u8,
	args: anytype,
) void {
	if (builtin.mode != .Debug)
		return;

	const writer = logfile.writer();
	writer.print("[{}] {}:", .{ scope, level }) catch unreachable;
	writer.print(format, args) catch unreachable;
	writer.writeByte('\n') catch unreachable;
	logfile.sync() catch unreachable;
}

// Reference all tests in other modules
comptime {
	std.testing.refAllDecls(@import("Parse.zig"));
	std.testing.refAllDecls(ZC);
	std.testing.refAllDecls(@import("utils.zig"));
}
