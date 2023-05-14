const std = @import("std");
const utils = @import("utils.zig");
const Ast = @import("Parse.zig");
const spoon = @import("spoon");
const Sheet = @import("Sheet.zig");
const Tui = @import("Tui.zig");
const TextInput = @import("text_input.zig").TextInput;

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

allocator: Allocator,

command_buf: TextInput(512) = .{},
status_message: std.BoundedArray(u8, 256) = .{},

pub const status_line = 0;
pub const input_line = 1;
pub const col_heading_line = 2;
pub const content_line = 3;

pub const Mode = enum {
	normal,
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
	var ret = Self{
		.sheet = Sheet.init(allocator),
		.tui = try Tui.init(),
		.allocator = allocator,
		.asts = try std.ArrayListUnmanaged(Ast).initCapacity(allocator, 8),
	};

	if (options.ui) {
		try ret.tui.term.uncook(.{});
	}

	if (options.filepath) |filepath| {
		try ret.loadFile(&ret.sheet, filepath);
	}

	return ret;
}

pub fn deinit(self: *Self) void {
	for (self.asts.items) |*ast| {
		ast.deinit(self.allocator);
	}
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

fn setMode(self: *Self, new_mode: Mode) void {
	if (new_mode == .command) {
		self.dismissStatusMessage();
	} else if (self.mode == .command) {
		self.tui.update.command = true;
	}

	self.mode = new_mode;
}

fn handleInput(self: *Self) !void {
	var buf: [16]u8 = undefined;
	const slice = try self.tui.term.readInput(&buf);

	switch (self.mode) {
		.normal => self.doNormalMode(slice) catch |err| switch (err) {
			error.OutOfMemory => self.setStatusMessage("Error: out of memory!", .{}),
		},
		.command => self.doCommandMode(slice) catch |err| switch (err) {
			// We should be able to recover from OOM
			error.OutOfMemory => self.setStatusMessage("Error: out of memory!", .{}),
			error.UnexpectedToken => self.setStatusMessage("Error: unexpected token", .{}),
			error.InvalidCellAddress => self.setStatusMessage("Error: invalid cell address", .{}),
			error.InvalidCommand => self.setStatusMessage("Error: invalid command", .{}),
			error.EmptyFileName => self.setStatusMessage("Error: must specify a file name", .{}),
		},
	}
}

fn doNormalMode(self: *Self, buf: []const u8) !void {
	var iter = spoon.inputParser(buf);

	while (iter.next()) |in| {
		if (!in.mod_ctrl)  switch (in.content) {
			.escape      => self.dismissStatusMessage(),
			.arrow_up    => self.setCursor(.{ .y = self.cursor.y -| 1, .x = self.cursor.x }),
			.arrow_down  => self.setCursor(.{ .y = self.cursor.y +| 1, .x = self.cursor.x }),
			.arrow_left  => self.setCursor(.{ .x = self.cursor.x -| 1, .y = self.cursor.y }),
			.arrow_right => self.setCursor(.{ .x = self.cursor.x +| 1, .y = self.cursor.y }),
			.home        => self.cursorToFirstCell(),
			.end         => self.cursorToLastCell(),
			.codepoint   => |cp| switch (cp) {
				'0' => self.cursorToFirstCell(),
				'$' => self.cursorToLastCell(),
				'g' => self.cursorToFirstCellInColumn(),
				'G' => self.cursorToLastCellInColumn(),
				':' => {
					self.setMode(.command);
					const writer = self.command_buf.writer();
					writer.writeByte(':') catch unreachable;
				},
				'D', 'x' => self.deleteCell() catch |err| switch (err) {
					error.OutOfMemory => self.setStatusMessage("Error: out of memory!", .{}),
				},
				'w' => {
					const positions = self.sheet.cells.keys();
					for (positions) |pos| {
						if (pos.hash() > self.cursor.hash()) {
							self.setCursor(pos);
							break;
						}
					}
				},
				'b' => {
					const positions = self.sheet.cells.keys();
					var pos_iter = std.mem.reverseIterator(positions);
					while (pos_iter.next()) |pos| {
						if (pos.hash() < self.cursor.hash()) {
							self.setCursor(pos);
							break;
						}
					}
				},
				'f' => self.incPrecision(self.cursor.x, 1),
				'F' => self.decPrecision(self.cursor.x, 1),
				'k' => self.setCursor(.{ .y = self.cursor.y -| 1, .x = self.cursor.x }),
				'j' => self.setCursor(.{ .y = self.cursor.y +| 1, .x = self.cursor.x }),
				'h' => self.setCursor(.{ .x = self.cursor.x -| 1, .y = self.cursor.y }),
				'l' => self.setCursor(.{ .x = self.cursor.x +| 1, .y = self.cursor.y }),
				'=' => {
					self.setMode(.command);
					const writer = self.command_buf.writer();
					self.cursor.writeCellAddress(writer) catch unreachable;
					writer.writeAll(" = ") catch unreachable;
				},
				else => {},
			},
			else => {},
		} else switch (in.content) {
			.codepoint => |cp| switch (cp) {
				// C-[ is indistinguishable from Escape on most terminals. On terminals where they
				// can be distinguished, we make them do the same thing for a consistent experience
				'[' => self.dismissStatusMessage(),
				else => {},
			},
			else => {},
		}
	}
}

fn doCommandMode(self: *Self, input: []const u8) !void {
	const status = self.command_buf.handleInput(input);
	switch (status) {
		.waiting => {},
		.cancelled => self.setMode(.normal),
		.string => |arr| {
			defer self.setMode(.normal);
			const str = arr.slice();

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
		},
	}
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

	// TODO: add confirmation for certain commands
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
			self.tui.update.status = true;
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

	self.tui.update.status = true;
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

	self.tui.update.cursor = true;
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

		if (w >= self.tui.term.width) break;
		if (x == 0) return;
	}

	if (x >= self.screen_pos.x) {
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

pub fn incPrecision(self: *Self, column: u16, n: u8) void {
	if (self.sheet.columns.getPtr(column)) |col| {
		col.precision +|= n;
		self.tui.update.cells = true;
	}
}

pub fn decPrecision(self: *Self, column: u16, n: u8) void {
	if (self.sheet.columns.getPtr(column)) |col| {
		col.precision -|= n;
		self.tui.update.cells = true;
	}
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

test "doCommandMode" {
	const t = std.testing;
	var zc = try Self.init(t.allocator, .{ .ui = false });
	defer zc.deinit();

	try zc.doCommandMode("b1 = 5\n");
	try zc.updateCells();

	try t.expectEqual(@as(u32, 1), zc.sheet.cellCount());
	try t.expectEqual(@as(u32, 1), zc.sheet.colCount());
	try t.expect(zc.sheet.getCell(.{ .y = 1, .x = 1 }) != null);

	try t.expectError(error.InvalidCommand, zc.doCommandMode(":\n"));
	try t.expectError(error.UnexpectedToken, zc.doCommandMode("a0 a0 a0\n"));
	try zc.doCommandMode("\n"); // Should do nothing
}

test "doNormalMode" {
	const t = std.testing;
	const Test = struct {
		fn testAllocs(allocator: Allocator) !void {
			var zc = try Self.init(allocator, .{ .ui = false });
			defer zc.deinit();

			const pos = struct {
				fn func(y: u16, x: u16) Position {
					return .{ .y = y, .x = x };
				}
			}.func;

			try t.expectEqual(Mode.normal, zc.mode);
			try t.expectEqual(pos(0, 0), zc.cursor);

			// Make sure cursor does not overflow in any way
			try zc.doNormalMode("hhhkkklhhjkk");
			try t.expectEqual(pos(0, 0), zc.cursor);

			// Test basic cursor movements
			try zc.doNormalMode("l");
			try t.expectEqual(pos(0, 1), zc.cursor);
			try zc.doNormalMode("lll");
			try t.expectEqual(pos(0, 4), zc.cursor);
			try zc.doNormalMode("j");
			try t.expectEqual(pos(1, 4), zc.cursor);
			try zc.doNormalMode("jjj");
			try t.expectEqual(pos(4, 4), zc.cursor);
			try zc.doNormalMode("kkk");
			try t.expectEqual(pos(1, 4), zc.cursor);
			try zc.doNormalMode("hhh");
			try t.expectEqual(pos(1, 1), zc.cursor);

			try zc.doNormalMode("=\n");
			try t.expectEqual(Mode.command, zc.mode);
			try t.expectEqualStrings("B1 = ", zc.command_buf.slice());
			try zc.doCommandMode("50\n");

			try t.expectEqual(@as(u32, 1), zc.sheet.cellCount());
			try zc.deleteCell(); // Delete cell under cursor
			try t.expectEqual(@as(u32, 0), zc.sheet.cellCount());
			try zc.deleteCell(); // Delete with no cell
			try t.expectEqual(@as(u32, 0), zc.sheet.cellCount());
		}
	};

	try t.checkAllAllocationFailures(t.allocator, Test.testAllocs, .{});
}
