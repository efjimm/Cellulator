// TODO: this whole file sucks
const std = @import("std");
const spoon = @import("spoon");
const utils = @import("utils.zig");
const bufutils = @import("buffer_utils.zig");
const ZC = @import("ZC.zig");
const Sheet = @import("Sheet.zig");
const Position = @import("Position.zig").Position;
const PosInt = Position.Int;
const wcWidth = @import("wcwidth").wcWidth;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const Col = Sheet.Column;

const Term = spoon.Term;

term: Term,
update_flags: UpdateFlags = .all,

/// Used by rendering to store all cells currently visible on the screen
cells: std.ArrayListUnmanaged(Sheet.CellHandle) = .empty,

/// Used by rendering to store all columns currently visible on the screen
cols: std.ArrayListUnmanaged(Sheet.Column.Handle) = .empty,

const UpdateFlags = packed struct {
    command: bool,
    column_headings: bool,
    row_numbers: bool,
    cells: bool,
    cursor: bool,

    pub const all: UpdateFlags = .{
        .command = true,
        .column_headings = true,
        .row_numbers = true,
        .cells = true,
        .cursor = true,
    };
};

const CellType = enum {
    number,
    string,
    err,
    blank,
};

const styles = std.EnumArray(CellType, [2]spoon.Style).init(.{
    .number = .{
        .{ .fg = .white, .bg = .black },
        .{ .fg = .black, .bg = .blue },
    },
    .string = .{
        .{ .fg = .green, .bg = .black },
        .{ .fg = .black, .bg = .blue },
    },
    .err = .{
        .{ .fg = .red, .bg = .black },
        .{ .fg = .red, .bg = .blue },
    },
    .blank = .{
        .{ .fg = .white, .bg = .black },
        .{ .fg = .black, .bg = .blue },
    },
});

const Self = @This();
const RenderContext = Term.RenderContext(8192);

pub const InitError = Term.InitError || Term.UncookError || error{OperationNotSupported};

pub var needs_resize = true;

fn resizeHandler(_: c_int) callconv(.C) void {
    needs_resize = true;
}

