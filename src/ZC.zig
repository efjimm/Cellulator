const std = @import("std");
const utils = @import("utils.zig");
const Ast = @import("Parse.zig");
const spoon = @import("spoon");
const Sheet = @import("Sheet.zig");
const Tui = @import("Tui.zig");
const critbit = @import("critbit.zig");
const text = @import("text.zig");
const Motion = text.Motion;
const wcWidth = @import("wcwidth").wcWidth;

const Position = Sheet.Position;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.zc);

const Self = @This();

running: bool = true,

sheet: Sheet,
tui: Tui,

prev_mode: Mode = .normal,
mode: Mode = .normal,

/// The top left corner of the screen
screen_pos: Position = .{},

anchor: Position = .{},

prev_cursor: Position = .{},

/// The cell position of the cursor
cursor: Position = .{},

command_screen_pos: u16 = 0,
command_cursor: u16 = 0,
command_buf: std.BoundedArray(u8, 512) = .{},

asts: std.ArrayListUnmanaged(Ast) = .{},

count: u32 = 0,

keymaps: KeyMap(Action, MapType),
command_keymaps: KeyMap(CommandAction, CommandMapType),

allocator: Allocator,

input_buf_sfa: std.heap.StackFallbackAllocator(INPUT_BUF_LEN),
input_buf: std.ArrayListUnmanaged(u8) = .{},

status_message_type: StatusMessageType = .info,
status_message: std.BoundedArray(u8, 256) = .{},

const INPUT_BUF_LEN = 256;

pub const status_line = 0;
pub const input_line = 1;
pub const col_heading_line = 2;
pub const content_line = 3;

pub const Mode = enum {
    normal,

    /// Holds the 'anchor' position
    visual,

    /// Same as visual mode, with different operations allowed. Used for inserting
    /// the text representation of the selected range into the command buffer.
    select,

    // Command modes

    command_normal,
    command_insert,

    // Operator pending modes
    command_change,
    command_delete,

    // To
    command_to_forwards,
    command_until_forwards,
    command_to_backwards,
    command_until_backwards,

    pub fn isCommandMode(mode: Mode) bool {
        return switch (mode) {
            .command_normal,
            .command_insert,
            .command_change,
            .command_delete,
            .command_to_forwards,
            .command_to_backwards,
            .command_until_forwards,
            .command_until_backwards,
            => true,
            .normal, .visual, .select => false,
        };
    }

    pub fn format(
        mode: Mode,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try writer.writeAll(@tagName(mode));
    }
};

pub const InitOptions = struct {
    filepath: ?[]const u8 = null,
    ui: bool = true,
};

pub fn init(allocator: Allocator, options: InitOptions) !Self {
    var ast_list = try std.ArrayListUnmanaged(Ast).initCapacity(allocator, 8);
    errdefer ast_list.deinit(allocator);

    var keymaps = try KeyMap(Action, MapType).init(outer_keys, allocator);
    errdefer keymaps.deinit(allocator);

    var command_keymaps = try KeyMap(CommandAction, CommandMapType).init(command_keys, allocator);
    errdefer command_keymaps.deinit(allocator);

    var tui = try Tui.init();
    errdefer tui.deinit();

    if (options.ui) {
        try tui.term.uncook(.{});
    }

    var ret = Self{
        .sheet = Sheet.init(allocator),
        .tui = tui,
        .allocator = allocator,
        .asts = ast_list,
        .keymaps = keymaps,
        .command_keymaps = command_keymaps,
        .input_buf_sfa = std.heap.stackFallback(INPUT_BUF_LEN, allocator),
    };

    try ret.sheet.ensureTotalCapacity(128);

    if (options.filepath) |filepath| {
        try ret.loadFile(&ret.sheet, filepath);
    }

    log.debug("Finished init", .{});

    return ret;
}

pub fn deinit(self: *Self) void {
    for (self.asts.items) |*ast| {
        ast.deinit(self.allocator);
    }

    self.input_buf.deinit(self.allocator);
    self.keymaps.deinit(self.allocator);
    self.command_keymaps.deinit(self.allocator);

    self.asts.deinit(self.allocator);
    self.sheet.deinit();
    self.tui.deinit();
    self.* = undefined;
}

pub fn resetInputBuf(self: *Self) void {
    self.input_buf.items.len = 0;
    self.input_buf_sfa.fixed_buffer_allocator.reset();
}

pub fn inputBufSlice(self: *Self) ![:0]const u8 {
    const len = self.input_buf.items.len;
    try self.input_buf.append(self.allocator, 0);
    self.input_buf.items.len = len;
    return self.input_buf.items.ptr[0..len :0];
}

pub fn run(self: *Self) !void {
    while (self.running) {
        try self.updateCells();
        try self.tui.render(self);
        try self.handleInput();
    }
}

pub const StatusMessageType = enum {
    info,
    warn,
    err,
};

pub fn setStatusMessage(
    self: *Self,
    t: StatusMessageType,
    comptime fmt: []const u8,
    args: anytype,
) void {
    self.dismissStatusMessage();
    self.status_message_type = t;
    const writer = self.status_message.writer();
    writer.print(fmt, args) catch {};
    self.tui.update.command = true;
}

pub fn dismissStatusMessage(self: *Self) void {
    self.status_message.len = 0;
    self.tui.update.command = true;
}

pub fn updateCells(self: *Self) Allocator.Error!void {
    return self.sheet.update();
}

fn setMode(self: *Self, new_mode: Mode) void {
    switch (self.mode) {
        .normal => {},
        .visual, .select => {
            self.tui.update.cells = true;
            self.tui.update.column_headings = true;
            self.tui.update.row_numbers = true;
        },
        .command_normal,
        .command_insert,
        .command_delete,
        .command_change,
        .command_to_forwards,
        .command_to_backwards,
        .command_until_forwards,
        .command_until_backwards,
        => self.tui.update.command = true,
    }

    self.prev_mode = self.mode;
    self.anchor = self.cursor;
    self.mode = new_mode;
}

const GetActionResult = union(enum) {
    normal: Action,
    command: CommandAction,
    prefix,
    not_found,
};

fn getAction(self: Self, input: [:0]const u8) GetActionResult {
    if (self.mode.isCommandMode()) {
        const keymap_type: CommandMapType = switch (self.mode) {
            .command_normal => .normal,
            .command_insert => .insert,
            .command_change, .command_delete => .operator_pending,
            .command_to_forwards,
            .command_to_backwards,
            .command_until_forwards,
            .command_until_backwards,
            => .to,
            else => unreachable,
        };

        return switch (self.command_keymaps.get(keymap_type, input)) {
            .value => |action| .{ .command = action },
            .prefix => .prefix,
            .not_found => .not_found,
        };
    }

    const keymap_type: MapType = switch (self.mode) {
        .normal => .normal,
        .visual => .visual,
        .select => .select,
        else => unreachable,
    };

    return switch (self.keymaps.get(keymap_type, input)) {
        .value => |action| .{ .normal = action },
        .prefix => .prefix,
        .not_found => .not_found,
    };
}

fn handleInput(self: *Self) !void {
    var buf: [INPUT_BUF_LEN / 2]u8 = undefined;
    const slice = try self.tui.term.readInput(&buf);

    const writer = self.input_buf.writer(self.allocator);
    try parseInput(slice, writer);

    const input = try self.inputBufSlice();
    const res = self.getAction(input);
    switch (res) {
        .normal => |action| switch (self.mode) {
            .normal => try self.doNormalMode(action),
            .visual, .select => self.doVisualMode(action),
            else => unreachable,
        },
        .command => |action| self.doCommandMode(action) catch |err| switch (err) {
            error.EmptyFileName => self.setStatusMessage(.err, "Empty file name", .{}),
            error.InvalidCellAddress => self.setStatusMessage(.err, "Invalid cell address", .{}),
            error.InvalidCommand => self.setStatusMessage(.err, "Invalid command", .{}),
            error.OutOfMemory => self.setStatusMessage(.err, "Out of memory!", .{}),
            error.UnexpectedToken => self.setStatusMessage(.err, "Unexpected token", .{}),
        },
        .prefix => return,
        .not_found => {
            if (self.mode.isCommandMode()) {
                try self.doCommandMode(.none);
            }
        },
    }
    self.resetInputBuf();
}

pub fn doCommandMode(self: *Self, action: CommandAction) !void {
    switch (self.mode) {
        .command_normal => try self.doCommandNormalMode(action),
        .command_insert => try self.doCommandInsertMode(action),
        .command_change, .command_delete => self.doCommandOperatorPendingMode(action),
        .command_to_forwards,
        .command_to_backwards,
        .command_until_forwards,
        .command_until_backwards,
        => self.doCommandToMode(action),
        else => unreachable,
    }
}

pub fn resetCommandBuf(self: *Self) void {
    self.command_buf.len = 0;
    self.setCommandCursor(0);
}

pub inline fn doCommandNormalMotion(self: *Self, range: text.Range) void {
    self.setCommandCursor(if (range.start == self.command_cursor) range.end else range.start);
}

fn clampCommandCursor(self: *Self) void {
    const slice = self.command_buf.slice();
    const len = @intCast(u16, slice.len);
    const end = len - text.prevCharacter(slice, len, @boolToInt(self.mode == .normal));

    if (self.command_cursor > end)
        self.setCommandCursor(end);
}

fn clampScreenToCommandCursor(self: *Self) void {
    if (self.command_cursor < self.command_screen_pos) {
        self.command_screen_pos = self.command_cursor;
        return;
    }

    const slice = self.command_buf.slice();
    var x: u16 = self.command_cursor;
    // Reserve either the width of the character under the cursor, or 1 column if none.
    var w: u16 = if (self.command_cursor < slice.len) blk: {
        const len = std.unicode.utf8ByteSequenceLength(slice[x]) catch unreachable;
        const cp = std.unicode.utf8Decode(slice[x .. x + len]) catch unreachable;
        break :blk wcWidth(cp);
    } else 1;

    while (true) {
        const prev = x;
        x -= text.prevCodepoint(slice, x);
        if (prev == x or x < self.screen_pos.x) break;

        const cp = std.unicode.utf8Decode(slice[x..prev]) catch unreachable;
        w += wcWidth(cp);

        if (w > self.tui.term.width) {
            if (prev > self.command_screen_pos) self.command_screen_pos = prev;
            break;
        }
    }
}

pub fn setCommandCursor(self: *Self, pos: u16) void {
    self.command_cursor = pos;
    self.clampCommandCursor();
    self.clampScreenToCommandCursor();
}

