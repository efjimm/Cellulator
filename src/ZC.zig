const std = @import("std");
const utils = @import("utils.zig");
const Ast = @import("Parse.zig");
const spoon = @import("spoon");
const Sheet = @import("Sheet.zig");
const Tui = @import("Tui.zig");
const CommandAction = @import("text_input.zig").Action;
const TextInput = @import("text_input.zig").TextInput;
const critbit = @import("critbit.zig");

const Position = Sheet.Position;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.zc);

const Self = @This();

sheet: Sheet,
tui: Tui,

mode: Mode = .normal,

/// The top left corner of the screen
screen_pos: Position = .{},

prev_cursor: Position = .{},
/// The cell position of the cursor
cursor: Position = .{},

running: bool = true,

asts: std.ArrayListUnmanaged(Ast) = .{},

count: u32 = 0,

keymaps: KeyMap(Action, MapType),
command_keymaps: KeyMap(CommandAction, CommandMapType),

allocator: Allocator,

input_buf: std.BoundedArray(u8, INPUT_BUF_LEN) = .{},
command_buf: TextInput(512) = .{},
status_message: std.BoundedArray(u8, 256) = .{},

const INPUT_BUF_LEN = 64;

pub const status_line = 0;
pub const input_line = 1;
pub const col_heading_line = 2;
pub const content_line = 3;

pub const Mode = union(enum) {
	normal,

	/// Holds the 'anchor' position
	visual: Position,

	/// Same as visual mode, with different operations allowed. Used for inserting
	/// the text representation of the selected range into the command buffer.
	select: Position,
	                  
	command,

	pub fn format(
		mode: Mode,
		comptime _: []const u8,
		_: std.fmt.FormatOptions,
		writer: anytype,
	) !void {
		try writer.writeAll(@tagName(mode));
	}
};

pub const InitOptions = struct {
	filepath: ?[]const u8 = null,
	ui: bool = true,
};

pub fn init(allocator: Allocator, options: InitOptions) !Self {
	var ast_list = try std.ArrayListUnmanaged(Ast).initCapacity(allocator, 8);
	errdefer ast_list.deinit(allocator);

	var keymaps = try KeyMap(Action, MapType).init(outer_keys, allocator);
	errdefer keymaps.deinit(allocator);

	var command_keymaps = try KeyMap(CommandAction, CommandMapType).init(command_keys, allocator);
	errdefer command_keymaps.deinit(allocator);

	var tui = try Tui.init();
	errdefer tui.deinit();

	if (options.ui) {
		try tui.term.uncook(.{});
	}

	var ret = Self{
		.sheet = Sheet.init(allocator),
		.tui = tui,
		.allocator = allocator,
		.asts = ast_list,
		.keymaps = keymaps,
		.command_keymaps = command_keymaps,
	};

	if (options.filepath) |filepath| {
		try ret.loadFile(&ret.sheet, filepath);
	}

	log.debug("Finished init", .{});

	return ret;
}

pub fn deinit(self: *Self) void {
	for (self.asts.items) |*ast| {
		ast.deinit(self.allocator);
	}

	self.keymaps.deinit(self.allocator);
	self.command_keymaps.deinit(self.allocator);

	self.asts.deinit(self.allocator);
	self.sheet.deinit();
	self.tui.deinit();
	self.* = undefined;
}

pub fn run(self: *Self) !void {
	while (self.running) {
		try self.updateCells();
		try self.tui.render(self);
		try self.handleInput();
	}
}

pub fn setStatusMessage(self: *Self, comptime fmt: []const u8, args: anytype) void {
	self.dismissStatusMessage();
	const writer = self.status_message.writer();
	writer.print(fmt, args) catch {};
	self.tui.update.command = true;
}

pub fn dismissStatusMessage(self: *Self) void {
	self.status_message.len = 0;
	self.tui.update.command = true;
}

pub fn updateCells(self: *Self) Allocator.Error!void {
	return self.sheet.update();
}

fn setMode(self: *Self, new_mode: std.meta.Tag(Mode)) void {
	switch (self.mode) {
		.normal => {},
		.visual, .select => {
			self.tui.update.cells = true;
			self.tui.update.column_headings = true;
			self.tui.update.row_numbers = true;
		},
		.command => self.tui.update.command = true,
	}

	switch (new_mode) {
		.normal => self.mode = .normal,
		.command => {
			self.dismissStatusMessage();
			self.mode = .command;
			self.tui.update.command = true;
		},
		inline .visual, .select => |tag| self.mode = @unionInit(Mode, @tagName(tag), self.cursor),
	}
}

fn inputBufSentinelArray(self: *Self) [INPUT_BUF_LEN + 1]u8 {
	var buf: [INPUT_BUF_LEN + 1]u8 = undefined;
	const slice = self.input_buf.slice();
	@memcpy(buf[0..slice.len], slice);
	buf[slice.len] = 0;
	return buf;
}

