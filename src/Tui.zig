//! TUI frontend for Cellulator.
//! Terminal emulators are inherently retained mode UIs, which complicates UI implementations.
//! You could emulate an immediate mode UI by clearing the screen and redrawing everything each
//! update, but this would likely cause flickering on many terminal emulators. This could be
//! somewhat reduced by drawing from left to right, top to bottom. Flicker would likely still
//! remain as many terminal emulators draw immediately as the input comes in, rather than waiting
//! for all input and drawing at once. Modern terminal emulators have a `sync` feature that allows
//! them to avoid flickering in these cases, but this isn't supported on older terminal emulators
//! including xterm and the Linux tty.
//
// TODO: Make TUI rendering resistant to OOM
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
const utils = @import("utils.zig");

pub const status_line = 0;
pub const input_line = 1;
pub const col_heading_line = 2;
pub const cell_view_line = 3;

term: Term,
update_flags: UpdateFlags = .all,
rc: ?Term.RenderContext = null,
zc: ?*ZC = null,
styles: Styles,
current_style: ?UiElement = null,

arena: std.heap.ArenaAllocator,

const Styles = std.EnumArray(UiElement, shovel.Style);

// No structural typing *GRIEF*
pub const Theme = @typeInfo(@TypeOf(Styles.init)).@"fn".params[0].type.?;

pub const default_theme: Theme = .{
    .status_line = .init(.none, .none, .none),
    .status_info = .init(.magenta, .none, .none),
    .status_warn = .init(.yellow, .none, .none),
    .status_err = .init(.red, .none, .none),
    .filepath = .init(.green, .none, .none),
    .cursor_pos = .init(.none, .none, .none),
    .mode_indicator = .init(.none, .none, .none),
    .count = .init(.green, .none, .{ .bold = true }),
    .command_line = .init(.none, .none, .none),

    .column_heading_unselected = .init(.blue, .none, .none),
    .column_heading_selected = .init(.black, .blue, .none),
    .row_heading_unselected = .init(.blue, .none, .none),
    .row_heading_selected = .init(.black, .blue, .none),

    .cell_number_unselected = .init(.none, .none, .none),
    .cell_number_selected = .init(.black, .blue, .none),
    .cell_text_unselected = .init(.green, .none, .none),
    .cell_text_selected = .init(.black, .green, .none),
    .cell_error_unselected = .init(.red, .none, .none),
    .cell_error_selected = .init(.black, .red, .none),
    .cell_blank_unselected = .init(.none, .none, .none),
    .cell_blank_selected = .init(.none, .blue, .none),

    .sheet_selected = .init(.black, .blue, .none),
    .sheet_unselected = .init(.none, .bright_black, .none),

    .token_number = .init(.green, .none, .none),
    .token_builtin = .init(.red, .none, .none),
    .token_let = .init(.yellow, .none, .none),
    .token_whitespace = .init(.{ .rgb = .{ 0x65, 0x73, 0x7e } }, .none, .none),
    .token_operator = .init(.magenta, .none, .none),
    .token_cell_address = .init(.cyan, .none, .{ .bold = true }),
    .token_parentheses = .init(.{ .rgb = .{ 0x65, 0x73, 0x7e } }, .none, .none),
    .token_single_quoted_string = .init(.green, .none, .none),
    .token_double_quoted_string = .init(.green, .none, .none),
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

    sheet_selected,
    sheet_unselected,

    token_number,
    token_let,
    token_builtin,
    token_whitespace,
    token_operator,
    token_cell_address,
    token_parentheses,
    token_single_quoted_string,
    token_double_quoted_string,
};

const UpdateFlags = packed struct {
    command: bool,
    column_headings: bool,
    row_numbers: bool,
    cells: bool,
    cursor: bool,
    sheet_list: bool,

    pub const all: UpdateFlags = .{
        .command = true,
        .column_headings = true,
        .row_numbers = true,
        .cells = true,
        .cursor = true,
        .sheet_list = true,
    };

    pub const none: UpdateFlags = .{
        .command = false,
        .column_headings = false,
        .row_numbers = false,
        .cells = false,
        .cursor = false,
        .sheet_list = false,
    };
};

