const std = @import("std");
const Pos = @import("ZC.zig").Pos;
const Ast = @import("Parse.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Self = @This();

columns: std.AutoArrayHashMapUnmanaged(u16, Column) = .{},
filename: []const u8 = &.{},

pub fn init() Self {
	return .{};
}

pub fn deinit(self: *Self, allocator: Allocator) void {
	for (self.columns.values()) |*c| {
		c.deinit(allocator);
	}

	self.columns.deinit(allocator);
	self.* = undefined;
}

pub fn setCell(
	self: *Self,
	allocator: Allocator,
	y: u16,
	x: u16,
	data: Cell,
) !void {
	const entry = try self.columns.getOrPut(allocator, x);
	if (!entry.found_existing) {
		entry.value_ptr.* = .{};
	}
	const col_ptr = entry.value_ptr;
	const cell_entry = try col_ptr.cells.getOrPut(allocator, y);

	if (cell_entry.found_existing) {
		cell_entry.value_ptr.ast.deinit(allocator);
	}

	cell_entry.value_ptr.* = data;
}

pub fn getCell(self: *Self, y: u16, x: u16) ?*Cell {
	if (self.columns.get(x)) |col| {
		return col.cells.getPtr(y);
	}
	return null;
}

pub fn evalCell(self: *Self, cell_pos: Pos) f64 {
	const Context = struct {
		sheet: *Self,
		stack: std.BoundedArray(Pos, 512) = .{},

		pub fn evalCell(context: *@This(), pos: Pos) f64 {
			// Check for cyclical references
			for (context.stack.slice()) |p| {
				if (std.meta.eql(pos, p)) {
					return 0;
				}
			}

			const cell = context.sheet.getCell(pos.y, pos.x) orelse return 0;

			if (context.stack.len == context.stack.capacity()) {
				_ = context.stack.orderedRemove(0);
			}

			context.stack.append(pos) catch unreachable;
			const ret = cell.ast.eval(context);
			_ = context.stack.pop();
			return ret;
		}
	};

	const cell = self.getCell(cell_pos.y, cell_pos.x) orelse return 0;
	var context = Context{ .sheet = self };
	return cell.ast.eval(&context);
}


pub const Cell = struct {
	ast: Ast = .{},

	pub fn deinit(self: *Cell, allocator: Allocator) void {
		self.ast.deinit(allocator);
		self.* = undefined;
	}

	pub fn isEmpty(self: Cell) bool {
		return self.ast.nodes.len == 0;
	}
};

pub const Column = struct {
	const CellMap = std.AutoArrayHashMapUnmanaged(u16, Cell);
	
	pub const default_width = 10;

	cells: CellMap = .{},
	width: u16 = default_width,
	precision: u8 = 2,

	pub fn deinit(self: *Column, allocator: Allocator) void {
		for (self.cells.values()) |*cell| {
			cell.deinit(allocator);
		}

		self.cells.deinit(allocator);
		self.* = undefined;
	}
};