fn handleInput(self: *Self) !void {
	var buf: [INPUT_BUF_LEN]u8 = undefined;
	const slice = try self.tui.term.readInput(&buf);

	// TODO: parseInput may write more bytes than the buffer allows, which will cut off long key
	// sequences
	const writer = self.input_buf.writer();
	parseInput(slice, writer) catch |err| switch (err) {
		error.Overflow => {},
	};

	switch (self.mode) {
		.normal => self.normalMode(),
		.visual, .select => self.visualMode(),
		.command => self.commandMode() catch |err| {
			self.setStatusMessage("Error: {s}", .{ @errorName(err) });
		},
	}
}

fn getAnchor(self: *Self) *Position {
	return switch (self.mode) {
		.visual, .select => |*anchor| anchor,
		.normal, .command => unreachable,
	};
}

fn visualMode(self: *Self) void {
	var input_buf = self.inputBufSentinelArray();
	const input = input_buf[0..self.input_buf.len:0];

	const map_type: MapType = switch (self.mode) {
		.visual => .visual,
		.select => .select,
		.normal, .command => unreachable,
	};

	const action = self.keymaps.get(map_type, input) orelse {
		if (!self.keymaps.contains(map_type, input)) self.input_buf.len = 0;
		return;
	};

	switch (action) {
		.enter_normal_mode => self.setMode(.normal),
		.swap_anchor => {
			const anchor = self.getAnchor();
			const temp = anchor.*;
			anchor.* = self.cursor;
			self.setCursor(temp);
		},

		.select_cancel => self.setMode(.command),
		.select_submit => {
			const writer = self.command_buf.writer();
			const tl = Position.topLeft(self.cursor, self.mode.select);
			const br = Position.bottomRight(self.cursor, self.mode.select);
			writer.print("{}:{}", .{ tl, br }) catch {};
			self.setMode(.command);
		},

		.cell_cursor_up => self.cursorUp(),
		.cell_cursor_down => self.cursorDown(),
		.cell_cursor_left => self.cursorLeft(),
		.cell_cursor_right => self.cursorRight(),
		.cell_cursor_row_first => self.cursorToFirstCellInColumn(),
		.cell_cursor_row_last => self.cursorToLastCellInColumn(),
		.cell_cursor_col_first => self.cursorToFirstCell(),
		.cell_cursor_col_last => self.cursorToLastCell(),
		.next_populated_cell => self.cursorNextPopulatedCell(),
		.prev_populated_cell => self.cursorPrevPopulatedCell(),

		.visual_move_up => {
			const anchor = self.getAnchor();
			if (anchor.y < self.cursor.y) {
				if (anchor.y > 0) {
					anchor.y -= 1;
					self.cursorUp();
				}
			} else if (self.cursor.y > 0) {
				anchor.y -= 1;
				self.cursorUp();
			}
		},
		.visual_move_down => {
			const anchor = self.getAnchor();
			if (anchor.y > self.cursor.y) {
				if (anchor.y < std.math.maxInt(u16)) {
					anchor.y += 1;
					self.cursorDown();
				}
			} else if (self.cursor.y < std.math.maxInt(u16)) {
				anchor.y += 1;
				self.cursorDown();
			}
		},
		.visual_move_left => {
			const anchor = self.getAnchor();
			if (anchor.x < self.cursor.x) {
				if (anchor.x > 0) {
					anchor.x -= 1;
					self.cursorLeft();
				}
			} else if (self.cursor.x > 0) {
				anchor.x -= 1;
				self.cursorLeft();
			}
		},
		.visual_move_right => {
			const anchor = self.getAnchor();
			if (anchor.x > self.cursor.x) {
				if (anchor.x < std.math.maxInt(u16)) {
					anchor.x += 1;
					self.cursorRight();
				}
			} else if (self.cursor.x < std.math.maxInt(u16)) {
				anchor.x += 1;
				self.cursorRight();
			}
		},

		.delete_cell => {
			self.sheet.deleteCellsInRange(self.cursor, self.mode.visual);
			self.setMode(.normal);
			self.tui.update.cells = true;
		},
		else => {},
	}
	self.input_buf.len = 0;
}

fn commandMode(self: *Self) !void {
	var input_buf = self.inputBufSentinelArray();
	const input = input_buf[0..self.input_buf.len:0];
	const map_type: CommandMapType = switch (self.command_buf.mode) {
		.normal => .normal,
		.insert => .insert,
		.operator_pending => .operator_pending,
		.to => .to,
	};

	if (self.command_keymaps.get(map_type, input)) |action| {
		self.input_buf.len = 0;
		const status = self.command_buf.do(action, input);
		switch (status) {
			.waiting => {},
			.cancelled => self.setMode(.normal),
			.select => self.setMode(.select),
			.string => |arr| try self.parseCommand(arr.slice()),
		}
	} else if (!self.command_keymaps.contains(map_type, input)) {
		var buf: [INPUT_BUF_LEN]u8 = undefined;
		const len = std.mem.replacementSize(u8, input, "<<", "<");
		_ = std.mem.replace(u8, input, "<<", "<", &buf);
		_ = self.command_buf.do(.none, buf[0..len]);
		self.input_buf.len = 0;
	}
}