pub fn doCommandMotion(self: *Self, motion: Motion) void {
    const count = self.getCount();
    const range = motion.do(self.command_buf.slice(), self.command_cursor, count);
    switch (self.mode) {
        .normal, .visual, .select => unreachable,
        .command_normal, .command_insert => {
            self.doCommandNormalMotion(range);
        },
        .command_change => {
            const m = switch (motion) {
                .normal_word_start_next => .normal_word_end_next,
                .long_word_start_next => .long_word_end_next,
                else => motion,
            };

            if (range.start != range.end) {
                // We want the 'end' part of the range to be inclusive for some motions and
                // exclusive for others.
                const end = range.end + switch (m) {
                    .normal_word_end_next,
                    .long_word_end_next,
                    .to_forwards,
                    .to_forwards_utf8,
                    .to_backwards,
                    .to_backwards_utf8,
                    .until_forwards,
                    .until_forwards_utf8,
                    .until_backwards,
                    .until_backwards_utf8,
                    => text.nextCharacter(self.command_buf.slice(), range.end, 1),
                    else => 0,
                };

                assert(end >= range.start);
                self.command_buf.replaceRange(range.start, end - range.start, &.{}) catch unreachable;
                self.setCommandCursor(range.start);
            }
            self.setMode(.command_insert);
        },
        .command_delete => {
            if (range.start != range.end) {
                const end = range.end + switch (motion) {
                    .normal_word_end_next,
                    .long_word_end_next,
                    .to_forwards,
                    .to_forwards_utf8,
                    .to_backwards,
                    .to_backwards_utf8,
                    .until_forwards,
                    .until_forwards_utf8,
                    .until_backwards,
                    .until_backwards_utf8,
                    => text.nextCharacter(self.command_buf.slice(), range.end, 1),
                    else => 0,
                };
                self.command_buf.replaceRange(range.start, end - range.start, &.{}) catch unreachable;
                self.setCommandCursor(range.start);
            }
            self.setMode(.command_normal);
        },
        .command_to_forwards,
        .command_to_backwards,
        .command_until_forwards,
        .command_until_backwards,
        => unreachable, // Attempted motion in 'to' mode
    }
    self.resetCount();
}

pub fn submitCommand(self: *Self) !void {
    assert(self.mode.isCommandMode());
    self.dismissStatusMessage();
    const res = self.parseCommand(self.command_buf.slice());
    self.resetCommandBuf();
    self.setMode(.normal);
    try res;
}

pub fn doCommandToMode(self: *Self, action: CommandAction) void {
    switch (action) {
        .enter_normal_mode => self.setMode(.command_normal),
        .none => {
            const keys = self.input_buf.items;
            if (keys.len > 0) {
                self.setMode(self.prev_mode);
                switch (self.prev_mode) {
                    .command_to_forwards => self.doCommandMotion(.{ .to_forwards_utf8 = keys }),
                    .command_to_backwards => self.doCommandMotion(.{ .to_backwards_utf8 = keys }),
                    .command_until_forwards => self.doCommandMotion(.{ .until_forwards_utf8 = keys }),
                    .command_until_backwards => self.doCommandMotion(.{ .until_backwards_utf8 = keys }),
                    else => unreachable,
                }
            }
        },
        else => {},
    }
}

pub fn doCommandNormalMode(self: *Self, action: CommandAction) !void {
    switch (action) {
        .submit_command => try self.submitCommand(),
        .enter_normal_mode => {
            self.resetCommandBuf();
            self.setMode(.normal);
        },
        .enter_insert_mode => self.setMode(.command_insert),
        .enter_insert_mode_after => {
            self.setMode(.command_insert);
            self.doCommandMotion(.char_next);
        },
        .enter_insert_mode_at_eol => {
            self.setMode(.command_insert);
            self.doCommandMotion(.eol);
        },
        .enter_insert_mode_at_bol => {
            self.setMode(.command_insert);
            self.doCommandMotion(.bol);
        },
        .operator_delete => self.setMode(.command_delete),
        .operator_change => self.setMode(.command_change),
        inline .delete_char, .change_char => |_, a| {
            const len = text.nextCharacter(self.command_buf.slice(), self.command_cursor, 1);
            self.command_buf.replaceRange(self.command_cursor, len, &.{}) catch unreachable;
            if (a == .change_char) self.setMode(.command_insert);
            self.clampCommandCursor();
        },
        .change_to_eol => {
            self.command_buf.len = self.command_cursor;
            self.setMode(.command_insert);
        },
        .delete_to_eol => {
            self.command_buf.len = self.command_cursor;
        },
        .change_line => {
            self.resetCommandBuf();
            self.setMode(.command_insert);
        },
        .operator_to_forwards => self.setMode(.command_to_forwards),
        .operator_to_backwards => self.setMode(.command_to_backwards),
        .operator_until_forwards => self.setMode(.command_until_forwards),
        .operator_until_backwards => self.setMode(.command_until_backwards),
        .zero => {
            if (self.count == 0) {
                self.setCommandCursor(0);
            } else {
                self.setCount(0);
            }
        },
        .count => |count| self.setCount(count),
        else => {
            if (action.isMotion()) {
                self.doCommandMotion(action.toMotion());
            }
        },
    }
}

fn doCommandInsertMode(self: *Self, action: CommandAction) !void {
    try switch (action) {
        .none => {
            const keys = self.input_buf.items;
            if (keys.len > 0) {
                self.command_buf.insertSlice(self.command_cursor, keys) catch return;
                self.setCommandCursor(self.command_cursor + @intCast(u16, keys.len));
            }
        },
        .backspace => {
            self.setMode(.command_change);
            self.doCommandMotion(.char_prev);
        },
        .submit_command => self.submitCommand(),
        .enter_normal_mode => self.setMode(.command_normal),
        .enter_select_mode => self.setMode(.select),
        .backwards_delete_word => {
            self.setMode(.command_change);
            self.doCommandMotion(.normal_word_start_prev);
        },
        .change_line => self.resetCommandBuf(),
        else => {
            if (action.isMotion()) {
                self.doCommandMotion(action.toMotion());
            }
        },
    };
}

/// Handles common actions between operator modes
fn doCommandOperatorPendingMode(self: *Self, action: CommandAction) void {
    switch (action) {
        .enter_normal_mode => self.setMode(.command_normal),

        .operator_to_forwards => self.setMode(.command_to_forwards),
        .operator_to_backwards => self.setMode(.command_to_backwards),
        .operator_until_forwards => self.setMode(.command_until_forwards),
        .operator_until_backwards => self.setMode(.command_until_backwards),

        .zero => if (self.count == 0) self.doCommandMotion(.bol) else self.setCount(0),
        .count => |count| self.setCount(count),

        .operator_delete => if (self.mode == .command_delete) self.doCommandMotion(.line),
        .operator_change => if (self.mode == .command_change) self.doCommandMotion(.line),
        inline else => |_, tag| {
            if (comptime CommandAction.isMotionTag(tag)) {
                self.doCommandMotion(action.toMotion());
            }
        },
    }
}

pub fn doNormalMode(self: *Self, action: Action) !void {
    switch (action) {
        .enter_command_mode => {
            self.setMode(.command_insert);
            const writer = self.command_buf.writer();
            writer.writeByte(':') catch unreachable;
            self.setCommandCursor(1);
        },
        .enter_visual_mode => self.setMode(.visual),
        .enter_normal_mode => {},
        .dismiss_count_or_status_message => {
            if (self.count != 0) {
                self.resetCount();
            } else {
                self.dismissStatusMessage();
            }
        },

        .cell_cursor_up => self.cursorUp(),
        .cell_cursor_down => self.cursorDown(),
        .cell_cursor_left => self.cursorLeft(),
        .cell_cursor_right => self.cursorRight(),
        .cell_cursor_row_first => self.cursorToFirstCellInColumn(),
        .cell_cursor_row_last => self.cursorToLastCellInColumn(),
        .cell_cursor_col_first => self.cursorToFirstCell(),
        .cell_cursor_col_last => self.cursorToLastCell(),

        .delete_cell => self.deleteCell() catch |err| switch (err) {
            error.OutOfMemory => self.setStatusMessage(.err, "Out of memory!", .{}),
        },
        .next_populated_cell => self.cursorNextPopulatedCell(),
        .prev_populated_cell => self.cursorPrevPopulatedCell(),
        .increase_precision => self.cursorIncPrecision(),
        .decrease_precision => self.cursorDecPrecision(),
        .increase_width => self.cursorIncWidth(),
        .decrease_width => self.cursorDecWidth(),
        .assign_cell => {
            self.setMode(.command_insert);
            const writer = self.command_buf.writer();
            self.cursor.writeCellAddress(writer) catch unreachable;
            writer.writeAll(" = ") catch unreachable;
            self.setCommandCursor(@intCast(u16, self.command_buf.len));
        },

        .zero => {
            if (self.count == 0) {
                self.cursorToFirstCell();
            } else {
                self.setCount(0);
            }
        },
        .count => |count| self.setCount(count),
        else => {},
    }
}

fn getAnchor(self: *Self) *Position {
    return &self.anchor;
}

fn doVisualMode(self: *Self, action: Action) void {
    assert(self.mode == .visual or self.mode == .select);
    switch (action) {
        .enter_normal_mode => self.setMode(.normal),
        .swap_anchor => {
            const anchor = self.getAnchor();
            const temp = anchor.*;
            anchor.* = self.cursor;
            self.setCursor(temp);
        },

        .select_cancel => self.setMode(.command_insert),
        .select_submit => {
            const writer = self.command_buf.writer();
            const tl = Position.topLeft(self.cursor, self.anchor);
            const br = Position.bottomRight(self.cursor, self.anchor);
            writer.print("{}:{}", .{ tl, br }) catch {};
            self.setMode(.command_insert);
        },

        .cell_cursor_up => self.cursorUp(),
        .cell_cursor_down => self.cursorDown(),
        .cell_cursor_left => self.cursorLeft(),
        .cell_cursor_right => self.cursorRight(),
        .cell_cursor_row_first => self.cursorToFirstCellInColumn(),
        .cell_cursor_row_last => self.cursorToLastCellInColumn(),
        .cell_cursor_col_first => self.cursorToFirstCell(),
        .cell_cursor_col_last => self.cursorToLastCell(),
        .next_populated_cell => self.cursorNextPopulatedCell(),
        .prev_populated_cell => self.cursorPrevPopulatedCell(),

        .zero => self.setCount(0),
        .count => |count| self.setCount(count),

        .visual_move_up => self.selectionUp(),
        .visual_move_down => self.selectionDown(),
        .visual_move_left => self.selectionLeft(),
        .visual_move_right => self.selectionRight(),

        .delete_cell => {
            self.sheet.deleteCellsInRange(self.cursor, self.anchor);
            self.setMode(.normal);
            self.tui.update.cells = true;
        },
        else => {},
    }
}

const ParseCommandError = Ast.ParseError || RunCommandError;

fn parseCommand(self: *Self, str: []const u8) ParseCommandError!void {
    if (str.len == 0) return;

    if (str[0] == ':') {
        return self.runCommand(str[1..]);
    }

    var ast = self.newAst();
    ast.parse(self.allocator, str) catch |err| {
        self.delAstAssumeCapacity(ast);
        return err;
    };

    const root = ast.rootNode();
    switch (root) {
        .assignment => |op| {
            const pos = ast.nodes.items(.data)[op.lhs].cell;
            ast.splice(op.rhs);

            self.sheet.setCell(pos, .{ .ast = ast }) catch |err| {
                self.delAstAssumeCapacity(ast);
                return err;
            };
            self.tui.update.cursor = true;
            self.tui.update.cells = true;
        },
        else => {
            self.delAstAssumeCapacity(ast);
        },
    }
}

