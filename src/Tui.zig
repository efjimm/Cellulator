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
const Screen = shovel.Screen;
pub const RenderError = Term.WriteError;

const Position = @import("Position.zig").Position;
const Sheet = @import("Sheet.zig");
const Cell = Sheet.Cell;
const Column = Sheet.Column;
const ZC = @import("ZC.zig");
const utils = @import("utils.zig");

pub const status_line = 0;
pub const input_line = 1;
pub const col_heading_line = cell_view_line - 1;
pub const cell_view_line = 3;

term: Term,
rc: ?Term.RenderContext = null,
zc: ?*ZC = null,
styles: Styles,
current_style: ?UiElement = null,
db: Screen.DoubleBuffer,
cursor: Screen.Cursor = .reset,
left: u16 = 0,
screen_data: ScreenData = undefined,

arena: std.heap.ArenaAllocator,

const Styles = std.EnumArray(UiElement, shovel.Style);

// No structural typing *GRIEF*
pub const Theme = @typeInfo(@TypeOf(Styles.init)).@"fn".params[0].type.?;

pub const default_theme: Theme = .{
    .status_line = .init(.none, .none, .none),
    .status_info = .init(.magenta, .none, .none),
    .status_warn = .init(.yellow, .none, .none),
    .status_err = .init(.red, .none, .none),
    .status_info_text = .init(.none, .none, .none),
    .status_warn_text = .init(.none, .none, .none),
    .status_err_text = .init(.none, .none, .none),
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
    .cell_ref_unselected = .init(.cyan, .none, .none),
    .cell_ref_selected = .init(.black, .cyan, .none),
    .cell_range_unselected = .init(.cyan, .none, .none),
    .cell_range_selected = .init(.black, .cyan, .none),
    .cell_visual_selected = .init(.none, .blue, .none),

    .sheet_selected = .init(.black, .blue, .none),
    .sheet_unselected = .init(.none, .bright_black, .none),

    .token_number = .init(.green, .none, .none),
    .token_builtin = .init(.red, .none, .none),
    .token_keyword = .init(.yellow, .none, .none),
    .token_whitespace = .init(.none, .none, .none),
    .token_operator = .init(.magenta, .none, .none),
    .token_cell_address = .init(.cyan, .none, .{ .bold = true }),
    .token_parentheses = .init(.{ .rgb = .{ 0x65, 0x73, 0x7e } }, .none, .none),
    .token_single_quoted_string = .init(.green, .none, .none),
    .token_double_quoted_string = .init(.green, .none, .none),

    .input_hints_background = .init(.none, .bright_black, .none),
    .input_hints_title = .init(.none, .bright_black, .none),
    .input_hints_keys = .init(.none, .bright_black, .none),
    .input_hints_description = .init(.none, .bright_black, .none),

    .cli_completion_selected = .init(.black, .blue, .none),
    .cli_completion_unselected = .init(.none, .bright_black, .none),

    .cmd_err_string = .init(.red, .bright_black, .none),
    .cmd_err_message = .init(.none, .bright_black, .none),
    .cmd_err_cmd = .init(.none, .bright_black, .none),
    .cmd_err_indicator = .init(.green, .bright_black, .none),
    .cmd_err_usage = .init(.none, .bright_black, .none),
    .cmd_err_desc = .init(.green, .bright_black, .none),
};

pub const UiElement = enum {
    status_line,
    status_info,
    status_warn,
    status_err,
    status_info_text,
    status_warn_text,
    status_err_text,

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
    cell_ref_unselected,
    cell_ref_selected,
    cell_range_unselected,
    cell_range_selected,
    cell_visual_selected,

    sheet_selected,
    sheet_unselected,

    token_number,
    token_keyword,
    token_builtin,
    token_whitespace,
    token_operator,
    token_cell_address,
    token_parentheses,
    token_single_quoted_string,
    token_double_quoted_string,

    input_hints_background,
    input_hints_title,
    input_hints_keys,
    input_hints_description,

    cli_completion_selected,
    cli_completion_unselected,

    cmd_err_string,
    cmd_err_message,
    cmd_err_cmd,
    cmd_err_indicator,
    cmd_err_usage,
    cmd_err_desc,
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
        } else {
            state.pop(1);
        }
    }
    tui.styles = .init(new_theme);
    state.setTop(0);
    return 0;
}

const zg = @import("zg");

pub fn stringWidth(
    _: *anyopaque,
    bytes: []const u8,
    opts: ZC.Ui.StringWidthOptions,
) ZC.Ui.StringWidthResult {
    const res = zg.display_width.strWidth(bytes, .{
        .max_width = opts.max_width,
    });
    return .{ .width = @intCast(res.width), .len = res.len };
}

pub fn stringWidthInternal(
    bytes: []const u8,
    opts: ZC.Ui.StringWidthOptions,
) ZC.Ui.StringWidthResult {
    const res = zg.display_width.strWidth(bytes, .{
        .max_width = opts.max_width,
    });
    return .{ .width = @intCast(res.width), .len = res.len };
}

pub const InitError = Term.InitError || Term.UncookError || error{OperationNotSupported};

