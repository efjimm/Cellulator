const std = @import("std");
const utils = @import("utils.zig");
const Allocator = std.mem.Allocator;
const Motion = @import("text.zig").Motion;
const critbit = @import("critbit.zig");
const shovel = @import("shovel");
const inputParser = shovel.inputParser;
const Term = shovel.Term;

const assert = std.debug.assert;

pub const SheetKeyMap = critbit.CritBitMap([*:0]const u8, Action, critbit.StringContextZ);
pub const CommandKeyMap = critbit.CritBitMap([*:0]const u8, CommandAction, critbit.StringContextZ);

pub const KeyMaps = struct {
    sheet_normal: SheetKeyMap,
    sheet_visual: SheetKeyMap,
    sheet_select: SheetKeyMap,
    command_normal: CommandKeyMap,
    command_insert: CommandKeyMap,
    command_operator_pending: CommandKeyMap,
    command_to: CommandKeyMap,

    pub fn deinit(k: *KeyMaps, allocator: Allocator) void {
        const fields = @typeInfo(KeyMaps).@"struct".fields;
        inline for (fields) |f| {
            @field(k, f.name).deinit(allocator);
        }
    }
};

pub fn createKeymaps(allocator: Allocator) !KeyMaps {
    const fields = @typeInfo(KeyMaps).@"struct".fields;

    var ret: KeyMaps = undefined;
    inline for (fields, 0..) |f, i| {
        const data = @field(@This(), f.name);
        const map = &@field(ret, f.name);

        map.* = .init();
        errdefer inline for (fields[0 .. i + 1]) |f2| {
            @field(ret, f2.name).deinit(allocator);
        };

        for (data.keys) |mapping| {
            const k, const v = mapping;
            try map.put(allocator, k, v);
        }

        for (data.inherit) |inherit| {
            for (inherit) |mapping| {
                const k, const v = mapping;
                try map.put(allocator, k, v);
            }
        }
    }

    return ret;
}

/// Parses the raw terminal input in `bytes` into a readable format for keybindings, outputting
/// the results to the given writer.
pub fn parse(
    term: *Term,
    bytes: []const u8,
    w: *std.Io.Writer,
) !void {
    var iter = inputParser(bytes, term);

    while (iter.next()) |in| {
        var special = false;
        if (in.mod_ctrl and in.mod_alt) {
            special = true;
            try w.writeAll("<C-M-");
        } else if (in.mod_ctrl) {
            special = true;
            try w.writeAll("<C-");
        } else if (in.mod_alt) {
            special = true;
            try w.writeAll("<M-");
        } else if (in.mod_shift) {
            special = true;
            try w.writeAll("<S-");
        }

        switch (in.content) {
            .escape => try w.writeAll("<Escape>"),
            .arrow_up => try w.writeAll("<Up>"),
            .arrow_down => try w.writeAll("<Down>"),
            .arrow_left => try w.writeAll("<Left>"),
            .arrow_right => try w.writeAll("<Right>"),
            .home => try w.writeAll("<Home>"),
            .end => try w.writeAll("<End>"),
            .begin => try w.writeAll("<Begin>"),
            .page_up => try w.writeAll("<PageUp>"),
            .page_down => try w.writeAll("<PageDown>"),
            .delete => try w.writeAll("<Delete>"),
            .insert => try w.writeAll("<Insert>"),
            .print => try w.writeAll("<Print>"),
            .scroll_lock => try w.writeAll("<Scroll>"),
            .pause => try w.writeAll("<Pause>"),
            .function => |function| try w.print("<F{d}>", .{function}),
            .enter => try w.writeAll("<Return>"),
            .command => {},
            .tab => try w.writeAll("<Tab>"),
            .backspace => try w.writeAll("<Delete>"),
            .codepoint => |cp| switch (cp) {
                '<' => try w.writeAll("<<"),
                127 => try w.writeAll("<Delete>"),
                0...'\n' - 1, '\n' + 1...'\r' - 1, '\r' + 1...31 => {},
                '\n', '\r', 32...'<' - 1, '<' + 1...126 => {
                    @branchHint(.likely);
                    try w.writeByte(@intCast(cp));
                },
                else => {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &buf) catch continue;
                    try w.writeAll(buf[0..len]);
                },
            },
            .mouse, .unknown => {},
        }

        if (special) {
            try w.writeByte('>');
        }
    }
}

