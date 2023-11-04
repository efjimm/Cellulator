const std = @import("std");
const spoon = @import("spoon");
const utils = @import("utils.zig");
const ZC = @import("ZC.zig");
const Sheet = @import("Sheet.zig");
const Position = @import("Position.zig").Position;
const PosInt = Position.Int;
const wcWidth = @import("wcwidth").wcWidth;
const assert = std.debug.assert;
const log = std.log.scoped(.tui);
const CellType = enum {
    number,
    string,
    err,
    blank,
};

const Term = spoon.Term;

term: Term,
update: UpdateFlags = .{},

const UpdateFlags = packed struct {
    command: bool = true,
    column_headings: bool = true,
    row_numbers: bool = true,
    cells: bool = true,
    cursor: bool = true,
};

const styles = blk: {
    const T = std.enums.EnumArray(CellType, [2]spoon.Style);
    var array = T.initUndefined();
    array.set(.number, .{
        .{ .fg = .white, .bg = .black },
        .{ .fg = .black, .bg = .blue },
    });
    array.set(.string, .{
        .{ .fg = .green, .bg = .black },
        .{ .fg = .black, .bg = .blue },
    });
    array.set(.err, .{
        .{ .fg = .red, .bg = .black },
        .{ .fg = .red, .bg = .blue },
    });
    array.set(.blank, .{
        .{ .fg = .white, .bg = .black },
        .{ .fg = .black, .bg = .blue },
    });
    assert(@typeInfo(CellType).Enum.fields.len == 4);
    break :blk array;
};

const Self = @This();
const RenderContext = Term.RenderContext(8192);

pub const InitError = Term.InitError || Term.UncookError || error{OperationNotSupported};

pub var needs_resize = true;

fn resizeHandler(_: c_int) callconv(.C) void {
    needs_resize = true;
}

