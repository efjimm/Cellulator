//! TUI frontend for Cellulator.
//! Terminal emulators are inherently retained mode UIs, which complicates UI implementations.
//! You could emulate an immediate mode UI by clearing the screen and redrawing everything each
//! update, but this would likely cause flickering on many terminal emulators. This could be
//! somewhat reduced by drawing from left to right, top to bottom. Flicker would likely still
//! remain as many terminal emulators draw immediately as the input comes in, rather than waiting
//! for all input and drawing at once. Modern terminal emulators have a `sync` feature that allows
//! them to avoid flickering in these cases, but this isn't supported on older terminal emulators
//! including xterm and the Linux tty.
const std = @import("std");
const assert = std.debug.assert;

const shovel = @import("shovel");
const Term = shovel.Term;
pub const RenderError = Term.WriteError;

const Position = @import("Position.zig").Position;
const Sheet = @import("Sheet.zig");
const Cell = Sheet.Cell;
const Column = Sheet.Column;
const ZC = @import("ZC.zig");

pub const status_line = 0;
pub const input_line = 1;
pub const col_heading_line = 2;
pub const content_line = 3;

term: Term,
update_flags: UpdateFlags = .all,
rc: ?*Term.RenderContext(8192) = null,
zc: ?*ZC = null,
styles: Styles,
current_style: ?UiElement = null,

arena: std.heap.ArenaAllocator,

const Styles = std.EnumArray(UiElement, shovel.Style);

// No structural typing *GRIEF*
pub const Theme = @typeInfo(@TypeOf(Styles.init)).@"fn".params[0].type.?;

pub const default_theme: Theme = .{
    .status_line = .init(.white, .black, .none),
    .status_info = .init(.magenta, .black, .none),
    .status_warn = .init(.yellow, .black, .none),
    .status_err = .init(.red, .black, .none),
    .filepath = .init(.green, .black, .none),
    .cursor_pos = .init(.white, .black, .none),
    .mode_indicator = .init(.white, .black, .none),
    .count = .init(.green, .black, .{ .bold = true }),
    .expression = .init(.cyan, .black, .none),
    .expression_error = .init(.red, .black, .none),
    .command_line = .init(.white, .black, .none),

    .column_heading_unselected = .init(.blue, .black, .none),
    .column_heading_selected = .init(.black, .blue, .none),
    .row_heading_unselected = .init(.blue, .black, .none),
    .row_heading_selected = .init(.black, .blue, .none),

    .cell_number_unselected = .init(.white, .black, .none),
    .cell_number_selected = .init(.black, .blue, .none),
    .cell_text_unselected = .init(.green, .black, .none),
    .cell_text_selected = .init(.black, .green, .none),
    .cell_error_unselected = .init(.red, .black, .none),
    .cell_error_selected = .init(.black, .red, .none),
    .cell_blank_unselected = .init(.white, .black, .none),
    .cell_blank_selected = .init(.black, .blue, .none),
};

pub const UiElement = enum {
    status_line,
    status_info,
    status_warn,
    status_err,

    filepath,
    cursor_pos,
    mode_indicator,
    count,
    expression,
    expression_error,
    command_line,

    column_heading_unselected,
    column_heading_selected,
    row_heading_unselected,
    row_heading_selected,

    cell_number_unselected,
    cell_number_selected,
    cell_text_unselected,
    cell_text_selected,
    cell_error_unselected,
    cell_error_selected,
    cell_blank_unselected,
    cell_blank_selected,
};

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

    pub const none: UpdateFlags = .{
        .command = false,
        .column_headings = false,
        .row_numbers = false,
        .cells = false,
        .cursor = false,
    };
};

const Tui = @This();

var needs_resize: std.atomic.Value(bool) = .init(true);

fn resizeHandler(_: c_int) callconv(.C) void {
    needs_resize.store(true, .monotonic);
}

pub const InitError = Term.InitError || Term.UncookError || error{OperationNotSupported};

