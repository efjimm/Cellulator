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

normal_keys: KeyMap,
command_normal_keys: CommandKeyMap,
command_insert_keys: CommandKeyMap,
command_operator_keys: CommandKeyMap,

allocator: Allocator,

input_buf: std.BoundedArray(u8, 64) = .{},
command_buf: TextInput(512) = .{},
status_message: std.BoundedArray(u8, 256) = .{},

pub const status_line = 0;
pub const input_line = 1;
pub const col_heading_line = 2;
pub const content_line = 3;

const KeyMap = critbit.CritBitMap([]const u8, Action, critbit.StringContext);
const CommandKeyMap = critbit.CritBitMap([]const u8, CommandAction, critbit.StringContext);

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
	var ast_list = try std.ArrayListUnmanaged(Ast).initCapacity(allocator, 8);
	errdefer ast_list.deinit(allocator);

	var normal_keys = KeyMap.init();
	errdefer normal_keys.deinit(allocator);

	for (default_normal_keys) |mapping| {
		try normal_keys.put(allocator, mapping[0], mapping[1]);
	}

	var command_normal_keys = CommandKeyMap.init();
	errdefer command_normal_keys.deinit(allocator);

	for (default_command_normal_keys) |mapping| {
		try command_normal_keys.put(allocator, mapping[0], mapping[1]);
	}

	var command_insert_keys = CommandKeyMap.init();
	errdefer command_insert_keys.deinit(allocator);

	for (default_command_insert_keys) |mapping| {
		try command_insert_keys.put(allocator, mapping[0], mapping[1]);
	}

	var command_operator_keys = CommandKeyMap.init();
	errdefer command_operator_keys.deinit(allocator);

	for (default_command_operator_keys) |mapping| {
		try command_operator_keys.put(allocator, mapping[0], mapping[1]);
	}

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
		.normal_keys = normal_keys,
		.command_normal_keys = command_normal_keys,
		.command_insert_keys = command_insert_keys,
		.command_operator_keys = command_operator_keys,
	};

	if (options.filepath) |filepath| {
		try ret.loadFile(&ret.sheet, filepath);
	}

	return ret;
}

pub fn deinit(self: *Self) void {
	for (self.asts.items) |*ast| {
		ast.deinit(self.allocator);
	}

	self.normal_keys.deinit(self.allocator);
	self.command_normal_keys.deinit(self.allocator);
	self.command_insert_keys.deinit(self.allocator);
	self.command_operator_keys.deinit(self.allocator);

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

	const writer = self.input_buf.writer();
	parseInput(slice, writer) catch unreachable;

	switch (self.mode) {
		.normal => self.normalMode(),
		.command => self.commandMode() catch |err| {
			self.setStatusMessage("Error: {s}", .{ @errorName(err) });
		},
	}
}

fn commandMode(self: *Self) !void {
	const input = self.input_buf.slice();
	const keys = switch (self.command_buf.mode) {
		.normal => &self.command_normal_keys,
		.insert => &self.command_insert_keys,
		.operator_pending => &self.command_operator_keys,
	};

	if (keys.get(input)) |action| {
		self.input_buf.len = 0;
		const status = self.command_buf.do(action);
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
	} else if (!keys.contains(input)) {
		if (self.command_buf.mode == .insert) {
			var buf: [64]u8 = undefined;
			const len = std.mem.replacementSize(u8, input, "<<", "<");
			_ = std.mem.replace(u8, input, "<<", "<", &buf);
			_ = self.command_buf.do(.{ .insert = buf[0..len] });
		}
		self.input_buf.len = 0;
	}
}