pub fn isSelectedCell(self: Self, pos: Position) bool {
    return switch (self.mode) {
        .visual, .select => pos.intersects(self.anchor, self.cursor),
        else => self.cursor.hash() == pos.hash(),
    };
}

pub fn isSelectedCol(self: Self, x: u16) bool {
    return switch (self.mode) {
        .visual, .select => {
            const min = @min(self.cursor.x, self.anchor.x);
            const max = @max(self.cursor.x, self.anchor.x);
            return x >= min and x <= max;
        },
        else => self.cursor.x == x,
    };
}

pub fn isSelectedRow(self: Self, y: u16) bool {
    return switch (self.mode) {
        .visual, .select => {
            const min = @min(self.cursor.y, self.anchor.y);
            const max = @max(self.cursor.y, self.anchor.y);
            return y >= min and y <= max;
        },
        else => self.cursor.y == y,
    };
}

pub fn nextPopulatedCell(self: *Self, start_pos: Position, count: u32) Position {
    if (count == 0) return start_pos;
    const positions = self.sheet.cells.keys();
    if (positions.len == 0) return start_pos;

    var ret = start_pos;

    // Index of the first position that is greater than start_pos
    const first = for (positions, count - 1..) |pos, i| {
        if (pos.hash() > start_pos.hash()) break i;
    } else return ret;

    // count-1 positions after the first one that is greater than start_pos
    return positions[@min(positions.len - 1, first)];
}

pub fn prevPopulatedCell(self: *Self, start_pos: Position, count: u32) Position {
    if (count == 0) return start_pos;

    const positions = self.sheet.cells.keys();
    var iter = std.mem.reverseIterator(positions);
    while (iter.next()) |pos| {
        if (pos.hash() < start_pos.hash()) break;
    } else return start_pos;

    return positions[iter.index -| (count - 1)];
}

pub fn cursorNextPopulatedCell(self: *Self) void {
    const new_pos = self.nextPopulatedCell(self.cursor, self.getCount());
    self.setCursor(new_pos);
    self.resetCount();
}

pub fn cursorPrevPopulatedCell(self: *Self) void {
    const new_pos = self.prevPopulatedCell(self.cursor, self.getCount());
    self.setCursor(new_pos);
    self.resetCount();
}

pub fn setCount(self: *Self, count: u4) void {
    assert(count <= 9);
    self.count = self.count *| 10 +| count;
}

pub fn getCount(self: Self) u32 {
    return if (self.count == 0) 1 else self.count;
}

pub fn getCountU16(self: Self) u16 {
    return @intCast(u16, @min(std.math.maxInt(u16), self.getCount()));
}

pub fn resetCount(self: *Self) void {
    self.count = 0;
}

const Cmd = enum {
    save,
    save_force,
    load,
    load_force,
    quit,
    quit_force,
};

const cmds = std.ComptimeStringMap(Cmd, .{
    .{ "w", .save },
    .{ "w!", .save_force },
    .{ "e", .load },
    .{ "e!", .load_force },
    .{ "q", .quit },
    .{ "q!", .quit_force },
});

pub const RunCommandError = error{
    InvalidCommand,
    EmptyFileName,
};

pub fn runCommand(self: *Self, str: []const u8) RunCommandError!void {
    var iter = utils.wordIterator(str);
    const cmd_str = iter.next() orelse return error.InvalidCommand;
    assert(cmd_str.len > 0);

    const cmd = cmds.get(cmd_str) orelse return error.InvalidCommand;

    switch (cmd) {
        .quit => {
            if (self.sheet.has_changes) {
                self.setStatusMessage(.warn, "No write since last change (add ! to override)", .{});
            } else {
                self.running = false;
            }
        },
        .quit_force => self.running = false,
        .save, .save_force => { // save
            writeFile(&self.sheet, .{ .filepath = iter.next() }) catch |err| {
                self.setStatusMessage(.warn, "Could not write file: {s}", .{@errorName(err)});
                return;
            };
            self.sheet.has_changes = false;
        },
        .load => { // load
            if (self.sheet.has_changes) {
                self.setStatusMessage(.warn, "No write since last change (add ! to override)", .{});
            } else {
                try self.loadCmd(iter.next() orelse "");
            }
        },
        .load_force => try self.loadCmd(iter.next() orelse ""),
    }
}

pub fn loadCmd(self: *Self, filepath: []const u8) !void {
    if (filepath.len == 0) return error.EmptyFileName;

    self.clearSheet(&self.sheet) catch |err| switch (err) {
        error.OutOfMemory => self.setStatusMessage(.err, "Out of memory!", .{}),
    };
    self.tui.update.cells = true;

    self.loadFile(&self.sheet, filepath) catch |err| {
        self.setStatusMessage(.err, "Could not open file: {s}", .{@errorName(err)});
        return;
    };
}

pub fn clearSheet(self: *Self, sheet: *Sheet) Allocator.Error!void {
    try self.asts.ensureUnusedCapacity(self.allocator, self.sheet.cellCount());
    for (sheet.cells.values()) |cell| {
        self.delAstAssumeCapacity(cell.ast);
    }
    sheet.cells.clearRetainingCapacity();
}

pub fn loadFile(self: *Self, sheet: *Sheet, filepath: []const u8) !void {
    const file = try std.fs.cwd().createFile(filepath, .{
        .read = true,
        .truncate = false,
    });
    defer file.close();

    var buf = std.io.bufferedReader(file.reader());
    const reader = buf.reader();

    log.debug("Loading file", .{});

    var sfa = std.heap.stackFallback(8192, sheet.allocator);
    var allocator = sfa.get();
    while (try reader.readUntilDelimiterOrEofAlloc(allocator, '\n', std.math.maxInt(u30))) |line| {
        defer {
            allocator.free(line);
            allocator = sfa.get();
        }

        var ast = self.newAst();
        ast.parse(self.allocator, line) catch |err| switch (err) {
            error.UnexpectedToken, error.InvalidCellAddress => continue,
            error.OutOfMemory => return error.OutOfMemory,
        };
        errdefer self.asts.appendAssumeCapacity(ast);

        const root = ast.rootTag();
        switch (root) {
            .assignment => {
                const assignment = ast.nodes.items(.data)[ast.rootNodeIndex()].assignment;
                const pos = ast.nodes.items(.data)[assignment.lhs].cell;
                ast.splice(assignment.rhs);
                try sheet.setCell(pos, .{ .ast = ast });
            },
            else => continue,
        }
    }

    sheet.setFilePath(filepath);
    sheet.has_changes = false;
}

pub const WriteFileOptions = struct {
    filepath: ?[]const u8 = null,
};

pub fn writeFile(sheet: *Sheet, opts: WriteFileOptions) !void {
    const filepath = opts.filepath orelse sheet.filepath.slice();
    if (filepath.len == 0) {
        return error.EmptyFileName;
    }

    var atomic_file = try std.fs.cwd().atomicFile(filepath, .{});
    defer atomic_file.deinit();

    var buf = std.io.bufferedWriter(atomic_file.file.writer());
    const writer = buf.writer();

    for (sheet.cells.keys(), sheet.cells.values()) |pos, *cell| {
        try pos.writeCellAddress(writer);
        try writer.writeAll(" = ");
        try cell.ast.print(writer);
        try writer.writeByte('\n');
    }

    try buf.flush();
    try atomic_file.finish();

    if (opts.filepath) |path| {
        sheet.setFilePath(path);
    }
}

pub fn deleteCell(self: *Self) Allocator.Error!void {
    const ast = self.sheet.deleteCell(self.cursor) orelse return;
    try self.delAst(ast);

    self.tui.update.cells = true;
    self.tui.update.cursor = true;
}

pub fn setCursor(self: *Self, new_pos: Position) void {
    self.prev_cursor = self.cursor;
    self.cursor = new_pos;
    self.clampScreenToCursor();

    switch (self.mode) {
        .visual, .select => {
            self.tui.update.cells = true;
            self.tui.update.column_headings = true;
            self.tui.update.row_numbers = true;
        },
        else => {
            self.tui.update.cursor = true;
        },
    }
}

pub fn cursorUp(self: *Self) void {
    self.setCursor(.{ .y = self.cursor.y -| self.getCountU16(), .x = self.cursor.x });
    self.resetCount();
}

pub fn cursorDown(self: *Self) void {
    self.setCursor(.{ .y = self.cursor.y +| self.getCountU16(), .x = self.cursor.x });
    self.resetCount();
}

pub fn cursorLeft(self: *Self) void {
    self.setCursor(.{ .y = self.cursor.y, .x = self.cursor.x -| self.getCountU16() });
    self.resetCount();
}

pub fn cursorRight(self: *Self) void {
    self.setCursor(.{ .y = self.cursor.y, .x = self.cursor.x +| self.getCountU16() });
    self.resetCount();
}

pub fn selectionUp(self: *Self) void {
    assert(self.mode == .visual or self.mode == .select);
    const anchor = self.getAnchor();
    const count = self.getCountU16();
    if (anchor.y < self.cursor.y) {
        const len = self.cursor.y - anchor.y;
        self.setCursor(.{ .y = @max(self.cursor.y -| count, len), .x = self.cursor.x });
        anchor.y -|= count;
    } else {
        const len = anchor.y - self.cursor.y;
        anchor.y = @max(anchor.y -| count, len);
        self.setCursor(.{ .y = self.cursor.y -| count, .x = self.cursor.x });
    }
    self.resetCount();
}

pub fn selectionDown(self: *Self) void {
    assert(self.mode == .visual or self.mode == .select);
    const anchor = self.getAnchor();
    const count = self.getCountU16();

    if (anchor.y < self.cursor.y) {
        const len = self.cursor.y - anchor.y;
        self.setCursor(.{ .y = self.cursor.y +| count, .x = self.cursor.x });
        anchor.y = @min(anchor.y +| count, std.math.maxInt(u16) - len);
    } else {
        const len = anchor.y - self.cursor.y;
        self.setCursor(.{ .y = @min(self.cursor.y +| count, std.math.maxInt(u16) - len), .x = self.cursor.x });
        anchor.y +|= count;
    }
    self.resetCount();
}

pub fn selectionLeft(self: *Self) void {
    assert(self.mode == .visual or self.mode == .select);
    const anchor = self.getAnchor();
    const count = self.getCountU16();
    if (anchor.x < self.cursor.x) {
        const len = self.cursor.x - anchor.x;
        self.setCursor(.{ .x = @max(self.cursor.x -| count, len), .y = self.cursor.y });
        anchor.x -|= count;
    } else {
        const len = anchor.x - self.cursor.x;
        anchor.x = @max(anchor.x -| count, len);
        self.setCursor(.{ .x = self.cursor.x -| count, .y = self.cursor.y });
    }
    self.resetCount();
}

pub fn selectionRight(self: *Self) void {
    assert(self.mode == .visual or self.mode == .select);
    const anchor = self.getAnchor();
    const count = self.getCountU16();

    if (anchor.x < self.cursor.x) {
        const len = self.cursor.x - anchor.x;
        self.setCursor(.{ .x = self.cursor.x +| count, .y = self.cursor.y });
        anchor.x = @min(anchor.x +| count, std.math.maxInt(u16) - len);
    } else {
        const len = anchor.x - self.cursor.x;
        self.setCursor(.{ .x = @min(self.cursor.x +| count, std.math.maxInt(u16) - len), .y = self.cursor.y });
        anchor.x +|= count;
    }
    self.resetCount();
}