pub const Action = union(enum) {
    enter_normal_mode,
    enter_visual_mode,
    enter_command_mode,
    edit_cell,
    dismiss_count_or_status_message,

    undo,
    redo,
    yank_cell,
    put_cell,
    put_cell_adjust,

    page_down,
    page_up,
    half_page_down,
    half_page_up,

    cell_cursor_up,
    cell_cursor_down,
    cell_cursor_left,
    cell_cursor_right,
    cell_cursor_row_first,
    cell_cursor_row_last,
    cell_cursor_col_first,
    cell_cursor_col_last,
    goto_row,
    goto_col,

    delete_cell,
    next_populated_cell,
    prev_populated_cell,
    increase_precision,
    decrease_precision,
    increase_width,
    decrease_width,
    assign_cell,
    assign_label,
    fit_text,
    delete_column,
    delete_row,
    insert_column,
    insert_row,

    text_align_left,
    text_align_right,
    text_align_center,

    visual_move_left,
    visual_move_right,
    visual_move_up,
    visual_move_down,
    select_submit,
    select_cancel,

    goto_next_sheet,
    goto_prev_sheet,
    close_sheet,

    zero,
    count: u4,

    // Visual mode only
    swap_anchor,

    pub fn description(action: Action) []const u8 {
        return switch (action) {
            .enter_normal_mode => "Enter normal mode",
            .enter_visual_mode => "Enter visual mode",
            .enter_command_mode => "Enter command mode",
            .edit_cell => "Edit cell expression",
            .dismiss_count_or_status_message => "Set count to 0 / Dismiss status message",

            .undo => "Undo",
            .redo => "Redo",
            .yank_cell => "Yank selected cells",
            .put_cell => "Put yanked cells",
            .put_cell_adjust => "Put yanked cells, adjusting expressions",

            .goto_next_sheet => "Goto next sheet",
            .goto_prev_sheet => "Goto previous sheet",
            .close_sheet => "Close the current sheet",

            .page_up => "Page up",
            .page_down => "Page down",
            .half_page_up => "Half page up",
            .half_page_down => "Half page down",
            .cell_cursor_up => "Move cursor up",
            .cell_cursor_down => "Move cursor down",
            .cell_cursor_left => "Move cursor left",
            .cell_cursor_right => "Move cursor right",
            .cell_cursor_row_first => "Goto first populated cell in column",
            .cell_cursor_row_last => "Goto last populated cell in column",
            .cell_cursor_col_first => "Goto first populated cell in row",
            .cell_cursor_col_last => "Goto last populated cell in row",
            .goto_row => "Goto row <n>",
            .goto_col => "Goto column <n>",

            .delete_cell => "Delete selected cells",
            .next_populated_cell => "Goto the next populated cell",
            .prev_populated_cell => "Goto the previous populated cell",
            .increase_precision => "Increase precision of selected columns",
            .decrease_precision => "Decrease precision of selected columns",
            .increase_width => "Increase width of selected columns",
            .decrease_width => "Decrease width of selected columns",
            .assign_cell => "Assign expression",
            .assign_label => "",
            .fit_text => "Fit column to contents",
            .delete_column => "Delete columns",
            .delete_row => "Delete rows",
            .insert_column => "Insert <n> columns",
            .insert_row => "Insert <n> rows",

            .text_align_left => "Align text left",
            .text_align_right => "Align text right",
            .text_align_center => "Align text center",

            .visual_move_left => "Move selection left",
            .visual_move_right => "Move selection right",
            .visual_move_up => "Move selection up",
            .visual_move_down => "Move selection down",
            .select_submit => "Submit selection",
            .select_cancel => "Cancel selection",

            .zero => "",
            .count => "",

            .swap_anchor => "Swap anchor",
        };
    }
};

comptime {
    assert(@sizeOf(CommandAction) <= 8);
}

