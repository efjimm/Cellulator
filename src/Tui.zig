const std = @import("std");
const spoon = @import("spoon");
const ZC = @import("ZC.zig");
const Sheet = @import("Sheet.zig");

const Position = Sheet.Position;
const Term = spoon.Term;

term: Term,

update_status: bool = true,
update_command: bool = true,
update_column_headings: bool = true,
update_row_numbers: bool = true,
update_cells: bool = true,
update_cursor: bool = true,

const Self = @This();
const RenderContext = Term.RenderContext(8192);

pub const InitError = Term.InitError || Term.UncookError || error{ OperationNotSupported };

var needs_resize = false;

fn resizeHandler(_: c_int) callconv(.C) void {
	needs_resize = true;
}

pub fn init() InitError!Self {
	try std.os.sigaction(std.os.SIG.WINCH, &.{
		.handler = .{ .handler = resizeHandler, },
		.mask = std.os.empty_sigset,
		.flags = std.os.SA.RESTART,
	}, null);

	return Self{
		.term = blk: {
			var term = try Term.init(.{});
			try term.uncook(.{});
			try term.fetchSize();

			break :blk term;
		},
	};
}

pub fn deinit(self: *Self) void {
	self.term.deinit();
	self.* = undefined;
}

pub const RenderError = Term.WriteError;

pub fn render(self: *Self, zc: *ZC) RenderError!void {
	if (needs_resize)
		try self.term.fetchSize();

	var rc = try self.term.getRenderContext(8192);
	try rc.hideCursor();

	if (self.term.width < 15 or self.term.height < 5) {
		try rc.writeAllWrapping("Terminal too small");
		return;
	}

	if (self.update_status) {
		try self.renderStatus(&rc, zc);
		self.update_status = false;
	}
	if (self.update_command or zc.mode == .command) {
		try self.renderCommand(&rc, zc);
		self.update_command = false;
	}
	if (self.update_column_headings) {
		try self.renderColumnHeadings(&rc, zc.*);
		self.update_column_headings = false;
	}
	if (self.update_row_numbers) {
		try self.renderRowNumbers(&rc, zc);
		self.update_row_numbers = false;
	}
	if (self.update_cells) {
		try self.renderRows(&rc, zc);
		try renderCursor(&rc, zc);
		self.update_cells = false;
		self.update_cursor = false;
	} else if (self.update_cursor) {
		try renderCursor(&rc, zc);
		self.update_cursor = false;
	}

	try rc.setStyle(.{});

	try rc.done();
}
pub fn renderStatus(
	self: Self,
	rc: *RenderContext,
	zc: *ZC,
) RenderError!void {
	try rc.moveCursorTo(ZC.status_line, 0);
	try rc.hideCursor();

	var rpw = rc.restrictedPaddingWriter(self.term.width);
	const writer = rpw.writer();

	try zc.cursor.writeCellAddress(writer);
	try writer.print(" {}", .{ zc.mode });

	try rpw.pad();
}

pub fn renderCommand(
	self: Self,
	rc: *RenderContext,
	zc: *ZC,
) RenderError!void {
	try rc.moveCursorTo(ZC.input_line, 0);
	try rc.clearToEol();

	if (zc.mode == .command) {
		const writer = rc.buffer.writer();
		try writer.writeAll(zc.command_buf.slice());
		try rc.showCursor();
	} else {
		var rpw = rc.restrictedPaddingWriter(self.term.width);
		const writer = rpw.writer();

		try writer.writeAll(zc.status_message.slice());
		try rpw.finish();
	}
}

pub fn renderColumnHeadings(
	self: Self,
	rc: *Term.RenderContext(8192),
	zc: ZC,
) RenderError!void {
	const writer = rc.buffer.writer();

	const reserved_cols = zc.leftReservedColumns();
	try rc.moveCursorTo(ZC.col_heading_line, reserved_cols);
	try rc.clearToBol();

	var x = zc.screen_pos.x;
	var w = reserved_cols;
	const columns = &zc.sheet.columns;

	try rc.setStyle(.{ .fg = .blue });

	while (w < self.term.width) : (x +|= 1) {
		const width = if (columns.get(x)) |col|
				col.width
			else
				Sheet.Column.default_width;

		var buf: [4]u8 = undefined;
		const name = Position.columnAddressBuf(x, &buf);

		if (x == zc.cursor.x) {
			try rc.setStyle(.{ .fg = .black, .bg = .blue });
			try writer.print("{s: ^[1]}", .{ name, width });
			try rc.setStyle(.{ .fg = .blue, .bg = .black });
		} else {
			try writer.print("{s: ^[1]}", .{ name, width });
		}

		w += width;
	}

	try rc.setStyle(.{});
}