pub inline fn contentHeight(self: Self) u16 {
    return self.tui.term.height -| content_line;
}

pub fn leftReservedColumns(self: Self) u16 {
    const y = self.screen_pos.y +| self.contentHeight() -| 1;

    if (y == 0)
        return 2;

    return std.math.log10(y) + 2;
}

pub fn clampScreenToCursor(self: *Self) void {
    self.clampScreenToCursorY();
    self.clampScreenToCursorX();
}

pub fn clampScreenToCursorY(self: *Self) void {
    const height = self.contentHeight();
    if (height == 0) return;

    if (self.cursor.y < self.screen_pos.y) {
        const old_max = self.screen_pos.y + (height - 1);
        self.screen_pos.y = self.cursor.y;
        const new_max = self.screen_pos.y + (height - 1);

        if (std.math.log10(old_max) != std.math.log10(new_max)) {
            self.tui.update.column_headings = true;
        }

        self.tui.update.row_numbers = true;
        self.tui.update.cells = true;
        return;
    }

    if (self.cursor.y - self.screen_pos.y >= height) {
        const old_max = self.screen_pos.y + (height - 1);
        self.screen_pos.y = self.cursor.y - (height - 1);
        const new_max = self.screen_pos.y + (height - 1);

        if (std.math.log10(old_max) != std.math.log10(new_max)) {
            self.tui.update.column_headings = true;
        }

        self.tui.update.row_numbers = true;
        self.tui.update.cells = true;
    }
}

pub fn clampScreenToCursorX(self: *Self) void {
    if (self.cursor.x < self.screen_pos.x) {
        self.screen_pos.x = self.cursor.x;
        self.tui.update.column_headings = true;
        self.tui.update.cells = true;
        return;
    }

    var w = self.leftReservedColumns();
    var x: u16 = self.cursor.x;

    while (true) : (x -= 1) {
        if (x < self.screen_pos.x) return;

        const col = self.sheet.getColumn(x);
        w += col.width;

        if (w > self.tui.term.width) break;
        if (x == 0) return;
    }

    if (x > self.screen_pos.x or (x == self.screen_pos.x and x < self.cursor.x)) {
        self.screen_pos.x = x +| 1;
        self.tui.update.column_headings = true;
        self.tui.update.cells = true;
    }
}

pub fn setPrecision(self: *Self, column: u16, new_precision: u8) void {
    if (self.sheet.columns.getPtr(column)) |col| {
        col.precision = new_precision;
        self.tui.update.cells = true;
    }
}

pub fn incPrecision(self: *Self, column: u16, count: u8) void {
    if (self.sheet.columns.getPtr(column)) |col| {
        col.precision +|= count;
        self.tui.update.cells = true;
    }
}

pub fn decPrecision(self: *Self, column: u16, count: u8) void {
    if (self.sheet.columns.getPtr(column)) |col| {
        col.precision -|= count;
        self.tui.update.cells = true;
    }
}

pub inline fn cursorIncPrecision(self: *Self) void {
    const count = @intCast(u8, @min(std.math.maxInt(u8), self.getCount()));
    self.incPrecision(self.cursor.x, count);
    self.resetCount();
}

pub inline fn cursorDecPrecision(self: *Self) void {
    const count = @intCast(u8, @min(std.math.maxInt(u8), self.getCount()));
    self.decPrecision(self.cursor.x, count);
    self.resetCount();
}

pub fn incWidth(self: *Self, column: u16, n: u8) void {
    if (self.sheet.columns.getPtr(column)) |col| {
        col.width +|= n;
        self.tui.update.cells = true;
        self.tui.update.column_headings = true;
    }
}

pub fn decWidth(self: *Self, column: u16, n: u8) void {
    if (self.sheet.columns.getPtr(column)) |col| {
        const new_width = col.width -| n;
        col.width = @max(1, new_width);
        self.tui.update.cells = true;
        self.tui.update.column_headings = true;
    }
}

pub inline fn cursorIncWidth(self: *Self) void {
    const count = @intCast(u8, @min(std.math.maxInt(u8), self.getCount()));
    self.incWidth(self.cursor.x, count);
    self.resetCount();
}

pub inline fn cursorDecWidth(self: *Self) void {
    const count = @intCast(u8, @min(std.math.maxInt(u8), self.getCount()));
    self.decWidth(self.cursor.x, count);
    self.resetCount();
}

pub fn newAst(self: *Self) Ast {
    return self.asts.popOrNull() orelse Ast{};
}

pub fn delAst(self: *Self, ast: Ast) Allocator.Error!void {
    var temp = ast;
    temp.nodes.len = 0;
    try self.asts.append(self.allocator, temp);
}

pub fn delAstAssumeCapacity(self: *Self, ast: Ast) void {
    var temp = ast;
    temp.nodes.len = 0;
    self.asts.appendAssumeCapacity(temp);
}

pub fn cursorToFirstCell(self: *Self) void {
    const positions = self.sheet.cells.keys();
    for (positions) |pos| {
        if (pos.y < self.cursor.y) continue;

        if (pos.y == self.cursor.y)
            self.setCursor(pos);
        break;
    }
}

pub fn cursorToLastCell(self: *Self) void {
    const positions = self.sheet.cells.keys();

    if (positions.len == 0) return;

    var new_pos = self.cursor;
    for (positions) |pos| {
        if (pos.y > self.cursor.y) break;
        new_pos = pos;
    }
    self.setCursor(new_pos);
}

pub fn cursorToFirstCellInColumn(self: *Self) void {
    const positions = self.sheet.cells.keys();
    if (positions.len == 0) return;

    for (positions) |pos| {
        if (pos.x == self.cursor.x) {
            self.setCursor(pos);
            break;
        }
    }
}

pub fn cursorToLastCellInColumn(self: *Self) void {
    const positions = self.sheet.cells.keys();
    if (positions.len == 0) return;

    var iter = std.mem.reverseIterator(positions);
    while (iter.next()) |pos| {
        if (pos.x == self.cursor.x) {
            self.setCursor(pos);
            break;
        }
    }
}

