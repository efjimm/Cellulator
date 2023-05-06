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
		self: Mode,
		comptime _: []const u8,
		_: std.fmt.FormatOptions,
		writer: anytype,
	) !void {
		const name = inline for (std.meta.fields(Mode)) |field| {
			const val = comptime std.meta.stringToEnum(Mode, field.name);
			if (self == val)
				break field.name;
		} else unreachable;

		try writer.writeAll(name);
	}
};

pub fn init(allocator: Allocator, filepath_opt: ?[]const u8) !Self {
	var ret = Self{
		.sheet = Sheet.init(allocator),
		.tui = try Tui.init(),
		.allocator = allocator,
		.asts = try std.ArrayListUnmanaged(Ast).initCapacity(allocator, 8),
	};

	if (filepath_opt) |filepath| {
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

	try switch (self.mode) {
		.normal => self.doNormalMode(slice),
		.command => self.doCommandMode(slice) catch |err| switch (err) {
			error.UnexpectedToken => self.setStatusMessage("Error: unexpected token", .{}),
			error.InvalidCommand => self.setStatusMessage("Error: invalid command", .{}),
			error.EmptyFileName => self.setStatusMessage("Error: must specify a file name", .{}),
			error.FileNotFound => self.setStatusMessage("Error: file not found", .{}),
			else => return err,
		},
	};
}

fn doNormalMode(self: *Self, buf: []const u8) !void {
	var iter = spoon.inputParser(buf);

	while (iter.next()) |in| {
		if (!in.mod_ctrl)  switch (in.content) {
			.escape => self.dismissStatusMessage(),
			.codepoint => |cp| switch (cp) {
				':' => {
					self.setMode(.command);
					const writer = self.command_buf.writer();
					writer.writeByte(':') catch unreachable;
				},
				'D', 'x' => try self.deleteCell(),
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

			if (str.len > 0 and str[0] == ':') {
				return self.runCommand(str[1..]);
			}

			var ast = self.newAst();
			try ast.parse(self.allocator, str);
			errdefer self.asts.appendAssumeCapacity(ast);

			const root = ast.rootNode();
			switch (root) {
				.assignment => |op| {
					const pos = ast.nodes.items(.data)[op.lhs].cell;
					ast.splice(op.rhs);

					try self.sheet.setCell(pos, .{ .ast = ast });
					self.tui.update.cursor = true;
					self.tui.update.cells = true;
				},
				else => {
					ast.deinit(self.allocator);
				},
			}
		},
	}
}

pub fn runCommand(self: *Self, str: []const u8) !void {
	var iter = utils.wordIterator(str);
	const cmd = iter.next() orelse return error.InvalidCommand;
	if (cmd.len == 0) return error.InvalidCommand;

	// TODO: add confirmation for certain commands
	switch (cmd[0]) {
		'q' => self.running = false,
		'w' => { // save
			try writeFile(&self.sheet, .{ .filepath = iter.next() });
			self.tui.update.status = true;
		},
		'e' => { // load
			const filepath = iter.next() orelse return error.EmptyFileName;
			try self.clearSheet(&self.sheet);
			try self.loadFile(&self.sheet, filepath);
			self.tui.update.status = true;
			self.tui.update.cells = true;
		},
		else => return error.InvalidCommand,
	}
}

pub fn clearSheet(self: *Self, sheet: *Sheet) Allocator.Error!void {
	for (sheet.cells.values()) |cell| {
		try self.delAst(cell.ast);
	}
	sheet.cells.clearRetainingCapacity();
}

pub fn loadFile(self: *Self, sheet: *Sheet, filepath: []const u8) !void {
	const file = try std.fs.cwd().openFile(filepath, .{});
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
	if (self.cursor.y < self.screen_pos.y) {
		self.screen_pos.y = self.cursor.y;
		self.tui.update.row_numbers = true;
		self.tui.update.cells = true;
		return;
	}

	const height = self.contentHeight();
	if (self.cursor.y - self.screen_pos.y >= height) {
		self.screen_pos.y = self.cursor.y - (height -| 1);
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

	const reserved_cols = self.leftReservedColumns();

	var w = reserved_cols;
	var x: i17 = self.cursor.x;

	while (true) : (x -= 1) {
		if (x < self.screen_pos.x)
			return;

		const width = blk: {
			if (x >= 0) {
				if (self.sheet.columns.get(@intCast(u16, x))) |col| {
					break :blk col.width;
				}
			}

			break :blk Sheet.Column.default_width;
		};

		w += width;

		if (w > self.tui.term.width)
			break;
	}

	if (x >= self.screen_pos.x) {
		self.screen_pos.x = @intCast(u16, @max(0, x + 1));
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
	try self.asts.append(self.allocator, ast);
}