pub fn init(allocator: std.mem.Allocator) InitError!Tui {
    std.posix.sigaction(std.posix.SIG.WINCH, &.{
        .handler = .{ .handler = resizeHandler },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    }, null);

    try shovel.initUnicodeData(allocator);

    const term: Term = try .init(allocator, .{
        .truecolour = .check,
        .terminfo = .{
            .fallback = .@"xterm-256color",
            .fallback_mode = .last_resort,
        },
    });

    return .{
        .term = term,
        .arena = .init(allocator),
        .styles = .init(default_theme),
        .db = .init(allocator, term.terminfo, term.grapheme_clustering_mode),
    };
}

pub fn deinit(tui: *Tui, allocator: std.mem.Allocator) void {
    tui.term.deinit(allocator);
    tui.arena.deinit();
    tui.db.deinit();
    shovel.deinitUnicodeData(allocator);
    tui.* = undefined;
}

pub fn uncook(tui: *Tui) !void {
    try tui.term.uncook(.{});
    tui.db.write.grapheme_clustering_mode = tui.term.grapheme_clustering_mode;
    tui.db.read.grapheme_clustering_mode = tui.term.grapheme_clustering_mode;
}

/// Returns the number of rows *fully* visible on the screen.
pub fn cellViewHeight(tui: *const Tui) u16 {
    return tui.term.height -| (cell_view_line + 1);
}

pub fn render(tui: *Tui, zc: *ZC) !void {
    defer _ = tui.arena.reset(.{ .retain_with_limit = 1 << 20 });

    if (needs_resize.load(.monotonic)) {
        try tui.term.fetchSize();
        try tui.db.resize(tui.term.width, tui.term.height);
        zc.clampScreenToCursor();
        needs_resize.store(false, .monotonic);
    }

    tui.left = zc.leftReservedColumns();

    var buf: [1 << 14]u8 = undefined;

    tui.zc = zc;
    defer {
        tui.zc = null;
        tui.current_style = null;
    }

    var b: [2048]u8 = undefined;
    var wr = tui.db.write.writerFull(&b, .truncate, .unicode);
    var term_writer = tui.term.writer(&buf);

    if (tui.term.width < 15 or tui.term.height < 5) {
        wr.clear();
        wr.overflow_mode = .wrap;
        try wr.interface.writeAll("Terminal too small");
        try wr.flush();
        try tui.db.dump(&term_writer.interface);
        try term_writer.interface.flush();
        return;
    }

    assert(tui.db.write.grapheme_clustering_mode == tui.term.grapheme_clustering_mode);

    if (!zc.mode.isCommandMode() and tui.term.cursor_visible) {
        try tui.term.terminfo.write(&term_writer.interface, .cursor_invisible, .{});
        tui.term.cursor_visible = false;
    }

    const col_count = try tui.visibleColumnCount();

    const height = tui.cellViewHeight();

    const cell_count = col_count * height;
    tui.screen_data = try tui.screenData(col_count, cell_count);
    try tui.renderRowNumbers(&wr);
    try tui.renderCells(&wr);
    try tui.renderCursor(&wr);
    try tui.renderInputHints(&wr);
    try tui.renderSheetList(&wr);
    try tui.renderStatus(&wr);
    try tui.renderColumnHeadings(&wr);
    try tui.renderCommandLineCompletions(&wr);
    try tui.renderCommandLine(&wr);

    try wr.flush();

    try tui.term.terminfo.write(&term_writer.interface, .cursor_address, .{ 0, 0 });
    try tui.db.dump(&term_writer.interface);
    const cx: i32 = @intCast(tui.cursor.cell_offset % tui.term.width);
    const cy: i32 = @intCast(tui.cursor.cell_offset / tui.term.width);
    if (zc.mode.isCommandMode()) {
        if (!tui.term.cursor_visible) {
            try tui.term.terminfo.write(&term_writer.interface, .cursor_visible, .{});
            tui.term.cursor_visible = true;
        }

        const cursor_shape: Term.CursorShape = switch (zc.mode) {
            .normal, .visual, .select => unreachable,
            .command_normal => .block,
            .command_insert => .bar,
            .command_to_forwards,
            .command_to_backwards,
            .command_until_forwards,
            .command_until_backwards,
            .command_change,
            .command_delete,
            => .underline,
        };
        try tui.term.setCursorShape(&term_writer.interface, cursor_shape);
        try tui.term.terminfo.write(&term_writer.interface, .cursor_address, .{ cy, cx });
    }
    try term_writer.interface.flush();
}

pub fn render2(tui: *Tui, zc: *ZC) !void {
    defer _ = tui.arena.reset(.{ .retain_with_limit = 1 << 20 });

    if (needs_resize.load(.monotonic)) {
        try tui.term.fetchSize();
        try tui.db.resize(tui.term.width, tui.term.height);
        zc.clampScreenToCursor();
        needs_resize.store(false, .monotonic);
    }

    tui.zc = zc;
    defer {
        tui.zc = null;
        tui.current_style = null;
    }

    tui.left = zc.leftReservedColumns();
    var b: [2048]u8 = undefined;
    var wr = tui.db.write.writerFull(&b, .truncate, .ascii);

    if (tui.term.width < 15 or tui.term.height < 5) {
        wr.clear();
        wr.overflow_mode = .wrap;
        try wr.interface.writeAll("Terminal too small");
        try wr.flush();
        return;
    }

    try tui.renderColumnHeadings(&wr);
    try tui.renderRowNumbers(&wr);
    try tui.renderCells(&wr);
    try tui.renderInputHints(&wr);
    try tui.renderCursor(&wr);

    try tui.renderSheetList(&wr);
    try tui.renderStatus(&wr);
    try tui.renderCommandLine(&wr);

    try wr.flush();
}