const Tui = @This();

var needs_resize: std.atomic.Value(bool) = .init(true);

fn resizeHandler(_: c_int) callconv(.c) void {
    needs_resize.store(true, .monotonic);
}

pub fn ui(tui: *Tui) ZC.Ui {
    return .{
        .ptr = tui,
        .vtable = &.{
            .applyTheme = applyTheme,
            .applyDefaultTheme = applyDefaultTheme,
            .stringWidth = stringWidth,
            .theme_file_extension = ".lua",
            .ui_name = "terminal",
        },
    };
}

const Lua = @import("zlua").Lua;

/// Executes the file at `path` via the Lua interpreter. The file should return a table
/// describing the TUI theme. The table should have keys matching the names of the fields in
/// `Theme`. Fields from `Theme` which are not present in the table will be left at their
/// default style.   The value of each field should be a table with the following keys:
/// `fg`, `bg`, and  `attrs`. `fg` and `bg` should be strings representing a colour that are
/// accepted  by `shovel.Style.Colour.fromDescription`. `attrs` should be an array of strings
/// representing terminal text attributes. The accepted strings are the same as the fields of
/// `shovel.Style.Attribute`.
///
/// Here is an example Lua theme definition:
///
/// ```lua
/// local my_terminal_theme = {
///   filepath = { fg = 'yellow', attrs = { 'bold', 'underline' } },
///   column_heading_unselected = { fg = 'yellow', bg = 'black'  },
///   column_heading_selected   = { fg = 'black',  bg = 'yellow' },
///   row_heading_unselected    = { fg = 'yellow', bg = 'black'  },
///   row_heading_selected      = { fg = 'black',  bg = 'yellow' },
///   cell_blank_selected       = { fg = 'black',  bg = 'yellow' },
///   cell_number_selected      = { fg = 'black',  bg = 'yellow' },
///   cell_text_selected        = { fg = 'black',  bg = 'yellow' },
///   cell_error_selected       = { fg = 'black',  bg = 'yellow' },
///
///   -- All unspecified fields are left at their default style
/// }
/// ```
fn applyTheme(ptr: *anyopaque, path: [:0]const u8) ZC.Ui.ApplyThemeError!void {
    const tui: *Tui = @ptrCast(@alignCast(ptr));

    const arena = tui.arena.allocator();
    defer _ = tui.arena.reset(.retain_capacity);

    const state = Lua.init(arena) catch return error.Failed;
    defer state.deinit();

    state.checkStack(3) catch return error.Failed;
    state.pushFunction(@ptrCast(&applyThemeLua));
    state.pushLightUserdata(tui);
    state.doFile(path) catch return error.Failed;

    state.protectedCall(.{ .args = 2 }) catch return error.Failed;
}

fn applyDefaultTheme(ptr: *anyopaque) ZC.Ui.ApplyThemeError!void {
    const tui: *Tui = @ptrCast(@alignCast(ptr));
    tui.styles = .init(default_theme);
    tui.update_flags = .all;
}

fn applyThemeLua(state: *Lua) callconv(.c) c_int {
    errdefer |err| state.raiseErrorStr("Unexpected error {s}", .{@errorName(err).ptr});
    const tui = try state.toUserdata(Tui, 1);

    var new_theme = default_theme;
    inline for (@typeInfo(Theme).@"struct".fields) |field| {
        var t = state.getField(2, field.name);
        if (t != .nil) {
            state.argExpected(t == .table, -1, "table");
            const parseColourString = @import("lua.zig").parseColourString;

            t = state.getField(-1, "fg");
            const fg = parseColourString(state, t);

            t = state.getField(-1, "bg");
            const bg = parseColourString(state, t);

            @field(new_theme, field.name) = .init(fg, bg, .none);
            tui.update_flags = .all;
        } else {
            state.pop(1);
        }
    }
    tui.styles = .init(new_theme);
    state.setTop(0);
    return 0;
}

pub fn stringWidth(
    _: *anyopaque,
    bytes: []const u8,
    opts: ZC.Ui.StringWidthOptions,
) ZC.Ui.StringWidthResult {
    const res = @import("zg").display_width.strWidth(bytes, .{
        .max_width = opts.max_width,
    });
    return .{ .width = @intCast(res.width), .len = res.len };
}

