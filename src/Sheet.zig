const std = @import("std");
const Position = @import("ZC.zig").Position;
const Ast = @import("Parse.zig");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Sheet = @This();

const NodeList = std.ArrayList(Position);
const NodeListUnmanaged = std.ArrayListUnmanaged(Position);

const log = std.log.scoped(.sheet);

columns: std.AutoArrayHashMapUnmanaged(u16, Column) = .{},
filename: []const u8 = &.{},
sorted_nodes: NodeListUnmanaged = .{},
needs_update: bool = false,

pub fn init() Sheet {
	return .{};
}

pub fn deinit(self: *Sheet, allocator: Allocator) void {
	for (self.columns.values()) |*c| {
		c.deinit(allocator);
	}

	self.sorted_nodes.deinit(allocator);
	self.columns.deinit(allocator);
	self.* = undefined;
}

pub fn setCell(
	sheet: *Sheet,
	allocator: Allocator,
	y: u16,
	x: u16,
	data: Cell,
) !void {
	const entry = try sheet.columns.getOrPut(allocator, x);
	if (!entry.found_existing) {
		entry.value_ptr.* = .{};
	}
	const col_ptr = entry.value_ptr;
	const cell_entry = try col_ptr.cells.getOrPut(allocator, y);

	if (cell_entry.found_existing) {
		cell_entry.value_ptr.ast.deinit(allocator);
	}

	cell_entry.value_ptr.* = data;
	sheet.needs_update = true;
}

pub fn getCell(sheet: Sheet, pos: Position) ?Cell {
	if (sheet.columns.get(pos.x)) |col| {
		return col.cells.get(pos.y);
	}
	return null;
}

pub fn getCellPtr(sheet: *Sheet, pos: Position) ?*Cell {
	if (sheet.columns.get(pos.x)) |col| {
		return col.cells.getPtr(pos.y);
	}
	return null;
}

const NodeMark = enum {
	temporary,
	permanent,
};

pub fn update(sheet: *Sheet, allocator: Allocator) Allocator.Error!void {
	if (!sheet.needs_update)
		return;

	try sheet.rebuildSortedNodeList(allocator);

	var iter = std.mem.reverseIterator(sheet.sorted_nodes.items);
	while (iter.next()) |pos| {
		const cell = sheet.getCellPtr(pos).?;
		_ = cell.eval(sheet);
	}

	sheet.needs_update = false;
}

pub fn rebuildSortedNodeList(sheet: *Sheet, allocator: Allocator) Allocator.Error!void {
	const node_count = blk: {
		var count: u32 = 0;
		for (sheet.columns.values()) |col| {
			count += @intCast(u32, col.cells.entries.len);
		}
		break :blk count;
	};

	// Topologically sorted set of cell positions
	var nodes = sheet.sorted_nodes.toManaged(allocator);
	nodes.clearRetainingCapacity();

	var visited_nodes = std.AutoHashMap(Position, NodeMark).init(allocator);
	defer visited_nodes.deinit();

	try nodes.ensureTotalCapacity(node_count + 1);
	try visited_nodes.ensureTotalCapacity(node_count + 1);

	while (visited_nodes.unmanaged.size < node_count) {
		for (sheet.columns.keys(), sheet.columns.values()) |x, col| {
			for (col.cells.keys()) |y| {
				const pos = Position{ .y = y, .x = x };
				if (!visited_nodes.contains(pos))
					try visit(sheet, pos, &nodes, &visited_nodes);
			}
		}
	}

	sheet.sorted_nodes = nodes.moveToUnmanaged();
}

fn visit(
	sheet: *Sheet,
	node: Position,
	nodes: *NodeList,
	visited_nodes: *std.AutoHashMap(Position, NodeMark),
) Allocator.Error!void {
	if (visited_nodes.get(node)) |mark| {
		switch (mark) {
			.permanent => return,
			.temporary => unreachable,
		}
	}

	var cell = sheet.getCell(node) orelse return;

	visited_nodes.putAssumeCapacity(node, .temporary);

	const Context = struct {
		sheet: *Sheet,
		node: Position,
		nodes: *NodeList,
		visited_nodes: *std.AutoHashMap(Position, NodeMark),

		pub fn func(context: @This(), index: u32) Allocator.Error!bool {
			const _cell = context.sheet.getCell(context.node).?;
			const ast_node = _cell.ast.nodes.get(index);
			if (ast_node == .cell) {
				if (context.visited_nodes.contains(ast_node.cell))
					return false;
				try visit(context.sheet, ast_node.cell, context.nodes, context.visited_nodes);
			}
			return true;
		}
	};

	try cell.ast.traverse(Context{
		.sheet = sheet,
		.node = node,
		.nodes = nodes,
		.visited_nodes = visited_nodes,
	});

	visited_nodes.putAssumeCapacity(node, .permanent);
	try nodes.insert(0, node);
}


pub const Cell = struct {
	num: ?f64 = null,
	ast: Ast = .{},

	pub fn deinit(cell: *Cell, allocator: Allocator) void {
		cell.ast.deinit(allocator);
		cell.* = undefined;
	}

	pub fn isEmpty(cell: Cell) bool {
		return cell.ast.nodes.len == 0;
	}

	pub fn getValue(cell: *Cell, sheet: *Sheet) f64 {
		return cell.num orelse cell.eval(sheet);
	}

	pub fn eval(cell: *Cell, sheet: *Sheet) f64 {
		const Context = struct {
			sheet: *const Sheet,
			stack: std.BoundedArray(Position, 512) = .{},
	
			pub fn evalCell(context: *@This(), pos: Position) f64 {
				// Check for cyclical references
				for (context.stack.slice()) |p| {
					if (std.meta.eql(pos, p)) {
						return 0;
					}
				}
	
				const _cell = context.sheet.getCell(pos) orelse return 0;
	
				if (context.stack.len == context.stack.capacity()) {
					_ = context.stack.orderedRemove(0);
				}
	
				context.stack.append(pos) catch unreachable;
				const ret = _cell.ast.eval(context);
				_ = context.stack.pop();
				return ret;
			}
		};
	
		var context = Context{ .sheet = sheet };
		const ret = cell.ast.eval(&context);
		cell.num = ret;
		return ret;
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