/// Sets the current style to the style associated with `element`.
fn setStyle(tui: *Tui, element: UiElement, wr: *Screen.Writer) !void {
    if (tui.current_style == element) return;
    const style = tui.styles.get(element);
    if (tui.current_style) |cs| {
        @branchHint(.likely);
        const current_style = tui.styles.get(cs);
        if (std.meta.eql(current_style, style)) return;
    }
    try wr.setStyle(style);
    tui.current_style = element;
}

fn renderSheetList(tui: *Tui, wr: *Screen.Writer) !void {
    const zc = tui.zc.?;

    try wr.setRectClamp(.{
        .x = 0,
        .y = tui.term.height - 1,
        .width = tui.term.width,
        .height = 1,
    });
    const w = &wr.interface;

    try tui.setStyle(.sheet_unselected, wr);

    for (zc.sheets.values(), zc.sheets.keys(), 0..) |sheet, name, i| {
        const style: UiElement =
            if (i != zc.current_sheet)
                .sheet_unselected
            else
                .sheet_selected;

        try tui.setStyle(style, wr);
        try w.print("{s} {s} ", .{
            if (sheet.has_changes) "[+]" else "",
            name,
        });

        try tui.setStyle(.sheet_unselected, wr);
    }
    try wr.clearToEol();
}

fn renderCommandLineCompletions(tui: *Tui, wr: *shovel.Screen.Writer) !void {
    const zc = tui.zc.?;
    if (zc.completionQuery() == null) return;

    const height = tui.cellViewHeight() / 2;
    if (height == 0) return;

    try wr.setRectClamp(.{
        .x = 0,
        .y = input_line + 1,
        .height = height,
        .width = tui.term.width,
    });
    try tui.setStyle(.sheet_unselected, wr);

    const old_mode = wr.unicode_mode;
    wr.unicode_mode = .unicode;
    defer wr.unicode_mode = old_mode;

    try tui.setStyle(.cli_completion_unselected, wr);
    var y: u16 = 0;
    var i: usize = if (zc.selected_completion) |sc| sc / height * height else 0;
    while (y < height and i < zc.completion_strings.items.len) : ({
        y += 1;
        i += 1;
    }) {
        try wr.setCursor(y, 0);

        const entry = zc.completion_strings.items[i];
        const text = zc.completions_buffer.items[entry.offset..][0..entry.len];
        if (i == zc.selected_completion) {
            try tui.setStyle(.cli_completion_selected, wr);
            try wr.interface.writeAll(text);
            try wr.clearToEol();
            try tui.setStyle(.cli_completion_unselected, wr);
        } else {
            try wr.interface.writeAll(text);
            try wr.clearToEol();
        }
    }
}

fn renderInputHints(tui: *Tui, wr: *Screen.Writer) !void {
    const Key = struct {
        // Integer value of the action enum. This is used to sort the entries based on the order in
        // the source code.
        integer_value: u8,
        key: []const u8,
        description: []const u8,
        key_width: u16,
        desc_width: u16,
    };

    const Context = struct {
        matches: *std.ArrayListUnmanaged(Key),
        allocator: std.mem.Allocator,
        input: []const u8,

        pub fn apply(ctx: *@This(), kv: anytype) !void {
            const full_slice = std.mem.span(kv.key);
            if (!std.mem.startsWith(u8, full_slice, ctx.input)) return;

            const slice = full_slice[ctx.input.len..];
            const desc = kv.value.description();

            try ctx.matches.append(ctx.allocator, .{
                .integer_value = @intFromEnum(kv.value),
                .key = slice,
                .description = desc,
                .key_width = 0,
                .desc_width = 0,
            });
        }
    };

    const zc = tui.zc.?;
    if (zc.input_buf.writer.end == 0) return;
    wr.unicode_mode = .unicode;

    const arena = tui.arena.allocator();
    const input = zc.inputSlice();

    const max_width = tui.term.width -| 4;

    if (max_width == 0) {
        @branchHint(.cold);
        return;
    }

    var matches: std.ArrayListUnmanaged(Key) = .empty;
    var ctx: Context = .{
        .matches = &matches,
        .allocator = arena,
        .input = input,
    };
    switch (zc.mode) {
        inline else => |mode| {
            const map = zc.getKeymap(mode);
            const n = map.contains(input.ptr) orelse return;
            try map.traverseNode(&.{ .inode = n }, .inode, &ctx);
        },
    }

    if (matches.items.len == 0) return;

    const SortContext = struct {
        pub fn lessThan(_: @This(), a: Key, b: Key) bool {
            return a.integer_value < b.integer_value;
        }
    };

    std.mem.sort(Key, matches.items, SortContext{}, SortContext.lessThan);

    var max_keys_width: u16 = 0;
    for (matches.items) |*match| {
        const kw_res = stringWidthInternal(match.key, .{ .max_width = max_width });
        if (kw_res.width > max_keys_width) max_keys_width = @intCast(kw_res.width);
        match.key = match.key[0..kw_res.len];
        match.key_width = @intCast(kw_res.width);
    }

    var max_desc_width: u16 = 0;
    for (matches.items) |*match| {
        const opts: ZC.Ui.StringWidthOptions = .{ .max_width = max_width - max_keys_width };
        const dw_res = stringWidthInternal(match.description, opts);
        if (dw_res.width > max_desc_width) max_desc_width = @intCast(dw_res.width);
        match.description = match.description[0..dw_res.len];
        match.desc_width = @intCast(dw_res.width);
    }

    // Actually start rendering

    const width = @min(tui.term.width, 2 + max_keys_width + 2 + max_desc_width + 2);

    const height = @min(tui.cellViewHeight(), matches.items.len + 2);
    const y = cell_view_line + (tui.cellViewHeight() - height);
    const x = tui.term.width -| width;

    try wr.setRect(.{ .x = x, .y = y, .height = height, .width = width });
    const w = &wr.interface;

    const input_res = stringWidthInternal(input, .{ .max_width = width - 2 });

    var b: [1][]const u8 = .{"─"};
    try tui.setStyle(.input_hints_background, wr);
    try w.writeAll("┌");
    try tui.setStyle(.input_hints_title, wr);
    try w.writeAll(input[0..input_res.len]);
    try tui.setStyle(.input_hints_background, wr);
    try w.writeSplatAll(&b, width - 2 - input_res.width);
    try w.writeAll("┐");

    var i: u16 = 1;
    for (matches.items[0..height -| 2]) |match| {
        try wr.setCursor(i, 0);

        try tui.setStyle(.input_hints_background, wr);
        try w.writeAll("│ ");

        try tui.setStyle(.input_hints_keys, wr);
        try w.writeAll(match.key);

        try tui.setStyle(.input_hints_background, wr);
        try w.splatByteAll(' ', max_keys_width - match.key_width + 2);

        try tui.setStyle(.input_hints_description, wr);
        try w.writeAll(match.description);

        try tui.setStyle(.input_hints_background, wr);
        try w.splatByteAll(' ', max_desc_width - match.desc_width);
        try w.writeAll(" │");

        i += 1;
    }
    try wr.setCursor(i, 0);
    try w.writeAll("└");
    try w.writeSplatAll(&b, width - 2);
    try w.writeAll("┘");
    try wr.flush();
}

