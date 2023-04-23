const std = @import("std");
const utils = @import("utils.zig");
const spoon = @import("spoon");
const ZC = @import("ZC.zig");
const Sheet = @import("Sheet.zig");

const Position = ZC.Position;
const Term = spoon.Term;

term: Term,
status_message: std.BoundedArray(u8, 256) = .{},

const Self = @This();

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

pub fn setStatusMessage(self: *Self, comptime fmt: []const u8, args: anytype) void {
	self.dismissStatusMessage();
	const writer = self.status_message.writer();
	writer.print(fmt, args) catch {};
}

pub fn dismissStatusMessage(self: *Self) void {
	self.status_message.len = 0;
}

pub fn render(self: *Self, zc: *ZC) RenderError!void {
	if (needs_resize)
		try self.term.fetchSize();

	var rc = try self.term.getRenderContext(8192);
	defer rc.done() catch {};

	try rc.hideCursor();
	try rc.clear();
	try rc.moveCursorTo(0, 0);

	const writer = rc.buffer.writer();

	if (self.term.width < 10 or self.term.height < 4) {
		try writer.writeAll("Terminal too small");
		return;
	}

	var buf: [64]u8 = undefined;
	try writer.writeAll(utils.posToCellName(zc.cursor.y, zc.cursor.x, &buf));

	try writer.print(" {}", .{ zc.mode });

	try self.renderColumnHeadings(&rc, zc.*);
	try self.renderRows(&rc, zc);

	try rc.moveCursorTo(ZC.input_line, 0);
	if (zc.mode == .command) {
		try rc.showCursor();
		try writer.writeAll(zc.command_buf.slice());
	} else {
		var rpw = rc.restrictedPaddingWriter(self.term.width);
		defer rpw.finish() catch {};
		const truncating_writer = rpw.writer();

		try truncating_writer.writeAll(self.status_message.slice());
	}
}

fn renderColumnHeadings(
	self: Self,
	rc: *Term.RenderContext(8192),
	zc: ZC,
) RenderError!void {
	const writer = rc.buffer.writer();

	const reserved_cols = zc.leftReservedColumns();
	try rc.moveCursorTo(ZC.col_heading_line, reserved_cols);

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
		const name = utils.columnIndexToNameBuf(x, &buf);

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

fn renderRows(
	self: Self,
	rc: *Term.RenderContext(8192),
	zc: *ZC,
) RenderError!void {
	const reserved_cols = zc.leftReservedColumns();

	// Loop over rows
	for (ZC.content_line..self.term.height, zc.screen_pos.y..) |line, y| {
		try rc.moveCursorTo(@intCast(u16, line), 0);

		var rpw = rc.restrictedPaddingWriter(self.term.width + 1);
		defer rpw.finish() catch {};

		const writer = rpw.writer();

		if (y == zc.cursor.y)
			try rc.setStyle(.{ .fg = .black, .bg = .blue })
		else
			try rc.setStyle(.{ .fg = .blue, .bg = .black });

		// Renders row number
		try writer.print("{d: >[1]} ", .{ y, reserved_cols - 1 });

		try rc.setStyle(.{});

		// Loop over columns
		var x = zc.screen_pos.x;
		while (true) : (x +|= 1) {
			if (y == zc.cursor.y and x == zc.cursor.x)
				try rc.setStyle(.{ .fg = .black, .bg = .blue });

			const col = zc.sheet.getColumn(x);
			if (rpw.width_left < col.width)
				break;

			const pos = Position{ .y = @intCast(u16, y), .x = x };
			const num_optional = if (zc.sheet.getCellPtr(pos)) |cell|
					cell.getValue(&zc.sheet)
				else
					null;
			
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

			if (y == zc.cursor.y and x == zc.cursor.x)
				try rc.setStyle(.{});
		}
	}
}
