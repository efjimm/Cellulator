const std = @import("std");
const Sheet = @import("Sheet.zig");
const Ast = @import("Parse.zig");

const Allocator = std.mem.Allocator;

pub fn loadFile(sheet: *Sheet, filepath: []const u8) !void {
	const file = try std.fs.cwd().openFile(filepath, .{});
	defer file.close();

	const slice = try file.reader().readAllAlloc(sheet.allocator, comptime std.math.maxInt(u30));
	defer sheet.allocator.free(slice);

	var line_iter = std.mem.tokenize(u8, slice, "\n");
	while (line_iter.next()) |line| {
		var ast = Ast.parse(sheet.allocator, line) catch continue;

		const root = ast.rootNode();
		switch (root) {
			.assignment => {
				const pos = ast.nodes.get(root.assignment.lhs).cell;

				ast.splice(root.assignment.rhs);
				try sheet.setCell(pos, .{ .ast = ast });
			},
			else => continue,
		}
	}
}