pub fn parseInput(bytes: []const u8, writer: anytype) @TypeOf(writer).Error!void {
    var iter = spoon.inputParser(bytes);

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
    dismiss_count_or_status_message,

    cell_cursor_up,
    cell_cursor_down,
    cell_cursor_left,
    cell_cursor_right,
    cell_cursor_row_first,
    cell_cursor_row_last,
    cell_cursor_col_first,
    cell_cursor_col_last,

    delete_cell,
    next_populated_cell,
    prev_populated_cell,
    increase_precision,
    decrease_precision,
    increase_width,
    decrease_width,
    assign_cell,

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

pub const CommandAction = union(enum(u6)) {
    submit_command = 26,
    enter_normal_mode,

    enter_select_mode,

    enter_insert_mode,
    enter_insert_mode_after,
    enter_insert_mode_at_eol,
    enter_insert_mode_at_bol,

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

    // Motion tagged union duplicated to reduce memory usage
    motion_normal_word_inside = 0,
    motion_long_word_inside = 1,
    motion_normal_word_around = 2,
    motion_long_word_around = 3,

    /// Absolutely cursed - these fields store two UCS codepoints. This is done to save one byte.
    /// Storing them as two UTF-8 codepoints would require 8 bytes. Storing them as two u21 values
    /// would cause each one to get padded to 4 bytes, using 8 bytes total.
    motion_inside_delimiters: [7]u8 align(4) = 4,
    motion_around_delimiters: [7]u8 align(4) = 5,

    motion_inside_single_delimiter: u21 = 6,
    motion_around_single_delimiter: u21 = 7,
    motion_to_forwards: u21 = 8,
    motion_to_backwards: u21 = 9,
    motion_until_forwards: u21 = 10,
    motion_until_backwards: u21 = 11,

    motion_normal_word_start_next = 12,
    motion_normal_word_start_prev = 13,
    motion_normal_word_end_next = 14,
    motion_normal_word_end_prev = 15,
    motion_long_word_start_next = 16,
    motion_long_word_start_prev = 17,
    motion_long_word_end_next = 18,
    motion_long_word_end_prev = 19,
    motion_char_next = 20,
    motion_char_prev = 21,
    motion_line = 22,
    motion_eol = 23,
    motion_bol = 24,

    /// Any inputs that aren't a mapping get passed as this. Its usage depends on the mode. For
    /// example, in insert mode the inputted text is passed along with this action if it does
    /// not correspond to another action.
    none,

    pub fn isMotion(action: CommandAction) bool {
        return @enumToInt(action) <= 24;
    }

    pub fn isMotionTag(tag: std.meta.Tag(CommandAction)) bool {
        return @enumToInt(tag) <= 24;
    }

    // Cursed function that converts a CommandAction to a Motion.
    pub fn toMotion(action: CommandAction) Motion {
        switch (action) {
            inline .motion_around_delimiters, .motion_inside_delimiters => |buf, action_tag| {
                const b align(4) = buf; // `buf` is not aligned for some reason, so copy it
                const cps align(4) = utils.unpackDoubleCp(&b);
                const tag = @intToEnum(std.meta.Tag(Motion), @enumToInt(action_tag));
                return @unionInit(Motion, @tagName(tag), .{
                    .left = cps[0],
                    .right = cps[1],
                });
            },
            else => {},
        }

        @setEvalBranchQuota(2000);
        const tag = @intToEnum(std.meta.Tag(Motion), @enumToInt(action));
        switch (action) {
            inline else => |payload, action_tag| switch (tag) {
                inline else => |t| {
                    if (comptime (@enumToInt(t) == @enumToInt(action_tag) and
                        isMotionTag(action_tag) and
                        action_tag != .motion_inside_delimiters and
                        action_tag != .motion_around_delimiters))
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

const outer_keys = [_]KeyMaps{
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
            .{ "+", .increase_width },
            .{ "-", .decrease_width },
            .{ "f", .increase_precision },
            .{ "F", .decrease_precision },
            .{ "=", .assign_cell },
            .{ "dd", .delete_cell },
            .{ ":", .enter_command_mode },
            .{ "v", .enter_visual_mode },
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
            .{ "a(", .{ .motion_around_delimiters = utils.packDoubleCp('(', ')') } },
            .{ "i(", .{ .motion_inside_delimiters = utils.packDoubleCp('(', ')') } },
            .{ "a)", .{ .motion_around_delimiters = utils.packDoubleCp('(', ')') } },
            .{ "i)", .{ .motion_inside_delimiters = utils.packDoubleCp('(', ')') } },
            .{ "a[", .{ .motion_around_delimiters = utils.packDoubleCp('[', ']') } },
            .{ "i[", .{ .motion_inside_delimiters = utils.packDoubleCp('[', ']') } },
            .{ "a]", .{ .motion_around_delimiters = utils.packDoubleCp('[', ']') } },
            .{ "i]", .{ .motion_inside_delimiters = utils.packDoubleCp('[', ']') } },
            .{ "i{", .{ .motion_inside_delimiters = utils.packDoubleCp('{', '}') } },
            .{ "a{", .{ .motion_around_delimiters = utils.packDoubleCp('{', '}') } },
            .{ "i}", .{ .motion_inside_delimiters = utils.packDoubleCp('{', '}') } },
            .{ "a}", .{ .motion_around_delimiters = utils.packDoubleCp('{', '}') } },
            .{ "i<<", .{ .motion_inside_delimiters = utils.packDoubleCp('<', '>') } },
            .{ "a<<", .{ .motion_around_delimiters = utils.packDoubleCp('<', '>') } },
            .{ "i>", .{ .motion_inside_delimiters = utils.packDoubleCp('<', '>') } },
            .{ "a>", .{ .motion_around_delimiters = utils.packDoubleCp('<', '>') } },
            .{ "i\"", .{ .motion_inside_single_delimiter = '"' } },
            .{ "a\"", .{ .motion_around_single_delimiter = '"' } },
            .{ "i'", .{ .motion_inside_single_delimiter = '\'' } },
            .{ "a'", .{ .motion_around_single_delimiter = '\'' } },
            .{ "i`", .{ .motion_inside_single_delimiter = '`' } },
            .{ "a`", .{ .motion_around_single_delimiter = '`' } },
        },
    },
    .{
        .type = .to,
        .parents = &.{.common_keys},
        .keys = &.{},
    },
};

// TODO: move these to a separate file

test "Normal mode keys" {
    const t = std.testing;

    var zc = try Self.init(t.allocator, .{ .ui = false });
    defer zc.deinit();

    try t.expectEqual(Mode.normal, zc.mode);

    try t.expectEqual(Action.cell_cursor_down, zc.getAction("j").normal);
    try t.expectEqual(Action.cell_cursor_up, zc.getAction("k").normal);
    try t.expectEqual(Action.cell_cursor_left, zc.getAction("h").normal);
    try t.expectEqual(Action.cell_cursor_right, zc.getAction("l").normal);
    try t.expectEqual(Action.next_populated_cell, zc.getAction("w").normal);
    try t.expectEqual(Action.prev_populated_cell, zc.getAction("b").normal);
    try t.expectEqual(Action.cell_cursor_row_first, zc.getAction("gg").normal);
    try t.expectEqual(Action.cell_cursor_row_last, zc.getAction("G").normal);
    try t.expectEqual(Action.cell_cursor_col_last, zc.getAction("$").normal);
    try t.expectEqual(Action.zero, zc.getAction("0").normal);
    try t.expectEqual(Action{ .count = 1 }, zc.getAction("1").normal);
    try t.expectEqual(Action{ .count = 2 }, zc.getAction("2").normal);
    try t.expectEqual(Action{ .count = 3 }, zc.getAction("3").normal);
    try t.expectEqual(Action{ .count = 4 }, zc.getAction("4").normal);
    try t.expectEqual(Action{ .count = 5 }, zc.getAction("5").normal);
    try t.expectEqual(Action{ .count = 6 }, zc.getAction("6").normal);
    try t.expectEqual(Action{ .count = 7 }, zc.getAction("7").normal);
    try t.expectEqual(Action{ .count = 8 }, zc.getAction("8").normal);
    try t.expectEqual(Action{ .count = 9 }, zc.getAction("9").normal);

    try t.expectEqual(Action.dismiss_count_or_status_message, zc.getAction("<C-[>").normal);
    try t.expectEqual(Action.dismiss_count_or_status_message, zc.getAction("<Escape>").normal);
    try t.expectEqual(Action.increase_width, zc.getAction("+").normal);
    try t.expectEqual(Action.decrease_width, zc.getAction("-").normal);
    try t.expectEqual(Action.increase_precision, zc.getAction("f").normal);
    try t.expectEqual(Action.decrease_precision, zc.getAction("F").normal);
    try t.expectEqual(Action.assign_cell, zc.getAction("=").normal);
    try t.expectEqual(Action.delete_cell, zc.getAction("dd").normal);
    try t.expectEqual(Action.enter_command_mode, zc.getAction(":").normal);
    try t.expectEqual(Action.enter_visual_mode, zc.getAction("v").normal);
}

test "Visual mode keys" {
    const t = std.testing;

    var zc = try Self.init(t.allocator, .{ .ui = false });
    defer zc.deinit();

    zc.setMode(.visual);
    try t.expectEqual(Mode.visual, zc.mode);

    try t.expectEqual(Action.enter_normal_mode, zc.getAction("<C-[>").normal);
    try t.expectEqual(Action.enter_normal_mode, zc.getAction("<Escape>").normal);
    try t.expectEqual(Action.swap_anchor, zc.getAction("o").normal);
    try t.expectEqual(Action.delete_cell, zc.getAction("d").normal);

    try t.expectEqual(Action.cell_cursor_down, zc.getAction("j").normal);
    try t.expectEqual(Action.cell_cursor_up, zc.getAction("k").normal);
    try t.expectEqual(Action.cell_cursor_left, zc.getAction("h").normal);
    try t.expectEqual(Action.cell_cursor_right, zc.getAction("l").normal);
    try t.expectEqual(Action.next_populated_cell, zc.getAction("w").normal);
    try t.expectEqual(Action.prev_populated_cell, zc.getAction("b").normal);
    try t.expectEqual(Action.cell_cursor_row_first, zc.getAction("gg").normal);
    try t.expectEqual(Action.cell_cursor_row_last, zc.getAction("G").normal);
    try t.expectEqual(Action.cell_cursor_col_last, zc.getAction("$").normal);
    try t.expectEqual(Action.zero, zc.getAction("0").normal);
    try t.expectEqual(Action{ .count = 1 }, zc.getAction("1").normal);
    try t.expectEqual(Action{ .count = 2 }, zc.getAction("2").normal);
    try t.expectEqual(Action{ .count = 3 }, zc.getAction("3").normal);
    try t.expectEqual(Action{ .count = 4 }, zc.getAction("4").normal);
    try t.expectEqual(Action{ .count = 5 }, zc.getAction("5").normal);
    try t.expectEqual(Action{ .count = 6 }, zc.getAction("6").normal);
    try t.expectEqual(Action{ .count = 7 }, zc.getAction("7").normal);
    try t.expectEqual(Action{ .count = 8 }, zc.getAction("8").normal);
    try t.expectEqual(Action{ .count = 9 }, zc.getAction("9").normal);
}

test "Select mode keys" {
    const t = std.testing;

    var zc = try Self.init(t.allocator, .{ .ui = false });
    defer zc.deinit();

    zc.setMode(.select);
    try t.expectEqual(Mode.select, zc.mode);

    try t.expectEqual(Action.select_cancel, zc.getAction("<C-[>").normal);
    try t.expectEqual(Action.select_cancel, zc.getAction("<Escape>").normal);
    try t.expectEqual(Action.swap_anchor, zc.getAction("o").normal);
    try t.expectEqual(Action.select_submit, zc.getAction("<Return>").normal);
    try t.expectEqual(Action.select_submit, zc.getAction("<C-j>").normal);
    try t.expectEqual(Action.select_submit, zc.getAction("<C-m>").normal);

    try t.expectEqual(Action.cell_cursor_down, zc.getAction("j").normal);
    try t.expectEqual(Action.cell_cursor_up, zc.getAction("k").normal);
    try t.expectEqual(Action.cell_cursor_left, zc.getAction("h").normal);
    try t.expectEqual(Action.cell_cursor_right, zc.getAction("l").normal);
    try t.expectEqual(Action.next_populated_cell, zc.getAction("w").normal);
    try t.expectEqual(Action.prev_populated_cell, zc.getAction("b").normal);
    try t.expectEqual(Action.cell_cursor_row_first, zc.getAction("gg").normal);
    try t.expectEqual(Action.cell_cursor_row_last, zc.getAction("G").normal);
    try t.expectEqual(Action.cell_cursor_col_last, zc.getAction("$").normal);
    try t.expectEqual(Action.zero, zc.getAction("0").normal);
    try t.expectEqual(Action{ .count = 1 }, zc.getAction("1").normal);
    try t.expectEqual(Action{ .count = 2 }, zc.getAction("2").normal);
    try t.expectEqual(Action{ .count = 3 }, zc.getAction("3").normal);
    try t.expectEqual(Action{ .count = 4 }, zc.getAction("4").normal);
    try t.expectEqual(Action{ .count = 5 }, zc.getAction("5").normal);
    try t.expectEqual(Action{ .count = 6 }, zc.getAction("6").normal);
    try t.expectEqual(Action{ .count = 7 }, zc.getAction("7").normal);
    try t.expectEqual(Action{ .count = 8 }, zc.getAction("8").normal);
    try t.expectEqual(Action{ .count = 9 }, zc.getAction("9").normal);
}

test "Command normal mode keys" {
    const t = std.testing;

    var zc = try Self.init(t.allocator, .{ .ui = false });
    defer zc.deinit();

    zc.setMode(.command_normal);

    try t.expectEqual(CommandAction.delete_char, zc.getAction("x").command);
    try t.expectEqual(CommandAction.operator_delete, zc.getAction("d").command);
    try t.expectEqual(CommandAction.delete_to_eol, zc.getAction("D").command);
    try t.expectEqual(CommandAction.operator_change, zc.getAction("c").command);
    try t.expectEqual(CommandAction.change_to_eol, zc.getAction("C").command);
    try t.expectEqual(CommandAction.change_char, zc.getAction("s").command);
    try t.expectEqual(CommandAction.change_line, zc.getAction("S").command);

    try t.expectEqual(CommandAction.enter_insert_mode, zc.getAction("i").command);
    try t.expectEqual(CommandAction.enter_insert_mode_at_bol, zc.getAction("I").command);
    try t.expectEqual(CommandAction.enter_insert_mode_after, zc.getAction("a").command);
    try t.expectEqual(CommandAction.enter_insert_mode_at_eol, zc.getAction("A").command);

    try t.expectEqual(CommandAction.submit_command, zc.getAction("<C-m>").command);
    try t.expectEqual(CommandAction.submit_command, zc.getAction("<C-j>").command);
    try t.expectEqual(CommandAction.submit_command, zc.getAction("<Return>").command);

    try t.expectEqual(CommandAction.motion_bol, zc.getAction("<Home>").command);
    try t.expectEqual(CommandAction.motion_eol, zc.getAction("<End>").command);
    try t.expectEqual(CommandAction.motion_char_prev, zc.getAction("<Left>").command);
    try t.expectEqual(CommandAction.motion_char_next, zc.getAction("<Right>").command);

    try t.expectEqual(CommandAction.enter_normal_mode, zc.getAction("<C-[>").command);
    try t.expectEqual(CommandAction.enter_normal_mode, zc.getAction("<Escape>").command);

    try t.expectEqual(CommandAction{ .count = 1 }, zc.getAction("1").command);
    try t.expectEqual(CommandAction{ .count = 2 }, zc.getAction("2").command);
    try t.expectEqual(CommandAction{ .count = 3 }, zc.getAction("3").command);
    try t.expectEqual(CommandAction{ .count = 4 }, zc.getAction("4").command);
    try t.expectEqual(CommandAction{ .count = 5 }, zc.getAction("5").command);
    try t.expectEqual(CommandAction{ .count = 6 }, zc.getAction("6").command);
    try t.expectEqual(CommandAction{ .count = 7 }, zc.getAction("7").command);
    try t.expectEqual(CommandAction{ .count = 8 }, zc.getAction("8").command);
    try t.expectEqual(CommandAction{ .count = 9 }, zc.getAction("9").command);

    try t.expectEqual(CommandAction.operator_to_forwards, zc.getAction("f").command);
    try t.expectEqual(CommandAction.operator_to_backwards, zc.getAction("F").command);
    try t.expectEqual(CommandAction.operator_until_forwards, zc.getAction("t").command);
    try t.expectEqual(CommandAction.operator_until_backwards, zc.getAction("T").command);
    try t.expectEqual(CommandAction.motion_char_prev, zc.getAction("h").command);
    try t.expectEqual(CommandAction.motion_char_next, zc.getAction("l").command);
    try t.expectEqual(CommandAction.zero, zc.getAction("0").command);
    try t.expectEqual(CommandAction.motion_eol, zc.getAction("$").command);
    try t.expectEqual(CommandAction.motion_normal_word_start_next, zc.getAction("w").command);
    try t.expectEqual(CommandAction.motion_long_word_start_next, zc.getAction("W").command);
    try t.expectEqual(CommandAction.motion_normal_word_end_next, zc.getAction("e").command);
    try t.expectEqual(CommandAction.motion_long_word_end_next, zc.getAction("E").command);
    try t.expectEqual(CommandAction.motion_normal_word_start_prev, zc.getAction("b").command);
    try t.expectEqual(CommandAction.motion_long_word_start_prev, zc.getAction("B").command);
    try t.expectEqual(CommandAction.motion_normal_word_end_prev, zc.getAction("<M-e>").command);
    try t.expectEqual(CommandAction.motion_long_word_end_prev, zc.getAction("<M-E>").command);
}

test "Command insert keys" {
    const t = std.testing;

    var zc = try Self.init(t.allocator, .{ .ui = false });
    defer zc.deinit();

    zc.setMode(.command_insert);

    try t.expectEqual(Mode.command_insert, zc.mode);
    try t.expectEqual(CommandAction.submit_command, zc.getAction("<C-m>").command);
    try t.expectEqual(CommandAction.submit_command, zc.getAction("<C-j>").command);
    try t.expectEqual(CommandAction.submit_command, zc.getAction("<Return>").command);

    try t.expectEqual(CommandAction.motion_bol, zc.getAction("<Home>").command);
    try t.expectEqual(CommandAction.motion_eol, zc.getAction("<End>").command);
    try t.expectEqual(CommandAction.motion_char_prev, zc.getAction("<Left>").command);
    try t.expectEqual(CommandAction.motion_char_next, zc.getAction("<Right>").command);

    try t.expectEqual(CommandAction.enter_normal_mode, zc.getAction("<C-[>").command);
    try t.expectEqual(CommandAction.enter_normal_mode, zc.getAction("<Escape>").command);

    try t.expectEqual(GetActionResult.not_found, zc.getAction("q"));
}

test "Command operator pending keys" {
    const t = std.testing;

    var zc = try Self.init(t.allocator, .{ .ui = false });
    defer zc.deinit();

    zc.setMode(.command_delete);

    try t.expectEqual(CommandAction.submit_command, zc.getAction("<C-m>").command);
    try t.expectEqual(CommandAction.submit_command, zc.getAction("<C-j>").command);
    try t.expectEqual(CommandAction.submit_command, zc.getAction("<Return>").command);

    try t.expectEqual(CommandAction.enter_normal_mode, zc.getAction("<C-[>").command);
    try t.expectEqual(CommandAction.enter_normal_mode, zc.getAction("<Escape>").command);

    try t.expectEqual(CommandAction.operator_delete, zc.getAction("d").command);
    try t.expectEqual(CommandAction.operator_change, zc.getAction("c").command);

    try t.expectEqual(CommandAction{ .count = 1 }, zc.getAction("1").command);
    try t.expectEqual(CommandAction{ .count = 2 }, zc.getAction("2").command);
    try t.expectEqual(CommandAction{ .count = 3 }, zc.getAction("3").command);
    try t.expectEqual(CommandAction{ .count = 4 }, zc.getAction("4").command);
    try t.expectEqual(CommandAction{ .count = 5 }, zc.getAction("5").command);
    try t.expectEqual(CommandAction{ .count = 6 }, zc.getAction("6").command);
    try t.expectEqual(CommandAction{ .count = 7 }, zc.getAction("7").command);
    try t.expectEqual(CommandAction{ .count = 8 }, zc.getAction("8").command);
    try t.expectEqual(CommandAction{ .count = 9 }, zc.getAction("9").command);

    try t.expectEqual(CommandAction.operator_to_forwards, zc.getAction("f").command);
    try t.expectEqual(CommandAction.operator_to_backwards, zc.getAction("F").command);
    try t.expectEqual(CommandAction.operator_until_forwards, zc.getAction("t").command);
    try t.expectEqual(CommandAction.operator_until_backwards, zc.getAction("T").command);
    try t.expectEqual(CommandAction.motion_char_prev, zc.getAction("h").command);
    try t.expectEqual(CommandAction.motion_char_next, zc.getAction("l").command);
    try t.expectEqual(CommandAction.zero, zc.getAction("0").command);
    try t.expectEqual(CommandAction.motion_eol, zc.getAction("$").command);
    try t.expectEqual(CommandAction.motion_normal_word_start_next, zc.getAction("w").command);
    try t.expectEqual(CommandAction.motion_long_word_start_next, zc.getAction("W").command);
    try t.expectEqual(CommandAction.motion_normal_word_end_next, zc.getAction("e").command);
    try t.expectEqual(CommandAction.motion_long_word_end_next, zc.getAction("E").command);
    try t.expectEqual(CommandAction.motion_normal_word_start_prev, zc.getAction("b").command);
    try t.expectEqual(CommandAction.motion_long_word_start_prev, zc.getAction("B").command);
    try t.expectEqual(CommandAction.motion_normal_word_end_prev, zc.getAction("<M-e>").command);
    try t.expectEqual(CommandAction.motion_long_word_end_prev, zc.getAction("<M-E>").command);
    try t.expectEqual(CommandAction.operator_delete, zc.getAction("d").command);
    try t.expectEqual(CommandAction.operator_change, zc.getAction("c").command);

    try t.expectEqual(CommandAction.motion_normal_word_around, zc.getAction("aw").command);
    try t.expectEqual(CommandAction.motion_long_word_around, zc.getAction("aW").command);
    try t.expectEqual(CommandAction.motion_normal_word_inside, zc.getAction("iw").command);
    try t.expectEqual(CommandAction.motion_long_word_inside, zc.getAction("iW").command);

    try t.expectEqual(CommandAction{ .motion_around_delimiters = utils.packDoubleCp('(', ')') }, zc.getAction("a(").command);
    try t.expectEqual(CommandAction{ .motion_inside_delimiters = utils.packDoubleCp('(', ')') }, zc.getAction("i(").command);
    try t.expectEqual(CommandAction{ .motion_around_delimiters = utils.packDoubleCp('(', ')') }, zc.getAction("a)").command);
    try t.expectEqual(CommandAction{ .motion_inside_delimiters = utils.packDoubleCp('(', ')') }, zc.getAction("i)").command);

    try t.expectEqual(CommandAction{ .motion_around_delimiters = utils.packDoubleCp('[', ']') }, zc.getAction("a[").command);
    try t.expectEqual(CommandAction{ .motion_inside_delimiters = utils.packDoubleCp('[', ']') }, zc.getAction("i[").command);
    try t.expectEqual(CommandAction{ .motion_around_delimiters = utils.packDoubleCp('[', ']') }, zc.getAction("a]").command);
    try t.expectEqual(CommandAction{ .motion_inside_delimiters = utils.packDoubleCp('[', ']') }, zc.getAction("i]").command);

    try t.expectEqual(CommandAction{ .motion_inside_delimiters = utils.packDoubleCp('{', '}') }, zc.getAction("i{").command);
    try t.expectEqual(CommandAction{ .motion_around_delimiters = utils.packDoubleCp('{', '}') }, zc.getAction("a{").command);
    try t.expectEqual(CommandAction{ .motion_inside_delimiters = utils.packDoubleCp('{', '}') }, zc.getAction("i}").command);
    try t.expectEqual(CommandAction{ .motion_around_delimiters = utils.packDoubleCp('{', '}') }, zc.getAction("a}").command);

    try t.expectEqual(CommandAction{ .motion_inside_delimiters = utils.packDoubleCp('<', '>') }, zc.getAction("i<<").command);
    try t.expectEqual(CommandAction{ .motion_around_delimiters = utils.packDoubleCp('<', '>') }, zc.getAction("a<<").command);
    try t.expectEqual(CommandAction{ .motion_inside_delimiters = utils.packDoubleCp('<', '>') }, zc.getAction("i>").command);
    try t.expectEqual(CommandAction{ .motion_around_delimiters = utils.packDoubleCp('<', '>') }, zc.getAction("a>").command);

    try t.expectEqual(CommandAction{ .motion_inside_single_delimiter = '"' }, zc.getAction("i\"").command);
    try t.expectEqual(CommandAction{ .motion_around_single_delimiter = '"' }, zc.getAction("a\"").command);

    try t.expectEqual(CommandAction{ .motion_inside_single_delimiter = '\'' }, zc.getAction("i'").command);
    try t.expectEqual(CommandAction{ .motion_around_single_delimiter = '\'' }, zc.getAction("a'").command);

    try t.expectEqual(CommandAction{ .motion_inside_single_delimiter = '`' }, zc.getAction("i`").command);
    try t.expectEqual(CommandAction{ .motion_around_single_delimiter = '`' }, zc.getAction("a`").command);
}

test "Command to keys" {
    const t = std.testing;

    var zc = try Self.init(t.allocator, .{ .ui = false });
    defer zc.deinit();

    zc.setMode(.command_to_forwards);

    try t.expectEqual(CommandAction.submit_command, zc.getAction("<C-m>").command);
    try t.expectEqual(CommandAction.submit_command, zc.getAction("<C-j>").command);
    try t.expectEqual(CommandAction.submit_command, zc.getAction("<Return>").command);

    try t.expectEqual(CommandAction.motion_bol, zc.getAction("<Home>").command);
    try t.expectEqual(CommandAction.motion_eol, zc.getAction("<End>").command);
    try t.expectEqual(CommandAction.motion_char_prev, zc.getAction("<Left>").command);
    try t.expectEqual(CommandAction.motion_char_next, zc.getAction("<Right>").command);

    try t.expectEqual(CommandAction.enter_normal_mode, zc.getAction("<C-[>").command);
    try t.expectEqual(CommandAction.enter_normal_mode, zc.getAction("<Escape>").command);
}

test "Outer mode counts" {
    const t = std.testing;
    var zc = try Self.init(t.allocator, .{ .ui = false });
    defer zc.deinit();

    try t.expectEqual(Mode.normal, zc.mode);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
}

test "Motions normal mode" {
    const t = std.testing;
    const max = std.math.maxInt(u16);

    var zc = try Self.init(t.allocator, .{ .ui = false });
    defer zc.deinit();

    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);

    // cell_cursor_right
    try zc.doNormalMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = 1, .y = 0 }, zc.cursor);
    try zc.doNormalMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = 2, .y = 0 }, zc.cursor);
    try zc.doNormalMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = 3, .y = 0 }, zc.cursor);

    try zc.doNormalMode(.{ .count = 9 });
    try zc.doNormalMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = 12, .y = 0 }, zc.cursor);
    try zc.doNormalMode(.{ .count = 1 });
    try zc.doNormalMode(.{ .count = 0 });
    try zc.doNormalMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = 22, .y = 0 }, zc.cursor);

    zc.setCursor(.{ .x = max - 2, .y = 0 });
    try t.expectEqual(Position{ .x = max - 2, .y = 0 }, zc.cursor);

    try zc.doNormalMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = max - 1, .y = 0 }, zc.cursor);
    try zc.doNormalMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = max, .y = 0 }, zc.cursor);
    try zc.doNormalMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = max, .y = 0 }, zc.cursor);

    // cell_cursor_left
    zc.setCursor(.{ .x = max, .y = 0 });
    try t.expectEqual(Position{ .x = max, .y = 0 }, zc.cursor);
    try zc.doNormalMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = max - 1, .y = 0 }, zc.cursor);
    try zc.doNormalMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = max - 2, .y = 0 }, zc.cursor);
    try zc.doNormalMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = max - 3, .y = 0 }, zc.cursor);

    try zc.doNormalMode(.{ .count = 9 });
    try zc.doNormalMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = max - 12, .y = 0 }, zc.cursor);
    try zc.doNormalMode(.{ .count = 1 });
    try zc.doNormalMode(.{ .count = 0 });
    try zc.doNormalMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = max - 22, .y = 0 }, zc.cursor);

    zc.setCursor(.{ .x = 2, .y = 0 });
    try t.expectEqual(Position{ .x = 2, .y = 0 }, zc.cursor);

    try zc.doNormalMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = 1, .y = 0 }, zc.cursor);
    try zc.doNormalMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
    try zc.doNormalMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);

    // cell cursor down
    zc.setCursor(.{ .x = 0, .y = 0 });
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);

    try zc.doNormalMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = 1 }, zc.cursor);
    try zc.doNormalMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = 2 }, zc.cursor);
    try zc.doNormalMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = 3 }, zc.cursor);

    try zc.doNormalMode(.{ .count = 9 });
    try zc.doNormalMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = 12 }, zc.cursor);
    try zc.doNormalMode(.cell_cursor_down);
    try zc.doNormalMode(.{ .count = 1 });
    try zc.doNormalMode(.{ .count = 0 });
    try zc.doNormalMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = 23 }, zc.cursor);

    zc.setCursor(.{ .x = 0, .y = max - 1 });
    try t.expectEqual(Position{ .x = 0, .y = max - 1 }, zc.cursor);
    try zc.doNormalMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = max }, zc.cursor);
    try zc.doNormalMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = max }, zc.cursor);
    try zc.doNormalMode(.{ .count = 9 });
    try zc.doNormalMode(.{ .count = 9 });
    try zc.doNormalMode(.{ .count = 9 });
    try zc.doNormalMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = max }, zc.cursor);

    // cell cursor up
    zc.setCursor(.{ .x = 0, .y = max });
    try t.expectEqual(Position{ .x = 0, .y = max }, zc.cursor);

    try zc.doNormalMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = max - 1 }, zc.cursor);
    try zc.doNormalMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = max - 2 }, zc.cursor);
    try zc.doNormalMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = max - 3 }, zc.cursor);

    try zc.doNormalMode(.{ .count = 9 });
    try zc.doNormalMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = max - 12 }, zc.cursor);
    try zc.doNormalMode(.{ .count = 1 });
    try zc.doNormalMode(.{ .count = 0 });
    try zc.doNormalMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = max - 22 }, zc.cursor);

    zc.setCursor(.{ .x = 0, .y = 2 });
    try zc.doNormalMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = 1 }, zc.cursor);
    try zc.doNormalMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
    try zc.doNormalMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
    try zc.doNormalMode(.{ .count = 9 });
    try zc.doNormalMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
    try zc.doNormalMode(.{ .count = 9 });
    try zc.doNormalMode(.{ .count = 9 });
    try zc.doNormalMode(.{ .count = 9 });
    try zc.doNormalMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);

    // next/prev_populated_cell
    // empty sheet - cursor shouldn't move
    try zc.doNormalMode(.next_populated_cell);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
    zc.setCursor(.{ .x = 50, .y = 50 });
    try zc.doNormalMode(.next_populated_cell);
    try t.expectEqual(Position{ .x = 50, .y = 50 }, zc.cursor);

    zc.setCursor(.{ .x = 0, .y = 0 });
    try zc.doNormalMode(.prev_populated_cell);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
    zc.setCursor(.{ .x = 50, .y = 50 });
    try zc.doNormalMode(.prev_populated_cell);
    try t.expectEqual(Position{ .x = 50, .y = 50 }, zc.cursor);

    try zc.parseCommand("C4 = 0");
    try zc.parseCommand("ZZZ0 = 5");
    try zc.parseCommand("A4 = 1");
    try zc.parseCommand("B2 = 4");
    try zc.parseCommand("B0 = 3");
    try zc.parseCommand("A500 = 2");
    try zc.updateCells();

    zc.setCursor(.{ .x = 0, .y = 0 });
    try zc.doNormalMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("B0"), zc.cursor);
    try zc.doNormalMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("ZZZ0"), zc.cursor);
    try zc.doNormalMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("B2"), zc.cursor);
    try zc.doNormalMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("A4"), zc.cursor);
    try zc.doNormalMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("C4"), zc.cursor);
    try zc.doNormalMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("A500"), zc.cursor);
    try zc.doNormalMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("A500"), zc.cursor);

    zc.setCursor(.{ .x = 0, .y = 0 });
    try zc.doNormalMode(.{ .count = 2 });
    try zc.doNormalMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("ZZZ0"), zc.cursor);
    try zc.doNormalMode(.{ .count = 9 });
    try zc.doNormalMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("A500"), zc.cursor);

    zc.setCursor(.{ .x = max, .y = max });
    try zc.doNormalMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("A500"), zc.cursor);
    try zc.doNormalMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("C4"), zc.cursor);
    try zc.doNormalMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("A4"), zc.cursor);
    try zc.doNormalMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("B2"), zc.cursor);
    try zc.doNormalMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("ZZZ0"), zc.cursor);
    try zc.doNormalMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("B0"), zc.cursor);
    try zc.doNormalMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("B0"), zc.cursor);

    zc.setCursor(.{ .x = max, .y = max });
    try zc.doNormalMode(.{ .count = 2 });
    try zc.doNormalMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("C4"), zc.cursor);
    try zc.doNormalMode(.{ .count = 9 });
    try zc.doNormalMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("B0"), zc.cursor);
}