fn renderStatus(tui: *Tui, wr: *Screen.Writer) !void {
    const zc = tui.zc.?;
    const arena = tui.arena.allocator();
    try wr.setRect(.{
        .x = 0,
        .y = status_line,
        .width = tui.term.width,
        .height = 1,
    });

    const writer = &wr.interface;

    try tui.setStyle(.token_cell_address, wr);
    try writer.print(" {f}", .{zc.cursor});
    try tui.setStyle(.status_line, wr);
    try writer.print(" {f}", .{zc.mode});

    const input = zc.inputSlice();
    if (zc.count != 0) {
        try tui.setStyle(.count, wr);
        try writer.print(" {d}{s}", .{ zc.getCount(), input });
        try tui.setStyle(.status_line, wr);
    } else if (input.len > 0) {
        try tui.setStyle(.count, wr);
        try writer.print(" {s}", .{input});
        try tui.setStyle(.status_line, wr);
    }

    try writer.writeAll(" [");
    const sheet = zc.currentSheet();
    if (sheet.getCell(zc.cursor)) |cell| {
        const buf = try arena.alloc(u8, 4096);
        var br: std.io.Writer = .fixed(buf);
        if (cell.root().unwrap()) |unwrapped|
            sheet.ast.print(unwrapped, &br) catch {};

        const bytes = br.buffered();
        var reader: std.io.Reader = .fixed(bytes);
        const tokens = try Tokenizer.collectTokens(arena, &reader, 128);
        const tags = tokens.items(.tag);
        const starts = tokens.items(.start);
        if (cell.expr.is_volatile) {
            try tui.setStyle(.token_keyword, wr);
            try writer.writeAll("volatile ");
        }
        for (tags[0 .. tags.len - 1], starts[0 .. starts.len - 1], starts[1..]) |tag, start, end| {
            try tui.writeToken(tag, bytes[start..end], wr);
        }
        try tui.writeToken(.eof, bytes[starts[starts.len - 1]..], wr);
    }

    try tui.setStyle(.status_line, wr);
    try writer.writeByte(']');

    const path = sheet.filepath.items;
    if (path.len > 0) {
        try tui.setStyle(.filepath, wr);
        try writer.print(" {s}", .{path});
    } else {
        try writer.writeAll(" No file");
    }

    try wr.clearToEol();
}

const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;

fn tokenStyle(tag: Token.Tag) UiElement {
    return switch (tag) {
        .builtin => .token_builtin,
        .number => .token_number,
        .keyword_let,
        .keyword_and,
        .keyword_or,
        => .token_keyword,
        .eof => .token_builtin,
        .plus,
        .minus,
        .forward_slash,
        .hash,
        .asterisk,
        .percent,
        => .token_operator,
        .rel_rel, .rel_abs, .abs_rel, .abs_abs => .token_cell_address,
        .lparen, .rparen => .token_parentheses,
        .single_string_literal_start, .single_string_literal_end => .token_single_quoted_string,
        .double_string_literal_start, .double_string_literal_end => .token_double_quoted_string,
        else => .command_line,
    };
}

fn writeToken(tui: *Tui, tag: Token.Tag, slice: []const u8, wr: *Screen.Writer) !void {
    const writer = &wr.interface;
    try tui.setStyle(tokenStyle(tag), wr);
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
                try tui.setStyle(.token_whitespace, wr);
                try writer.writeAll(whitespace);
            }
        },
    }
}

