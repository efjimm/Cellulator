const std = @import("std");
const utils = @import("utils.zig");
const spoon = @import("spoon");
const Sheet = @import("Sheet.zig");
const Tui = @import("Tui.zig");
const TextInput = @import("text_input.zig").TextInput;

const Allocator = std.mem.Allocator;

const Self = @This();

sheet: Sheet,
tui: Tui,

mode: Mode = .normal,

/// The top left corner of the screen
screen_pos: Pos = .{},

// The cell position of the cursor
cursor: Pos = .{},

running: bool = true,

allocator: Allocator,

command_buf: TextInput(1024) = .{},

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

const Pos = struct {
	x: u16 = 0,
	y: u16 = 0,
};

pub fn init(allocator: Allocator) !Self {
	return .{
		.sheet = Sheet.init(),
		.tui = try Tui.init(),
		.allocator = allocator,
	};
}

pub fn deinit(self: *Self) void {
	self.sheet.deinit(self.allocator);
	self.tui.deinit();
	self.* = undefined;
}

pub fn run(self: *Self) !void {
	while (self.running) {
		self.clampScreenToCursor();

		try self.tui.render(self);
		try self.handleInput();
	}
}

fn handleInput(self: *Self) !void {
	var buf: [16]u8 = undefined;
	const slice = try self.tui.term.readInput(&buf);

	try switch (self.mode) {
		.normal => self.doNormalMode(slice),
		.command => self.doCommandMode(slice),
	};
}

fn doNormalMode(self: *Self, buf: []const u8) !void {
	var iter = spoon.inputParser(buf);

	while (iter.next()) |in| {
		switch (in.content) {
			.escape => self.running = false,
			.codepoint => |cp| switch (cp) {
				'g' => self.mode = .command,
				'f' => {
					if (self.sheet.columns.getPtr(self.cursor.x)) |col| {
						col.precision +|= 1;
					}
				},
				'F' => {
					if (self.sheet.columns.getPtr(self.cursor.x)) |col| {
						col.precision -|= 1;
					}
				},
				'j' => self.cursor.y +|= 1,
				'J' => self.cursor.y *|= 10,
				'L' => self.cursor.x *|= 26,
				'k' => self.cursor.y -|= 1,
				'l' => self.cursor.x +|= 1,
				'h' => self.cursor.x -|= 1,
				'=' => {
					self.mode = .command;
					self.command_buf.array.append('=') catch unreachable;
				},
				else => {},
			},
			else => {},
		}
	}
}

fn doCommandMode(self: *Self, input: []const u8) !void {
	const status = try self.command_buf.handleInput(input);
	switch (status) {
		.waiting => {},
		.cancelled => self.mode = .normal,
		.string => |arr| {
			defer self.mode = .normal;
			const str = arr.slice();

			if (str.len == 0)
				return;

			switch (str[0]) {
				'=' => {

					const num = std.fmt.parseFloat(f64, str[1..]) catch return;
					try self.sheet.setCell(self.allocator, self.cursor.y, self.cursor.x, num);
				},
				else => {},
			}
		},
	}
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

pub fn columnIndexToName(index: u16, buf: []u8) []const u8 {
	if (index < 26) {
		std.debug.assert(buf.len >= 1);
		buf[0] = 'A' + @intCast(u8, index);
		return buf[0..1];
	}

	var stream = std.io.fixedBufferStream(buf);
	const writer = stream.writer();

	var i = index +| 1;
	while (i > 0) : (i /= 26) {
		i -= 1;
		const r = @intCast(u8, i % 26);
		writer.writeByte('A' + r) catch break;
	}

	const slice = stream.getWritten();
	std.mem.reverse(u8, slice);
	return slice;
}

pub fn posToCellName(y: u16, x: u16, buf: []u8) []const u8 {
	var _buf: [16]u8 = undefined;
	const col_name = columnIndexToName(x, &_buf);

	return std.fmt.bufPrint(buf, "{s}{d}", .{ col_name, y }) catch return "";
}

pub fn cursorUp(self: *Self) void {
	self.cursor.y -|= 1;
}

pub fn clampScreenToCursor(self: *Self) void {
	self.clampScreenToCursorY();
	self.clampScreenToCursorX();
}

pub fn clampScreenToCursorY(self: *Self) void {
	if (self.cursor.y < self.screen_pos.y) {
		self.screen_pos.y = self.cursor.y;
		return;
	}

	const height = self.contentHeight();
	if (self.cursor.y - self.screen_pos.y >= height) {
		self.screen_pos.y = self.cursor.y - (height -| 1);
	}
}

pub fn clampScreenToCursorX(self: *Self) void {
	if (self.cursor.x < self.screen_pos.x) {
		self.screen_pos.x = self.cursor.x;
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
	}
}