pub const InitError = Term.InitError || Term.UncookError || error{OperationNotSupported};

pub fn init(allocator: std.mem.Allocator) InitError!Tui {
    std.posix.sigaction(std.posix.SIG.WINCH, &.{
        .handler = .{
            .handler = resizeHandler,
        },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    try shovel.initUnicodeData(allocator);

    return .{
        .term = try .init(allocator, .{ .truecolour = .check }),
        .arena = .init(allocator),
        .styles = .init(default_theme),
    };
}

pub fn deinit(tui: *Tui, allocator: std.mem.Allocator) void {
    tui.term.deinit(allocator);
    tui.arena.deinit();
    shovel.deinitUnicodeData(allocator);
    tui.* = undefined;
}

pub fn update(tui: *Tui, comptime fields: []const std.meta.FieldEnum(UpdateFlags)) void {
    inline for (fields) |tag| {
        @field(tui.update_flags, @tagName(tag)) = true;
    }
}

/// Returns the number of rows *fully* visible on the screen.
pub fn cellViewHeight(tui: *const Tui) u16 {
    return tui.term.height -| (cell_view_line + 1);
}

pub fn render(tui: *Tui, zc: *ZC) !void {
    defer _ = tui.arena.reset(.{ .retain_with_limit = 1 << 20 });
    assert(tui.rc == null);

    if (needs_resize.load(.monotonic)) {
        try tui.term.fetchSize();
        zc.clampScreenToCursor();
        tui.update_flags = .all;
        needs_resize.store(false, .monotonic);
    }

    var buf: [1 << 14]u8 = undefined;
    var rc = try tui.term.getRenderContext(&buf);
    rc.hideCursor() catch unreachable;

    if (tui.term.width < 15 or tui.term.height < 5) {
        rc.clear() catch unreachable;
        rc.moveCursorTo(0, 0) catch unreachable;
        rc.writeAllWrapping("Terminal too small") catch unreachable;
        try rc.done();
        return;
    }

    tui.zc = zc;
    tui.rc = rc;
    defer {
        tui.zc = null;
        tui.rc = null;
    }
    errdefer unreachable;

    // TODO: Don't update this every frame
    try tui.renderStatus();
    if (tui.update_flags.column_headings)
        try tui.renderColumnHeadings();

    if (tui.update_flags.row_numbers)
        try tui.renderRowNumbers();

    if (tui.update_flags.cells) {
        try tui.renderCells();
    }

    if (tui.update_flags.cursor) {
        try tui.renderCursor();
    }

    try tui.renderSheetList();

    if (tui.update_flags.command or zc.mode.isCommandMode())
        tui.renderCommandLine() catch return tui.rc.?.writer.err.?;

    try tui.rc.?.done();

    tui.update_flags = .none;
}

/// Sets the current style to the style associated with `element`.
fn setStyle(tui: *Tui, element: UiElement) !void {
    if (tui.current_style == element) return;
    const style = tui.styles.get(element);
    try tui.rc.?.setStyle(style);
    tui.current_style = element;
}

fn renderSheetList(tui: *Tui) !void {
    const rc = &tui.rc.?;
    const zc = tui.zc.?;

    try rc.moveCursorTo(tui.term.height - 1, 0);
    var rpw = rc.cellWriter(tui.term.width);
    const writer = &rpw.interface;

    try tui.setStyle(.sheet_unselected);

    for (zc.sheets.values(), zc.sheets.keys(), 0..) |sheet, name, i| {
        const style: UiElement =
            if (i != zc.current_sheet)
                .sheet_unselected
            else
                .sheet_selected;

        try tui.setStyle(style);
        try writer.print("{s} {s} ", .{
            if (sheet.has_changes) "[+]" else "",
            name,
        });

        try tui.setStyle(.sheet_unselected);
    }

    try rpw.finish();
    try rc.clearToEol();
}

fn renderStatus(tui: *Tui) !void {
    const rc = &tui.rc.?;
    const zc = tui.zc.?;
    const arena = tui.arena.allocator();
    try rc.moveCursorTo(status_line, 0);
    try rc.hideCursor();

    const writer = &rc.writer.interface;

    try tui.setStyle(.token_cell_address);
    try writer.print(" {f}", .{zc.cursor});
    try tui.setStyle(.status_line);
    try writer.print(" {f}", .{zc.mode});

    if (zc.count != 0) {
        try tui.setStyle(.count);
        try writer.print(" {d}{s}", .{ zc.getCount(), zc.input_buf.items });
        try tui.setStyle(.status_line);
    } else if (zc.input_buf.items.len > 0) {
        try tui.setStyle(.count);
        try writer.print(" {s}", .{zc.input_buf.items});
        try tui.setStyle(.status_line);
    }

    try writer.writeAll(" [");
    const sheet = zc.currentSheet();
    if (sheet.getCell(zc.cursor)) |cell| {
        const ast = @import("ast.zig");

        const buf = try arena.alloc(u8, 4096);
        var wr: std.io.Writer = .fixed(buf);
        ast.print(sheet.ast_nodes, cell.expr_root, sheet.strings_buf.items, &wr) catch {};

        var reader: std.io.Reader = .fixed(wr.buffer);
        const tokens = try Tokenizer.collectTokens(arena, &reader, 128);
        const tags = tokens.items(.tag);
        const starts = tokens.items(.start);
        for (tags[0 .. tags.len - 1], starts[0 .. starts.len - 1], starts[1..]) |tag, start, end| {
            try tui.writeToken(tag, buf[start..end]);
        }
        try tui.writeToken(.eof, buf[starts[starts.len - 1]..]);
    }

    try tui.setStyle(.status_line);
    try writer.writeByte(']');

    const path = sheet.filepath.constSlice();
    if (path.len > 0) {
        try tui.setStyle(.filepath);
        try writer.print(" {s}", .{path});
    } else {
        try writer.writeAll(" No file");
    }

    try rc.clearToEol();
}

const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;

fn tokenStyle(tag: Token.Tag) UiElement {
    return switch (tag) {
        .builtin => .token_builtin,
        .number => .token_number,
        .keyword_let => .token_let,
        .eof => .token_builtin,
        .plus,
        .minus,
        .forward_slash,
        .hash,
        .asterisk,
        .percent,
        => .token_operator,
        .cell_name => .token_cell_address,
        .lparen, .rparen => .token_parentheses,
        .single_string_literal_start, .single_string_literal_end => .token_single_quoted_string,
        .double_string_literal_start, .double_string_literal_end => .token_double_quoted_string,
        else => .command_line,
    };
}

fn writeToken(tui: *Tui, tag: Token.Tag, slice: []const u8) !void {
    const rc = &tui.rc.?;
    const writer = &rc.writer.interface;
    try tui.setStyle(tokenStyle(tag));
    switch (tag) {
        // These tags allow trailing whitespace as part of their contents
        .single_string_literal_start, .double_string_literal_start => {
            try writer.writeAll(slice);
        },
        else => {
            const trimmed = std.mem.trimRight(u8, slice, &std.ascii.whitespace);
            try writer.writeAll(trimmed);
            const whitespace = slice[trimmed.len..];
            if (whitespace.len > 0) {
                try tui.setStyle(.token_whitespace);
                try writer.writeAll(whitespace);
            }
        },
    }
}

fn renderCommandLine(tui: *Tui) !void {
    const rc = &tui.rc.?;
    const zc = tui.zc.?;
    try rc.moveCursorTo(input_line, 0);
    try tui.setStyle(.command_line);
    try rc.clearToEol();
    const writer = &rc.writer.interface;

    const arena = tui.arena.allocator();

    if (zc.mode.isCommandMode()) {
        var buf: [128]u8 = undefined;
        var reader = zc.command.reader(&buf);

        const left = zc.command.left();
        const right = zc.command.right();

        const i = zc.command_screen_pos;
        const c = zc.command.cursor;
        assert(c >= i);

        if (i < left.len) {
            if (c > left.len) {
                try writer.writeAll(left[i..]);
                try writer.writeAll(right[0 .. c - left.len]);
                try rc.saveCursor();
            } else {
                try writer.writeAll(left[i..c]);
                try rc.saveCursor();
            }
        } else {
            try writer.writeAll(right[i - left.len .. c - left.len]);
            try rc.saveCursor();
        }

        const tokens = try Tokenizer.collectTokens(
            arena,
            &reader.interface,
            zc.command.length() / 2,
        );

        try rc.moveCursorTo(input_line, 0);

        const tags = tokens.items(.tag);
        const starts = tokens.items(.start);

        const index, const cutoff =
            for (starts, 0..) |start, j| {
                if (start >= left.len) break .{ j, start - left.len };
            } else .{ tokens.len - 1, 0 };

        for (
            tags[0..index],
            starts[0..index],
            starts[1 .. index + 1],
        ) |tag, start, end| {
            try tui.writeToken(tag, left[start..@min(left.len, end)]);
        }

        try writer.writeAll(right[0..cutoff]);

        for (
            tags[index .. tags.len - 1],
            starts[index .. starts.len - 1],
            starts[index + 1 ..],
        ) |tag, start, end| {
            const adjusted_start = start - left.len;
            const adjusted_end = end - left.len;

            try tui.writeToken(tag, right[adjusted_start..adjusted_end]);
        }

        const last_start = starts[starts.len - 1];
        if (last_start < left.len) {
            try tui.writeToken(.eof, left[last_start..]);
            try writer.writeAll(right);
        } else {
            try tui.writeToken(.eof, right[last_start - left.len ..]);
        }

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
        try rc.restoreCursor();
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
    }
}

fn renderColumnHeadings(tui: *Tui) !void {
    const rc = &tui.rc.?;
    const zc = tui.zc.?;

    const reserved_cols = zc.leftReservedColumns();
    try rc.moveCursorTo(col_heading_line, reserved_cols);
    try rc.clearToBol();

    var x = zc.screen_pos.x;
    var w = reserved_cols;

    try tui.setStyle(.column_heading_unselected);

    // TODO: Clean up these calls to getColumn
    while (w < tui.term.width) : (x += 1) {
        const col: Column = zc.currentSheet().getColumn(x) orelse .{};
        const width = @min(tui.term.width - reserved_cols, col.width);

        var buf: [Position.max_str_len]u8 = undefined;
        const name = Position.columnAddressBuf(x, &buf);

        if (zc.isSelectedCol(x)) {
            try tui.setStyle(.column_heading_selected);
            try shovel.writeTruncating(name, width, .center, &rc.writer.interface);
            try tui.setStyle(.column_heading_unselected);
        } else {
            try shovel.writeTruncating(name, width, .center, &rc.writer.interface);
        }

        if (x == std.math.maxInt(Position.Int)) {
            try rc.clearToEol();
            break;
        }
        w += width;
    }
}

fn renderRowNumbers(tui: *Tui) !void {
    const rc = &tui.rc.?;
    const zc = tui.zc.?;
    const width = zc.leftReservedColumns();
    try tui.setStyle(.row_heading_unselected);

    try rc.moveCursorTo(col_heading_line, 0);
    try rc.writer.interface.splatByteAll(' ', width);

    for (
        cell_view_line..cell_view_line + tui.cellViewHeight(),
        zc.screen_pos.y..,
    ) |screen_line, sheet_line| {
        try rc.moveCursorTo(@intCast(screen_line), 0);

        var rpw = rc.cellWriter(width);

        if (zc.isSelectedRow(@intCast(sheet_line))) {
            try tui.setStyle(.row_heading_selected);

            try rpw.interface.print("{d: ^[1]}", .{ sheet_line, width });
            try rpw.pad();

            try tui.setStyle(.row_heading_unselected);
        } else {
            try rpw.interface.print("{d: ^[1]}", .{ sheet_line, width });
            try rpw.pad();
        }
    }
}

fn renderCursor(tui: *Tui) !void {
    const zc = tui.zc.?;

    // Overwrite the old cursor if it's still on screen
    const old_col_handle = zc.currentSheet().cols.findEntry(&.{zc.prev_cursor.x});
    const x_on_screen, const y_on_screen = tui.isOnScreen(zc, zc.prev_cursor);

    if (x_on_screen and y_on_screen) {
        const old_x = posXToScreenX(zc, zc.prev_cursor.x);
        const old_y = posYToScreenY(zc, zc.prev_cursor.y);
        try tui.renderCursorAtPos(zc.prev_cursor, old_col_handle, old_x, old_y);
    }

    if (x_on_screen and zc.cursor.x != zc.prev_cursor.x) {
        const old_x = posXToScreenX(zc, zc.prev_cursor.x);
        try tui.overwriteColumnHeading(zc.prev_cursor, old_col_handle, old_x);
    }
    if (y_on_screen and zc.cursor.y != zc.prev_cursor.y)
        try tui.overwriteRowHeading(zc.prev_cursor);

    // Draw the new cursor
    const new_col_handle = zc.currentSheet().cols.findEntry(&.{zc.cursor.x});
    const new_x = posXToScreenX(zc, zc.cursor.x);
    const new_y = posYToScreenY(zc, zc.cursor.y);
    try tui.renderCursorAtPos(zc.cursor, new_col_handle, new_x, new_y);
    if (zc.cursor.y != zc.prev_cursor.y)
        try tui.overwriteRowHeading(zc.cursor);
    if (zc.cursor.x != zc.prev_cursor.x)
        try tui.overwriteColumnHeading(zc.cursor, new_col_handle, new_x);
}

fn overwriteRowHeading(tui: *Tui, pos: Position) !void {
    const zc = tui.zc.?;
    const rc = &tui.rc.?;
    const left = zc.leftReservedColumns();

    const y = posYToScreenY(zc, pos.y);

    try rc.moveCursorTo(y, 0);
    try tui.setStyle(
        if (isSelected(zc, pos))
            .row_heading_selected
        else
            .row_heading_unselected,
    );
    try rc.writer.interface.print("{d: ^[1]}", .{ pos.y, left });
}

fn posXToScreenX(zc: *ZC, px: Position.Int) u16 {
    var x = zc.leftReservedColumns();
    var i = zc.screen_pos.x;
    while (i < px) : (i += 1) {
        const c: Column = zc.currentSheet().getColumn(i) orelse .{};
        x += c.width;
    }
    return x;
}

fn posYToScreenY(zc: *ZC, py: Position.Int) u16 {
    return @intCast(py - zc.screen_pos.y + cell_view_line);
}

fn overwriteColumnHeading(tui: *Tui, pos: Position, col_handle: Column.Handle, screen_x: u16) !void {
    const zc = tui.zc.?;
    const rc = &tui.rc.?;
    const left = zc.leftReservedColumns();

    const col = zc.currentSheet().getColumnByHandleOrDefault(col_handle);

    const width = @min(col.width, rc.term.width - left);
    try rc.moveCursorTo(col_heading_line, screen_x);
    try tui.setStyle(
        if (isSelected(zc, pos))
            .column_heading_selected
        else
            .column_heading_unselected,
    );

    var buf: [Position.max_str_len]u8 = undefined;
    const slice = Position.columnAddressBuf(pos.x, &buf);
    try shovel.writeTruncating(slice, width, .center, &rc.writer.interface);
}

fn renderCursorAtPos(tui: *Tui, pos: Position, col_handle: Column.Handle, screen_x: u16, screen_y: u16) !void {
    const rc = &tui.rc.?;
    const zc = tui.zc.?;

    if (zc.mode.isVisual()) return;

    // Render the cells and headings at the current cursor position with a specific colour.
    const col = zc.currentSheet().getColumnByHandleOrDefault(col_handle);
    const cell_handle = zc.currentSheet().getCellHandleByPos(pos);
    const text_attrs_handle = zc.currentSheet().text_attrs.findEntry(&.{ pos.x, pos.y });
    try rc.moveCursorTo(screen_y, screen_x);
    try tui.renderCell(
        pos,
        cell_handle,
        col.precision,
        col.width,
        zc.currentSheet().getTextAttrs(text_attrs_handle),
    );
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
fn visibleColumnCount(tui: *const Tui) u16 {
    const zc = tui.zc.?;

    var width: u16 = 0;
    var col_count: u16 = 0;
    var last = zc.screen_pos.x;
    const view_width = tui.term.width - zc.leftReservedColumns();

    var cols_iter = zc.currentSheet().cols.iteratorAt(.{zc.screen_pos.x});
    while (cols_iter.next()) |handle| {
        assert(last >= zc.screen_pos.x);

        const col = zc.currentSheet().cols.getPoint(handle)[0];
        // TODO: This is a hack for a deficiency in `PhTree.iteratorAt`
        if (col < zc.screen_pos.x) {
            return @min(
                divCeil(view_width, Column.default_width),
                std.math.maxInt(Position.Int) - zc.screen_pos.x +| 1,
            );
        }

        const diff: u16 = @intCast(@min(view_width, col - last));
        const diff_width = diff * Column.default_width;
        const w = diff_width + zc.currentSheet().cols.getValue(handle).width;

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
    const Handle = @FieldType(Sheet, field_name).Leaf.Handle;
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
    const sheet = zc.currentSheet();
    const arena = tui.arena.allocator();

    var cols: std.ArrayList(Column.Handle) = try .initCapacity(arena, col_count);
    var cells: std.ArrayList(Cell.Handle) = try .initCapacity(arena, cell_count);
    var attr_handles: std.ArrayList(Sheet.TextAttrs.Handle) = try .initCapacity(arena, cell_count);

    const tl: *const [2]u32 = &.{ zc.screen_pos.x, zc.screen_pos.y };
    const br: *const [2]u32 = &.{
        zc.screen_pos.x +| (col_count - 1),
        zc.screen_pos.y +| (tui.cellViewHeight() - 1),
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
    const rc = &tui.rc.?;
    const zc = tui.zc.?;
    const sheet = zc.currentSheet();

    const col_count = tui.visibleColumnCount();
    const height = tui.cellViewHeight();
    const cell_count = col_count * height;

    const cols, const cells, const text_attrs = try tui.screenData(col_count, cell_count);

    const screen_col_start = zc.leftReservedColumns();
    const view_width = tui.term.width - screen_col_start;
    var y: Position.Int = 0; // Relative to the screen pos
    while (y < height) : (y += 1) {
        const screen_line = cell_view_line + y;
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
            assert(cell_handle == .invalid or pos.eql(sheet.posFromCellHandle(cell_handle)));

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
    const rc = &tui.rc.?;
    const zc = tui.zc.?;
    const sheet = zc.currentSheet();
    const selected = isSelected(zc, pos);

    var rpw = rc.cellWriter(width);

    if (cell_handle == .invalid) {
        try tui.setStyle(if (selected) .cell_blank_selected else .cell_blank_unselected);
        try rpw.pad();
        return;
    }

    const cell: *const Cell = sheet.getCellFromHandle(cell_handle);

    switch (cell.value_tag) {
        .number => {
            try tui.setStyle(if (selected) .cell_number_selected else .cell_number_unselected);
            try rpw.interface.print("{d: >[1].[2]}", .{ cell.value.number, width, precision });
            try rpw.pad();
        },
        .string => {
            try tui.setStyle(if (selected) .cell_text_selected else .cell_text_unselected);

            const text = zc.currentSheet().cellStringValue(cell);
            const alignment = utils.enumFromEnum(shovel.TextAlignment, text_attrs.alignment);
            try shovel.writeTruncating(text, width, alignment, &rc.writer.interface);
        },
        .err => {
            try tui.setStyle(if (selected) .cell_error_selected else .cell_error_unselected);
            try rpw.interface.print("{s: >[1]}", .{ "ERROR", width });
            try rpw.pad();
        },
    }
}

const OnScreenResult = struct {
    x: bool,
    y: bool,
};

fn isOnScreen(tui: *const Tui, zc: *ZC, pos: Position) [2]bool {
    if (pos.x < zc.screen_pos.x and pos.y < zc.screen_pos.y)
        return .{ false, false };

    const col_count = tui.visibleColumnCount();
    const height = tui.cellViewHeight();

    return .{
        pos.x >= zc.screen_pos.x and pos.x <= zc.screen_pos.x +| col_count,
        pos.y >= zc.screen_pos.y and pos.y <= zc.screen_pos.y +| height,
    };
}