fn parseCommand(self: *Self, str: []const u8) !void {
	defer self.setMode(.normal);

	if (str.len == 0) return;

	if (str[0] == ':') {
		return self.runCommand(str[1..]);
	}

	var ast = self.newAst();
	ast.parse(self.allocator, str) catch |err| {
		self.delAstAssumeCapacity(ast);
		return err;
	};

	const root = ast.rootNode();
	switch (root) {
		.assignment => |op| {
			const pos = ast.nodes.items(.data)[op.lhs].cell;
			ast.splice(op.rhs);

			self.sheet.setCell(pos, .{ .ast = ast }) catch |err| {
				self.delAstAssumeCapacity(ast);
				return err;
			};
			self.tui.update.cursor = true;
			self.tui.update.cells = true;
		},
		else => {
			self.delAstAssumeCapacity(ast);
		},
	}
}

fn normalMode(self: *Self) void {
	var input_buf = self.inputBufSentinelArray();
	const input = input_buf[0..self.input_buf.len:0];
	if (self.keymaps.get(.normal, input)) |action| {
		switch (action) {
			.enter_command_mode => {
				self.setMode(.command);
				const writer = self.command_buf.writer();
				writer.writeByte(':') catch unreachable;
			},
			.enter_visual_mode => self.setMode(.visual),
			.enter_normal_mode => {},
			.dismiss_count_or_status_message => {
				if (self.count != 0) {
					self.resetCount();
				} else {
					self.dismissStatusMessage();
				}
			},

			.cell_cursor_up => self.cursorUp(),
			.cell_cursor_down => self.cursorDown(),
			.cell_cursor_left => self.cursorLeft(),
			.cell_cursor_right => self.cursorRight(),
			.cell_cursor_row_first => self.cursorToFirstCellInColumn(),
			.cell_cursor_row_last => self.cursorToLastCellInColumn(),
			.cell_cursor_col_first => self.cursorToFirstCell(),
			.cell_cursor_col_last => self.cursorToLastCell(),

			.delete_cell => self.deleteCell() catch |err| switch (err) {
				error.OutOfMemory => self.setStatusMessage("Error: out of memory!", .{}),
			},
			.next_populated_cell => self.cursorNextPopulatedCell(),
			.prev_populated_cell => self.cursorPrevPopulatedCell(),
			.increase_precision => self.cursorIncPrecision(),
			.decrease_precision => self.cursorDecPrecision(),
			.increase_width => self.cursorIncWidth(),
			.decrease_width => self.cursorDecWidth(),
			.assign_cell => {
				self.setMode(.command);
				const writer = self.command_buf.writer();
				self.cursor.writeCellAddress(writer) catch unreachable;
				writer.writeAll(" = ") catch unreachable;
			},

			.zero => {
				if (self.count == 0) {
					self.cursorToFirstCell();
				} else {
					self.setCount(0);
				}
			},
			.count => |count| self.setCount(count),
			else => {},
		}
		self.input_buf.len = 0;
	} else if (!self.keymaps.contains(.normal, input)) {
		self.input_buf.len = 0;
	}
}

pub fn isSelectedCell(self: Self, pos: Position) bool {
	return switch (self.mode) {
		.visual, .select => |anchor| pos.intersects(anchor, self.cursor),
		else => self.cursor.hash() == pos.hash(),
	};
}

pub fn isSelectedCol(self: Self, x: u16) bool {
	return switch (self.mode) {
		.visual, .select => |anchor| {
			const min = @min(self.cursor.x, anchor.x);
			const max = @max(self.cursor.x, anchor.x);
			return x >= min and x <= max;
		},
		else => self.cursor.x == x,
	};
}

pub fn isSelectedRow(self: Self, y: u16) bool {
	return switch (self.mode) {
		.visual, .select => |anchor| {
			const min = @min(self.cursor.y, anchor.y);
			const max = @max(self.cursor.y, anchor.y);
			return y >= min and y <= max;
		},
		else => self.cursor.y == y,
	};
}

pub fn nextPopulatedCell(self: *Self, start_pos: Position, count: u32) Position {
	if (count == 0) return start_pos;
	const positions = self.sheet.cells.keys();
	if (positions.len == 0) return start_pos;

	var ret = start_pos;

	// Index of the first position that is greater than start_pos
	const first = for (positions, count - 1..) |pos, i| {
		if (pos.hash() > start_pos.hash()) break i;
	} else return ret;

	// count-1 positions after the first one that is greater than start_pos
	return positions[@min(positions.len - 1, first)];
}

pub fn prevPopulatedCell(self: *Self, start_pos: Position, count: u32) Position {
	if (count == 0) return start_pos;

	const positions = self.sheet.cells.keys();
	var iter = std.mem.reverseIterator(positions);
	while (iter.next()) |pos| {
		if (pos.hash() < start_pos.hash()) break;
	} else return start_pos;

	return positions[iter.index -| (count - 1)];
}

pub fn cursorNextPopulatedCell(self: *Self) void {
	const new_pos = self.nextPopulatedCell(self.cursor, self.getCount());
	self.setCursor(new_pos);
	self.resetCount();
}

pub fn cursorPrevPopulatedCell(self: *Self) void {
	const new_pos = self.prevPopulatedCell(self.cursor, self.getCount());
	self.setCursor(new_pos);
	self.resetCount();
}

pub fn setCount(self: *Self, count: u4) void {
	assert(count <= 9);
	self.count = self.count *| 10 +| count;
}