test "Motions visual mode" {
    const t = std.testing;
    const max = std.math.maxInt(u16);

    var zc = try Self.init(t.allocator, .{ .ui = false });
    defer zc.deinit();

    zc.setMode(.visual);
    try t.expectEqual(Mode.visual, zc.mode);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.getAnchor().*);

    // cell_cursor_right
    zc.doVisualMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = 1, .y = 0 }, zc.cursor);
    zc.doVisualMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = 2, .y = 0 }, zc.cursor);
    zc.doVisualMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = 3, .y = 0 }, zc.cursor);

    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = 12, .y = 0 }, zc.cursor);
    zc.doVisualMode(.{ .count = 1 });
    zc.doVisualMode(.{ .count = 0 });
    zc.doVisualMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = 22, .y = 0 }, zc.cursor);

    zc.setCursor(.{ .x = max - 2, .y = 0 });
    try t.expectEqual(Position{ .x = max - 2, .y = 0 }, zc.cursor);

    zc.doVisualMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = max - 1, .y = 0 }, zc.cursor);
    zc.doVisualMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = max, .y = 0 }, zc.cursor);
    zc.doVisualMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = max, .y = 0 }, zc.cursor);

    // cell_cursor_left
    zc.setCursor(.{ .x = max, .y = 0 });
    try t.expectEqual(Position{ .x = max, .y = 0 }, zc.cursor);
    zc.doVisualMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = max - 1, .y = 0 }, zc.cursor);
    zc.doVisualMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = max - 2, .y = 0 }, zc.cursor);
    zc.doVisualMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = max - 3, .y = 0 }, zc.cursor);

    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = max - 12, .y = 0 }, zc.cursor);
    zc.doVisualMode(.{ .count = 1 });
    zc.doVisualMode(.{ .count = 0 });
    zc.doVisualMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = max - 22, .y = 0 }, zc.cursor);

    zc.setCursor(.{ .x = 2, .y = 0 });
    try t.expectEqual(Position{ .x = 2, .y = 0 }, zc.cursor);

    zc.doVisualMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = 1, .y = 0 }, zc.cursor);
    zc.doVisualMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
    zc.doVisualMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);

    // cell cursor down
    zc.setCursor(.{ .x = 0, .y = 0 });
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);

    zc.doVisualMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = 1 }, zc.cursor);
    zc.doVisualMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = 2 }, zc.cursor);
    zc.doVisualMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = 3 }, zc.cursor);

    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = 12 }, zc.cursor);
    zc.doVisualMode(.cell_cursor_down);
    zc.doVisualMode(.{ .count = 1 });
    zc.doVisualMode(.{ .count = 0 });
    zc.doVisualMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = 23 }, zc.cursor);

    zc.setCursor(.{ .x = 0, .y = max - 1 });
    try t.expectEqual(Position{ .x = 0, .y = max - 1 }, zc.cursor);
    zc.doVisualMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = max }, zc.cursor);
    zc.doVisualMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = max }, zc.cursor);
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = max }, zc.cursor);

    // cell cursor up
    zc.setCursor(.{ .x = 0, .y = max });
    try t.expectEqual(Position{ .x = 0, .y = max }, zc.cursor);

    zc.doVisualMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = max - 1 }, zc.cursor);
    zc.doVisualMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = max - 2 }, zc.cursor);
    zc.doVisualMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = max - 3 }, zc.cursor);

    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = max - 12 }, zc.cursor);
    zc.doVisualMode(.{ .count = 1 });
    zc.doVisualMode(.{ .count = 0 });
    zc.doVisualMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = max - 22 }, zc.cursor);

    zc.setCursor(.{ .x = 0, .y = 2 });
    zc.doVisualMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = 1 }, zc.cursor);
    zc.doVisualMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
    zc.doVisualMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);

    // next/prev_populated_cell
    // empty sheet - cursor shouldn't move
    zc.doVisualMode(.next_populated_cell);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
    zc.setCursor(.{ .x = 50, .y = 50 });
    zc.doVisualMode(.next_populated_cell);
    try t.expectEqual(Position{ .x = 50, .y = 50 }, zc.cursor);

    zc.setCursor(.{ .x = 0, .y = 0 });
    zc.doVisualMode(.prev_populated_cell);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
    zc.setCursor(.{ .x = 50, .y = 50 });
    zc.doVisualMode(.prev_populated_cell);
    try t.expectEqual(Position{ .x = 50, .y = 50 }, zc.cursor);

    try zc.parseCommand("C4 = 0");
    try zc.parseCommand("ZZZ0 = 5");
    try zc.parseCommand("A4 = 1");
    try zc.parseCommand("B2 = 4");
    try zc.parseCommand("B0 = 3");
    try zc.parseCommand("A500 = 2");
    try zc.updateCells();

    zc.setCursor(.{ .x = 0, .y = 0 });
    zc.doVisualMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("B0"), zc.cursor);
    zc.doVisualMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("ZZZ0"), zc.cursor);
    zc.doVisualMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("B2"), zc.cursor);
    zc.doVisualMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("A4"), zc.cursor);
    zc.doVisualMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("C4"), zc.cursor);
    zc.doVisualMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("A500"), zc.cursor);
    zc.doVisualMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("A500"), zc.cursor);

    zc.setCursor(.{ .x = 0, .y = 0 });
    zc.doVisualMode(.{ .count = 2 });
    zc.doVisualMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("ZZZ0"), zc.cursor);
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("A500"), zc.cursor);

    zc.setCursor(.{ .x = max, .y = max });
    zc.doVisualMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("A500"), zc.cursor);
    zc.doVisualMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("C4"), zc.cursor);
    zc.doVisualMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("A4"), zc.cursor);
    zc.doVisualMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("B2"), zc.cursor);
    zc.doVisualMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("ZZZ0"), zc.cursor);
    zc.doVisualMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("B0"), zc.cursor);
    zc.doVisualMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("B0"), zc.cursor);

    zc.setCursor(.{ .x = max, .y = max });
    zc.doVisualMode(.{ .count = 2 });
    zc.doVisualMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("C4"), zc.cursor);
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("B0"), zc.cursor);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.getAnchor().*);

    // swap_anchor
    zc.doVisualMode(.swap_anchor);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
    try t.expectEqual(Position.fromAddress("B0"), zc.getAnchor().*);

    zc.setCursor(.{ .x = max, .y = max });
    zc.doVisualMode(.swap_anchor);
    try t.expectEqual(Position{ .x = max, .y = max }, zc.getAnchor().*);
    try t.expectEqual(Position.fromAddress("B0"), zc.cursor);

    zc.setCursor(.{ .x = max - 10, .y = max - 10 });
    zc.doVisualMode(.swap_anchor);
    try t.expectEqual(Position{ .x = max - 10, .y = max - 10 }, zc.getAnchor().*);
    try t.expectEqual(Position{ .x = max, .y = max }, zc.cursor);

    // visual_move_left
    zc.doVisualMode(.visual_move_left);
    try t.expectEqual(Position{ .x = max - 1, .y = max }, zc.cursor);
    try t.expectEqual(Position{ .x = max - 11, .y = max - 10 }, zc.getAnchor().*);
    zc.doVisualMode(.visual_move_left);
    try t.expectEqual(Position{ .x = max - 2, .y = max }, zc.cursor);
    try t.expectEqual(Position{ .x = max - 12, .y = max - 10 }, zc.getAnchor().*);
    zc.doVisualMode(.visual_move_left);
    try t.expectEqual(Position{ .x = max - 3, .y = max }, zc.cursor);
    try t.expectEqual(Position{ .x = max - 13, .y = max - 10 }, zc.getAnchor().*);

    // with counts
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.visual_move_left);
    try t.expectEqual(Position{ .x = max - 12, .y = max }, zc.cursor);
    try t.expectEqual(Position{ .x = max - 22, .y = max - 10 }, zc.getAnchor().*);
    zc.doVisualMode(.{ .count = 1 });
    zc.doVisualMode(.{ .count = 0 });
    zc.doVisualMode(.visual_move_left);
    try t.expectEqual(Position{ .x = max - 22, .y = max }, zc.cursor);
    try t.expectEqual(Position{ .x = max - 32, .y = max - 10 }, zc.getAnchor().*);
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.visual_move_left);
    try t.expectEqual(Position{ .x = max - 10021, .y = max }, zc.cursor);
    try t.expectEqual(Position{ .x = max - 10031, .y = max - 10 }, zc.getAnchor().*);
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.visual_move_left);
    try t.expectEqual(Position{ .x = 10, .y = max }, zc.cursor);
    try t.expectEqual(Position{ .x = 0, .y = max - 10 }, zc.getAnchor().*);
    zc.doVisualMode(.visual_move_left);
    try t.expectEqual(Position{ .x = 10, .y = max }, zc.cursor);
    try t.expectEqual(Position{ .x = 0, .y = max - 10 }, zc.getAnchor().*);

    // visual_move_right
    zc.setCursor(.{ .x = 0, .y = 0 });
    zc.getAnchor().* = .{ .x = 10, .y = 10 };
    zc.doVisualMode(.visual_move_right);
    try t.expectEqual(Position{ .x = 1, .y = 0 }, zc.cursor);
    try t.expectEqual(Position{ .x = 11, .y = 10 }, zc.getAnchor().*);
    zc.doVisualMode(.visual_move_right);
    try t.expectEqual(Position{ .x = 2, .y = 0 }, zc.cursor);
    try t.expectEqual(Position{ .x = 12, .y = 10 }, zc.getAnchor().*);
    zc.doVisualMode(.visual_move_right);
    try t.expectEqual(Position{ .x = 3, .y = 0 }, zc.cursor);
    try t.expectEqual(Position{ .x = 13, .y = 10 }, zc.getAnchor().*);

    // with counts
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.visual_move_right);
    try t.expectEqual(Position{ .x = 12, .y = 0 }, zc.cursor);
    try t.expectEqual(Position{ .x = 22, .y = 10 }, zc.getAnchor().*);
    zc.doVisualMode(.{ .count = 1 });
    zc.doVisualMode(.{ .count = 0 });
    zc.doVisualMode(.visual_move_right);
    try t.expectEqual(Position{ .x = 22, .y = 0 }, zc.cursor);
    try t.expectEqual(Position{ .x = 32, .y = 10 }, zc.getAnchor().*);
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.visual_move_right);
    try t.expectEqual(Position{ .x = 10021, .y = 0 }, zc.cursor);
    try t.expectEqual(Position{ .x = 10031, .y = 10 }, zc.getAnchor().*);
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.visual_move_right);
    try t.expectEqual(Position{ .x = max - 10, .y = 0 }, zc.cursor);
    try t.expectEqual(Position{ .x = max, .y = 10 }, zc.getAnchor().*);
    zc.doVisualMode(.visual_move_right);
    try t.expectEqual(Position{ .x = max - 10, .y = 0 }, zc.cursor);
    try t.expectEqual(Position{ .x = max, .y = 10 }, zc.getAnchor().*);

    // visual_move_up
    zc.setCursor(.{ .x = max, .y = max });
    zc.getAnchor().* = .{ .x = max - 10, .y = max - 10 };
    zc.doVisualMode(.visual_move_up);
    try t.expectEqual(Position{ .y = max - 1, .x = max }, zc.cursor);
    try t.expectEqual(Position{ .y = max - 11, .x = max - 10 }, zc.getAnchor().*);
    zc.doVisualMode(.visual_move_up);
    try t.expectEqual(Position{ .y = max - 2, .x = max }, zc.cursor);
    try t.expectEqual(Position{ .y = max - 12, .x = max - 10 }, zc.getAnchor().*);
    zc.doVisualMode(.visual_move_up);
    try t.expectEqual(Position{ .y = max - 3, .x = max }, zc.cursor);
    try t.expectEqual(Position{ .y = max - 13, .x = max - 10 }, zc.getAnchor().*);

    // with counts
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.visual_move_up);
    try t.expectEqual(Position{ .y = max - 12, .x = max }, zc.cursor);
    try t.expectEqual(Position{ .y = max - 22, .x = max - 10 }, zc.getAnchor().*);
    zc.doVisualMode(.{ .count = 1 });
    zc.doVisualMode(.{ .count = 0 });
    zc.doVisualMode(.visual_move_up);
    try t.expectEqual(Position{ .y = max - 22, .x = max }, zc.cursor);
    try t.expectEqual(Position{ .y = max - 32, .x = max - 10 }, zc.getAnchor().*);
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.visual_move_up);
    try t.expectEqual(Position{ .y = max - 10021, .x = max }, zc.cursor);
    try t.expectEqual(Position{ .y = max - 10031, .x = max - 10 }, zc.getAnchor().*);
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.visual_move_up);
    try t.expectEqual(Position{ .y = 10, .x = max }, zc.cursor);
    try t.expectEqual(Position{ .y = 0, .x = max - 10 }, zc.getAnchor().*);
    zc.doVisualMode(.visual_move_up);
    try t.expectEqual(Position{ .y = 10, .x = max }, zc.cursor);
    try t.expectEqual(Position{ .y = 0, .x = max - 10 }, zc.getAnchor().*);

    // visual_move_down
    zc.setCursor(.{ .y = 0, .x = 0 });
    zc.getAnchor().* = .{ .y = 10, .x = 10 };
    zc.doVisualMode(.visual_move_down);
    try t.expectEqual(Position{ .y = 1, .x = 0 }, zc.cursor);
    try t.expectEqual(Position{ .y = 11, .x = 10 }, zc.getAnchor().*);
    zc.doVisualMode(.visual_move_down);
    try t.expectEqual(Position{ .y = 2, .x = 0 }, zc.cursor);
    try t.expectEqual(Position{ .y = 12, .x = 10 }, zc.getAnchor().*);
    zc.doVisualMode(.visual_move_down);
    try t.expectEqual(Position{ .y = 3, .x = 0 }, zc.cursor);
    try t.expectEqual(Position{ .y = 13, .x = 10 }, zc.getAnchor().*);

    // with counts
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.visual_move_down);
    try t.expectEqual(Position{ .y = 12, .x = 0 }, zc.cursor);
    try t.expectEqual(Position{ .y = 22, .x = 10 }, zc.getAnchor().*);
    zc.doVisualMode(.{ .count = 1 });
    zc.doVisualMode(.{ .count = 0 });
    zc.doVisualMode(.visual_move_down);
    try t.expectEqual(Position{ .y = 22, .x = 0 }, zc.cursor);
    try t.expectEqual(Position{ .y = 32, .x = 10 }, zc.getAnchor().*);
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.visual_move_down);
    try t.expectEqual(Position{ .y = 10021, .x = 0 }, zc.cursor);
    try t.expectEqual(Position{ .y = 10031, .x = 10 }, zc.getAnchor().*);
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.{ .count = 9 });
    zc.doVisualMode(.visual_move_down);
    try t.expectEqual(Position{ .y = max - 10, .x = 0 }, zc.cursor);
    try t.expectEqual(Position{ .y = max, .x = 10 }, zc.getAnchor().*);
    zc.doVisualMode(.visual_move_down);
    try t.expectEqual(Position{ .y = max - 10, .x = 0 }, zc.cursor);
    try t.expectEqual(Position{ .y = max, .x = 10 }, zc.getAnchor().*);
}