pub fn init(allocator: std.mem.Allocator) InitError!Tui {
    std.posix.sigaction(std.posix.SIG.WINCH, &.{
        .handler = .{
            .handler = resizeHandler,
        },
        .mask = std.posix.empty_sigset,
        .flags = 0,
    }, null);

    return .{
        .term = try Term.init(allocator, .{}),
        .arena = .init(allocator),
        .styles = .init(default_theme),
    };
}

pub fn deinit(tui: *Tui, allocator: std.mem.Allocator) void {
    tui.term.deinit(allocator);
    tui.arena.deinit();
    tui.* = undefined;
}

pub fn update(tui: *Tui, comptime fields: []const std.meta.FieldEnum(UpdateFlags)) void {
    inline for (fields) |tag| {
        @field(tui.update_flags, @tagName(tag)) = true;
    }
}

/// Returns the number of rows *fully* visible on the screen.
pub fn contentHeight(tui: *const Tui) u16 {
    return tui.term.height -| content_line;
}

pub fn render(tui: *Tui, zc: *ZC) !void {
    assert(tui.rc == null);

    if (needs_resize.load(.monotonic)) {
        try tui.term.fetchSize();
        zc.clampScreenToCursor();
        tui.update_flags = .all;
        needs_resize.store(false, .monotonic);
    }

    var rc = try tui.term.getRenderContext(8192);
    rc.hideCursor() catch unreachable;

    if (tui.term.width < 15 or tui.term.height < 5) {
        rc.clear() catch unreachable;
        rc.moveCursorTo(0, 0) catch unreachable;
        rc.writeAllWrapping("Terminal too small") catch unreachable;
        try rc.done();
        return;
    }

    tui.zc = zc;
    tui.rc = &rc;
    defer {
        tui.zc = null;
        tui.rc = null;
    }

    try tui.renderStatus();
    if (tui.update_flags.column_headings)
        try tui.renderColumnHeadings();

    if (tui.update_flags.row_numbers)
        try tui.renderRowNumbers();

    if (tui.update_flags.cells) {
        try tui.renderCells();
    } else if (tui.update_flags.cursor) {
        try tui.renderCursor();
    }

    if (tui.update_flags.command or zc.mode.isCommandMode())
        try tui.renderCommandLine();

    try rc.done();

    tui.update_flags = .none;
}

/// Sets the current style to the style associated with `element`.
fn setStyle(tui: *Tui, element: UiElement) !void {
    if (tui.current_style == element) return;
    const style = tui.styles.get(element);
    try tui.rc.?.setStyle(style);
    tui.current_style = element;
}

fn renderStatus(tui: *Tui) RenderError!void {
    const rc = tui.rc.?;
    const zc = tui.zc.?;
    try rc.moveCursorTo(status_line, 0);
    try rc.hideCursor();

    var rpw = rc.cellWriter(tui.term.width);
    const writer = rpw.writer();

    const filepath = zc.sheet.getFilePath();
    if (filepath.len > 0) {
        try tui.setStyle(.filepath);
        try writer.writeAll(filepath);
        try tui.setStyle(.status_line);
    } else {
        try tui.setStyle(.status_line);
        writer.writeAll("<no file>") catch unreachable;
    }

    if (zc.sheet.has_changes) {
        try writer.writeAll(" [+]");
    }

    try writer.print(" {} {}", .{ zc.cursor, zc.mode });

    if (zc.count != 0) {
        try tui.setStyle(.count);
        try writer.print(" {d}{s}", .{ zc.getCount(), zc.input_buf.items });
    } else if (zc.input_buf.items.len > 0) {
        try tui.setStyle(.count);
        try writer.print(" {s}", .{zc.input_buf.items});
    }

    try tui.setStyle(.status_line);
    try writer.writeAll(" [");
    if (zc.sheet.getCell(zc.cursor)) |cell| {
        if (!cell.isError()) {
            try tui.setStyle(.expression);
        } else {
            try tui.setStyle(.expression_error);
        }
        try zc.sheet.printCellExpression(zc.cursor, writer);
    }

    try tui.setStyle(.status_line);
    try writer.writeByte(']');
    try rpw.pad();
}

