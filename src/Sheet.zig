const std = @import("std");
const Allocator = std.mem.Allocator;

const Self = @This();

columns: std.AutoArrayHashMapUnmanaged(u16, Column),
filename: []const u8 = &[_]u8{},

pub fn init() Self {
	return .{
		.columns = .{},
	};
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
	num: f64,
) Allocator.Error!void {
	const entry = try self.columns.getOrPut(allocator, x);
	if (!entry.found_existing) {
		entry.value_ptr.* = .{};
	}
	const col_ptr = entry.value_ptr;

	const cell_entry = try col_ptr.cells.getOrPut(allocator, y);

	if (!cell_entry.found_existing) {
		cell_entry.value_ptr.* = .{ .num = num };
	} else {
		cell_entry.value_ptr.num = num;
	}
}

pub fn getCell(
	self: *Self,
	y: u16,
	x: u16,
) ?*Cell {
	if (self.columns.get(x)) |col| {
		return col.getPtr(y);
	}

	return null;
}

pub const Cell = struct {
	num: ?f64 = null,
};

pub const Column = struct {
	const CellMap = std.AutoArrayHashMapUnmanaged(u16, Cell);
	
	pub const default_width = 10;

	cells: CellMap = .{},
	width: u16 = default_width,
	precision: u8 = 2,

	pub fn deinit(self: *Column, allocator: Allocator) void {
		self.cells.deinit(allocator);
		self.* = undefined;
	}
};
