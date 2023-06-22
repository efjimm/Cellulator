const std = @import("std");
const spoon = @import("spoon");
const utils = @import("utils.zig");
const ZC = @import("ZC.zig");
const Sheet = @import("Sheet.zig");
const wcWidth = @import("wcwidth").wcWidth;
const assert = std.debug.assert;
const log = std.log.scoped(.tui);

const Position = Sheet.Position;
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
    try rc.hideCursor();

    if (self.term.width < 15 or self.term.height < 5) {
        try rc.clear();
        try rc.moveCursorTo(0, 0);
        try rc.writeAllWrapping("Terminal too small");
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

    const filepath = zc.sheet.getFilePath();
    if (filepath.len > 0) {
        writer.writeByte('[') catch unreachable;
        rc.setStyle(.{ .fg = .green }) catch unreachable;
        try writer.writeAll(filepath);
        try rc.setStyle(.{});
        try writer.writeAll("] ");
    } else {
        writer.writeAll("[no file] ") catch unreachable;
    }

    if (zc.sheet.has_changes) {
        try writer.writeAll("[+] ");
    }

    try zc.cursor.writeCellAddress(writer);
    try writer.print(" {} ", .{zc.mode});

    if (zc.count != 0) {
        try writer.print("{d} ", .{zc.getCount()});
    }

    try writer.writeAll(zc.input_buf.items);

    if (zc.sheet.text_cells.get(zc.cursor)) |cell| {
        try writer.print("[{}]", .{cell});
    } else if (zc.sheet.getCell(zc.cursor)) |cell| {
        switch (cell.getValue()) {
            .err => {
                try writer.writeByte('[');
                try rc.setStyle(.{ .fg = .red });
                try writer.print("{}", .{cell});
                try rc.setStyle(.{});
                try writer.writeByte(']');
            },
            else => try writer.print("[{}]", .{cell}),
        }
    }

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

    if (zc.mode.isCommandMode()) {
        const buf = zc.commandBuf();

        var i = zc.command_screen_pos;
        while (i < buf.len and !rpw.finished) : (i += 1) {
            try writer.writeByte(buf.get(i));
        }

        const cursor_pos = blk: {
            var pos: u16 = 0;
            const len = @min(
                buf.gap_start - zc.command_screen_pos,
                zc.command_cursor - zc.command_screen_pos,
            );

            var iter = std.unicode.Utf8Iterator{
                .bytes = buf.left()[0..len],
                .i = 0,
            };

            while (iter.nextCodepoint()) |cp| {
                pos += wcWidth(cp);
            }

            if (zc.command_cursor >= buf.gap_start) {
                iter = .{
                    .bytes = buf.right()[0 .. (zc.command_cursor - zc.command_screen_pos) - len],
                    .i = 0,
                };

                while (iter.nextCodepoint()) |cp| {
                    pos += wcWidth(cp);
                }
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
                try rc.setStyle(.{ .fg = .magenta });
                try writer.writeAll("Info: ");
            },
            .warn => {
                try rc.setStyle(.{ .fg = .yellow });
                try writer.writeAll("Warning: ");
            },
            .err => {
                try rc.setStyle(.{ .fg = .red });
                try writer.writeAll("Error: ");
            },
        }
        try rc.setStyle(.{});
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

    try rc.setStyle(.{ .fg = .blue });

    while (w < self.term.width) : (x += 1) {
        const width = @min(self.term.width - reserved_cols, zc.sheet.getColumn(x).width);

        var buf: [4]u8 = undefined;
        const name = Position.columnAddressBuf(x, &buf);

        if (zc.isSelectedCol(x)) {
            try rc.setStyle(.{ .fg = .black, .bg = .blue });
            try writer.print("{s: ^[1]}", .{ name, width });
            try rc.setStyle(.{ .fg = .blue, .bg = .black });
        } else {
            try writer.print("{s: ^[1]}", .{ name, width });
        }

        if (x == std.math.maxInt(u16)) {
            try rc.clearToEol();
            break;
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

        var rpw = rc.restrictedPaddingWriter(width);
        const writer = rpw.writer();

        if (zc.isSelectedRow(@intCast(u16, sheet_line))) {
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
    var buf: [16]u8 = undefined;

    const left = zc.leftReservedColumns();
    const writer = rc.buffer.writer();

    if (isOnScreen(&zc.tui, zc, zc.prev_cursor)) {
        // Overrwrite old cursor with a normal looking cell. Also overwrites the old column heading
        // and line number.
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

        try rc.setStyle(.{});

        try rc.moveCursorTo(prev_pos.y, prev_pos.x);
        _ = try renderCell(rc, zc, zc.prev_cursor);

        try rc.setStyle(.{ .fg = .blue, .bg = .black });

        const col = zc.sheet.getColumn(zc.prev_cursor.x);
        const width = @min(col.width, rc.term.width - left);

        try rc.moveCursorTo(ZC.col_heading_line, prev_pos.x);
        try writer.print("{s: ^[1]}", .{
            Position.columnAddressBuf(zc.prev_cursor.x, &buf),
            width,
        });

        try rc.moveCursorTo(prev_pos.y, 0);
        try writer.print("{d: ^[1]}", .{ zc.prev_cursor.y, left });
    }

    const pos = Position{
        .y = zc.cursor.y - zc.screen_pos.y + ZC.content_line,
        .x = blk: {
            assert(zc.screen_pos.x <= zc.cursor.x);

            var x: u16 = left;
            for (zc.screen_pos.x..zc.cursor.x) |i| {
                const col = zc.sheet.getColumn(@intCast(u16, i));
                x += col.width;
            }
            break :blk x;
        },
    };

    // Render the cells and headings at the current cursor position with a specific colour.
    try rc.moveCursorTo(pos.y, pos.x);
    _ = try renderCursorCell(rc, zc, zc.cursor);
    try rc.setStyle(.{ .fg = .black, .bg = .blue });

    const col = zc.sheet.getColumn(zc.cursor.x);
    const width = @min(col.width, rc.term.width - left);
    try rc.moveCursorTo(ZC.col_heading_line, pos.x);
    try writer.print("{s: ^[1]}", .{
        Position.columnAddressBuf(zc.cursor.x, &buf),
        width,
    });

    try rc.moveCursorTo(pos.y, 0);
    try writer.print("{d: ^[1]}", .{ zc.cursor.y, left });
    try rc.setStyle(.{});
}

pub fn renderCursorCell(
    rc: *RenderContext,
    zc: *ZC,
    pos: Position,
) RenderError!u16 {
    try rc.setStyle(.{ .fg = .black, .bg = .blue });
    const ret = renderCell(rc, zc, pos);
    try rc.setStyle(.{});
    return ret;
}

pub fn renderCells(
    self: Self,
    rc: *RenderContext,
    zc: *ZC,
) RenderError!void {
    const reserved_cols = zc.leftReservedColumns();

    try rc.setStyle(.{});

    for (ZC.content_line..self.term.height, zc.screen_pos.y..) |line, y| {
        try rc.moveCursorTo(@intCast(u16, line), reserved_cols);

        var w: u16 = reserved_cols;
        for (zc.screen_pos.x..@as(usize, std.math.maxInt(u16)) + 1) |x| {
            const pos = Position{ .y = @intCast(u16, y), .x = @intCast(u16, x) };
            switch (zc.mode) {
                .visual, .select => {
                    if (pos.hash() == zc.cursor.hash() or pos.intersects(zc.anchor, zc.cursor)) {
                        w += try renderCursorCell(rc, zc, pos);
                    } else {
                        w += try renderCell(rc, zc, pos);
                    }
                },
                else => {
                    if (pos.hash() == zc.cursor.hash()) {
                        w += try renderCursorCell(rc, zc, pos);
                    } else {
                        w += try renderCell(rc, zc, pos);
                    }
                },
            }
            if (w >= self.term.width) break;
        } else {
            // Hit maxInt(u16) and didn't go past the end of the screen, so we clear the rest of
            // the line to remove any artifacts
            try rc.clearToEol();
        }
    }
}

pub fn renderCell(
    rc: *RenderContext,
    zc: *ZC,
    pos: Position,
) RenderError!u16 {
    const col = zc.sheet.columns.get(pos.x) orelse {
        const width = Sheet.Column.default_width;
        try rc.buffer.writer().writeByteNTimes(' ', width);
        return width;
    };

    const width = getColWidth: {
        var width: u16 = 0;
        for (zc.screen_pos.x..pos.x) |x| {
            const c = zc.sheet.getColumn(@intCast(u16, x));
            width += c.width;
        }
        const screen_width = rc.term.width - zc.leftReservedColumns();
        break :getColWidth @min(col.width, screen_width - width);
    };

    var rpw = rc.restrictedPaddingWriter(width);
    const writer = rpw.writer();

    if (zc.sheet.text_cells.get(pos)) |cell| {
        const text = cell.text.items();
        const text_width = utils.strWidth(text, width);
        const left_pad = (width - text_width) / 2;
        if (pos.hash() != zc.cursor.hash()) {
            try rc.setStyle(.{ .fg = .green });
            try writer.writeByteNTimes(' ', left_pad);
            try writer.print("{s}", .{text});
            try rpw.pad();
            try rc.setStyle(.{});
        } else {
            try writer.writeByteNTimes(' ', left_pad);
            try writer.print("{s}", .{text});
            try rpw.pad();
        }
    } else if (zc.sheet.getCell(pos)) |cell| {
        switch (cell.getValue()) {
            .none => {},
            .err => {
                try writer.print("{s: >[1]}", .{ "ERROR", width });
            },
            .num => |num| {
                try writer.print("{d: >[1].[2]}", .{
                    num, width, col.precision,
                });
            },
        }
        try rpw.pad();
    } else {
        try writer.print("{s: >[1]}", .{ "", width });
        try rpw.pad();
    }
    return width;
}

pub fn isOnScreen(tui: *Self, zc: *ZC, pos: Position) bool {
    if (pos.x < zc.screen_pos.x or pos.y < zc.screen_pos.y) return false;

    var w: u16 = zc.leftReservedColumns();
    const end_col = blk: {
        var i: u16 = zc.screen_pos.x;
        while (true) : (i += 1) {
            const col = zc.sheet.getColumn(i);
            w += col.width;
            if (w >= tui.term.width or i == std.math.maxInt(u16)) break :blk i;
        }
        unreachable;
    };
    if (w >= tui.term.width and pos.x > end_col) return false;

    const end_row = zc.screen_pos.y +| (tui.term.height - ZC.content_line);
    if (pos.y > end_row) return false;

    return true;
}