fn renderCommandLine(tui: *Tui) RenderError!void {
    const rc = tui.rc.?;
    const zc = tui.zc.?;
    try rc.moveCursorTo(input_line, 0);
    try rc.clearToEol();
    var rpw = rc.cellWriter(rc.term.width);
    const writer = rpw.writer();
    try tui.setStyle(.command_line);

    if (zc.mode.isCommandMode()) {
        const left = zc.command.left();
        const left_len: u32 = @intCast(left.len);
        const right = zc.command.right();

        // TODO: don't write all of this, only write what fits on screen
        const i = zc.command_screen_pos;
        if (i < left_len) {
            try writer.print("{s}{s}", .{ left[i..], right });
        } else {
            try writer.writeAll(right[i - left.len ..]);
        }

        const cursor_pos = blk: {
            const bufutils = @import("buffer_utils.zig");
            var iter: bufutils.Utf8Iterator(@TypeOf(zc.command)) = .{
                .data = zc.command,
                .index = zc.command_screen_pos,
            };
            var pos: u16 = 0;
            while (iter.nextCodepoint()) |cp| {
                if (iter.index > zc.command.cursor) break;
                pos += @import("wcwidth").wcWidth(cp);
            }

            break :blk pos;
        };
        try rpw.finish();

        try rc.moveCursorTo(input_line, cursor_pos);
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
                try tui.setStyle(.status_info);
                try writer.writeAll("Info: ");
            },
            .warn => {
                try tui.setStyle(.status_warn);
                try writer.writeAll("Warning: ");
            },
            .err => {
                try tui.setStyle(.status_err);
                try writer.writeAll("Error: ");
            },
        }
        try tui.setStyle(.command_line);
        try writer.writeAll(zc.status_message.slice());
        try rpw.finish();
    }
}

fn renderColumnHeadings(tui: *Tui) RenderError!void {
    const rc = tui.rc.?;
    const zc = tui.zc.?;
    const writer = rc.buffer.writer();

    const reserved_cols = zc.leftReservedColumns();
    try rc.moveCursorTo(col_heading_line, reserved_cols);
    try rc.clearToBol();

    var x = zc.screen_pos.x;
    var w = reserved_cols;

    try tui.setStyle(.column_heading_unselected);

    // TODO: Clean up these calls to getColumn
    while (w < tui.term.width) : (x += 1) {
        const col: Column = zc.sheet.getColumn(x) orelse .{};
        const width = @min(tui.term.width - reserved_cols, col.width);

        var buf: [Position.max_str_len]u8 = undefined;
        const name = Position.columnAddressBuf(x, &buf);

        if (zc.isSelectedCol(x)) {
            try tui.setStyle(.column_heading_selected);
            try writer.print("{s: ^[1]}", .{ name, width });
            try tui.setStyle(.column_heading_unselected);
        } else {
            try writer.print("{s: ^[1]}", .{ name, width });
        }

        if (x == std.math.maxInt(Position.Int)) {
            try rc.clearToEol();
            break;
        }
        w += width;
    }
}

fn renderRowNumbers(tui: *Tui) RenderError!void {
    const rc = tui.rc.?;
    const zc = tui.zc.?;
    const width = zc.leftReservedColumns();
    try tui.setStyle(.row_heading_unselected);

    try rc.moveCursorTo(col_heading_line, 0);
    try rc.buffer.writer().writeByteNTimes(' ', width);

    for (content_line..tui.term.height, zc.screen_pos.y..) |screen_line, sheet_line| {
        try rc.moveCursorTo(@intCast(screen_line), 0);

        var rpw = rc.cellWriter(width);
        const writer = rpw.writer();

        if (zc.isSelectedRow(@intCast(sheet_line))) {
            try tui.setStyle(.row_heading_selected);

            try writer.print("{d: ^[1]}", .{ sheet_line, width });
            try rpw.pad();

            try tui.setStyle(.row_heading_unselected);
        } else {
            try writer.print("{d: ^[1]}", .{ sheet_line, width });
            try rpw.pad();
        }
    }
}