fn normalMode(self: *Self) void {
	const input = self.input_buf.slice();
	if (self.normal_keys.get(input)) |action| {
		switch (action) {
			.enter_command_mode => {
				self.setMode(.command);
				const writer = self.command_buf.writer();
				writer.writeByte(':') catch unreachable;
			},
			.dismiss_status_message => self.dismissStatusMessage(),

			.cell_cursor_up => self.setCursor(.{ .y = self.cursor.y -| 1, .x = self.cursor.x }),
			.cell_cursor_down => self.setCursor(.{ .y = self.cursor.y +| 1, .x = self.cursor.x }),
			.cell_cursor_left => self.setCursor(.{ .y = self.cursor.y, .x = self.cursor.x -| 1 }),
			.cell_cursor_right => self.setCursor(.{ .y = self.cursor.y, .x = self.cursor.x +| 1 }),
			.cell_cursor_row_first => self.cursorToFirstCellInColumn(),
			.cell_cursor_row_last => self.cursorToLastCellInColumn(),
			.cell_cursor_col_first => self.cursorToFirstCell(),
			.cell_cursor_col_last => self.cursorToLastCell(),

			.delete_cell => self.deleteCell() catch |err| switch (err) {
				error.OutOfMemory => self.setStatusMessage("Error: out of memory!", .{}),
			},
			.next_populated_cell => {
				const positions = self.sheet.cells.keys();
				for (positions) |pos| {
					if (pos.hash() > self.cursor.hash()) {
						self.setCursor(pos);
						break;
					}
				}
			},
			.prev_populated_cell => {
				const positions = self.sheet.cells.keys();
				var pos_iter = std.mem.reverseIterator(positions);
				while (pos_iter.next()) |pos| {
					if (pos.hash() < self.cursor.hash()) {
						self.setCursor(pos);
						break;
					}
				}
			},
			.increase_precision => self.incPrecision(self.cursor.x, 1),
			.decrease_precision => self.decPrecision(self.cursor.x, 1),
			.increase_width => self.incWidth(self.cursor.x, 1),
			.decrease_width => self.decWidth(self.cursor.x, 1),
			.assign_cell => {
				self.setMode(.command);
				const writer = self.command_buf.writer();
				self.cursor.writeCellAddress(writer) catch unreachable;
				writer.writeAll(" = ") catch unreachable;
			},
		}
		self.input_buf.len = 0;
	} else if (!self.normal_keys.contains(input)) {
		self.input_buf.len = 0;
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
					const len = std.unicode.utf8Encode(cp, &buf) catch unreachable;
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

pub const Action = enum {
	enter_command_mode,
	dismiss_status_message,

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
};

const Mapping = struct {
	[]const u8,
	Action,
};

const default_normal_keys = [_]Mapping{
	.{ "+", .increase_width },
	.{ "-", .decrease_width },
	.{ "f", .increase_precision },
	.{ "F", .decrease_precision },
	.{ "j", .cell_cursor_down },
	.{ "k", .cell_cursor_up },
	.{ "h", .cell_cursor_left },
	.{ "l", .cell_cursor_right },
	.{ "w", .next_populated_cell },
	.{ "b", .prev_populated_cell },
	.{ "gg", .cell_cursor_row_first },
	.{ "G", .cell_cursor_row_last },
	.{ "0", .cell_cursor_col_first },
	.{ "$", .cell_cursor_col_last },
	.{ "=", .assign_cell },
	.{ "dd", .delete_cell },
	.{ "x", .delete_cell },
	.{ "<Escape>", .dismiss_status_message },
	.{ ":", .enter_command_mode },
};

const CommandMapping = struct {
	[]const u8,
	CommandAction,
};

const default_command_normal_keys = [_]CommandMapping{
	.{ "1", .{ .count = 1 } },
	.{ "2", .{ .count = 2 } },
	.{ "3", .{ .count = 3 } },
	.{ "4", .{ .count = 4 } },
	.{ "5", .{ .count = 5 } },
	.{ "6", .{ .count = 6 } },
	.{ "7", .{ .count = 7 } },
	.{ "8", .{ .count = 8 } },
	.{ "9", .{ .count = 9 } },

	.{ "<C-[>", .enter_normal_mode },
	.{ "<Escape>", .enter_normal_mode },

	.{ "<C-m>", .submit_command },
	.{ "<C-j>", .submit_command },
	.{ "<Return>", .submit_command },

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

	.{ "<Left>", .{ .motion = .char_prev } },
	.{ "<Right>", .{ .motion = .char_next } },
	.{ "<Home>", .{ .motion = .bol } },
	.{ "<End>", .{ .motion = .eol } },

	.{ "h", .{ .motion = .char_prev } },
	.{ "l", .{ .motion = .char_next } },
	.{ "0", .zero },
	.{ "$", .{ .motion = .eol } },
	.{ "w", .{ .motion = .normal_word_start_next } },
	.{ "W", .{ .motion = .long_word_start_next   } },
	.{ "e", .{ .motion = .normal_word_end_next   } },
	.{ "E", .{ .motion = .long_word_end_next     } },
	.{ "b", .{ .motion = .normal_word_start_prev } },
	.{ "B", .{ .motion = .long_word_start_prev   } },
	.{ "<M-e>", .{ .motion = .normal_word_end_prev } },
	.{ "<M-E>", .{ .motion = .long_word_end_prev } },
};

const default_command_insert_keys = [_]CommandMapping{
	.{ "<C-[>", .enter_normal_mode },
	.{ "<Escape>", .enter_normal_mode },

	.{ "<C-m>", .submit_command },
	.{ "<C-j>", .submit_command },
	.{ "<Return>", .submit_command },

	.{ "<C-h>", .backspace },
	.{ "<Delete>", .backspace },
	.{ "<C-u>", .change_line },

	.{ "<Home>", .{ .motion = .bol } },
	.{ "<End>", .{ .motion = .eol } },
	.{ "<Left>", .{ .motion = .char_prev } },
	.{ "<Right>", .{ .motion = .char_next } },

	.{ "<C-a>", .{ .motion = .bol } },
	.{ "<C-e>", .{ .motion = .eol } },
	.{ "<C-b>", .{ .motion = .char_prev } },
	.{ "<C-f>", .{ .motion = .char_next } },
	.{ "<C-w>", .backwards_delete_word },
};

const default_command_operator_keys = [_]CommandMapping{
	.{ "1", .{ .count = 1 } },
	.{ "2", .{ .count = 2 } },
	.{ "3", .{ .count = 3 } },
	.{ "4", .{ .count = 4 } },
	.{ "5", .{ .count = 5 } },
	.{ "6", .{ .count = 6 } },
	.{ "7", .{ .count = 7 } },
	.{ "8", .{ .count = 8 } },
	.{ "9", .{ .count = 9 } },

	.{ "<C-[>", .enter_normal_mode },
	.{ "<Escape>", .enter_normal_mode },
	.{ "d", .operator_delete },
	.{ "c", .operator_change },

	.{ "<Left>", .{ .motion = .char_prev } },
	.{ "<Right>", .{ .motion = .char_next } },
	.{ "<Home>", .{ .motion = .bol } },
	.{ "<End>", .{ .motion = .eol } },

	.{ "h", .{ .motion = .char_prev } },
	.{ "l", .{ .motion = .char_next } },
	.{ "0", .zero },
	.{ "$", .{ .motion = .eol } },
	.{ "w", .{ .motion = .normal_word_start_next } },
	.{ "W", .{ .motion = .long_word_start_next   } },
	.{ "e", .{ .motion = .normal_word_end_next   } },
	.{ "E", .{ .motion = .long_word_end_next     } },
	.{ "b", .{ .motion = .normal_word_start_prev } },
	.{ "B", .{ .motion = .long_word_start_prev   } },
	.{ "<M-e>", .{ .motion = .normal_word_end_prev } },
	.{ "<M-E>", .{ .motion = .long_word_end_prev } },

	.{ "aw", .{ .motion = .normal_word_around } },
	.{ "aW", .{ .motion = .long_word_around } },
	.{ "iw", .{ .motion = .normal_word_inside } },
	.{ "iW", .{ .motion = .long_word_inside } },

	.{ "a(", .{ .motion = .{ .around_delimiters = .{ .left = "(", .right = ")" } } } },
	.{ "i(", .{ .motion = .{ .inside_delimiters = .{ .left = "(", .right = ")" } } } },
	.{ "a)", .{ .motion = .{ .around_delimiters = .{ .left = "(", .right = ")" } } } },
	.{ "i)", .{ .motion = .{ .inside_delimiters = .{ .left = "(", .right = ")" } } } },

	.{ "a[", .{ .motion = .{ .around_delimiters = .{ .left = "[", .right = "]" } } } },
	.{ "i[", .{ .motion = .{ .inside_delimiters = .{ .left = "[", .right = "]" } } } },
	.{ "a]", .{ .motion = .{ .around_delimiters = .{ .left = "[", .right = "]" } } } },
	.{ "i]", .{ .motion = .{ .inside_delimiters = .{ .left = "[", .right = "]" } } } },

	.{ "i{", .{ .motion = .{ .inside_delimiters = .{ .left = "{", .right = "}" } } } },
	.{ "a{", .{ .motion = .{ .around_delimiters = .{ .left = "{", .right = "}" } } } },
	.{ "i}", .{ .motion = .{ .inside_delimiters = .{ .left = "{", .right = "}" } } } },
	.{ "a}", .{ .motion = .{ .around_delimiters = .{ .left = "{", .right = "}" } } } },

	.{ "i<<", .{ .motion = .{ .inside_delimiters = .{ .left = "<", .right = ">" } } } },
	.{ "a<<", .{ .motion = .{ .around_delimiters = .{ .left = "<", .right = ">" } } } },
	.{ "i>", .{ .motion = .{ .inside_delimiters = .{ .left = "<", .right = ">" } } } },
	.{ "a>", .{ .motion = .{ .around_delimiters = .{ .left = "<", .right = ">" } } } },

	.{ "i\"", .{ .motion = .{ .inside_single_delimiter = "\"" } } },
	.{ "a\"", .{ .motion = .{ .around_single_delimiter = "\"" } } },

	.{ "i'", .{ .motion = .{ .inside_single_delimiter = "'" } } },
	.{ "a'", .{ .motion = .{ .around_single_delimiter = "'" } } },

	.{ "i`", .{ .motion = .{ .inside_single_delimiter = "`" } } },
	.{ "a`", .{ .motion = .{ .around_single_delimiter = "`" } } },
};