pub fn getCount(self: Self) u32 {
	return if (self.count == 0) 1 else self.count;
}

pub fn getCountU16(self: Self) u16 {
	return @intCast(u16, @min(std.math.maxInt(u16), self.getCount()));
}

pub fn resetCount(self: *Self) void {
	self.count = 0;
}

const Cmd = enum {
	save,
	save_force,
	load,
	load_force,
	quit,
	quit_force,
};

const cmds = std.ComptimeStringMap(Cmd, .{
	.{ "w", .save },
	.{ "w!", .save_force },
	.{ "e", .load },
	.{ "e!", .load_force },
	.{ "q", .quit },
	.{ "q!", .quit_force },
});

pub fn runCommand(self: *Self, str: []const u8) !void {
	var iter = utils.wordIterator(str);
	const cmd_str = iter.next() orelse return error.InvalidCommand;
	assert(cmd_str.len > 0);

	const cmd = cmds.get(cmd_str) orelse return error.InvalidCommand;

	switch (cmd) {
		.quit => {
			if (self.sheet.has_changes) {
				self.setStatusMessage("No write since last change (add ! to override)", .{});
			} else {
				self.running = false;
			}
		},
		.quit_force => self.running = false,
		.save, .save_force => { // save
			writeFile(&self.sheet, .{ .filepath = iter.next() }) catch |err| {
				self.setStatusMessage("Could not write file: {s}", .{ @errorName(err) });
				return;
			};
			self.sheet.has_changes = false;
		},
		.load => { // load
			if (self.sheet.has_changes) {
				self.setStatusMessage("No write since last change (add ! to override)", .{});
			} else {
				try self.loadCmd(&iter);
			}
		},
		.load_force => try self.loadCmd(&iter),
	}
}

pub fn loadCmd(self: *Self, iter: *utils.WordIterator) !void {
	const filepath = iter.next() orelse return error.EmptyFileName;
	var new_sheet = Sheet.init(self.allocator);
	self.loadFile(&new_sheet, filepath) catch |err| {
		self.setStatusMessage("Could not open file: {s}", .{ @errorName(err) });
		return;
	};

	var old_sheet = self.sheet;
	self.sheet = new_sheet;

	// Re-use asts
	self.clearSheet(&old_sheet) catch |err| switch (err) {
		error.OutOfMemory => self.setStatusMessage("Error: out of memory!", .{}),
	};
	old_sheet.deinit();

	self.tui.update.cells = true;
}

pub fn clearSheet(self: *Self, sheet: *Sheet) Allocator.Error!void {
	for (sheet.cells.values()) |cell| {
		try self.delAst(cell.ast);
	}
	sheet.cells.clearRetainingCapacity();
}

pub fn loadFile(self: *Self, sheet: *Sheet, filepath: []const u8) !void {
	const file = try std.fs.cwd().createFile(filepath, .{
		.read = true,
		.truncate = false,
	});
	defer file.close();

	const slice = try file.reader().readAllAlloc(sheet.allocator, comptime std.math.maxInt(u30));
	defer sheet.allocator.free(slice);

	var line_iter = std.mem.tokenize(u8, slice, "\n");
	while (line_iter.next()) |line| {
		var ast = self.newAst();
		ast.parse(self.allocator, line) catch |err| switch (err) {
			error.UnexpectedToken => continue,
			else => return err,
		};
		errdefer self.asts.appendAssumeCapacity(ast);

		const root = ast.rootNode();
		switch (root) {
			.assignment => {
				const pos = ast.nodes.items(.data)[root.assignment.lhs].cell;
				ast.splice(root.assignment.rhs);
				try sheet.setCell(pos, .{ .ast = ast });
			},
			else => continue,
		}
	}

	sheet.setFilePath(filepath);
	sheet.has_changes = false;
}

pub const WriteFileOptions = struct {
	filepath: ?[]const u8 = null,
};

pub fn writeFile(sheet: *Sheet, opts: WriteFileOptions) !void {
	const filepath = opts.filepath orelse sheet.filepath.slice();
	if (filepath.len == 0) {
		return error.EmptyFileName;
	}

	var atomic_file = try std.fs.cwd().atomicFile(filepath, .{});
	defer atomic_file.deinit();

	var buf = std.io.bufferedWriter(atomic_file.file.writer());
	const writer = buf.writer();

	for (sheet.cells.keys(), sheet.cells.values()) |pos, *cell| {
		try pos.writeCellAddress(writer);
		try writer.writeAll(" = ");
		try cell.ast.print(writer);
		try writer.writeByte('\n');
	}

	try buf.flush();
	try atomic_file.finish();

	if (opts.filepath) |path| {
		sheet.setFilePath(path);
	}
}

pub fn deleteCell(self: *Self) Allocator.Error!void {
	const ast = self.sheet.deleteCell(self.cursor) orelse return;
	try self.delAst(ast);

	self.tui.update.cells = true;
	self.tui.update.cursor = true;
}

pub fn setCursor(self: *Self, new_pos: Position) void {
	self.prev_cursor = self.cursor;
	self.cursor = new_pos;
	self.clampScreenToCursor();

	switch (self.mode) {
		.visual, .select => {
			self.tui.update.cells = true;
			self.tui.update.column_headings = true;
			self.tui.update.row_numbers = true;
		},
		else => {
			self.tui.update.cursor = true;
		},
	}
}