pub const CommandAction = union(enum(u6)) {
    // Motion tagged union duplicated to reduce memory usage

    motion_normal_word_inside,
    motion_long_word_inside,
    motion_normal_word_around,
    motion_long_word_around,

    /// Absolutely cursed - these fields store two UCS codepoints. This is done to save one byte.
    /// Storing them as two UTF-8 codepoints would require 8 bytes. Storing them as two u21 values
    /// would cause each one to get padded to 4 bytes, using 8 bytes total.
    motion_inside_delimiters: [7]u8 align(4),
    motion_around_delimiters: [7]u8 align(4),

    motion_inside_delimiters_scalar: [2]u8,
    motion_around_delimiters_scalar: [2]u8,
    motion_inside_single_delimiter_scalar: u8,
    motion_around_single_delimiter_scalar: u8,

    motion_inside_single_delimiter: u21,
    motion_around_single_delimiter: u21,
    motion_to_forwards: u21,
    motion_to_backwards: u21,
    motion_until_forwards: u21,
    motion_until_backwards: u21,

    motion_normal_word_start_next,
    motion_normal_word_start_prev,
    motion_normal_word_end_next,
    motion_normal_word_end_prev,
    motion_long_word_start_next,
    motion_long_word_start_prev,
    motion_long_word_end_next,
    motion_long_word_end_prev,
    motion_char_next,
    motion_char_prev,
    motion_line,
    motion_eol,
    motion_bol,

    // End of duplication

    completion_next,
    completion_prev,

    submit_command,
    enter_normal_mode,

    enter_select_mode,

    enter_insert_mode,
    enter_insert_mode_after,
    enter_insert_mode_at_eol,
    enter_insert_mode_at_bol,

    history_next,
    history_prev,

    backspace,
    delete_char,
    change_to_eol,
    delete_to_eol,
    delete_to_bol,
    change_char,
    change_line,
    backwards_delete_word,

    operator_delete,
    operator_change,

    operator_to_forwards,
    operator_until_forwards,
    operator_to_backwards,
    operator_until_backwards,

    zero,
    count: u4,

    /// Any inputs that aren't a mapping get passed as this. Its usage depends on the mode. For
    /// example, in insert mode the inputted text is passed along with this action if it does
    /// not correspond to another action.
    none,

    pub fn description(action: CommandAction) []const u8 {
        return switch (action) {
            .motion_normal_word_inside => "Inside word",
            .motion_long_word_inside => "Inside WORD",
            .motion_normal_word_around => "Around word",
            .motion_long_word_around => "Around WORD",

            .motion_inside_delimiters => "Inside delimiters",
            .motion_around_delimiters => "Around delimiters",

            .motion_inside_delimiters_scalar => "Inside delimiters",
            .motion_around_delimiters_scalar => "Around delimiters",
            .motion_inside_single_delimiter_scalar => "Inside delimiters",
            .motion_around_single_delimiter_scalar => "Around delimiters",

            .motion_inside_single_delimiter => "Inside delimiters",
            .motion_around_single_delimiter => "Around delimiters",
            .motion_to_forwards => "To forwards",
            .motion_to_backwards => "To backwards",
            .motion_until_forwards => "Until forwards",
            .motion_until_backwards => "Until backwards",

            .motion_normal_word_start_next => "Next word start",
            .motion_normal_word_start_prev => "Previous word start",
            .motion_normal_word_end_next => "Next word end",
            .motion_normal_word_end_prev => "Previous word end",
            .motion_long_word_start_next => "Next WORD start",
            .motion_long_word_start_prev => "Previous WORD start",
            .motion_long_word_end_next => "Next WORD end",
            .motion_long_word_end_prev => "Previous WORD end",
            .motion_char_next => "Next character",
            .motion_char_prev => "Previous character",
            .motion_line => "Line",
            .motion_eol => "To end of line",
            .motion_bol => "To beginning of line",

            .completion_next => "Next completion",
            .completion_prev => "Previous completion",

            .submit_command => "Submit command",
            .enter_normal_mode => "Enter normal mode",

            .enter_select_mode => "Enter select mode",

            .enter_insert_mode => "Insert at cursor",
            .enter_insert_mode_after => "Insert after cursor",
            .enter_insert_mode_at_eol => "Insert at end of line",
            .enter_insert_mode_at_bol => "Insert at beginning of line",

            .history_next => "History next",
            .history_prev => "History prev",

            .backspace => "Backspace",
            .delete_char => "Delete character",
            .change_to_eol => "Change to end of line",
            .delete_to_eol => "Delete to end of line",
            .delete_to_bol => "Delete to beginning of line",
            .change_char => "Change character",
            .change_line => "Change line",
            .backwards_delete_word => "Delete word backwards",

            .operator_delete => "Delete mode",
            .operator_change => "Change mode",

            .operator_to_forwards => "To forwards",
            .operator_until_forwards => "Until forwards",
            .operator_to_backwards => "To backwards",
            .operator_until_backwards => "Until backwards",

            .zero => "Zero",
            .count => "Count",

            .none => "",
        };
    }

    pub fn isMotion(action: CommandAction) bool {
        return @intFromEnum(action) <= @intFromEnum(CommandAction.motion_bol);
    }

    pub fn isMotionTag(tag: std.meta.Tag(CommandAction)) bool {
        return @intFromEnum(tag) <= @intFromEnum(CommandAction.motion_bol);
    }

    // Cursed function that converts a CommandAction to a Motion.
    pub fn toMotion(action: CommandAction) Motion {
        switch (action) {
            inline .motion_around_delimiters,
            .motion_inside_delimiters,
            => |buf, action_tag| {
                const b align(4) = buf; // `buf` is not aligned for some reason, so copy it
                const cps align(4) = utils.unpackDoubleCp(&b);
                const tag: std.meta.Tag(Motion) = @enumFromInt(@intFromEnum(action_tag));
                return @unionInit(Motion, @tagName(tag), .{
                    .left = cps[0],
                    .right = cps[1],
                });
            },
            inline .motion_inside_single_delimiter_scalar,
            .motion_around_single_delimiter_scalar,
            => |c, action_tag| {
                const tag: std.meta.Tag(Motion) = @enumFromInt(@intFromEnum(action_tag));
                return @unionInit(Motion, @tagName(tag), c);
            },
            else => {},
        }

        @setEvalBranchQuota(2000);
        const tag: std.meta.Tag(Motion) = @enumFromInt(@intFromEnum(action));
        switch (action) {
            inline else => |payload, action_tag| switch (tag) {
                inline else => |t| {
                    if (comptime (@intFromEnum(t) == @intFromEnum(action_tag) and
                        isMotionTag(action_tag) and
                        action_tag != .motion_inside_delimiters and
                        action_tag != .motion_around_delimiters and
                        action_tag != .motion_inside_single_delimiter_scalar and
                        action_tag != .motion_around_single_delimiter_scalar))
                    {
                        return @unionInit(Motion, @tagName(t), payload);
                    }
                },
            },
        }
        unreachable;
    }
};