pub fn init() InitError!Self {
    try std.os.sigaction(std.os.SIG.WINCH, &.{
        .handler = .{
            .handler = resizeHandler,
        },
        .mask = std.os.empty_sigset,
        .flags = 0,
    }, null);

    return Self{
        .term = blk: {
            var term = try Term.init(.{});

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
    if (needs_resize) {
        try self.term.fetchSize();
        zc.clampScreenToCursor();
        self.update = .{};
        needs_resize = false;
    }

    var rc = try self.term.getRenderContext(8192);
    rc.hideCursor() catch unreachable;

    if (self.term.width < 15 or self.term.height < 5) {
        rc.clear() catch unreachable;
        rc.moveCursorTo(0, 0) catch unreachable;
        rc.writeAllWrapping("Terminal too small") catch unreachable;
        try rc.done();
        return;
    }

    try self.renderStatus(&rc, zc);
    if (self.update.column_headings) {
        try self.renderColumnHeadings(&rc, zc.*);
        self.update.column_headings = false;
    }
    if (self.update.row_numbers) {
        try self.renderRowNumbers(&rc, zc);
        self.update.row_numbers = false;
    }
    if (self.update.cells) {
        try self.renderCells(&rc, zc);
        try renderCursor(&rc, zc);
        self.update.cells = false;
        self.update.cursor = false;
    } else if (self.update.cursor) {
        try renderCursor(&rc, zc);
        self.update.cursor = false;
    }
    if (self.update.command or zc.mode.isCommandMode()) {
        try renderCommandLine(&rc, zc);
        self.update.command = false;
    }

    try rc.setStyle(.{ .fg = .white, .bg = .black });

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

    const filepath = zc.sheet.getFilePath();
    if (filepath.len > 0) {
        try rc.setStyle(.{ .fg = .green, .bg = .black, .attrs = .{ .underline = true } });
        try writer.writeAll(filepath);
        try rc.setStyle(.{ .fg = .white, .bg = .black });
    } else {
        try rc.setStyle(.{ .fg = .white, .bg = .black });
        writer.writeAll("<no file>") catch unreachable;
    }

    if (zc.sheet.has_changes) {
        try writer.writeAll(" [+]");
    }

    try writer.print(" {}", .{zc.cursor});
    try writer.print(" {}", .{zc.mode});

    if (zc.count != 0) {
        try rc.setStyle(.{ .fg = .green, .bg = .black, .attrs = .{ .bold = true } });
        try writer.print(" {d}{s}", .{ zc.getCount(), zc.input_buf.items });
        try rc.setStyle(.{ .fg = .white, .bg = .black });
    } else if (zc.input_buf.items.len > 0) {
        try rc.setStyle(.{ .fg = .green, .bg = .black, .attrs = .{ .bold = true } });
        try writer.print(" {s}", .{zc.input_buf.items});
        try rc.setStyle(.{ .fg = .white, .bg = .black });
    }

    try writer.writeAll(" [");
    if (zc.sheet.getCell(zc.cursor)) |cell| {
        if (!cell.isError()) {
            try rc.setStyle(.{ .fg = .cyan, .bg = .black });
        } else {
            try rc.setStyle(.{ .fg = .red, .bg = .black });
        }
        try zc.sheet.printCellExpression(zc.cursor, writer);

        try rc.setStyle(.{ .fg = .white, .bg = .black });
    }
    try writer.writeByte(']');

    try rpw.pad();
}

pub fn renderCommandLine(
    rc: *RenderContext,
    zc: *ZC,
) RenderError!void {
    try rc.moveCursorTo(ZC.input_line, 0);
    try rc.clearToEol();
    var rpw = rc.restrictedPaddingWriter(rc.term.width);
    const writer = rpw.writer();
    try rc.setStyle(.{ .fg = .white, .bg = .black });

    if (zc.mode.isCommandMode()) {
        const left = zc.command.left();
        const left_len: u32 = @intCast(left.len);
        const right = zc.command.right();

        // TODO: don't write all of this, only write what fits on screen
        var i = zc.command_screen_pos;
        if (i < left_len) {
            try writer.writeAll(left[i..]);
            try writer.writeAll(right);
        } else {
            try writer.writeAll(right[i - left.len ..]);
        }

        const cursor_pos = blk: {
            var iter = utils.Utf8Iterator(@TypeOf(zc.command)){
                .data = zc.command,
                .index = zc.command_screen_pos,
            };
            var pos: u16 = 0;
            while (iter.nextCodepoint()) |cp| {
                if (iter.index > zc.command.cursor) break;
                pos += wcWidth(cp);
            }

            break :blk pos;
        };
        try rpw.finish();

        try rc.moveCursorTo(ZC.input_line, cursor_pos);
        switch (zc.mode) {
            .normal, .visual, .select => unreachable,
            .command_normal => try rc.setCursorShape(.block),
            .command_insert => try rc.setCursorShape(.bar),
            .command_to_forwards,
            .command_to_backwards,
            .command_until_forwards,
            .command_until_backwards,
            .command_change,
            .command_delete,
            => try rc.setCursorShape(.underline),
        }
        try rc.showCursor();
    } else if (zc.status_message.len > 0) {
        switch (zc.status_message_type) {
            .info => {
                try rc.setStyle(.{ .fg = .magenta, .bg = .black });
                try writer.writeAll("Info: ");
            },
            .warn => {
                try rc.setStyle(.{ .fg = .yellow, .bg = .black });
                try writer.writeAll("Warning: ");
            },
            .err => {
                try rc.setStyle(.{ .fg = .red, .bg = .black });
                try writer.writeAll("Error: ");
            },
        }
        try rc.setStyle(.{ .fg = .white, .bg = .black });
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

    try rc.setStyle(.{ .fg = .blue, .bg = .black });

    while (w < self.term.width) : (x += 1) {
        const width = @min(self.term.width - reserved_cols, zc.sheet.getColumn(x).width);

        var buf: [Position.max_str_len]u8 = undefined;
        const name = Position.columnAddressBuf(x, &buf);

        if (zc.isSelectedCol(x)) {
            try rc.setStyle(.{ .fg = .black, .bg = .blue });
            try writer.print("{s: ^[1]}", .{ name, width });
            try rc.setStyle(.{ .fg = .blue, .bg = .black });
        } else {
            try writer.print("{s: ^[1]}", .{ name, width });
        }

        if (x == std.math.maxInt(PosInt)) {
            try rc.clearToEol();
            break;
        }
        w += width;
    }

    try rc.setStyle(.{ .fg = .white, .bg = .black });
}

pub fn renderRowNumbers(self: Self, rc: *RenderContext, zc: *ZC) RenderError!void {
    const width = zc.leftReservedColumns();
    try rc.setStyle(.{ .fg = .blue, .bg = .black });

    try rc.moveCursorTo(ZC.col_heading_line, 0);
    try rc.buffer.writer().writeByteNTimes(' ', width);

    for (ZC.content_line..self.term.height, zc.screen_pos.y..) |screen_line, sheet_line| {
        try rc.moveCursorTo(@intCast(screen_line), 0);

        var rpw = rc.restrictedPaddingWriter(width);
        const writer = rpw.writer();

        if (zc.isSelectedRow(@intCast(sheet_line))) {
            try rc.setStyle(.{ .fg = .black, .bg = .blue });

            try writer.print("{d: ^[1]}", .{ sheet_line, width });
            try rpw.pad();

            try rc.setStyle(.{ .fg = .blue, .bg = .black });
        } else {
            try writer.print("{d: ^[1]}", .{ sheet_line, width });
            try rpw.pad();
        }
    }
}

pub fn renderCursor(
    rc: *RenderContext,
    zc: *ZC,
) RenderError!void {
    switch (zc.mode) {
        .visual, .select => return,
        else => {},
    }
    var buf: [Position.max_str_len]u8 = undefined;

    const left = zc.leftReservedColumns();
    const writer = rc.buffer.writer();

    if (isOnScreen(&zc.tui, zc, zc.prev_cursor)) {
        // Overrwrite old cursor with a normal looking cell. Also overwrites the old column heading
        // and line number.
        const prev_y: u16 = @intCast(zc.prev_cursor.y - zc.screen_pos.y + ZC.content_line);
        const prev_x = blk: {
            var x: u16 = left;
            for (zc.screen_pos.x..zc.prev_cursor.x) |i| {
                const col = zc.sheet.getColumn(@intCast(i));
                x += col.width;
            }
            break :blk x;
        };

        try rc.setStyle(.{ .fg = .white, .bg = .black });

        try rc.moveCursorTo(prev_y, prev_x);
        _ = try renderCell(rc, zc, zc.prev_cursor);

        try rc.setStyle(.{ .fg = .blue, .bg = .black });

        const col = zc.sheet.getColumn(zc.prev_cursor.x);
        const width = @min(col.width, rc.term.width - left);

        try rc.moveCursorTo(ZC.col_heading_line, prev_x);
        try writer.print("{s: ^[1]}", .{
            Position.columnAddressBuf(zc.prev_cursor.x, &buf),
            width,
        });

        try rc.moveCursorTo(prev_y, 0);
        try writer.print("{d: ^[1]}", .{ zc.prev_cursor.y, left });
    }

    const y: u16 = @intCast(zc.cursor.y - zc.screen_pos.y + ZC.content_line);
    const x = blk: {
        assert(zc.screen_pos.x <= zc.cursor.x);

        var x: u16 = left;
        for (zc.screen_pos.x..zc.cursor.x) |i| {
            const col = zc.sheet.getColumn(@intCast(i));
            x += col.width;
        }
        break :blk x;
    };

    // Render the cells and headings at the current cursor position with a specific colour.
    try rc.moveCursorTo(y, x);
    _ = try renderCell(rc, zc, zc.cursor);
    try rc.setStyle(.{ .fg = .black, .bg = .blue });

    const col = zc.sheet.getColumn(zc.cursor.x);
    const width = @min(col.width, rc.term.width - left);
    try rc.moveCursorTo(ZC.col_heading_line, x);
    try writer.print("{s: ^[1]}", .{
        Position.columnAddressBuf(zc.cursor.x, &buf),
        width,
    });

    try rc.moveCursorTo(y, 0);
    try writer.print("{d: ^[1]}", .{ zc.cursor.y, left });
    try rc.setStyle(.{ .fg = .white, .bg = .black });
}

fn isSelected(zc: ZC, pos: Position) bool {
    return pos.hash() == zc.cursor.hash() or switch (zc.mode) {
        .visual, .select => pos.intersects(zc.anchor, zc.cursor),
        else => false,
    };
}

pub fn renderCells(
    self: Self,
    rc: *RenderContext,
    zc: *ZC,
) RenderError!void {
    const reserved_cols = zc.leftReservedColumns();

    try rc.setStyle(.{ .fg = .white, .bg = .black });

    for (ZC.content_line..self.term.height, zc.screen_pos.y..) |line, y| {
        try rc.moveCursorTo(@intCast(line), reserved_cols);

        var w = reserved_cols;
        for (zc.screen_pos.x..@as(Position.HashInt, std.math.maxInt(Position.Int)) + 1) |x| {
            const pos = Position{ .y = @intCast(y), .x = @intCast(x) };
            w += try renderCell(rc, zc, pos);
            if (w >= self.term.width) break;
        } else {
            // Hit maxInt(Position.Int) and didn't go past the end of the screen, so we clear the
            // rest of the line to remove any artifacts
            try rc.setStyle(.{ .fg = .white, .bg = .black });
            try rc.clearToEol();
        }
    }
}

pub fn renderCell(
    rc: *RenderContext,
    zc: *ZC,
    pos: Position,
) RenderError!u16 {
    const selected = isSelected(zc.*, pos);

    const col = zc.sheet.columns.get(pos.x) orelse {
        // No cells in this column, render blank cell
        try rc.setStyle(styles.get(.blank)[@intFromBool(selected)]);
        const width = Sheet.Column.default_width;
        try rc.buffer.writer().writeByteNTimes(' ', width);
        return width;
    };

    const width = getColWidth: {
        var width: u16 = 0;
        for (zc.screen_pos.x..pos.x) |x| {
            const c = zc.sheet.getColumn(@intCast(x));
            width += c.width;
        }
        const screen_width = rc.term.width - zc.leftReservedColumns();
        break :getColWidth @min(col.width, screen_width - width);
    };

    var rpw = rc.restrictedPaddingWriter(width);
    const writer = rpw.writer();

    if (zc.sheet.getCell(pos)) |cell| {
        const tag: CellType = @enumFromInt(@intFromEnum(cell.value));
        try rc.setStyle(styles.get(tag)[@intFromBool(selected)]);

        switch (cell.value) {
            .number => |num| {
                try writer.print("{d: >[1].[2]}", .{
                    num, width, col.precision,
                });
                try rpw.pad();
            },
            .string => |ptr| {
                const text = std.mem.span(ptr);
                const text_width = utils.strWidth(text, width);
                const left_pad = (width - text_width) / 2;
                try writer.writeByteNTimes(' ', left_pad);
                if (cell.isError()) {
                    if (pos.hash() == zc.cursor.hash()) {
                        try writer.writeAll(text);
                        try rpw.pad();
                    } else {
                        try writer.writeAll(text);
                        try rpw.pad();
                    }
                } else if (pos.hash() != zc.cursor.hash()) {
                    try writer.writeAll(text);
                    try rpw.pad();
                } else {
                    try writer.writeAll(text);
                    try rpw.pad();
                }
            },
            .err => {
                try writer.print("{s: >[1]}", .{ "ERROR", width });
                try rpw.pad();
            },
        }
    } else {
        try rc.setStyle(styles.get(.blank)[@intFromBool(selected)]);
        try writer.print("{s: >[1]}", .{ "", width });
        try rpw.pad();
    }
    return width;
}

pub fn isOnScreen(tui: *Self, zc: *ZC, pos: Position) bool {
    if (pos.x < zc.screen_pos.x or pos.y < zc.screen_pos.y)
        return false;

    var w = zc.leftReservedColumns();
    const end_col = blk: {
        var i = zc.screen_pos.x;
        while (true) : (i += 1) {
            const col = zc.sheet.getColumn(i);
            w += col.width;
            if (w >= tui.term.width or i == std.math.maxInt(Position.Int))
                break :blk i;
        }
        unreachable;
    };
    if (w >= tui.term.width and pos.x > end_col) return false;

    const end_row = zc.screen_pos.y +| (tui.term.height - ZC.content_line);
    return pos.y <= end_row;
}