pub fn cursorUp(self: *Self) void {
	self.setCursor(.{ .y = self.cursor.y -| self.getCountU16(), .x = self.cursor.x });
	self.resetCount();
}

pub fn cursorDown(self: *Self) void {
	self.setCursor(.{ .y = self.cursor.y +| self.getCountU16(), .x = self.cursor.x });
	self.resetCount();
}

pub fn cursorLeft(self: *Self) void {
	self.setCursor(.{ .y = self.cursor.y, .x = self.cursor.x -| self.getCountU16() });
	self.resetCount();
}

pub fn cursorRight(self: *Self) void {
	self.setCursor(.{ .y = self.cursor.y, .x = self.cursor.x +| self.getCountU16() });
	self.resetCount();
}

pub inline fn contentHeight(self: Self) u16 {
	return self.tui.term.height -| content_line;
}

pub fn leftReservedColumns(self: Self) u16 {
	const y = self.screen_pos.y +| self.contentHeight() -| 1;

	if (y == 0)
		return 2;

	return std.math.log10(y) + 2;
}

pub fn clampScreenToCursor(self: *Self) void {
	self.clampScreenToCursorY();
	self.clampScreenToCursorX();
}

pub fn clampScreenToCursorY(self: *Self) void {
	const height = self.contentHeight();
	if (height == 0) return;

	if (self.cursor.y < self.screen_pos.y) {
		const old_max = self.screen_pos.y + (height - 1);
		self.screen_pos.y = self.cursor.y;
		const new_max = self.screen_pos.y + (height - 1);

		if (std.math.log10(old_max) != std.math.log10(new_max)) {
			self.tui.update.column_headings = true;
		}

		self.tui.update.row_numbers = true;
		self.tui.update.cells = true;
		return;
	}

	if (self.cursor.y - self.screen_pos.y >= height) {
		const old_max = self.screen_pos.y + (height - 1);
		self.screen_pos.y = self.cursor.y - (height - 1);
		const new_max = self.screen_pos.y + (height - 1);

		if (std.math.log10(old_max) != std.math.log10(new_max)) {
			self.tui.update.column_headings = true;
		}

		self.tui.update.row_numbers = true;
		self.tui.update.cells = true;
	}
}

pub fn clampScreenToCursorX(self: *Self) void {
	if (self.cursor.x < self.screen_pos.x) {
		self.screen_pos.x = self.cursor.x;
		self.tui.update.column_headings = true;
		self.tui.update.cells = true;
		return;
	}

	var w = self.leftReservedColumns();
	var x: u16 = self.cursor.x;

	while (true) : (x -= 1) {
		if (x < self.screen_pos.x) return;

		const col = self.sheet.getColumn(x);
		w += col.width;

		if (w > self.tui.term.width) break;
		if (x == 0) return;
	}

	if (x > self.screen_pos.x or (x == self.screen_pos.x and x < self.cursor.x)) {
		self.screen_pos.x = x + 1;
		self.tui.update.column_headings = true;
		self.tui.update.cells = true;
	}
}

pub fn setPrecision(self: *Self, column: u16, new_precision: u8) void {
	if (self.sheet.columns.getPtr(column)) |col| {
		col.precision = new_precision;
		self.tui.update.cells = true;
	}
}

pub fn incPrecision(self: *Self, column: u16, count: u8) void {
	if (self.sheet.columns.getPtr(column)) |col| {
		col.precision +|= count;
		self.tui.update.cells = true;
	}
}

pub fn decPrecision(self: *Self, column: u16, count: u8) void {
	if (self.sheet.columns.getPtr(column)) |col| {
		col.precision -|= count;
		self.tui.update.cells = true;
	}
}

pub inline fn cursorIncPrecision(self: *Self) void {
	const count = @intCast(u8, @min(std.math.maxInt(u8), self.getCount()));
	self.incPrecision(self.cursor.x, count);
	self.resetCount();
}

pub inline fn cursorDecPrecision(self: *Self) void {
	const count = @intCast(u8, @min(std.math.maxInt(u8), self.getCount()));
	self.decPrecision(self.cursor.x, count);
	self.resetCount();
}

pub fn incWidth(self: *Self, column: u16, n: u8) void {
	if (self.sheet.columns.getPtr(column)) |col| {
		col.width +|= n;
		self.tui.update.cells = true;
		self.tui.update.column_headings = true;
	}
}

pub fn decWidth(self: *Self, column: u16, n: u8) void {
	if (self.sheet.columns.getPtr(column)) |col| {
		const new_width = col.width -| n;
		col.width = @max(1, new_width);
		self.tui.update.cells = true;
		self.tui.update.column_headings = true;
	}
}

pub inline fn cursorIncWidth(self: *Self) void {
	const count = @intCast(u8, @min(std.math.maxInt(u8), self.getCount()));
	self.incWidth(self.cursor.x, count);
	self.resetCount();
}

pub inline fn cursorDecWidth(self: *Self) void {
	const count = @intCast(u8, @min(std.math.maxInt(u8), self.getCount()));
	self.decWidth(self.cursor.x, count);
	self.resetCount();
}