pub const MapType = enum {
    normal,
    visual,
    select,

    visual_motions,
    common_motions,
    common_keys,
};

pub const CommandMapType = enum {
    normal,
    insert,
    operator_pending,
    to,
    non_insert_keys,
    common_keys,
};

const SheetKey = struct { [*:0]const u8, Action };
const CommandKey = struct { [*:0]const u8, CommandAction };

const SheetKeyMapData = struct {
    inherit: []const []const SheetKey,
    keys: []const SheetKey,
};

const CommandKeyMapData = struct {
    inherit: []const []const CommandKey,
    keys: []const CommandKey,
};

const sheet_common: []const SheetKey = &.{
    .{ "x", .delete_cell },
    .{ "<<", .text_align_left },
    .{ ">", .text_align_right },
    .{ "|", .text_align_center },
    .{ "yy", .yank_cell },
    .{ "p", .put_cell },
    .{ "P", .put_cell_adjust },
};

const sheet_motions: []const SheetKey = &.{
    .{ "<C-f>", .page_down },
    .{ "<C-b>", .page_up },
    .{ "<C-d>", .half_page_down },
    .{ "<C-u>", .half_page_up },
    .{ "j", .cell_cursor_down },
    .{ "k", .cell_cursor_up },
    .{ "h", .cell_cursor_left },
    .{ "l", .cell_cursor_right },
    .{ "w", .next_populated_cell },
    .{ "b", .prev_populated_cell },
    .{ "gc", .goto_col },
    .{ "gr", .goto_row },
    .{ "gg", .cell_cursor_row_first },
    .{ "G", .cell_cursor_row_last },
    .{ "ge", .cell_cursor_row_last },
    .{ "$", .cell_cursor_col_last },
    .{ "0", .zero }, // Could be motion or count
    .{ "1", .{ .count = 1 } },
    .{ "2", .{ .count = 2 } },
    .{ "3", .{ .count = 3 } },
    .{ "4", .{ .count = 4 } },
    .{ "5", .{ .count = 5 } },
    .{ "6", .{ .count = 6 } },
    .{ "7", .{ .count = 7 } },
    .{ "8", .{ .count = 8 } },
    .{ "9", .{ .count = 9 } },
};