fn renderCommandLine(tui: *Tui, wr: *Screen.Writer) !void {
    const zc = tui.zc.?;
    try wr.setRectClamp(.{
        .x = 0,
        .y = input_line,
        .width = tui.term.width,
        .height = tui.term.height,
    });
    try tui.setStyle(.command_line, wr);
    try wr.clearToEol();
    const writer = &wr.interface;

    wr.overflow_mode = .wrap;

    const arena = tui.arena.allocator();

    if (zc.mode.isCommandMode()) {
        var buf: [128]u8 = undefined;
        var reader = zc.command.reader(&buf);

        const left = zc.command.left();
        const right = zc.command.right();

        const i = zc.command_screen_pos;
        const c = zc.command.cursor;
        assert(c >= i);

        if (c < left.len) {
            try writer.writeAll(left[0..c]);
        } else {
            try writer.writeAll(left);
            try writer.writeAll(right[0 .. c - left.len]);
        }
        try wr.flush();
        tui.cursor = wr.cursor;
        try wr.setCursor(0, 0);

        // writeToken does not write the initial whitespace, so do that first
        const leading_whitespace_left =
            std.mem.indexOfNone(u8, left, &std.ascii.whitespace) orelse left.len;
        const leading_whitespace_right =
            if (leading_whitespace_left == left.len)
                std.mem.indexOfNone(u8, right, &std.ascii.whitespace) orelse right.len
            else
                0;

        try tui.setStyle(.token_whitespace, wr);
        if (leading_whitespace_left > 0) {
            try wr.interface.writeAll(left[0..leading_whitespace_left]);
        }

        if (leading_whitespace_right > 0) {
            try wr.interface.writeAll(right[0..leading_whitespace_right]);
        }

        const tokens = try Tokenizer.collectTokens(
            arena,
            &reader.interface,
            zc.command.length() / 2,
        );

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
            try tui.writeToken(tag, left[start..@min(left.len, end)], wr);
        }

        try writer.writeAll(right[0..cutoff]);

        for (
            tags[index .. tags.len - 1],
            starts[index .. starts.len - 1],
            starts[index + 1 ..],
        ) |tag, start, end| {
            const adjusted_start = start - left.len;
            const adjusted_end = end - left.len;

            try tui.writeToken(tag, right[adjusted_start..adjusted_end], wr);
        }

        const last_start = starts[starts.len - 1];
        if (last_start < left.len) {
            try tui.writeToken(.eof, left[last_start..], wr);
            try writer.writeAll(right);
        } else {
            try tui.writeToken(.eof, right[last_start - left.len ..], wr);
        }

        try tui.setStyle(.command_line, wr);
        try wr.clearToEol();
    } else switch (zc.status.tag) {
        .none => {
            try wr.clearToEol();
        },
        inline .info, .warn, .err => |tag| {
            switch (tag) {
                .info => {
                    try tui.setStyle(.status_info, wr);
                    try writer.writeAll("Info: ");
                    try tui.setStyle(.status_info_text, wr);
                },
                .warn => {
                    try tui.setStyle(.status_warn, wr);
                    try writer.writeAll("Warning: ");
                    try tui.setStyle(.status_warn_text, wr);
                },
                .err => {
                    try tui.setStyle(.status_err, wr);
                    try writer.writeAll("Error: ");
                    try tui.setStyle(.status_err_text, wr);
                },
                else => comptime unreachable,
            }
            try writer.writeAll(zc.status.msg.items);
            try wr.clearToEol();
        },
        .cmd_info => {
            const usage = zc.status.usage.items;
            const desc = zc.status.cmd_description;

            // Top border
            var d2 = [_][]const u8{"─"};
            try tui.setStyle(.cmd_err_message, wr);
            try wr.interface.writeSplatAll(&d2, tui.term.width);

            try tui.setStyle(.cmd_err_usage, wr);
            try writer.print("Usage:\n{s}", .{usage});
            if (desc.len > 0) {
                try writer.writeAll("\n\n");
                try tui.setStyle(.cmd_err_desc, wr);
                try writer.print("{s}", .{desc});
            }

            try tui.setStyle(.cmd_err_message, wr);
            try writer.writeAll("\n\nPress escape to dismiss");
            try wr.clearToEol();

            // Bottom border
            var d = [_][]const u8{ "\n", "─" };
            try wr.interface.writeSplatAll(&d, tui.term.width);
        },
        .cmd_err => {
            const err = zc.status.msg.items;
            const cmd = zc.status.cmd.items;
            const usage = zc.status.usage.items;
            const desc = zc.status.cmd_description;

            // Top border
            var d2 = [_][]const u8{"─"};
            try tui.setStyle(.cmd_err_message, wr);
            try wr.interface.writeSplatAll(&d2, tui.term.width);

            try tui.setStyle(.cmd_err_string, wr);
            try writer.writeAll("Error: ");
            try tui.setStyle(.cmd_err_message, wr);
            try writer.print("{s}\n", .{err});
            try tui.setStyle(.cmd_err_cmd, wr);
            try writer.print(":{s}\n", .{cmd});

            try tui.setStyle(.cmd_err_indicator, wr);
            try writer.splatByteAll(' ', zc.status.err_offset);
            try writer.writeAll(" ^");
            try writer.splatByteAll('~', zc.status.err_size -| 1);

            try tui.setStyle(.cmd_err_usage, wr);
            try writer.print("\nUsage:\n{s}", .{usage});
            if (desc.len > 0) {
                try writer.writeAll("\n\n");
                try tui.setStyle(.cmd_err_desc, wr);
                try writer.print("{s}", .{desc});
            }

            try tui.setStyle(.cmd_err_message, wr);
            try writer.writeAll("\n\nPress escape to dismiss");
            try wr.clearToEol();

            // Bottom border
            var d = [_][]const u8{ "\n", "─" };
            try wr.interface.writeSplatAll(&d, tui.term.width);
        },
    }
}