pub fn newAst(self: *Self) Ast {
	return self.asts.popOrNull() orelse Ast{};
}

pub fn delAst(self: *Self, ast: Ast) Allocator.Error!void {
	var temp = ast;
	temp.nodes.len = 0;
	try self.asts.append(self.allocator, temp);
}

pub fn delAstAssumeCapacity(self: *Self, ast: Ast) void {
	var temp = ast;
	temp.nodes.len = 0;
	self.asts.appendAssumeCapacity(temp);
}

pub fn cursorToFirstCell(self: *Self) void {
	const positions = self.sheet.cells.keys();
	for (positions) |pos| {
		if (pos.y < self.cursor.y) continue;

		if (pos.y == self.cursor.y)
			self.setCursor(pos);
		break;
	}
}

pub fn cursorToLastCell(self: *Self) void {
	const positions = self.sheet.cells.keys();

	if (positions.len == 0) return;

	var new_pos = self.cursor;
	for (positions) |pos| {
		if (pos.y > self.cursor.y) break;
		new_pos = pos;
	}
	self.setCursor(new_pos);
}

pub fn cursorToFirstCellInColumn(self: *Self) void {
	const positions = self.sheet.cells.keys();
	if (positions.len == 0) return;

	for (positions) |pos| {
		if (pos.x == self.cursor.x) {
			self.setCursor(pos);
			break;
		}
	}
}

pub fn cursorToLastCellInColumn(self: *Self) void {
	const positions = self.sheet.cells.keys();
	if (positions.len == 0) return;

	var iter = std.mem.reverseIterator(positions);
	while (iter.next()) |pos| {
		if (pos.x == self.cursor.x) {
			self.setCursor(pos);
			break;
		}
	}
}

pub fn parseInput(bytes: []const u8, writer: anytype) @TypeOf(writer).Error!void {
	var iter = spoon.inputParser(bytes);

	while (iter.next()) |in| {
		var special = false;
		if (in.mod_ctrl and in.mod_alt) {
			special = true;
			try writer.writeAll("<C-M-");
		} else if (in.mod_ctrl) {
			special = true;
			try writer.writeAll("<C-");
		} else if (in.mod_alt) {
			special = true;
			try writer.writeAll("<M-");
		}

		switch (in.content) {
			.escape => try writer.writeAll("<Escape>"),
			.arrow_up => try writer.writeAll("<Up"),
			.arrow_down => try writer.writeAll("<Down>"),
			.arrow_left => try writer.writeAll("<Left>"),
			.arrow_right => try writer.writeAll("<Right>"),
			.home => try writer.writeAll("<Home>"),
			.end => try writer.writeAll("<End>"),
			.begin => try writer.writeAll("<Begin>"),
			.page_up => try writer.writeAll("<PageUp>"),
			.page_down => try writer.writeAll("<PageDown>"),
			.delete => try writer.writeAll("<Delete>"),
			.insert => try writer.writeAll("<Insert>"),
			.print => try writer.writeAll("<Print>"),
			.scroll_lock => try writer.writeAll("<Scroll>"),
			.pause => try writer.writeAll("<Pause>"),
			.function => |function| try writer.print("<F{d}>", .{ function }),
			.codepoint => |cp| switch (cp) {
				'<' => try writer.writeAll("<<"),
				'\n', '\r' => try writer.writeAll("<Return>"),
				127 => try writer.writeAll("<Delete>"),
				0...'\n'-1, '\n'+1...'\r'-1, '\r'+1...31 => {},
				else => {
					var buf: [4]u8 = undefined;
					const len = std.unicode.utf8Encode(cp, &buf) catch continue;
					try writer.writeAll(buf[0..len]);
				},
			},
			.mouse, .unknown => try writer.writeAll("\x00"),
		}

		if (special) {
			try writer.writeByte('>');
		}
	}
}

pub const Action = union(enum) {
	enter_normal_mode,
	enter_visual_mode,
	enter_command_mode,
	dismiss_count_or_status_message,

	cell_cursor_up,
	cell_cursor_down,
	cell_cursor_left,
	cell_cursor_right,
	cell_cursor_row_first,
	cell_cursor_row_last,
	cell_cursor_col_first,
	cell_cursor_col_last,

	delete_cell,
	next_populated_cell,
	prev_populated_cell,
	increase_precision,
	decrease_precision,
	increase_width,
	decrease_width,
	assign_cell,

	visual_move_left,
	visual_move_right,
	visual_move_up,
	visual_move_down,
	select_submit,
	select_cancel,

	zero,
	count: u4,

	// Visual mode only
	swap_anchor,
};

pub const MapType = enum {
	normal,
	visual,
	select,

	visual_motions,
	common_motions,
	common_keys,
};

pub const CommandMapType = enum {
	normal,
	insert,
	operator_pending,
	to,
	non_insert_keys,
	common_keys,
};