fn renderCursor(tui: *Tui) RenderError!void {
    const zc = tui.zc.?;

    // Overwrite the old cursor if it's still on screen
    if (tui.isOnScreen(zc, zc.prev_cursor))
        try tui.renderCursorAtPos(zc.prev_cursor);

    // Draw the new cursor
    try tui.renderCursorAtPos(zc.cursor);
}

fn renderCursorAtPos(tui: *Tui, pos: Position) !void {
    const rc = tui.rc.?;
    const zc = tui.zc.?;

    if (zc.mode.isVisual()) return;
    var buf: [Position.max_str_len]u8 = undefined;

    const left = zc.leftReservedColumns();
    const writer = rc.buffer.writer();

    const y: u16 = @intCast(pos.y - zc.screen_pos.y + content_line);
    const x = blk: {
        assert(zc.screen_pos.x <= pos.x);

        var x = left;
        var i = zc.screen_pos.x;
        while (i < pos.x) : (i += 1) {
            const col: Column = zc.sheet.getColumn(i) orelse .{};
            x += col.width;
        }
        break :blk x;
    };

    // Render the cells and headings at the current cursor position with a specific colour.
    try rc.moveCursorTo(y, x);
    const col_handle = zc.sheet.cols.findEntry(&.{pos.x});
    const col = zc.sheet.getColumnByHandleOrDefault(col_handle);

    const cell_handle = zc.sheet.getCellHandleByPos(pos);
    const text_attrs_handle = zc.sheet.text_attrs.findEntry(&.{
        pos.x,
        pos.y,
    });
    try tui.renderCell(
        pos,
        cell_handle,
        col.precision,
        col.width,
        zc.sheet.getTextAttrs(text_attrs_handle),
    );

    const width = @min(col.width, rc.term.width - left);
    try rc.moveCursorTo(col_heading_line, x);
    try tui.setStyle(
        if (isSelected(zc, pos))
            .column_heading_selected
        else
            .column_heading_unselected,
    );

    try writer.print("{s: ^[1]}", .{ Position.columnAddressBuf(pos.x, &buf), width });

    try rc.moveCursorTo(y, 0);
    try writer.print("{d: ^[1]}", .{ pos.y, left });
}

fn isSelected(zc: *const ZC, pos: Position) bool {
    return pos == zc.cursor or switch (zc.mode) {
        .visual, .select => pos.intersects(zc.anchor, zc.cursor),
        else => false,
    };
}

fn divCeil(n: anytype, d: @TypeOf(n)) @TypeOf(n) {
    const t = @typeInfo(@TypeOf(n));
    comptime assert(t.int.signedness == .unsigned);
    assert(d != 0);
    return std.math.divCeil(@TypeOf(n), n, d) catch unreachable;
}

/// Returns the number of columns currently visible on screen.
fn contentWidth(tui: *const Tui) u16 {
    const zc = tui.zc.?;

    var width: u16 = 0;
    var col_count: u16 = 0;
    var last = zc.screen_pos.x;
    const view_width = tui.term.width - zc.leftReservedColumns();

    var cols_iter = zc.sheet.cols.iteratorAt(.{zc.screen_pos.x});
    while (cols_iter.next()) |handle| {
        assert(last >= zc.screen_pos.x);

        const col = zc.sheet.cols.getPoint(handle)[0];
        // TODO: This is a hack for a deficiency in `PhTree.iteratorAt`
        if (col < zc.screen_pos.x) {
            return @min(
                divCeil(view_width, Column.default_width),
                std.math.maxInt(Position.Int) - zc.screen_pos.x +| 1,
            );
        }

        const diff: u16 = @intCast(@min(view_width, col - last));
        const diff_width = diff * Column.default_width;
        const w = diff_width + zc.sheet.cols.getValue(handle).width;

        if (width + w >= view_width) {
            const remaining_width = view_width - width;
            if (remaining_width > diff_width) {
                col_count += diff + 1;
                break;
            }
            col_count += divCeil(remaining_width, Column.default_width);

            break;
        }
        width += w;
        col_count += diff + 1;
        last = col +% 1;
    } else {
        col_count += divCeil(view_width -| width, Column.default_width);
        col_count = @min(col_count, std.math.maxInt(Position.Int) - zc.screen_pos.x +| 1);
    }

    return col_count;
}

