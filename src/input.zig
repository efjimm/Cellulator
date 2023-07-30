const std = @import("std");
const utils = @import("utils.zig");
const Allocator = std.mem.Allocator;
const Motion = @import("text.zig").Motion;
const critbit = @import("critbit.zig");
const inputParser = @import("spoon").inputParser;

const assert = std.debug.assert;

pub fn createKeymaps(allocator: Allocator) !struct {
    sheet_keys: KeyMap(Action, MapType),
    command_keys: KeyMap(CommandAction, CommandMapType),
} {
    var sheet_keymaps = try KeyMap(Action, MapType).init(sheet_keys, allocator);
    errdefer sheet_keymaps.deinit(allocator);

    var command_keymaps = try KeyMap(CommandAction, CommandMapType).init(command_keys, allocator);
    errdefer command_keymaps.deinit(allocator);

    return .{
        .sheet_keys = sheet_keymaps,
        .command_keys = command_keymaps,
    };
}

pub fn parse(bytes: []const u8, writer: anytype) @TypeOf(writer).Error!void {
    var iter = inputParser(bytes);

    while (iter.next()) |in| {
        var special = false;
        if (in.mod_ctrl and in.mod_alt) {
            special = true;
            try writer.writeAll("<C-M-");
        } else if (in.mod_ctrl) {
            special = true;
            try writer.writeAll("<C-");
        } else if (in.mod_alt) {
            special = true;
            try writer.writeAll("<M-");
        }

        switch (in.content) {
            .escape => try writer.writeAll("<Escape>"),
            .arrow_up => try writer.writeAll("<Up>"),
            .arrow_down => try writer.writeAll("<Down>"),
            .arrow_left => try writer.writeAll("<Left>"),
            .arrow_right => try writer.writeAll("<Right>"),
            .home => try writer.writeAll("<Home>"),
            .end => try writer.writeAll("<End>"),
            .begin => try writer.writeAll("<Begin>"),
            .page_up => try writer.writeAll("<PageUp>"),
            .page_down => try writer.writeAll("<PageDown>"),
            .delete => try writer.writeAll("<Delete>"),
            .insert => try writer.writeAll("<Insert>"),
            .print => try writer.writeAll("<Print>"),
            .scroll_lock => try writer.writeAll("<Scroll>"),
            .pause => try writer.writeAll("<Pause>"),
            .function => |function| try writer.print("<F{d}>", .{function}),
            .codepoint => |cp| switch (cp) {
                '<' => try writer.writeAll("<<"),
                '\n', '\r' => try writer.writeAll("<Return>"),
                127 => try writer.writeAll("<Delete>"),
                0...'\n' - 1, '\n' + 1...'\r' - 1, '\r' + 1...31 => {},
                else => {
                    var buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &buf) catch continue;
                    try writer.writeAll(buf[0..len]);
                },
            },
            .mouse, .unknown => {},
        }

        if (special) {
            try writer.writeByte('>');
        }
    }
}

pub const Action = union(enum) {
    enter_normal_mode,
    enter_visual_mode,
    enter_command_mode,
    edit_cell,
    edit_label,
    dismiss_count_or_status_message,

    undo,
    redo,

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

    visual_move_left,
    visual_move_right,
    visual_move_up,
    visual_move_down,
    select_submit,
    select_cancel,

    zero,
    count: u4,

    // Visual mode only
    swap_anchor,
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

pub fn KeyMap(comptime A: type, comptime M: type) type {
    return struct {
        const CritMap = critbit.CritBitMap([*:0]const u8, A, critbit.StringContextZ);
        pub const Map = struct {
            keys: CritMap,
            parents: []const M,
        };

        maps: std.EnumArray(M, Map),

        pub fn init(default: anytype, allocator: Allocator) !@This() {
            var maps = std.EnumArray(M, Map).initFill(.{
                .keys = CritMap.init(),
                .parents = &.{},
            });
            errdefer for (&maps.values) |*v| v.keys.deinit(allocator);

            for (default) |map| {
                var m = CritMap.init();
                errdefer m.deinit(allocator);

                for (map.keys) |mapping| {
                    try m.put(allocator, mapping[0], mapping[1]);
                }

                maps.set(map.type, .{
                    .keys = m,
                    .parents = map.parents,
                });
            }
            return .{
                .maps = maps,
            };
        }

        /// Returns the action associated with the given input, or `null` if not found. Looks
        /// recursively through parent maps if not found.
        pub fn get(self: @This(), mode: M, input: [*:0]const u8) CritMap.GetResult {
            var state: CritMap.GetResult = .not_found;
            const map = self.maps.getPtrConst(mode);
            switch (map.keys.get(input)) {
                .value => |v| return .{ .value = v },
                .prefix => state = .prefix,
                .not_found => {},
            }

            return for (map.parents) |parent_mode| {
                switch (self.get(parent_mode, input)) {
                    .value => |v| return .{ .value = v },
                    .prefix => state = .prefix,
                    .not_found => {},
                }
            } else state;
        }

        pub fn contains(self: @This(), mode: M, input: [*:0]const u8) bool {
            const map = self.maps.getPtrConst(mode);
            if (map.keys.contains(input)) return true;
            for (map.parents) |parent_mode| {
                const parent = self.maps.getPtrConst(parent_mode);
                if (parent.keys.contains(input)) return true;
            }
            return false;
        }

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            for (&self.maps.values) |*v| {
                v.keys.deinit(allocator);
            }
            self.* = undefined;
        }
    };
}