pub fn KeyMap(comptime A: type, comptime M: type) type {
	return struct {
		const CritMap = critbit.CritBitMap([*:0]const u8, A, critbit.StringContextZ);
		pub const Map = struct {
			keys: CritMap,
			parents: []const M,
		};

		maps: std.EnumArray(M, Map),

		pub fn init(default: anytype, allocator: Allocator) !@This() {
			var maps = std.EnumArray(M, Map).initFill(.{
				.keys = CritMap.init(),
				.parents = &.{},
			});
			errdefer for (&maps.values) |*v| v.keys.deinit(allocator);

			for (default) |map| {
				var m = CritMap.init();
				errdefer m.deinit(allocator);

				for (map.keys) |mapping| {
					try m.put(allocator, mapping[0], mapping[1]);
				}

				maps.set(map.type, .{
					.keys = m,
					.parents = map.parents,
				});
			}
			return .{
				.maps = maps,
			};
		}

		/// Returns the action associated with the given input, or `null` if not found. Looks
		/// recursively through parent maps if not found.
		pub fn get(self: @This(), mode: M, input: [*:0]const u8) ?A {
			const map = self.maps.getPtrConst(mode);
			return map.keys.get(input) orelse for (map.parents) |parent_mode| {
				if (self.get(parent_mode, input)) |ret| break ret;
			} else null;
		}

		pub fn contains(self: @This(), mode: M, input: [*:0]const u8) bool {
			const map = self.maps.getPtrConst(mode);
			if (map.keys.contains(input)) return true;
			for (map.parents) |parent_mode| {
				const parent = self.maps.getPtrConst(parent_mode);
				if (parent.keys.contains(input)) return true;
			}
			return false;
		}

		pub fn deinit(self: *@This(), allocator: Allocator) void {
			for (&self.maps.values) |*v| {
				v.keys.deinit(allocator);
			}
			self.* = undefined;
		}
	};
}

const KeyMaps = struct {
	type: MapType,
	parents: []const MapType,
	keys: []const struct {
		[*:0]const u8,
		Action,
	},
};

const outer_keys = [_]KeyMaps{
	.{
		.type = .common_keys,
		.parents = &.{},
		.keys = &.{
			.{ "x", .delete_cell },
		},
	},
	.{
		.type = .common_motions,
		.parents = &.{},
		.keys = &.{
			.{ "j", .cell_cursor_down },
			.{ "k", .cell_cursor_up },
			.{ "h", .cell_cursor_left },
			.{ "l", .cell_cursor_right },
			.{ "w", .next_populated_cell },
			.{ "b", .prev_populated_cell },
			.{ "gg", .cell_cursor_row_first },
			.{ "G", .cell_cursor_row_last },
			.{ "$", .cell_cursor_col_last },

			.{ "0", .zero }, // Could be motion or count
			.{ "1", .{ .count = 1 } },
			.{ "2", .{ .count = 2 } },
			.{ "3", .{ .count = 3 } },
			.{ "4", .{ .count = 4 } },
			.{ "5", .{ .count = 5 } },
			.{ "6", .{ .count = 6 } },
			.{ "7", .{ .count = 7 } },
			.{ "8", .{ .count = 8 } },
			.{ "9", .{ .count = 9 } },
		},
	},
	.{
		.type = .visual_motions,
		.parents = &.{},
		.keys = &.{
			.{ "<M-h>", .visual_move_left },
			.{ "<M-l>", .visual_move_right },
			.{ "<M-k>", .visual_move_up },
			.{ "<M-j>", .visual_move_down },
		},
	},
	.{
		.type = .normal,
		.parents = &.{ .common_motions },
		.keys = &.{
			.{ "<C-[>", .dismiss_count_or_status_message },
			.{ "<Escape>", .dismiss_count_or_status_message },

			.{ "+", .increase_width },
			.{ "-", .decrease_width },
			.{ "f", .increase_precision },
			.{ "F", .decrease_precision },
			.{ "=", .assign_cell },
			.{ "dd", .delete_cell },
			.{ ":", .enter_command_mode },
			.{ "v", .enter_visual_mode },
		},
	},
	.{
		.type = .visual,
		.parents = &.{ .common_motions, .visual_motions },
		.keys = &.{
			.{ "<C-[>", .enter_normal_mode },
			.{ "<Escape>", .enter_normal_mode },

			.{ "o", .swap_anchor },
			.{ "d", .delete_cell },
		},
	},
	.{
		.type = .select,
		.parents = &.{ .common_motions, .visual_motions },
		.keys = &.{
			.{ "<C-[>", .select_cancel },
			.{ "<Escape>", .select_cancel },

			.{ "o", .swap_anchor },
			.{ "<Return>", .select_submit },
			.{ "<C-j>", .select_submit },
			.{ "<C-m>", .select_submit },
		},
	},
};

const CommandKeyMaps = struct {
	type: CommandMapType,
	parents: []const CommandMapType,
	keys: []const struct {
		[*:0]const u8,
		CommandAction,
	},
};