fn SheetTreeContext(comptime field_name: []const u8) type {
    const Handle = @FieldType(Sheet, field_name).ValueHandle;
    return struct {
        sheet: *Sheet,
        zc: *ZC,
        col_count: u32,

        fn lessThan(ctx: @This(), a: Handle, b: Handle) bool {
            const p1 = @field(ctx.sheet, field_name).getPoint(a);
            const p2 = @field(ctx.sheet, field_name).getPoint(b);
            if (p1[1] == p2[1]) return p1[0] < p2[0];
            return p1[1] < p2[1];
        }

        pub fn newIndex(ctx: @This(), handle: Handle) usize {
            const p = @field(ctx.sheet, field_name).getPoint(handle);
            const x = p[0] - ctx.zc.screen_pos.x;
            const y = p[1] - ctx.zc.screen_pos.y;
            return y * ctx.col_count + x;
        }
    };
}

fn screenData(tui: *Tui, col_count: u16, cell_count: u16) !struct {
    []const Column.Handle,
    []const Cell.Handle,
    []const Sheet.TextAttrs,
} {
    const ColContext = struct {
        zc: *ZC,
        sheet: *Sheet,

        pub fn newIndex(ctx: @This(), handle: Column.Handle) usize {
            return ctx.sheet.cols.getPoint(handle)[0] - ctx.zc.screen_pos.x;
        }
    };

    const CellContext = SheetTreeContext("cell_tree");
    const TextAttrsContext = SheetTreeContext("text_attrs");

    const zc = tui.zc.?;
    const sheet = &zc.sheet;
    const arena = tui.arena.allocator();

    var cols: std.ArrayList(Column.Handle) = try .initCapacity(arena, col_count);
    var cells: std.ArrayList(Cell.Handle) = try .initCapacity(arena, cell_count);
    var attr_handles: std.ArrayList(Sheet.TextAttrs.Handle) = try .initCapacity(arena, cell_count);

    const tl: *const [2]u32 = &.{ zc.screen_pos.x, zc.screen_pos.y };
    const br: *const [2]u32 = &.{
        zc.screen_pos.x +| (col_count - 1),
        zc.screen_pos.y +| (tui.term.height - content_line - 1),
    };

    sheet.cols.queryWindow(&.{tl[0]}, &.{br[0]}, &cols) catch unreachable;
    sheet.cell_tree.queryWindow(tl, br, &cells) catch unreachable;
    sheet.text_attrs.queryWindow(tl, br, &attr_handles) catch unreachable;

    const cell_context: CellContext = .{ .sheet = sheet, .zc = zc, .col_count = col_count };
    const text_context: TextAttrsContext = .{ .sheet = sheet, .zc = zc, .col_count = col_count };
    const col_context: ColContext = .{ .zc = zc, .sheet = sheet };

    std.mem.sortUnstable(Cell.Handle, cells.items, cell_context, CellContext.lessThan);
    std.mem.sortUnstable(Sheet.TextAttrs.Handle, attr_handles.items, text_context, TextAttrsContext.lessThan);

    const padList = @import("utils.zig").padList;
    padList(Cell.Handle, &cells, .invalid, cell_count, cell_context);
    padList(Sheet.TextAttrs.Handle, &attr_handles, .invalid, cell_count, text_context);
    padList(Column.Handle, &cols, .invalid, col_count, col_context);

    const attrs = try arena.alloc(Sheet.TextAttrs, cell_count);
    for (attr_handles.items, attrs) |handle, *dest| {
        dest.* = sheet.getTextAttrs(handle);
    }

    return .{
        try cols.toOwnedSlice(),
        try cells.toOwnedSlice(),
        attrs,
    };
}