const sheet_motions_visual: []const SheetKey = &.{
    .{ "<M-h>", .visual_move_left },
    .{ "<M-l>", .visual_move_right },
    .{ "<M-k>", .visual_move_up },
    .{ "<M-j>", .visual_move_down },
};

const sheet_normal: SheetKeyMapData = .{
    .inherit = &.{ sheet_common, sheet_motions },
    .keys = &.{
        .{ "<C-[>", .dismiss_count_or_status_message },
        .{ "<Escape>", .dismiss_count_or_status_message },
        .{ "\\", .assign_label },
        .{ "aa", .fit_text },
        .{ "+", .increase_width },
        .{ "-", .decrease_width },
        .{ "f", .increase_precision },
        .{ "F", .decrease_precision },
        .{ "=", .assign_cell },
        .{ "e", .edit_cell },
        .{ "dd", .delete_cell },
        .{ ":", .enter_command_mode },
        .{ "v", .enter_visual_mode },
        .{ "dc", .delete_column },
        .{ "dr", .delete_row },
        .{ "ic", .insert_column },
        .{ "ir", .insert_row },
        .{ "u", .undo },
        .{ "U", .redo },
        .{ "gn", .goto_next_sheet },
        .{ "gp", .goto_prev_sheet },
        .{ "<C-w>q", .close_sheet },
    },
};

const sheet_visual: SheetKeyMapData = .{
    .inherit = &.{ sheet_common, sheet_motions, sheet_motions_visual },
    .keys = &.{
        .{ "<C-[>", .enter_normal_mode },
        .{ "<Escape>", .enter_normal_mode },
        .{ "o", .swap_anchor },
        .{ "d", .delete_cell },
    },
};

const sheet_select: SheetKeyMapData = .{
    .inherit = &.{ sheet_common, sheet_motions, sheet_motions_visual },
    .keys = &.{
        .{ "<C-[>", .select_cancel },
        .{ "<Escape>", .select_cancel },
        .{ "o", .swap_anchor },
        .{ "<Return>", .select_submit },
        .{ "<C-j>", .select_submit },
        .{ "<C-m>", .select_submit },
    },
};

const command_common: []const CommandKey = &.{
    .{ "<C-m>", .submit_command },
    .{ "<C-j>", .submit_command },
    .{ "<Return>", .submit_command },
    .{ "<Home>", .motion_bol },
    .{ "<End>", .motion_eol },
    .{ "<Left>", .motion_char_prev },
    .{ "<Right>", .motion_char_next },
    .{ "<C-[>", .enter_normal_mode },
    .{ "<Escape>", .enter_normal_mode },
};

const command_non_insert: []const CommandKey = &.{
    .{ "1", .{ .count = 1 } },
    .{ "2", .{ .count = 2 } },
    .{ "3", .{ .count = 3 } },
    .{ "4", .{ .count = 4 } },
    .{ "5", .{ .count = 5 } },
    .{ "6", .{ .count = 6 } },
    .{ "7", .{ .count = 7 } },
    .{ "8", .{ .count = 8 } },
    .{ "9", .{ .count = 9 } },
    .{ "f", .operator_to_forwards },
    .{ "F", .operator_to_backwards },
    .{ "t", .operator_until_forwards },
    .{ "T", .operator_until_backwards },
    .{ "h", .motion_char_prev },
    .{ "l", .motion_char_next },
    .{ "0", .zero },
    .{ "$", .motion_eol },
    .{ "w", .motion_normal_word_start_next },
    .{ "W", .motion_long_word_start_next },
    .{ "e", .motion_normal_word_end_next },
    .{ "E", .motion_long_word_end_next },
    .{ "b", .motion_normal_word_start_prev },
    .{ "B", .motion_long_word_start_prev },
    .{ "<M-e>", .motion_normal_word_end_prev },
    .{ "<M-E>", .motion_long_word_end_prev },
};