const command_keys = [_]CommandKeyMaps{
	.{
		.type = .common_keys,
		.parents = &.{},
		.keys = &.{
			.{ "<C-m>", .submit_command },
			.{ "<C-j>", .submit_command },
			.{ "<Return>", .submit_command },

			.{ "<Home>", .motion_bol },
			.{ "<End>", .motion_eol },
			.{ "<Left>", .motion_char_prev },
			.{ "<Right>", .motion_char_next },

			.{ "<C-[>", .enter_normal_mode },
			.{ "<Escape>", .enter_normal_mode },
		},
	},
	.{
		.type = .non_insert_keys,
		.parents = &.{},
		.keys = &.{
			.{ "1", .{ .count = 1 } },
			.{ "2", .{ .count = 2 } },
			.{ "3", .{ .count = 3 } },
			.{ "4", .{ .count = 4 } },
			.{ "5", .{ .count = 5 } },
			.{ "6", .{ .count = 6 } },
			.{ "7", .{ .count = 7 } },
			.{ "8", .{ .count = 8 } },
			.{ "9", .{ .count = 9 } },

			.{ "f", .operator_to_forwards },
			.{ "F", .operator_to_backwards },
			.{ "t", .operator_until_forwards },
			.{ "T", .operator_until_backwards },

			.{ "h", .motion_char_prev },
			.{ "l", .motion_char_next },
			.{ "0", .zero },
			.{ "$", .motion_eol },
			.{ "w", .motion_normal_word_start_next },
			.{ "W", .motion_long_word_start_next },
			.{ "e", .motion_normal_word_end_next },
			.{ "E", .motion_long_word_end_next },
			.{ "b", .motion_normal_word_start_prev },
			.{ "B", .motion_long_word_start_prev },
			.{ "<M-e>", .motion_normal_word_end_prev },
			.{ "<M-E>", .motion_long_word_end_prev },
		},
	},
	.{
		.type = .normal,
		.parents = &.{ .common_keys, .non_insert_keys },
		.keys = &.{
			.{ "x", .delete_char },
			.{ "d", .operator_delete },
			.{ "D", .delete_to_eol },
			.{ "c", .operator_change },
			.{ "C", .change_to_eol },
			.{ "s", .change_char },
			.{ "S", .change_line },

			.{ "i", .enter_insert_mode },
			.{ "I", .enter_insert_mode_at_bol },
			.{ "a", .enter_insert_mode_after },
			.{ "A", .enter_insert_mode_at_eol },
		},
	},
	.{
		.type = .insert,
		.parents = &.{ .common_keys },
		.keys = &.{
			.{ "<C-h>", .backspace },
			.{ "<Delete>", .backspace },
			.{ "<C-u>", .change_line },
			.{ "<C-v>", .enter_select_mode },

			.{ "<C-a>", .motion_bol },
			.{ "<C-e>", .motion_eol },
			.{ "<C-b>", .motion_char_prev },
			.{ "<C-f>", .motion_char_next },
			.{ "<C-w>", .backwards_delete_word },
		},
	},
	.{
		.type = .operator_pending,
		.parents = &.{ .common_keys, .non_insert_keys },
		.keys = &.{
			.{ "d", .operator_delete },
			.{ "c", .operator_change },

			.{ "aw", .motion_normal_word_around },
			.{ "aW", .motion_long_word_around },
			.{ "iw", .motion_normal_word_inside },
			.{ "iW", .motion_long_word_inside },

			.{ "a(", .{ .motion_around_delimiters = utils.packDoubleCp('(', ')') } },
			.{ "i(", .{ .motion_inside_delimiters = utils.packDoubleCp('(', ')') } },
			.{ "a)", .{ .motion_around_delimiters = utils.packDoubleCp('(', ')') } },
			.{ "i)", .{ .motion_inside_delimiters = utils.packDoubleCp('(', ')') } },

			.{ "a[", .{ .motion_around_delimiters = utils.packDoubleCp('[', ']') } },
			.{ "i[", .{ .motion_inside_delimiters = utils.packDoubleCp('[', ']') } },
			.{ "a]", .{ .motion_around_delimiters = utils.packDoubleCp('[', ']') } },
			.{ "i]", .{ .motion_inside_delimiters = utils.packDoubleCp('[', ']') } },

			.{ "i{", .{ .motion_inside_delimiters = utils.packDoubleCp('{', '}') } },
			.{ "a{", .{ .motion_around_delimiters = utils.packDoubleCp('{', '}') } },
			.{ "i}", .{ .motion_inside_delimiters = utils.packDoubleCp('{', '}') } },
			.{ "a}", .{ .motion_around_delimiters = utils.packDoubleCp('{', '}') } },

			.{ "i<<", .{ .motion_inside_delimiters = utils.packDoubleCp('<', '>') } },
			.{ "a<<", .{ .motion_around_delimiters = utils.packDoubleCp('<', '>') } },
			.{ "i>", .{ .motion_inside_delimiters = utils.packDoubleCp('<', '>') } },
			.{ "a>", .{ .motion_around_delimiters = utils.packDoubleCp('<', '>') } },

			.{ "i\"", .{ .motion_inside_single_delimiter = '"' } },
			.{ "a\"", .{ .motion_around_single_delimiter = '"' } },

			.{ "i'", .{ .motion_inside_single_delimiter = '\'' } },
			.{ "a'", .{ .motion_around_single_delimiter = '\'' } },

			.{ "i`", .{ .motion_inside_single_delimiter = '`' } },
			.{ "a`", .{ .motion_around_single_delimiter = '`' } },
		},
	},
	.{
		.type = .to,
		.parents = &.{ .common_keys },
		.keys = &.{
		},
	},
};