pub fn renderRowNumbers(self: Self, rc: *RenderContext, zc: *ZC) RenderError!void {
	const width = zc.leftReservedColumns();
	try rc.setStyle(.{ .fg = .blue, .bg = .black });

	try rc.moveCursorTo(ZC.col_heading_line, 0);
	try rc.buffer.writer().writeByteNTimes(' ', width);

	for (ZC.content_line..self.term.height, zc.screen_pos.y..) |screen_line, sheet_line| {
		try rc.moveCursorTo(@intCast(u16, screen_line), 0);

		if (zc.cursor.y == sheet_line)
			try rc.setStyle(.{ .fg = .black, .bg = .blue });

		var rpw = rc.restrictedPaddingWriter(width);
		const writer = rpw.writer();

		try writer.print("{d: ^[1]}", .{ sheet_line, width });

		try rpw.pad();

		if (zc.cursor.y == sheet_line)
			try rc.setStyle(.{ .fg = .blue, .bg = .black });
	}
}

pub fn renderCursor(
	rc: *RenderContext,
	zc: *ZC,
) RenderError!void {
	var buf: [16]u8 = undefined;

	try rc.setStyle(.{});
	const left = zc.leftReservedColumns();
	const writer = rc.buffer.writer();

	// Overrwrite old cursor with a normal looking cell. Also overwrites the old column heading and
	// line number.
	const prev_pos = Position{
		.y = zc.prev_cursor.y - zc.screen_pos.y + ZC.content_line,
		.x = blk: {
			var x: u16 = left;
			for (zc.screen_pos.x..zc.prev_cursor.x) |i| {
				const col = zc.sheet.getColumn(@intCast(u16, i));
				x += col.width;
			}
			break :blk x;
		},
	};

	try rc.moveCursorTo(prev_pos.y, prev_pos.x);
	_ = try renderCell(rc, zc, zc.prev_cursor);

	try rc.setStyle(.{ .fg = .blue, .bg = .black });

	const prev_col = zc.sheet.getColumn(zc.prev_cursor.x);

	try rc.moveCursorTo(ZC.col_heading_line, prev_pos.x);
	try writer.print("{s: ^[1]}", .{
		Position.columnAddressBuf(zc.prev_cursor.x, &buf),
		prev_col.width,
	});

	try rc.moveCursorTo(prev_pos.y, 0);
	try writer.print("{d: ^[1]}", .{ zc.prev_cursor.y, left });


	// Render the cells and headings at the current cursor position with a specific colour.
	try rc.setStyle(.{ .fg = .black, .bg = .blue });

	const pos = Position{
		.y = zc.cursor.y - zc.screen_pos.y + ZC.content_line,
		.x = blk: {
			var x: u16 = left;
			for (zc.screen_pos.x..zc.cursor.x) |i| {
				const col = zc.sheet.getColumn(@intCast(u16, i));
				x += col.width;
			}
			break :blk x;
		},
	};
	try rc.moveCursorTo(pos.y, pos.x);
	_ = try renderCell(rc, zc, zc.cursor);

	const col = zc.sheet.getColumn(pos.x);
	try rc.moveCursorTo(ZC.col_heading_line, pos.x);
	try writer.print("{s: ^[1]}", .{
		Position.columnAddressBuf(zc.cursor.x, &buf),
		col.width,
	});

	try rc.moveCursorTo(pos.y, 0);
	try writer.print("{d: ^[1]}", .{ zc.cursor.y, left });
}

pub fn renderRows(
	self: Self,
	rc: *RenderContext,
	zc: *ZC,
) RenderError!void {
	const reserved_cols = zc.leftReservedColumns();
	const width = self.term.width - reserved_cols;

	try rc.setStyle(.{});

	for (ZC.content_line..self.term.height, zc.screen_pos.y..) |line, y| {
		try rc.moveCursorTo(@intCast(u16, line), reserved_cols);

		var w: u16 = 0;
		for (zc.screen_pos.x..std.math.maxInt(u16)) |x| {
			w += try renderCell(rc, zc, Position{ .y = @intCast(u16, y), .x = @intCast(u16, x) });
			if (w >= width)
				break;
		}
	}
}

pub fn renderCell(
	rc: *RenderContext,
	zc: *ZC,
	pos: Position,
) RenderError!u16 {
	const col = zc.sheet.getColumn(pos.x);
	const num_optional = if (zc.sheet.getCellPtr(pos)) |cell|
			cell.getValue(&zc.sheet)
		else
			null;

	var rpw = rc.restrictedPaddingWriter(col.width);
	const writer = rpw.writer();
	
	var buf: [256]u8 = undefined;
	if (num_optional) |num| {
		const slice = buf[0..col.width];
		const text = std.fmt.bufPrint(slice, "{d: >[1].[2]}", .{
			num, col.width, col.precision
		}) catch slice;

		try writer.writeAll(text);
	} else {
		try writer.print("{s: >[1]}", .{ "", col.width });
	}

	try rpw.finish();

	return col.width;
}