fn renderColumnHeadings(tui: *Tui, wr: *Screen.Writer) !void {
    const zc = tui.zc.?;

    try wr.flush();
    wr.unicode_mode = .ascii;
    defer wr.unicode_mode = .unicode;

    try wr.setRect(.{
        .x = 0,
        .y = col_heading_line,
        .height = 1,
        .width = tui.term.width,
    });

    var x = zc.screen_pos.x;
    var w = tui.left;

    try tui.setStyle(.column_heading_unselected, wr);
    try wr.interface.splatByteAll(' ', tui.left);

    while (w < tui.term.width) : (x += 1) {
        const col_width = tui.screen_data.widths[x - zc.screen_pos.x];
        var buf: [Position.max_str_len]u8 = undefined;
        const name = Position.columnAddressBuf(x, &buf);

        const n = (col_width -| name.len) / 2;
        if (zc.isSelectedCol(x)) {
            try tui.setStyle(.column_heading_selected, wr);
            if (name.len >= col_width) {
                try wr.interface.writeAll(name[0..col_width]);
            } else {
                try wr.interface.splatByteAll(' ', n);
                try wr.interface.writeAll(name);
                try wr.interface.splatByteAll(' ', col_width -| name.len - n);
            }
            try tui.setStyle(.column_heading_unselected, wr);
        } else {
            if (name.len >= col_width) {
                try wr.interface.writeAll(name[0..col_width]);
            } else {
                try wr.interface.splatByteAll(' ', n);
                try wr.interface.writeAll(name);
                try wr.interface.splatByteAll(' ', col_width -| name.len - n);
            }
        }

        if (x == std.math.maxInt(Position.Int)) {
            @branchHint(.unlikely);
            try wr.clearToEol();
            break;
        }
        w += col_width;
    }
    try wr.flush();
}

fn renderRowNumbers(tui: *Tui, wr: *Screen.Writer) !void {
    const zc = tui.zc.?;

    try wr.flush();
    wr.unicode_mode = .ascii;
    defer wr.unicode_mode = .unicode;

    try tui.setStyle(.row_heading_unselected, wr);
    try wr.setRect(.{
        .x = 0,
        .y = cell_view_line,
        .width = tui.left,
        .height = tui.cellViewHeight(),
    });

    wr.overflow_mode = .wrap;

    var y: u64 = zc.screen_pos.y;
    while (y < @as(u64, zc.screen_pos.y) + tui.cellViewHeight()) : (y += 1) {
        if (zc.isSelectedRow(@intCast(y))) {
            @branchHint(.unlikely);
            try tui.setStyle(.row_heading_selected, wr);
            try wr.interface.print("{d: ^[1]}", .{ y, tui.left });
            try tui.setStyle(.row_heading_unselected, wr);
        } else {
            try wr.interface.print("{d: ^[1]}", .{ y, tui.left });
        }
    }
    try wr.flush();
}

/// This is done separately from `renderCells` for performance reasons.
fn renderCursor(tui: *Tui, wr: *Screen.Writer) !void {
    const zc = tui.zc.?;
    const range = zc.anyCursorRange();

    const start_y = cell_view_line + (range.tl.y -| zc.screen_pos.y);
    const end_y = start_y +| (range.br.y - range.tl.y);

    const start_x = range.tl.x -| zc.screen_pos.x;
    const end_x = range.br.x -| zc.screen_pos.x;

    var start: usize = tui.left;
    for (0..start_x) |x| {
        start += tui.screen_data.widths[x];
    }
    var width: usize = 0;
    for (start_x..@min(tui.screen_data.widths.len, @as(u64, end_x) + 1)) |x|
        width += tui.screen_data.widths[x];

    const style: UiElement = blk: {
        if (zc.mode.isVisual())
            break :blk .cell_visual_selected;

        const cell = zc.currentSheet().getCellPtr(range.tl) orelse break :blk .cell_blank_selected;
        break :blk switch (cell.expr.value_tag) {
            .number => .cell_number_selected,
            .string => .cell_text_selected,
            .err => .cell_error_selected,
            .ref_cell => .cell_ref_selected,
            .ref_range => .cell_range_selected,
            .simple_function => .cell_number_selected,
            .builtin_function => .cell_number_selected,
            .closure => .cell_number_selected,
        };
    };

    wr.styleRect(
        wr.s.clampedRect(.{
            .x = @intCast(start),
            .y = @intCast(start_y),
            .width = @intCast(width),
            .height = @intCast(@min(std.math.maxInt(u16), end_y - start_y + 1)),
        }),
        tui.styles.get(style),
    );
}

fn divCeil(n: anytype, d: @TypeOf(n)) @TypeOf(n) {
    const t = @typeInfo(@TypeOf(n));
    comptime assert(t.int.signedness == .unsigned);
    assert(d != 0);
    return std.math.divCeil(@TypeOf(n), n, d) catch unreachable;
}