const KeyMaps = struct {
    type: MapType,
    parents: []const MapType,
    keys: []const struct {
        [*:0]const u8,
        Action,
    },
};

const sheet_keys = [_]KeyMaps{
    .{
        .type = .common_keys,
        .parents = &.{},
        .keys = &.{
            .{ "x", .delete_cell },
        },
    },
    .{
        .type = .common_motions,
        .parents = &.{},
        .keys = &.{
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
        },
    },
    .{
        .type = .visual_motions,
        .parents = &.{},
        .keys = &.{
            .{ "<M-h>", .visual_move_left },
            .{ "<M-l>", .visual_move_right },
            .{ "<M-k>", .visual_move_up },
            .{ "<M-j>", .visual_move_down },
        },
    },
    .{
        .type = .normal,
        .parents = &.{.common_motions},
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
            .{ "E", .edit_label },
            .{ "dd", .delete_cell },
            .{ ":", .enter_command_mode },
            .{ "v", .enter_visual_mode },
            .{ "u", .undo },
            .{ "U", .redo },
        },
    },
    .{
        .type = .visual,
        .parents = &.{ .common_motions, .visual_motions },
        .keys = &.{
            .{ "<C-[>", .enter_normal_mode },
            .{ "<Escape>", .enter_normal_mode },
            .{ "o", .swap_anchor },
            .{ "d", .delete_cell },
        },
    },
    .{
        .type = .select,
        .parents = &.{ .common_motions, .visual_motions },
        .keys = &.{
            .{ "<C-[>", .select_cancel },
            .{ "<Escape>", .select_cancel },
            .{ "o", .swap_anchor },
            .{ "<Return>", .select_submit },
            .{ "<C-j>", .select_submit },
            .{ "<C-m>", .select_submit },
        },
    },
};

const CommandKeyMaps = struct {
    type: CommandMapType,
    parents: []const CommandMapType,
    keys: []const struct {
        [*:0]const u8,
        CommandAction,
    },
};

const command_keys = [_]CommandKeyMaps{
    .{
        .type = .common_keys,
        .parents = &.{},
        .keys = &.{
            .{ "<C-m>", .submit_command },
            .{ "<C-j>", .submit_command },
            .{ "<Return>", .submit_command },
            .{ "<Home>", .motion_bol },
            .{ "<End>", .motion_eol },
            .{ "<Left>", .motion_char_prev },
            .{ "<Right>", .motion_char_next },
            .{ "<C-[>", .enter_normal_mode },
            .{ "<Escape>", .enter_normal_mode },
        },
    },
    .{
        .type = .non_insert_keys,
        .parents = &.{},
        .keys = &.{
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
        },
    },
    .{
        .type = .normal,
        .parents = &.{ .common_keys, .non_insert_keys },
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
    },
    .{
        .type = .insert,
        .parents = &.{.common_keys},
        .keys = &.{
            .{ "<C-p>", .history_prev },
            .{ "<C-n>", .history_next },
            .{ "<Up>", .history_prev },
            .{ "<Down>", .history_next },
            .{ "<C-h>", .backspace },
            .{ "<Delete>", .backspace },
            .{ "<C-u>", .change_line },
            .{ "<C-v>", .enter_select_mode },
            .{ "<C-a>", .motion_bol },
            .{ "<C-e>", .motion_eol },
            .{ "<C-b>", .motion_char_prev },
            .{ "<C-f>", .motion_char_next },
            .{ "<C-w>", .backwards_delete_word },
        },
    },
    .{
        .type = .operator_pending,
        .parents = &.{ .common_keys, .non_insert_keys },
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
    },
    .{
        .type = .to,
        .parents = &.{.common_keys},
        .keys = &.{},
    },
};
