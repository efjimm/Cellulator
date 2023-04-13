const std = @import("std");
const spoon = @import("spoon");
const Sheet = @import("Sheet.zig");
const Tui = @import("Tui.zig");
const ZC = @import("ZC.zig");

const Allocator = std.mem.Allocator;

var zc: ZC = undefined;

pub fn main() !void {
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

comptime {
	std.testing.refAllDecls(@import("Parser.zig"));
	std.testing.refAllDecls(ZC);
	std.testing.refAllDecls(@import("utils.zig"));
}