const command_normal: CommandKeyMapData = .{
    .inherit = &.{ command_common, command_non_insert },
    .keys = &.{
        .{ "k", .history_prev },
        .{ "j", .history_next },
        .{ "<Up>", .history_prev },
        .{ "<Down>", .history_next },
        .{ "x", .delete_char },
        .{ "d", .operator_delete },
        .{ "D", .delete_to_eol },
        .{ "c", .operator_change },
        .{ "C", .change_to_eol },
        .{ "s", .change_char },
        .{ "S", .change_line },
        .{ "i", .enter_insert_mode },
        .{ "I", .enter_insert_mode_at_bol },
        .{ "a", .enter_insert_mode_after },
        .{ "A", .enter_insert_mode_at_eol },
    },
};
const command_insert: CommandKeyMapData = .{
    .inherit = &.{command_common},
    .keys = &.{
        .{ "<Tab>", .completion_next },
        .{ "<S-<Tab>>", .completion_prev },
        .{ "<C-p>", .history_prev },
        .{ "<C-n>", .history_next },
        .{ "<Up>", .history_prev },
        .{ "<Down>", .history_next },
        .{ "<C-h>", .backspace },
        .{ "<Delete>", .backspace },
        .{ "<C-u>", .delete_to_bol },
        .{ "<C-k>", .delete_to_eol },
        .{ "<C-v>", .enter_select_mode },
        .{ "<C-a>", .motion_bol },
        .{ "<C-e>", .motion_eol },
        .{ "<C-b>", .motion_char_prev },
        .{ "<C-f>", .motion_char_next },
        .{ "<C-w>", .backwards_delete_word },
    },
};
const command_operator_pending: CommandKeyMapData = .{
    .inherit = &.{ command_common, command_non_insert },
    .keys = &.{
        .{ "d", .operator_delete },
        .{ "c", .operator_change },
        .{ "aw", .motion_normal_word_around },
        .{ "aW", .motion_long_word_around },
        .{ "iw", .motion_normal_word_inside },
        .{ "iW", .motion_long_word_inside },
        .{ "a(", .{ .motion_around_delimiters_scalar = .{ '(', ')' } } },
        .{ "i(", .{ .motion_inside_delimiters_scalar = .{ '(', ')' } } },
        .{ "a)", .{ .motion_around_delimiters_scalar = .{ '(', ')' } } },
        .{ "i)", .{ .motion_inside_delimiters_scalar = .{ '(', ')' } } },
        .{ "a[", .{ .motion_around_delimiters_scalar = .{ '[', ']' } } },
        .{ "i[", .{ .motion_inside_delimiters_scalar = .{ '[', ']' } } },
        .{ "a]", .{ .motion_around_delimiters_scalar = .{ '[', ']' } } },
        .{ "i]", .{ .motion_inside_delimiters_scalar = .{ '[', ']' } } },
        .{ "i{", .{ .motion_inside_delimiters_scalar = .{ '{', '}' } } },
        .{ "a{", .{ .motion_around_delimiters_scalar = .{ '{', '}' } } },
        .{ "i}", .{ .motion_inside_delimiters_scalar = .{ '{', '}' } } },
        .{ "a}", .{ .motion_around_delimiters_scalar = .{ '{', '}' } } },
        .{ "i<<", .{ .motion_inside_delimiters_scalar = .{ '<', '>' } } },
        .{ "a<<", .{ .motion_around_delimiters_scalar = .{ '<', '>' } } },
        .{ "i>", .{ .motion_inside_delimiters_scalar = .{ '<', '>' } } },
        .{ "a>", .{ .motion_around_delimiters_scalar = .{ '<', '>' } } },
        .{ "i\"", .{ .motion_inside_single_delimiter_scalar = '"' } },
        .{ "a\"", .{ .motion_around_single_delimiter_scalar = '"' } },
        .{ "i'", .{ .motion_inside_single_delimiter_scalar = '\'' } },
        .{ "a'", .{ .motion_around_single_delimiter_scalar = '\'' } },
        .{ "i`", .{ .motion_inside_single_delimiter_scalar = '`' } },
        .{ "a`", .{ .motion_around_single_delimiter_scalar = '`' } },
    },
};

const command_to: CommandKeyMapData = .{
    .inherit = &.{command_common},
    .keys = &.{},
};