pub fn init(allocator: Allocator) InitError!Self {
    std.posix.sigaction(std.posix.SIG.WINCH, &.{
        .handler = .{
            .handler = resizeHandler,
        },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);

    return Self{
        .term = try Term.init(allocator, .{}),
    };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.term.deinit(allocator);
    self.cells.deinit(allocator);
    self.cols.deinit(allocator);
    self.* = undefined;
}

pub fn update(tui: *Self, comptime fields: []const std.meta.FieldEnum(UpdateFlags)) void {
    inline for (fields) |tag| {
        @field(tui.update_flags, @tagName(tag)) = true;
    }
}

pub const RenderError = Term.WriteError;

pub fn render(self: *Self, allocator: Allocator, zc: *ZC) !void {
    if (needs_resize) {
        try self.term.fetchSize();
        zc.clampScreenToCursor();
        self.update_flags = .all;
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
    if (self.update_flags.column_headings) {
        try self.renderColumnHeadings(&rc, zc);
        self.update_flags.column_headings = false;
    }
    if (self.update_flags.row_numbers) {
        try self.renderRowNumbers(&rc, zc);
        self.update_flags.row_numbers = false;
    }
    if (self.update_flags.cells) {
        try self.renderCells(allocator, &rc, zc);
        self.update_flags.cells = false;
        self.update_flags.cursor = false;
    } else if (self.update_flags.cursor) {
        try renderCursor(&rc, zc);
        self.update_flags.cursor = false;
    }
    if (self.update_flags.command or zc.mode.isCommandMode()) {
        try renderCommandLine(&rc, zc);
        self.update_flags.command = false;
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

    var rpw = rc.cellWriter(self.term.width);
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
    var rpw = rc.cellWriter(rc.term.width);
    const writer = rpw.writer();
    try rc.setStyle(.{ .fg = .white, .bg = .black });

    if (zc.mode.isCommandMode()) {
        const left = zc.command.left();
        const left_len: u32 = @intCast(left.len);
        const right = zc.command.right();

        // TODO: don't write all of this, only write what fits on screen
        const i = zc.command_screen_pos;
        if (i < left_len) {
            try writer.writeAll(left[i..]);
            try writer.writeAll(right);
        } else {
            try writer.writeAll(right[i - left.len ..]);
        }

        const cursor_pos = blk: {
            var iter = bufutils.Utf8Iterator(@TypeOf(zc.command)){
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
    zc: *ZC,
) RenderError!void {
    const writer = rc.buffer.writer();

    const reserved_cols = zc.leftReservedColumns();
    try rc.moveCursorTo(ZC.col_heading_line, reserved_cols);
    try rc.clearToBol();

    var x = zc.screen_pos.x;
    var w = reserved_cols;

    try rc.setStyle(.{ .fg = .blue, .bg = .black });

    // TODO: Clean up these calls to getColumn
    while (w < self.term.width) : (x += 1) {
        const col: Col = zc.sheet.getColumn(x) orelse .{};
        const width = @min(self.term.width - reserved_cols, col.width);

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

        var rpw = rc.cellWriter(width);
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
                const col: Col = zc.sheet.getColumn(@intCast(i)) orelse .{};
                x += col.width;
            }
            break :blk x;
        };

        try rc.setStyle(.{ .fg = .white, .bg = .black });

        try rc.moveCursorTo(prev_y, prev_x);
        const col_handle = zc.sheet.cols.findEntry(&.{zc.prev_cursor.x});
        const col = if (col_handle.isValid()) zc.sheet.cols.valuePtr(col_handle).* else Sheet.Column{};
        const cell_handle: Sheet.CellHandle = zc.sheet.getCellHandleByPos(zc.prev_cursor) orelse .invalid;
        try renderCell(rc, zc, zc.prev_cursor, cell_handle, col_handle, col.width);

        try rc.setStyle(.{ .fg = .blue, .bg = .black });

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
            const col: Col = zc.sheet.getColumn(@intCast(i)) orelse .{};
            x += col.width;
        }
        break :blk x;
    };

    // Render the cells and headings at the current cursor position with a specific colour.
    try rc.moveCursorTo(y, x);
    const col_handle = zc.sheet.cols.findEntry(&.{zc.cursor.x});
    const col = if (col_handle.isValid()) zc.sheet.cols.valuePtr(col_handle).* else Sheet.Column{};
    const cell_handle: Sheet.CellHandle = zc.sheet.getCellHandleByPos(zc.cursor) orelse .invalid;
    try renderCell(rc, zc, zc.cursor, cell_handle, col_handle, col.width);
    try rc.setStyle(.{ .fg = .black, .bg = .blue });

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

/// Returns the number of columns currently visible on screen.
fn screenColumnWidth(self: Self, zc: *ZC) u32 {
    const reserved_cols = zc.leftReservedColumns();
    var cols_iter = zc.sheet.cols.iteratorAt(.{zc.screen_pos.x});
    var width: u16 = 0;
    var col_count: u32 = 0;
    var last = zc.screen_pos.x;
    const cells_width = self.term.width - reserved_cols;

    while (cols_iter.next()) |handle| {
        assert(last >= zc.screen_pos.x);

        const col = zc.sheet.cols.point(handle)[0];
        if (col < zc.screen_pos.x) return std.math.divCeil(
            u16,
            cells_width,
            Sheet.Column.default_width,
        ) catch unreachable;

        const diff: u16 = @intCast(col - last);
        const diff_w = diff * Sheet.Column.default_width;
        const col_w = zc.sheet.cols.valuePtr(handle).width;
        const w = diff_w + col_w;

        if (width + w >= cells_width) {
            const remaining_width = cells_width - width;
            if (remaining_width > diff_w) {
                col_count += diff + 1;
            } else {
                col_count += std.math.divCeil(
                    u16,
                    remaining_width,
                    Sheet.Column.default_width,
                ) catch unreachable;
            }

            break;
        }
        width += w;
        col_count += diff + 1;
        last = col +% 1;
    } else {
        col_count += std.math.divCeil(
            u16,
            cells_width -| width,
            Sheet.Column.default_width,
        ) catch unreachable;
    }

    return col_count;
}

pub fn renderCells(
    self: *Self,
    allocator: Allocator,
    rc: *RenderContext,
    zc: *ZC,
) !void {
    try rc.setStyle(.{ .fg = .white, .bg = .black });

    var cols: std.ArrayList(Sheet.Columns.Handle) = self.cols.toManaged(allocator);
    var cells: std.ArrayList(Sheet.CellHandle) = self.cells.toManaged(allocator);
    cols.clearRetainingCapacity();
    cells.clearRetainingCapacity();

    defer {
        self.cols = cols.moveToUnmanaged();
        self.cells = cells.moveToUnmanaged();
    }

    const col_count = self.screenColumnWidth(zc);
    const height = self.term.height -| ZC.content_line;
    const cell_count = col_count * height;
    try cols.ensureTotalCapacity(col_count);
    try cells.ensureTotalCapacity(cell_count);

    zc.sheet.cell_tree.queryWindow(
        &.{ zc.screen_pos.x, zc.screen_pos.y },
        &.{ zc.screen_pos.x +| (col_count - 1), zc.screen_pos.y +| (self.term.height - ZC.content_line - 1) },
        &cells,
    ) catch unreachable;

    zc.sheet.cols.queryWindow(
        &.{zc.screen_pos.x},
        &.{zc.screen_pos.x +| (col_count - 1)},
        &cols,
    ) catch unreachable;

    const sheet = zc.sheet;

    var i = cols.items.len;
    const old_cols_len = cols.items.len;
    cols.items.len = col_count;
    @memset(cols.items[old_cols_len..], .invalid);
    while (i > 0) {
        i -= 1;
        const handle = cols.items[i];
        const new_index = sheet.cols.point(handle)[0] - zc.screen_pos.x;
        cols.items[new_index] = handle;
        cols.items[i] = .invalid;
    }

    const SortContext = struct {
        sheet: *Sheet,

        pub fn lessThan(ctx: @This(), a: Sheet.CellHandle, b: Sheet.CellHandle) bool {
            const p1 = ctx.sheet.cell_tree.point(a);
            const p2 = ctx.sheet.cell_tree.point(b);
            if (p1[1] == p2[1]) return p1[0] < p2[0];
            return p1[1] < p2[1];
        }
    };

    std.mem.sortUnstable(
        Sheet.CellHandle,
        cells.items,
        SortContext{ .sheet = zc.sheet },
        SortContext.lessThan,
    );

    i = cells.items.len;
    const old_cells_len = cells.items.len;
    cells.items.len = cell_count;
    @memset(cells.items[old_cells_len..], .invalid);
    while (i > 0) {
        i -= 1;
        const handle = cells.items[i];
        const p = sheet.cell_tree.point(handle);
        const x = p[0] - zc.screen_pos.x;
        const y = p[1] - zc.screen_pos.y;
        const new_index = y * col_count + x;
        assert(new_index >= i);
        cells.items[i] = .invalid;
        cells.items[new_index] = handle;
    }

    const screen_col_start = zc.leftReservedColumns();
    const cells_width = self.term.width - screen_col_start;
    i = 0;
    var y = zc.screen_pos.y;
    var j: usize = 0;
    while (y - zc.screen_pos.y < height) : (y += 1) {
        const screen_line = ZC.content_line + (y - zc.screen_pos.y);
        try rc.moveCursorTo(@intCast(screen_line), screen_col_start);

        var w: u16 = 0;
        var x = zc.screen_pos.x;
        while (x - zc.screen_pos.x < col_count) : ({
            x += 1;
            j += 1;
        }) {
            // const rel_y = y - zc.screen_pos.y;
            const rel_x = x - zc.screen_pos.x;

            const col_handle = cols.items[rel_x];
            const col = colFromHandle(sheet, col_handle);
            const cell_handle = cells.items[j];

            const pos: Position = .init(x, y);
            if (cell_handle.isValid()) {
                assert(pos.eql(sheet.posFromCellHandle(cell_handle)));
            }
            const cell_width = @min(col.width, cells_width - w);
            try renderCell(rc, zc, pos, cell_handle, col_handle, cell_width);
            w += col.width;
        }
    }
}

inline fn colFromHandle(sheet: *Sheet, handle: Sheet.Column.Handle) Sheet.Column {
    return if (handle.isValid())
        sheet.cols.valuePtr(handle).*
    else
        Sheet.Column{};
}

fn renderCell(
    rc: *RenderContext,
    zc: *ZC, // TODO: This should be a field of Self
    pos: Position,
    cell_handle: Sheet.CellHandle,
    col_handle: Sheet.Column.Handle,
    width: u16,
) !void {
    const sheet = zc.sheet;
    const selected = Position.eql(pos, zc.cursor);

    const col = if (col_handle.isValid())
        sheet.cols.valuePtr(col_handle).*
    else
        Sheet.Column{};

    var rpw = rc.cellWriter(width);
    const writer = rpw.writer();

    if (cell_handle.isValid()) {
        const cell: *const Sheet.Cell = sheet.getCellFromHandle(cell_handle);
        const tag: CellType = @enumFromInt(@intFromEnum(cell.value_type));
        try rc.setStyle(styles.get(tag)[@intFromBool(selected)]);

        switch (cell.value_type) {
            .number => {
                try writer.print("{d: >[1].[2]}", .{
                    cell.value.number, width, col.precision,
                });
                try rpw.pad();
            },
            .string => {
                const text = zc.sheet.cellStringValue(cell);
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
}

pub fn isOnScreen(tui: *Self, zc: *ZC, pos: Position) bool {
    if (pos.x < zc.screen_pos.x or pos.y < zc.screen_pos.y)
        return false;

    const col_count = tui.screenColumnWidth(zc);
    const height = tui.term.height -| ZC.content_line;

    return pos.x <= zc.screen_pos.x +| col_count and pos.y <= zc.screen_pos.y +| height;
}