const GetColsContext = struct {
    widths: []u16,
    sheet: *const Sheet,
    screen_x: u32,

    pub fn func(ctx: @This(), h: Column.Handle) !void {
        const x = ctx.sheet.cols.getPoint(h)[0] - ctx.screen_x;
        ctx.widths[x] = ctx.sheet.cols.getValue(h).width;
    }
};

/// Returns the number of columns currently visible on screen.
fn visibleColumnCount(tui: *Tui) !u16 {
    const zc = tui.zc.?;
    const sheet = zc.currentSheet();

    const widths = try tui.arena.allocator().alloc(u16, @as(u32, tui.term.width) + 1);
    @memset(widths, Column.default_width);
    sheet.cols.traverse(&.{zc.screen_pos.x}, &.{zc.screen_pos.x +| tui.term.width}, GetColsContext{
        .sheet = sheet,
        .widths = widths,
        .screen_x = zc.screen_pos.x,
    }) catch unreachable;

    var total_width: u16 = 0;
    var i: u16 = 0;
    for (widths) |w| {
        total_width += w;
        i += 1;
        if (total_width >= tui.term.width) break;
    }

    return i;
}

fn SheetTreeContext(comptime field_name: []const u8) type {
    const Handle = @FieldType(Sheet, field_name).Entry.Handle;
    return struct {
        sheet: *Sheet,
        zc: *ZC,
        col_count: u16,

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

const ScreenData = struct {
    widths: []const u16,
    precisions: []const u8,
    values: []const Cell.Value,
    attrs: []const Sheet.TextAttrs,
    extra: []const Extra,

    const Tag = enum(u4) {
        blank,
        number,
        string,
        err,
        ref_cell,
        ref_range,
        simple_function,
        builtin_function,
        closure,
    };

    const Extra = packed struct {
        is_volatile: bool,
        tag: Tag,
    };
};

fn screenData(tui: *Tui, col_count: u16, cell_count: u16) !ScreenData {
    const zc = tui.zc.?;
    const sheet = zc.currentSheet();
    const arena = tui.arena.allocator();

    const widths = try arena.alloc(u16, col_count);
    const precisions = try arena.alloc(u8, col_count);
    const values = try arena.alloc(Cell.Value, cell_count);
    const extra = try arena.alloc(ScreenData.Extra, cell_count);
    const attrs = try arena.alloc(Sheet.TextAttrs, cell_count);

    @memset(widths, Column.default_width);
    @memset(precisions, 2);
    @memset(extra, .{ .is_volatile = false, .tag = .blank });
    @memset(attrs, .default);

    const tl: *const [2]u32 = &.{ zc.screen_pos.x, zc.screen_pos.y };
    const br: *const [2]u32 = &.{
        zc.screen_pos.x +| (col_count - 1),
        zc.screen_pos.y +| (tui.cellViewHeight() - 1),
    };

    const CellContext = struct {
        values: []Cell.Value,
        extra: []ScreenData.Extra,
        sheet: *Sheet,
        zc: *ZC,
        col_count: u16,

        pub fn func(ctx: @This(), h: Cell.Handle) !void {
            const p = ctx.sheet.cell_tree.getPoint(h);
            const x = p[0] - ctx.zc.screen_pos.x;
            const y = p[1] - ctx.zc.screen_pos.y;
            const cell = ctx.sheet.cell_tree.getValue(h).*;
            ctx.extra[y * ctx.col_count + x] = .{
                .tag = switch (cell.expr.value_tag) {
                    .number => .number,
                    .string => .string,
                    .err => .err,
                    .ref_cell => .ref_cell,
                    .ref_range => .ref_range,
                    .simple_function => .simple_function,
                    .builtin_function => .builtin_function,
                    .closure => .closure,
                },
                .is_volatile = cell.expr.is_volatile,
            };
            ctx.values[y * ctx.col_count + x] = cell.value;
        }
    };

    const AttrContext = struct {
        attrs: []Sheet.TextAttrs,
        sheet: *Sheet,
        zc: *ZC,
        col_count: u16,

        pub fn func(ctx: @This(), h: Sheet.TextAttrs.Handle) !void {
            const p = ctx.sheet.text_attrs.getPoint(h);
            const x = p[0] - ctx.zc.screen_pos.x;
            const y = p[1] - ctx.zc.screen_pos.y;
            ctx.attrs[y * ctx.col_count + x] = ctx.sheet.text_attrs.getValue(h).*;
        }
    };

    const ColContext = struct {
        widths: []u16,
        precisions: []u8,
        sheet: *Sheet,
        zc: *ZC,
        col_count: u16,

        pub fn func(ctx: @This(), h: Column.Handle) !void {
            const p = ctx.sheet.cols.getPoint(h);
            const x = p[0] - ctx.zc.screen_pos.x;
            const col = ctx.sheet.cols.getValue(h);
            ctx.widths[x] = col.width;
            ctx.precisions[x] = col.precision;
        }
    };

    sheet.cols.traverse(&.{tl[0]}, &.{br[0]}, ColContext{
        .widths = widths,
        .precisions = precisions,
        .sheet = sheet,
        .zc = zc,
        .col_count = col_count,
    }) catch unreachable;

    // sheet.cell_tree.queryWindow(tl, br, &cells) catch unreachable;
    sheet.cell_tree.traverse(tl, br, CellContext{
        .extra = extra,
        .values = values,
        .sheet = sheet,
        .zc = zc,
        .col_count = col_count,
    }) catch unreachable;

    sheet.text_attrs.traverse(tl, br, AttrContext{
        .attrs = attrs,
        .sheet = sheet,
        .zc = zc,
        .col_count = col_count,
    }) catch unreachable;

    return .{
        .widths = widths,
        .precisions = precisions,
        .values = values,
        .extra = extra,
        .attrs = attrs,
    };
}

fn renderCells(tui: *Tui, wr: *Screen.Writer) !void {
    const zc = tui.zc.?;
    const sheet = zc.currentSheet();

    const col_count = try tui.visibleColumnCount();
    const height = tui.cellViewHeight();

    const data = tui.screen_data;

    const screen_col_start = tui.left;
    try wr.setRectClamp(.{
        .x = screen_col_start,
        .y = cell_view_line,
        .width = tui.term.width,
        .height = tui.term.height,
    });

    wr.overflow_mode = .wrap;
    const old_mode = wr.unicode_mode;
    wr.unicode_mode = .unicode;
    defer wr.unicode_mode = old_mode;

    var y: Position.Int = 0; // Relative to the screen pos
    var i: usize = 0;
    while (y < height) : (y += 1) {
        var w: u16 = 0;
        var x: Position.Int = 0; // Relative to the screen pos
        while (x < col_count) : ({
            x += 1;
            i += 1;
        }) {
            const width = @min(data.widths[x], wr.rect.width -| w);
            if (width == 0) continue;

            var buf: [512]u8 = undefined;
            switch (data.extra[i].tag) {
                .blank => {
                    try tui.setStyle(.cell_blank_unselected, wr);
                    try wr.interface.splatByteAll(' ', width);
                },
                .number => {
                    try tui.setStyle(.cell_number_unselected, wr);
                    var bw: std.io.Writer = .fixed(&buf);
                    bw.print("{d: >[1].[2]}", .{
                        data.values[i].number,
                        width,
                        data.precisions[x],
                    }) catch {};
                    if (bw.end > width) {
                        bw.end = width - 1;
                        bw.writeAll("…") catch {};
                    }
                    try wr.interface.writeAll(bw.buffered());
                },
                .string => {
                    try tui.setStyle(.cell_text_unselected, wr);

                    const text = sheet.string_values.items(data.values[i].string);
                    const alignment = utils.enumFromEnum(
                        shovel.TextAlignment,
                        data.attrs[i].alignment,
                    );
                    try shovel.writeTruncating(
                        text,
                        width,
                        alignment,
                        tui.term.grapheme_clustering_mode,
                        &wr.interface,
                    );
                },
                .err => {
                    try tui.setStyle(.cell_error_unselected, wr);
                    try wr.interface.print("{s: >[1]}", .{ "ERROR", width });
                },
                .ref_cell => {
                    try tui.setStyle(.cell_ref_unselected, wr);
                    const slice = std.fmt.bufPrint(&buf, "{f}", .{data.values[i].ref_cell}) catch
                        unreachable;
                    try shovel.writeTruncating(
                        slice,
                        width,
                        .right,
                        tui.term.grapheme_clustering_mode,
                        &wr.interface,
                    );
                },
                .ref_range => {
                    try tui.setStyle(.cell_range_unselected, wr);
                    const range = sheet.cellValueRange(data.values[i].ref_range).*;

                    const slice = std.fmt.bufPrint(&buf, "{f}", .{range}) catch unreachable;
                    try shovel.writeTruncating(
                        slice,
                        width,
                        .right,
                        tui.term.grapheme_clustering_mode,
                        &wr.interface,
                    );
                },
                .simple_function => {
                    try tui.setStyle(.cell_number_unselected, wr);
                    // TODO: Syntax highlight these
                    const root = data.values[i].simple_function.index;
                    const slice = try std.fmt.allocPrint(
                        tui.arena.allocator(),
                        "{f}",
                        .{sheet.ast.fmtExpression(root)},
                    );
                    try shovel.writeTruncating(
                        slice,
                        width,
                        .right,
                        tui.term.grapheme_clustering_mode,
                        &wr.interface,
                    );
                },
                .builtin_function => {
                    try tui.setStyle(.cell_number_unselected, wr);
                    // TODO: Syntax highlight these
                    const tag = data.values[i].builtin_function;
                    const slice = try std.fmt.allocPrint(tui.arena.allocator(), "{f}", .{tag});
                    try shovel.writeTruncating(
                        slice,
                        width,
                        .right,
                        tui.term.grapheme_clustering_mode,
                        &wr.interface,
                    );
                },
                .closure => {
                    try tui.setStyle(.cell_number_unselected, wr);
                    // TODO: Syntax highlight these
                    const index = data.values[i].closure.index;
                    const root = sheet.closures.items[index].function.root;
                    const slice = try std.fmt.allocPrint(
                        tui.arena.allocator(),
                        "{f}",
                        .{sheet.ast.fmtExpression(root)},
                    );
                    try shovel.writeTruncating(
                        slice,
                        width,
                        .right,
                        tui.term.grapheme_clustering_mode,
                        &wr.interface,
                    );
                },
            }
            w += width;
        }
        try wr.flush();
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