fn renderCells(tui: *Tui) !void {
    const rc = tui.rc.?;
    const zc = tui.zc.?;
    const sheet = &zc.sheet;

    const col_count = tui.contentWidth();
    const height = tui.contentHeight();
    const cell_count = col_count * height;

    defer _ = tui.arena.reset(.{ .retain_with_limit = comptime std.math.pow(usize, 2, 20) });
    const cols, const cells, const text_attrs = try tui.screenData(col_count, cell_count);

    const screen_col_start = zc.leftReservedColumns();
    const view_width = tui.term.width - screen_col_start;
    var y: Position.Int = 0; // Relative to the screen pos
    while (y < height) : (y += 1) {
        const screen_line = content_line + y;
        try rc.moveCursorTo(@intCast(screen_line), screen_col_start);

        var w: u16 = 0;
        var x: Position.Int = 0; // Relative to the screen pos
        while (x < col_count) : (x += 1) {
            const i = y * col_count + x;
            const cell_handle = cells[i];
            const attrs = text_attrs[i];

            const col = sheet.getColumnByHandleOrDefault(cols[x]);
            const cell_width = @min(col.width, view_width - w);

            const pos = zc.screen_pos.add(.init(x, y));
            assert(!cell_handle.isValid() or pos.eql(sheet.posFromCellHandle(cell_handle)));

            try tui.renderCell(pos, cell_handle, col.precision, cell_width, attrs);
            w += col.width;
        }

        try tui.setStyle(.cell_blank_unselected);
        try rc.clearToEol();
    }
}

fn renderCell(
    tui: *Tui,
    pos: Position,
    cell_handle: Cell.Handle,
    precision: @FieldType(Column, "precision"),
    width: @FieldType(Column, "width"),
    text_attrs: Sheet.TextAttrs,
) !void {
    const rc = tui.rc.?;
    const zc = tui.zc.?;
    const sheet = &zc.sheet;
    const selected = isSelected(zc, pos);

    var rpw = rc.cellWriter(width);
    const writer = rpw.writer();

    if (!cell_handle.isValid()) {
        try tui.setStyle(if (selected) .cell_blank_selected else .cell_blank_unselected);
        try writer.print("{s: >[1]}", .{ "", width });
        try rpw.pad();
        return;
    }

    const cell: *const Cell = sheet.getCellFromHandle(cell_handle);

    switch (cell.value_type) {
        .number => {
            try tui.setStyle(if (selected) .cell_number_selected else .cell_number_unselected);
            try writer.print("{d: >[1].[2]}", .{ cell.value.number, width, precision });
        },
        .string => {
            try tui.setStyle(if (selected) .cell_text_selected else .cell_text_unselected);

            const text = zc.sheet.cellStringValue(cell);
            const text_width = @import("utils.zig").strWidth(text, width);

            const left_pad = switch (text_attrs.alignment) {
                .left => 0,
                .right => width - text_width,
                .center => (width - text_width) / 2,
            };
            try writer.writeByteNTimes(' ', left_pad);
            try writer.writeAll(text);
        },
        .err => {
            try tui.setStyle(if (selected) .cell_error_selected else .cell_error_unselected);
            try writer.print("{s: >[1]}", .{ "ERROR", width });
        },
    }
    try rpw.pad();
}

fn isOnScreen(tui: *const Tui, zc: *ZC, pos: Position) bool {
    if (pos.x < zc.screen_pos.x or pos.y < zc.screen_pos.y)
        return false;

    const col_count = tui.contentWidth();
    const height = tui.term.height -| content_line;

    return pos.x <= zc.screen_pos.x +| col_count and pos.y <= zc.screen_pos.y +| height;
}
