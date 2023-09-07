const std = @import("std");
const utils = @import("utils.zig");
const Ast = @import("Ast.zig");
const spoon = @import("spoon");
const Sheet = @import("Sheet.zig");
const Tui = @import("Tui.zig");
const critbit = @import("critbit.zig");
const text = @import("text.zig");
const Motion = text.Motion;
const wcWidth = @import("wcwidth").wcWidth;
const GapBuffer = @import("GapBuffer.zig");
const Command = @import("Command.zig");
const Position = @import("Position.zig");
const lua = @import("lua.zig");
const Lua = @import("ziglua").Lua;

const input = @import("input.zig");
const Action = input.Action;
const CommandAction = input.CommandAction;
const KeyMap = input.KeyMap;
const MapType = input.MapType;
const CommandMapType = input.CommandMapType;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.zc);

const Self = @This();

lua: Lua,

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

count: u32 = 0,

command_screen_pos: u32 = 0,
command: Command = .{},

asts: std.ArrayListUnmanaged(Ast) = .{},

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

/// Initialises via a pointer rather than returning an instance, as we need a
/// stable pointer to a ZC instance.
pub fn init(zc: *Self, allocator: Allocator, options: InitOptions) !void {
    errdefer zc.* = undefined;

    zc.allocator = allocator;

    var ast_list = try std.ArrayListUnmanaged(Ast).initCapacity(allocator, 8);
    errdefer ast_list.deinit(allocator);

    var keys = try input.createKeymaps(allocator);
    errdefer {
        keys.sheet_keys.deinit(allocator);
        keys.command_keys.deinit(allocator);
    }

    var tui = try Tui.init();
    errdefer tui.deinit();

    if (options.ui) try tui.term.uncook(.{});

    var sheet = Sheet.init(allocator);
    errdefer sheet.deinit();

    try sheet.ensureTotalCapacity(128);

    var lua_state = try lua.init(zc);
    errdefer lua_state.deinit();

    zc.* = Self{
        .lua = lua_state,
        .sheet = sheet,
        .tui = tui,
        .allocator = allocator,
        .asts = ast_list,
        .keymaps = keys.sheet_keys,
        .command_keymaps = keys.command_keys,
        .input_buf_sfa = std.heap.stackFallback(INPUT_BUF_LEN, allocator),
    };

    zc.sourceLua() catch |err| log.err("Could not source init.lua: {}", .{err});

    zc.emitEvent("Init", .{});

    if (options.filepath) |filepath| {
        try zc.loadFile(&zc.sheet, filepath);
    }

    log.debug("Finished init", .{});
    zc.emitEvent("Start", .{});
}

pub fn sourceLua(self: *Self) !void {
    var buf: [std.fs.MAX_PATH_BYTES + 1]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const paths: []const []const u8 = if (std.os.getenv("XDG_CONFIG_HOME")) |path|
        &.{ path, "cellulator/init.lua" }
    else if (std.os.getenv("HOME")) |path|
        &.{ path, ".config/cellulator/init.lua" }
    else
        return error.CouldNotDeterminePath;

    const path = try std.fs.path.joinZ(allocator, paths);
    log.debug("Sourcing lua file '{s}'", .{path});
    try self.lua.doFile(path);
}

pub fn deinit(self: *Self) void {
    for (self.asts.items) |*ast| {
        ast.deinit(self.allocator);
    }

    self.lua.deinit();
    self.command.deinit(self.allocator);

    self.input_buf.deinit(self.allocator);
    self.keymaps.deinit(self.allocator);
    self.command_keymaps.deinit(self.allocator);

    self.asts.deinit(self.allocator);
    self.sheet.deinit();
    self.tui.deinit();
    self.* = undefined;
}

/// Emits the given event, calling it's dispatcher with `args`.
pub fn emitEvent(self: *Self, event: [:0]const u8, args: anytype) void {
    log.debug("Emitting event '{s}' with {d} arguments", .{ event, args.len });
    lua.emitEvent(&self.lua, event, args) catch |err| {
        log.err("Lua runtime error: {}", .{err});
    }; // TODO: notify of Lua errors
}

pub fn resetInputBuf(self: *Self) void {
    self.input_buf.items.len = 0;
    self.input_buf_sfa.fixed_buffer_allocator.reset();
}

pub fn inputBufSlice(self: *Self) Allocator.Error![:0]const u8 {
    const len = self.input_buf.items.len;
    try self.input_buf.append(self.allocator, 0);
    self.input_buf.items.len = len;
    return self.input_buf.items.ptr[0..len :0];
}

pub fn run(self: *Self) !void {
    while (self.running) {
        try self.updateCells();
        try self.updateTextCells();
        try self.tui.render(self);
        try self.handleInput();
    }
}

pub const ChangeCellOpts = struct {
    emit_event: bool = true,
    undo_opts: Sheet.UndoOpts = .{},
};

/// Sets the cell at `pos` to the expression represented by `ast`.
pub fn setCell(
    self: *Self,
    pos: Position,
    source: []const u8,
    ast: Ast,
    opts: ChangeCellOpts,
) !void {
    try self.sheet.setCell(pos, source, ast, .{});
    self.tui.update.cursor = true;
    self.tui.update.cells = true;
    if (opts.emit_event)
        self.emitEvent("SetCell", .{pos});
}

/// Sets the cell at `pos` to the expression represented by `expr`.
pub fn setCellString(self: *Self, pos: Position, expr: []const u8, opts: ChangeCellOpts) !void {
    var ast = self.createAst();
    errdefer self.destroyAst(ast);

    try ast.parseExpr(self.allocator, expr);
    try self.setCell(pos, expr, ast, opts);
}

// TODO: merge this and `deleteCell`
pub fn deleteCell2(self: *Self, pos: Position, opts: ChangeCellOpts) !void {
    try self.sheet.deleteCell(pos, opts.undo_opts);
    self.tui.update.cursor = true;
    self.tui.update.cells = true;
    if (opts.emit_event)
        self.emitEvent("DeleteCell", .{pos});
}

pub const StatusMessageType = enum {
    info,
    warn,
    err,
};

// TODO: Use std.log for this, and also output to file in debug mode
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

pub fn updateTextCells(self: *Self) Allocator.Error!void {
    return self.sheet.update();
}

pub fn setMode(self: *Self, new_mode: Mode) void {
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

    if (new_mode.isCommandMode()) {
        self.clampCommandCursor();
    }
}

const GetActionResult = union(enum) {
    normal: Action,
    command: CommandAction,
    prefix,
    not_found,
};

fn getAction(self: Self, bytes: [:0]const u8) GetActionResult {
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

        return switch (self.command_keymaps.get(keymap_type, bytes)) {
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

    return switch (self.keymaps.get(keymap_type, bytes)) {
        .value => |action| .{ .normal = action },
        .prefix => .prefix,
        .not_found => .not_found,
    };
}

fn handleInput(self: *Self) !void {
    var buf: [INPUT_BUF_LEN / 2]u8 = undefined;
    const slice = try self.tui.term.readInput(&buf);

    const writer = self.input_buf.writer(self.allocator);
    try input.parse(slice, writer);

    const bytes = try self.inputBufSlice();
    const res = self.getAction(bytes);
    switch (res) {
        .normal => |action| switch (self.mode) {
            .normal => try self.doNormalMode(action),
            .visual, .select => self.doVisualMode(action) catch |err| switch (err) {
                error.OutOfMemory => self.setStatusMessage(.err, "Out of memory!", .{}),
            },
            else => unreachable,
        },
        .command => |action| self.doCommandMode(action, self.input_buf.items) catch |err| switch (err) {
            error.EmptyFileName => self.setStatusMessage(.err, "Empty file name", .{}),
            error.InvalidCellAddress => self.setStatusMessage(.err, "Invalid cell address", .{}),
            error.InvalidCommand => self.setStatusMessage(.err, "Invalid command", .{}),
            error.OutOfMemory => self.setStatusMessage(.err, "Out of memory!", .{}),
            error.UnexpectedToken => self.setStatusMessage(.err, "Unexpected token", .{}),
            error.InvalidSyntax => self.setStatusMessage(.err, "Invalid syntax", .{}),
        },
        .prefix => return,
        .not_found => {
            if (self.mode.isCommandMode()) {
                try self.doCommandMode(.none, bytes);
            }
        },
    }
    self.resetInputBuf();
}

pub fn doCommandMode(self: *Self, action: CommandAction, keys: []const u8) !void {
    switch (self.mode) {
        .command_normal => try self.doCommandNormalMode(action),
        .command_insert => try self.doCommandInsertMode(action, keys),
        .command_change, .command_delete => try self.doCommandOperatorPendingMode(action),
        .command_to_forwards,
        .command_to_backwards,
        .command_until_forwards,
        .command_until_backwards,
        => self.doCommandToMode(action),
        else => unreachable,
    }
}

pub inline fn doCommandNormalMotion(self: *Self, range: text.Range) void {
    self.setCommandCursor(if (range.start == self.command.cursor) range.end else range.start);
}

fn clampCommandCursor(self: *Self) void {
    if (self.mode == .command_normal) {
        const len = self.command.length();
        if (self.command.cursor == len) {
            const new = len - text.prevCharacter(self.command, len, 1);
            self.command.setCursor(new);
        }
    }
}

fn clampScreenToCommandCursor(self: *Self) void {
    if (self.command.cursor < self.command_screen_pos) {
        self.command_screen_pos = self.command.cursor;
        return;
    }

    const len = self.command.length();
    var x: u32 = self.command.cursor;
    // Reserve either the width of the character under the cursor, or 1 column if none.
    var w: u16 = if (self.command.cursor < len) blk: {
        var builder = utils.CodepointBuilder{};
        var i: u32 = 0;
        while (builder.appendByte(self.command.get(x + i))) : (i += 1) {}
        break :blk wcWidth(builder.codepoint());
    } else 1;

    while (true) {
        const prev = x;
        x -= text.prevCodepoint(self.command, prev);
        if (prev == x or x < self.screen_pos.x) break;

        var builder = utils.CodepointBuilder{ .desired_len = @intCast(prev - x) };
        for (0..builder.desired_len) |i| _ = builder.appendByte(self.command.get(x + @as(u3, @intCast(i))));
        w += wcWidth(builder.codepoint());

        if (w > self.tui.term.width) {
            if (prev > self.command_screen_pos) self.command_screen_pos = prev;
            break;
        }
    }
}

pub fn setCommandCursor(self: *Self, pos: u32) void {
    self.command.setCursor(pos);
    self.clampCommandCursor();
    self.clampScreenToCommandCursor();
}

pub fn commandWrite(self: *Self, bytes: []const u8) Allocator.Error!usize {
    const ret = try self.command.write(self.allocator, bytes);
    self.clampCommandCursor();
    self.clampScreenToCommandCursor();
    return ret;
}

pub fn commandWriter(self: *Self) CommandWriter {
    return .{
        .context = self,
    };
}

const CommandWriter = std.io.Writer(*Self, Allocator.Error, commandWrite);

pub fn submitCommand(self: *Self) !void {
    assert(self.mode.isCommandMode());

    self.dismissStatusMessage();

    defer {
        self.setMode(.normal);
    }

    const slice = try self.command.submit(self.allocator);
    const res = self.parseCommand(slice);
    self.commandHistoryNext();

    try res;
}

pub fn commandHistoryNext(self: *Self) void {
    self.command.next(self.getCount());
    self.setCommandCursor(self.command.length());
    self.resetCount();
}

pub fn commandHistoryPrev(self: *Self) void {
    self.command.prev(self.getCount());
    self.setCommandCursor(self.command.length());
    self.resetCount();
}

pub fn doCommandMotion(self: *Self, motion: Motion) Allocator.Error!void {
    const count = self.getCount();
    switch (self.mode) {
        .normal, .visual, .select => unreachable,
        .command_normal, .command_insert => {
            const range = motion.do(self.command, self.command.cursor, count);
            self.doCommandNormalMotion(range);
        },
        .command_change => {
            const m = switch (motion) {
                .normal_word_start_next => .normal_word_end_next,
                .long_word_start_next => .long_word_end_next,
                else => motion,
            };
            const range = m.do(self.command, self.command.cursor, count);

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
                    => text.nextCharacter(self.command, range.end, 1),
                    else => 0,
                };

                assert(end >= range.start);
                try self.command.replaceRange(self.allocator, range.start, end - range.start, &.{});
                self.setCommandCursor(range.start);
            }
            self.setMode(.command_insert);
        },
        .command_delete => {
            const range = motion.do(self.command, self.command.cursor, count);
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
                    => text.nextCharacter(self.command, range.end, 1),
                    else => 0,
                };
                try self.command.replaceRange(self.allocator, range.start, end - range.start, &.{});
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

pub fn doCommandNormalMode(self: *Self, action: CommandAction) !void {
    switch (action) {
        .history_next => self.commandHistoryNext(),
        .history_prev => self.commandHistoryPrev(),
        .submit_command => try self.submitCommand(),
        .enter_normal_mode => {
            self.command.resetBuffer();
            self.setMode(.normal);
        },
        .enter_insert_mode => self.setMode(.command_insert),
        .enter_insert_mode_after => {
            self.setMode(.command_insert);
            self.doCommandMotion(.char_next) catch unreachable;
        },
        .enter_insert_mode_at_eol => {
            self.setMode(.command_insert);
            self.doCommandMotion(.eol) catch unreachable;
        },
        .enter_insert_mode_at_bol => {
            self.setMode(.command_insert);
            self.doCommandMotion(.bol) catch unreachable;
        },
        .operator_delete => self.setMode(.command_delete),
        .operator_change => self.setMode(.command_change),
        inline .delete_char, .change_char => |_, a| {
            const len = text.nextCharacter(self.command, self.command.cursor, 1);
            try self.command.replaceRange(self.allocator, self.command.cursor, len, &.{});
            if (a == .change_char) self.setMode(.command_insert);
            self.clampCommandCursor();
        },
        .change_to_eol => {
            try self.command.copyIfNeeded(self.allocator);
            self.command.buffer.shrinkRetainingCapacity(self.command.cursor);
            self.setMode(.command_insert);
        },
        .delete_to_eol => {
            try self.command.copyIfNeeded(self.allocator);
            self.command.buffer.shrinkRetainingCapacity(self.command.cursor);
        },
        .change_line => {
            self.command.resetBuffer();
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
                self.doCommandMotion(action.toMotion()) catch unreachable;
            }
        },
    }
}

fn doCommandInsertMode(self: *Self, action: CommandAction, keys: []const u8) !void {
    try switch (action) {
        .none => {
            const writer = self.commandWriter();
            try writer.writeAll(keys);
        },
        .history_next => self.commandHistoryNext(),
        .history_prev => self.commandHistoryPrev(),
        .backspace => {
            const len = text.prevCharacter(self.command, self.command.cursor, 1);
            try self.command.deleteBackwards(self.allocator, len);
        },
        .submit_command => self.submitCommand(),
        .enter_normal_mode => self.setMode(.command_normal),
        .enter_select_mode => self.setMode(.select),
        .backwards_delete_word => {
            self.setMode(.command_change);
            self.doCommandMotion(.normal_word_start_prev) catch unreachable;
        },
        .change_line => self.command.resetBuffer(),
        else => {
            if (action.isMotion()) {
                self.doCommandMotion(action.toMotion()) catch unreachable;
            }
        },
    };
}

/// Handles common actions between operator modes
fn doCommandOperatorPendingMode(self: *Self, action: CommandAction) Allocator.Error!void {
    switch (action) {
        .enter_normal_mode => self.setMode(.command_normal),

        .operator_to_forwards => self.setMode(.command_to_forwards),
        .operator_to_backwards => self.setMode(.command_to_backwards),
        .operator_until_forwards => self.setMode(.command_until_forwards),
        .operator_until_backwards => self.setMode(.command_until_backwards),

        .zero => if (self.count == 0) try self.doCommandMotion(.bol) else self.setCount(0),
        .count => |count| self.setCount(count),

        .operator_delete => if (self.mode == .command_delete) try self.doCommandMotion(.line),
        .operator_change => if (self.mode == .command_change) try self.doCommandMotion(.line),
        inline else => |_, tag| {
            if (comptime CommandAction.isMotionTag(tag)) {
                try self.doCommandMotion(action.toMotion());
            }
        },
    }
}

pub fn doCommandToMode(self: *Self, action: CommandAction) void {
    switch (action) {
        .enter_normal_mode => self.setMode(.command_normal),
        .none => {
            const keys = self.input_buf.items;
            if (keys.len > 0) {
                self.setMode(self.prev_mode);
                switch (self.prev_mode) {
                    .command_to_forwards => self.doCommandMotion(.{ .to_forwards_utf8 = keys }) catch unreachable,
                    .command_to_backwards => self.doCommandMotion(.{ .to_backwards_utf8 = keys }) catch unreachable,
                    .command_until_forwards => self.doCommandMotion(.{ .until_forwards_utf8 = keys }) catch unreachable,
                    .command_until_backwards => self.doCommandMotion(.{ .until_backwards_utf8 = keys }) catch unreachable,
                    else => unreachable,
                }
            }
        },
        else => {},
    }
}

pub fn doNormalMode(self: *Self, action: Action) !void {
    switch (action) {
        .enter_command_mode => {
            self.setMode(.command_insert);
            const writer = self.commandWriter();
            try writer.writeByte(':');
        },
        .edit_cell => {
            self.setMode(.command_insert);
            const writer = self.commandWriter();
            try writer.print("let {} = ", .{self.cursor});
            try self.sheet.printCellExpression(self.cursor, writer);
        },
        .fit_text => try self.cursorExpandWidth(),
        .enter_visual_mode => self.setMode(.visual),
        .enter_normal_mode => {},
        .dismiss_count_or_status_message => {
            if (self.count != 0) {
                self.resetCount();
            } else {
                self.dismissStatusMessage();
            }
        },

        .undo => try self.undo(),
        .redo => try self.redo(),
        .cell_cursor_up => self.cursorUp(),
        .cell_cursor_down => self.cursorDown(),
        .cell_cursor_left => self.cursorLeft(),
        .cell_cursor_right => self.cursorRight(),
        .cell_cursor_row_first => self.cursorToFirstCellInColumn(),
        .cell_cursor_row_last => self.cursorToLastCellInColumn(),
        .cell_cursor_col_first => self.cursorToFirstCellInRow(),
        .cell_cursor_col_last => self.cursorToLastCellInRow(),
        .goto_col => self.cursorGotoCol(),
        .goto_row => self.cursorGotoRow(),

        .delete_cell => self.deleteCell() catch |err| switch (err) {
            error.OutOfMemory => self.setStatusMessage(.err, "Out of memory!", .{}),
        },
        .next_populated_cell => self.cursorNextPopulatedCell(),
        .prev_populated_cell => self.cursorPrevPopulatedCell(),
        .increase_precision => try self.cursorIncPrecision(),
        .decrease_precision => try self.cursorDecPrecision(),
        .increase_width => try self.cursorIncWidth(),
        .decrease_width => try self.cursorDecWidth(),
        .assign_cell => {
            self.setMode(.command_insert);
            try self.commandWriter().print("let {} = ", .{self.cursor});
        },

        .zero => {
            if (self.count == 0) {
                self.cursorToFirstCellInRow();
            } else {
                self.setCount(0);
            }
        },
        .count => |count| self.setCount(count),
        else => {},
    }
}

fn doVisualMode(self: *Self, action: Action) Allocator.Error!void {
    assert(self.mode == .visual or self.mode == .select);
    switch (action) {
        .enter_normal_mode => self.setMode(.normal),
        .swap_anchor => {
            const temp = self.anchor;
            self.anchor = self.cursor;
            self.setCursor(temp);
        },

        .select_cancel => self.setMode(.command_insert),
        .select_submit => {
            defer self.setMode(.command_insert);
            const writer = self.commandWriter();

            const tl = Position.topLeft(self.cursor, self.anchor);
            const br = Position.bottomRight(self.cursor, self.anchor);

            try writer.print("{}:{}", .{ tl, br });
        },

        .cell_cursor_up => self.cursorUp(),
        .cell_cursor_down => self.cursorDown(),
        .cell_cursor_left => self.cursorLeft(),
        .cell_cursor_right => self.cursorRight(),
        .cell_cursor_row_first => self.cursorToFirstCellInColumn(),
        .cell_cursor_row_last => self.cursorToLastCellInColumn(),
        .cell_cursor_col_first => self.cursorToFirstCellInRow(),
        .cell_cursor_col_last => self.cursorToLastCellInRow(),
        .next_populated_cell => self.cursorNextPopulatedCell(),
        .prev_populated_cell => self.cursorPrevPopulatedCell(),

        .zero => self.setCount(0),
        .count => |count| self.setCount(count),

        .visual_move_up => self.selectionUp(),
        .visual_move_down => self.selectionDown(),
        .visual_move_left => self.selectionLeft(),
        .visual_move_right => self.selectionRight(),

        .delete_cell => {
            try self.sheet.deleteCellsInRange(self.cursor, self.anchor);
            self.setMode(.normal);
            self.tui.update.cells = true;
        },
        else => {},
    }
}

const ParseCommandError = Ast.ParseError || RunCommandError;

fn parseCommand(self: *Self, str: []const u8) !void {
    if (str.len == 0) return;

    switch (str[0]) {
        ':' => return self.runCommand(str[1..]),
        else => {},
    }

    var ast = self.createAst();
    errdefer self.destroyAst(ast);
    try ast.parse(self.allocator, str);

    const op = ast.rootNode().assignment;
    const pos = ast.nodes.items(.data)[op.lhs].cell;
    ast.splice(op.rhs);

    try self.setCell(pos, str, ast, .{});
    self.sheet.endUndoGroup();
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
    return @intCast(@min(std.math.maxInt(u16), self.getCount()));
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
    fill,
};

const cmds = std.ComptimeStringMap(Cmd, .{
    .{ "w", .save },
    .{ "w!", .save_force },
    .{ "e", .load },
    .{ "e!", .load_force },
    .{ "q", .quit },
    .{ "q!", .quit_force },
    .{ "fill", .fill },
});

pub const RunCommandError = error{
    InvalidCommand,
    InvalidSyntax,
    InvalidCellAddress,
    EmptyFileName,
} || Allocator.Error;

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
            self.writeFile(iter.next()) catch |err| {
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
        .fill => {
            // TODO: This parses differently than ranges in assignments, due to using a WordIterator

            const range = blk: {
                const string = iter.next() orelse return error.InvalidSyntax;
                var range_iter = std.mem.splitScalar(u8, string, ':');
                const lhs = range_iter.next() orelse return error.InvalidSyntax;
                const rhs = range_iter.next() orelse return error.InvalidSyntax;

                const p1 = Position.fromAddress(lhs) catch return error.InvalidCellAddress;
                const p2 = Position.fromAddress(rhs) catch return error.InvalidCellAddress;

                break :blk .{
                    .tl = Position.topLeft(p1, p2),
                    .br = Position.bottomRight(p1, p2),
                };
            };

            const value = blk: {
                const string = iter.next() orelse return error.InvalidSyntax;
                const num = std.fmt.parseFloat(f64, string) catch return error.InvalidSyntax;
                break :blk num;
            };

            const increment = blk: {
                const string = iter.next() orelse break :blk 0;
                const num = std.fmt.parseFloat(f64, string) catch return error.InvalidSyntax;
                break :blk num;
            };

            defer self.sheet.endUndoGroup();

            // TODO: pre-allocate
            var i: f64 = value;
            for (range.tl.y..@as(usize, range.br.y) + 1) |y| {
                for (range.tl.x..@as(usize, range.br.x) + 1) |x| {
                    var ast = self.createAst();
                    errdefer self.destroyAst(ast);

                    try ast.nodes.append(self.allocator, .{ .number = i });
                    try self.setCell(.{ .y = @intCast(y), .x = @intCast(x) }, "", ast, .{});
                    i += increment;
                }
            }
        },
    }
}

pub fn loadCmd(self: *Self, filepath: []const u8) !void {
    if (filepath.len == 0) return error.EmptyFileName;

    self.clearSheet(&self.sheet) catch |err| switch (err) {
        error.OutOfMemory => {
            self.setStatusMessage(.err, "Out of memory!", .{});
            return;
        },
    };
    self.tui.update.cells = true;

    self.loadFile(&self.sheet, filepath) catch |err| {
        self.setStatusMessage(.err, "Could not open file: {s}", .{@errorName(err)});
        return;
    };
}

pub fn clearSheet(self: *Self, sheet: *Sheet) Allocator.Error!void {
    const count = self.sheet.cellCount() + sheet.undos.len + sheet.redos.len;
    try self.asts.ensureUnusedCapacity(self.allocator, count);
    sheet.clearRetainingCapacity(self);
}

pub fn loadFile(self: *Self, sheet: *Sheet, filepath: []const u8) !void {
    return sheet.loadFile(self.allocator, filepath, self);
}

pub fn writeFile(self: *Self, filepath: ?[]const u8) !void {
    return self.sheet.writeFile(.{ .filepath = filepath });
}

pub fn undo(self: *Self) Allocator.Error!void {
    defer self.resetCount();
    self.tui.update.cells = true;
    self.tui.update.column_headings = true;
    self.tui.update.row_numbers = true;

    for (0..self.getCount()) |_| {
        try self.sheet.undo();
    }
}

pub fn redo(self: *Self) Allocator.Error!void {
    defer self.resetCount();
    self.tui.update.cells = true;
    self.tui.update.column_headings = true;
    self.tui.update.row_numbers = true;

    for (0..self.getCount()) |_| {
        try self.sheet.redo();
    }
}

pub fn deleteCell(self: *Self) Allocator.Error!void {
    try self.sheet.deleteCell(self.cursor, .{});
    self.sheet.endUndoGroup();

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
    const count = self.getCountU16();
    if (self.anchor.y < self.cursor.y) {
        const len = self.cursor.y - self.anchor.y;
        self.setCursor(.{ .y = @max(self.cursor.y -| count, len), .x = self.cursor.x });
        self.anchor.y -|= count;
    } else {
        const len = self.anchor.y - self.cursor.y;
        self.anchor.y = @max(self.anchor.y -| count, len);
        self.setCursor(.{ .y = self.cursor.y -| count, .x = self.cursor.x });
    }
    self.resetCount();
}

pub fn selectionDown(self: *Self) void {
    assert(self.mode == .visual or self.mode == .select);
    const count = self.getCountU16();

    if (self.anchor.y < self.cursor.y) {
        const len = self.cursor.y - self.anchor.y;
        self.setCursor(.{ .y = self.cursor.y +| count, .x = self.cursor.x });
        self.anchor.y = @min(self.anchor.y +| count, std.math.maxInt(u16) - len);
    } else {
        const len = self.anchor.y - self.cursor.y;
        self.setCursor(.{ .y = @min(self.cursor.y +| count, std.math.maxInt(u16) - len), .x = self.cursor.x });
        self.anchor.y +|= count;
    }
    self.resetCount();
}

pub fn selectionLeft(self: *Self) void {
    assert(self.mode == .visual or self.mode == .select);
    const count = self.getCountU16();
    if (self.anchor.x < self.cursor.x) {
        const len = self.cursor.x - self.anchor.x;
        self.setCursor(.{ .x = @max(self.cursor.x -| count, len), .y = self.cursor.y });
        self.anchor.x -|= count;
    } else {
        const len = self.anchor.x - self.cursor.x;
        self.anchor.x = @max(self.anchor.x -| count, len);
        self.setCursor(.{ .x = self.cursor.x -| count, .y = self.cursor.y });
    }
    self.resetCount();
}

pub fn selectionRight(self: *Self) void {
    assert(self.mode == .visual or self.mode == .select);
    const count = self.getCountU16();

    if (self.anchor.x < self.cursor.x) {
        const len = self.cursor.x - self.anchor.x;
        self.setCursor(.{ .x = self.cursor.x +| count, .y = self.cursor.y });
        self.anchor.x = @min(self.anchor.x +| count, std.math.maxInt(u16) - len);
    } else {
        const len = self.anchor.x - self.cursor.x;
        self.setCursor(.{ .x = @min(self.cursor.x +| count, std.math.maxInt(u16) - len), .y = self.cursor.y });
        self.anchor.x +|= count;
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
        w += @min(self.tui.term.width -| self.leftReservedColumns(), col.width);

        if (w > self.tui.term.width) break;
        if (x == 0) return;
    }

    if (x < self.cursor.x and (x >= self.screen_pos.x or x == self.screen_pos.x)) {
        self.screen_pos.x = x +| 1;
        self.tui.update.column_headings = true;
        self.tui.update.cells = true;
    }
}

pub fn setPrecision(self: *Self, column: u16, new_precision: u8) Allocator.Error!void {
    try self.sheet.setPrecision(column, new_precision, .{});
    self.tui.update.cells = true;
}

pub fn incPrecision(self: *Self, column: u16, count: u8) Allocator.Error!void {
    try self.sheet.incPrecision(column, count, .{});
    self.tui.update.cells = true;
}

pub fn decPrecision(self: *Self, column: u16, count: u8) Allocator.Error!void {
    try self.sheet.decPrecision(column, count, .{});
    self.tui.update.cells = true;
}

pub inline fn cursorIncPrecision(self: *Self) Allocator.Error!void {
    const count: u8 = @intCast(@min(std.math.maxInt(u8), self.getCount()));
    try self.incPrecision(self.cursor.x, count);
    self.resetCount();
}

pub inline fn cursorDecPrecision(self: *Self) Allocator.Error!void {
    const count: u8 = @intCast(@min(std.math.maxInt(u8), self.getCount()));
    try self.decPrecision(self.cursor.x, count);
    self.resetCount();
}

pub fn incWidth(self: *Self, column: u16, n: u8) Allocator.Error!void {
    try self.sheet.incWidth(column, n, .{});
    self.tui.update.cells = true;
    self.tui.update.column_headings = true;
}

pub fn decWidth(self: *Self, column: u16, n: u8) Allocator.Error!void {
    try self.sheet.decWidth(column, n, .{});
    self.tui.update.cells = true;
    self.tui.update.column_headings = true;
}

pub inline fn cursorIncWidth(self: *Self) Allocator.Error!void {
    const count: u8 = @intCast(@min(std.math.maxInt(u8), self.getCount()));
    try self.incWidth(self.cursor.x, count);
    self.resetCount();
}

pub inline fn cursorDecWidth(self: *Self) Allocator.Error!void {
    const count: u8 = @intCast(@min(std.math.maxInt(u8), self.getCount()));
    try self.decWidth(self.cursor.x, count);
    self.resetCount();
}

pub fn cursorExpandWidth(self: *Self) Allocator.Error!void {
    const col = self.sheet.columns.getPtr(self.cursor.x) orelse return;

    const max_width = self.tui.term.width - self.leftReservedColumns();
    const width_needed = self.sheet.widthNeededForColumn(self.cursor.x, col.precision, max_width);
    try self.sheet.setColWidth(col, self.cursor.x, width_needed, .{});
    self.clampScreenToCursorX();
    self.tui.update.cells = true;
    self.tui.update.column_headings = true;
}

pub fn createAst(self: *Self) Ast {
    return self.asts.popOrNull() orelse Ast{};
}

pub fn delAst(self: *Self, ast: Ast) Allocator.Error!void {
    var temp = ast;
    temp.nodes.len = 0;
    try self.asts.append(self.allocator, temp);
}

pub fn destroyAst(self: *Self, ast: Ast) void {
    var temp = ast;
    temp.nodes.len = 0;
    self.asts.appendAssumeCapacity(temp);
}

pub fn cursorToFirstCellInRow(self: *Self) void {
    const pos = self.sheet.firstCellInRow(self.cursor.y) orelse return;
    self.setCursor(pos);
}

pub fn cursorToLastCellInRow(self: *Self) void {
    const pos = self.sheet.lastCellInRow(self.cursor.y) orelse return;
    self.setCursor(pos);
}

pub fn cursorToFirstCellInColumn(self: *Self) void {
    const pos = self.sheet.firstCellInColumn(self.cursor.x) orelse return;
    self.setCursor(pos);
}

pub fn cursorToLastCellInColumn(self: *Self) void {
    const pos = self.sheet.lastCellInColumn(self.cursor.x) orelse return;
    self.setCursor(pos);
}

pub fn cursorGotoRow(self: *Self) void {
    const count: u16 = @intCast(@min(std.math.maxInt(u16), self.count));
    self.resetCount();
    self.setCursor(.{ .x = self.cursor.x, .y = count });
}

pub fn cursorGotoCol(self: *Self) void {
    const count: u16 = @intCast(@min(std.math.maxInt(u16), self.count));
    self.resetCount();
    self.setCursor(.{ .x = count, .y = self.cursor.y });
}

test "Sheet mode counts" {
    const t = std.testing;
    var zc: Self = undefined;
    try zc.init(t.allocator, .{ .ui = false });
    defer zc.deinit();

    try t.expectEqual(Mode.normal, zc.mode);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
}

test "Motions normal mode" {
    const t = std.testing;
    const max = std.math.maxInt(u16);

    var zc: Self = undefined;
    try zc.init(t.allocator, .{ .ui = false });
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

    try zc.parseCommand("let C4 = 0");
    try zc.parseCommand("let ZZZ0 = 5");
    try zc.parseCommand("let A4 = 1");
    try zc.parseCommand("let B2 = 4");
    try zc.parseCommand("let B0 = 3");
    try zc.parseCommand("let A500 = 2");
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

    var zc: Self = undefined;
    try zc.init(t.allocator, .{ .ui = false });
    defer zc.deinit();

    zc.setMode(.visual);
    try t.expectEqual(Mode.visual, zc.mode);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.anchor);

    // cell_cursor_right
    try zc.doVisualMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = 1, .y = 0 }, zc.cursor);
    try zc.doVisualMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = 2, .y = 0 }, zc.cursor);
    try zc.doVisualMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = 3, .y = 0 }, zc.cursor);

    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = 12, .y = 0 }, zc.cursor);
    try zc.doVisualMode(.{ .count = 1 });
    try zc.doVisualMode(.{ .count = 0 });
    try zc.doVisualMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = 22, .y = 0 }, zc.cursor);

    zc.setCursor(.{ .x = max - 2, .y = 0 });
    try t.expectEqual(Position{ .x = max - 2, .y = 0 }, zc.cursor);

    try zc.doVisualMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = max - 1, .y = 0 }, zc.cursor);
    try zc.doVisualMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = max, .y = 0 }, zc.cursor);
    try zc.doVisualMode(.cell_cursor_right);
    try t.expectEqual(Position{ .x = max, .y = 0 }, zc.cursor);

    // cell_cursor_left
    zc.setCursor(.{ .x = max, .y = 0 });
    try t.expectEqual(Position{ .x = max, .y = 0 }, zc.cursor);
    try zc.doVisualMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = max - 1, .y = 0 }, zc.cursor);
    try zc.doVisualMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = max - 2, .y = 0 }, zc.cursor);
    try zc.doVisualMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = max - 3, .y = 0 }, zc.cursor);

    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = max - 12, .y = 0 }, zc.cursor);
    try zc.doVisualMode(.{ .count = 1 });
    try zc.doVisualMode(.{ .count = 0 });
    try zc.doVisualMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = max - 22, .y = 0 }, zc.cursor);

    zc.setCursor(.{ .x = 2, .y = 0 });
    try t.expectEqual(Position{ .x = 2, .y = 0 }, zc.cursor);

    try zc.doVisualMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = 1, .y = 0 }, zc.cursor);
    try zc.doVisualMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
    try zc.doVisualMode(.cell_cursor_left);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);

    // cell cursor down
    zc.setCursor(.{ .x = 0, .y = 0 });
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);

    try zc.doVisualMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = 1 }, zc.cursor);
    try zc.doVisualMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = 2 }, zc.cursor);
    try zc.doVisualMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = 3 }, zc.cursor);

    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = 12 }, zc.cursor);
    try zc.doVisualMode(.cell_cursor_down);
    try zc.doVisualMode(.{ .count = 1 });
    try zc.doVisualMode(.{ .count = 0 });
    try zc.doVisualMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = 23 }, zc.cursor);

    zc.setCursor(.{ .x = 0, .y = max - 1 });
    try t.expectEqual(Position{ .x = 0, .y = max - 1 }, zc.cursor);
    try zc.doVisualMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = max }, zc.cursor);
    try zc.doVisualMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = max }, zc.cursor);
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.cell_cursor_down);
    try t.expectEqual(Position{ .x = 0, .y = max }, zc.cursor);

    // cell cursor up
    zc.setCursor(.{ .x = 0, .y = max });
    try t.expectEqual(Position{ .x = 0, .y = max }, zc.cursor);

    try zc.doVisualMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = max - 1 }, zc.cursor);
    try zc.doVisualMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = max - 2 }, zc.cursor);
    try zc.doVisualMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = max - 3 }, zc.cursor);

    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = max - 12 }, zc.cursor);
    try zc.doVisualMode(.{ .count = 1 });
    try zc.doVisualMode(.{ .count = 0 });
    try zc.doVisualMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = max - 22 }, zc.cursor);

    zc.setCursor(.{ .x = 0, .y = 2 });
    try zc.doVisualMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = 1 }, zc.cursor);
    try zc.doVisualMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
    try zc.doVisualMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.cell_cursor_up);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);

    // next/prev_populated_cell
    // empty sheet - cursor shouldn't move
    try zc.doVisualMode(.next_populated_cell);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
    zc.setCursor(.{ .x = 50, .y = 50 });
    try zc.doVisualMode(.next_populated_cell);
    try t.expectEqual(Position{ .x = 50, .y = 50 }, zc.cursor);

    zc.setCursor(.{ .x = 0, .y = 0 });
    try zc.doVisualMode(.prev_populated_cell);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
    zc.setCursor(.{ .x = 50, .y = 50 });
    try zc.doVisualMode(.prev_populated_cell);
    try t.expectEqual(Position{ .x = 50, .y = 50 }, zc.cursor);

    try zc.parseCommand("let C4 = 0");
    try zc.parseCommand("let ZZZ0 = 5");
    try zc.parseCommand("let A4 = 1");
    try zc.parseCommand("let B2 = 4");
    try zc.parseCommand("let B0 = 3");
    try zc.parseCommand("let A500 = 2");
    try zc.updateCells();

    zc.setCursor(.{ .x = 0, .y = 0 });
    try zc.doVisualMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("B0"), zc.cursor);
    try zc.doVisualMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("ZZZ0"), zc.cursor);
    try zc.doVisualMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("B2"), zc.cursor);
    try zc.doVisualMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("A4"), zc.cursor);
    try zc.doVisualMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("C4"), zc.cursor);
    try zc.doVisualMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("A500"), zc.cursor);
    try zc.doVisualMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("A500"), zc.cursor);

    zc.setCursor(.{ .x = 0, .y = 0 });
    try zc.doVisualMode(.{ .count = 2 });
    try zc.doVisualMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("ZZZ0"), zc.cursor);
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.next_populated_cell);
    try t.expectEqual(try Position.fromAddress("A500"), zc.cursor);

    zc.setCursor(.{ .x = max, .y = max });
    try zc.doVisualMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("A500"), zc.cursor);
    try zc.doVisualMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("C4"), zc.cursor);
    try zc.doVisualMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("A4"), zc.cursor);
    try zc.doVisualMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("B2"), zc.cursor);
    try zc.doVisualMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("ZZZ0"), zc.cursor);
    try zc.doVisualMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("B0"), zc.cursor);
    try zc.doVisualMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("B0"), zc.cursor);

    zc.setCursor(.{ .x = max, .y = max });
    try zc.doVisualMode(.{ .count = 2 });
    try zc.doVisualMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("C4"), zc.cursor);
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.prev_populated_cell);
    try t.expectEqual(try Position.fromAddress("B0"), zc.cursor);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.anchor);

    // swap_anchor
    try zc.doVisualMode(.swap_anchor);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
    try t.expectEqual(Position.fromAddress("B0"), zc.anchor);

    zc.setCursor(.{ .x = max, .y = max });
    try zc.doVisualMode(.swap_anchor);
    try t.expectEqual(Position{ .x = max, .y = max }, zc.anchor);
    try t.expectEqual(Position.fromAddress("B0"), zc.cursor);

    zc.setCursor(.{ .x = max - 10, .y = max - 10 });
    try zc.doVisualMode(.swap_anchor);
    try t.expectEqual(Position{ .x = max - 10, .y = max - 10 }, zc.anchor);
    try t.expectEqual(Position{ .x = max, .y = max }, zc.cursor);

    // visual_move_left
    try zc.doVisualMode(.visual_move_left);
    try t.expectEqual(Position{ .x = max - 1, .y = max }, zc.cursor);
    try t.expectEqual(Position{ .x = max - 11, .y = max - 10 }, zc.anchor);
    try zc.doVisualMode(.visual_move_left);
    try t.expectEqual(Position{ .x = max - 2, .y = max }, zc.cursor);
    try t.expectEqual(Position{ .x = max - 12, .y = max - 10 }, zc.anchor);
    try zc.doVisualMode(.visual_move_left);
    try t.expectEqual(Position{ .x = max - 3, .y = max }, zc.cursor);
    try t.expectEqual(Position{ .x = max - 13, .y = max - 10 }, zc.anchor);

    // with counts
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.visual_move_left);
    try t.expectEqual(Position{ .x = max - 12, .y = max }, zc.cursor);
    try t.expectEqual(Position{ .x = max - 22, .y = max - 10 }, zc.anchor);
    try zc.doVisualMode(.{ .count = 1 });
    try zc.doVisualMode(.{ .count = 0 });
    try zc.doVisualMode(.visual_move_left);
    try t.expectEqual(Position{ .x = max - 22, .y = max }, zc.cursor);
    try t.expectEqual(Position{ .x = max - 32, .y = max - 10 }, zc.anchor);
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.visual_move_left);
    try t.expectEqual(Position{ .x = max - 10021, .y = max }, zc.cursor);
    try t.expectEqual(Position{ .x = max - 10031, .y = max - 10 }, zc.anchor);
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.visual_move_left);
    try t.expectEqual(Position{ .x = 10, .y = max }, zc.cursor);
    try t.expectEqual(Position{ .x = 0, .y = max - 10 }, zc.anchor);
    try zc.doVisualMode(.visual_move_left);
    try t.expectEqual(Position{ .x = 10, .y = max }, zc.cursor);
    try t.expectEqual(Position{ .x = 0, .y = max - 10 }, zc.anchor);

    // visual_move_right
    zc.setCursor(.{ .x = 0, .y = 0 });
    zc.anchor = .{ .x = 10, .y = 10 };
    try zc.doVisualMode(.visual_move_right);
    try t.expectEqual(Position{ .x = 1, .y = 0 }, zc.cursor);
    try t.expectEqual(Position{ .x = 11, .y = 10 }, zc.anchor);
    try zc.doVisualMode(.visual_move_right);
    try t.expectEqual(Position{ .x = 2, .y = 0 }, zc.cursor);
    try t.expectEqual(Position{ .x = 12, .y = 10 }, zc.anchor);
    try zc.doVisualMode(.visual_move_right);
    try t.expectEqual(Position{ .x = 3, .y = 0 }, zc.cursor);
    try t.expectEqual(Position{ .x = 13, .y = 10 }, zc.anchor);

    // with counts
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.visual_move_right);
    try t.expectEqual(Position{ .x = 12, .y = 0 }, zc.cursor);
    try t.expectEqual(Position{ .x = 22, .y = 10 }, zc.anchor);
    try zc.doVisualMode(.{ .count = 1 });
    try zc.doVisualMode(.{ .count = 0 });
    try zc.doVisualMode(.visual_move_right);
    try t.expectEqual(Position{ .x = 22, .y = 0 }, zc.cursor);
    try t.expectEqual(Position{ .x = 32, .y = 10 }, zc.anchor);
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.visual_move_right);
    try t.expectEqual(Position{ .x = 10021, .y = 0 }, zc.cursor);
    try t.expectEqual(Position{ .x = 10031, .y = 10 }, zc.anchor);
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.visual_move_right);
    try t.expectEqual(Position{ .x = max - 10, .y = 0 }, zc.cursor);
    try t.expectEqual(Position{ .x = max, .y = 10 }, zc.anchor);
    try zc.doVisualMode(.visual_move_right);
    try t.expectEqual(Position{ .x = max - 10, .y = 0 }, zc.cursor);
    try t.expectEqual(Position{ .x = max, .y = 10 }, zc.anchor);

    // visual_move_up
    zc.setCursor(.{ .x = max, .y = max });
    zc.anchor = .{ .x = max - 10, .y = max - 10 };
    try zc.doVisualMode(.visual_move_up);
    try t.expectEqual(Position{ .y = max - 1, .x = max }, zc.cursor);
    try t.expectEqual(Position{ .y = max - 11, .x = max - 10 }, zc.anchor);
    try zc.doVisualMode(.visual_move_up);
    try t.expectEqual(Position{ .y = max - 2, .x = max }, zc.cursor);
    try t.expectEqual(Position{ .y = max - 12, .x = max - 10 }, zc.anchor);
    try zc.doVisualMode(.visual_move_up);
    try t.expectEqual(Position{ .y = max - 3, .x = max }, zc.cursor);
    try t.expectEqual(Position{ .y = max - 13, .x = max - 10 }, zc.anchor);

    // with counts
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.visual_move_up);
    try t.expectEqual(Position{ .y = max - 12, .x = max }, zc.cursor);
    try t.expectEqual(Position{ .y = max - 22, .x = max - 10 }, zc.anchor);
    try zc.doVisualMode(.{ .count = 1 });
    try zc.doVisualMode(.{ .count = 0 });
    try zc.doVisualMode(.visual_move_up);
    try t.expectEqual(Position{ .y = max - 22, .x = max }, zc.cursor);
    try t.expectEqual(Position{ .y = max - 32, .x = max - 10 }, zc.anchor);
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.visual_move_up);
    try t.expectEqual(Position{ .y = max - 10021, .x = max }, zc.cursor);
    try t.expectEqual(Position{ .y = max - 10031, .x = max - 10 }, zc.anchor);
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.visual_move_up);
    try t.expectEqual(Position{ .y = 10, .x = max }, zc.cursor);
    try t.expectEqual(Position{ .y = 0, .x = max - 10 }, zc.anchor);
    try zc.doVisualMode(.visual_move_up);
    try t.expectEqual(Position{ .y = 10, .x = max }, zc.cursor);
    try t.expectEqual(Position{ .y = 0, .x = max - 10 }, zc.anchor);

    // visual_move_down
    zc.setCursor(.{ .y = 0, .x = 0 });
    zc.anchor = .{ .y = 10, .x = 10 };
    try zc.doVisualMode(.visual_move_down);
    try t.expectEqual(Position{ .y = 1, .x = 0 }, zc.cursor);
    try t.expectEqual(Position{ .y = 11, .x = 10 }, zc.anchor);
    try zc.doVisualMode(.visual_move_down);
    try t.expectEqual(Position{ .y = 2, .x = 0 }, zc.cursor);
    try t.expectEqual(Position{ .y = 12, .x = 10 }, zc.anchor);
    try zc.doVisualMode(.visual_move_down);
    try t.expectEqual(Position{ .y = 3, .x = 0 }, zc.cursor);
    try t.expectEqual(Position{ .y = 13, .x = 10 }, zc.anchor);

    // with counts
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.visual_move_down);
    try t.expectEqual(Position{ .y = 12, .x = 0 }, zc.cursor);
    try t.expectEqual(Position{ .y = 22, .x = 10 }, zc.anchor);
    try zc.doVisualMode(.{ .count = 1 });
    try zc.doVisualMode(.{ .count = 0 });
    try zc.doVisualMode(.visual_move_down);
    try t.expectEqual(Position{ .y = 22, .x = 0 }, zc.cursor);
    try t.expectEqual(Position{ .y = 32, .x = 10 }, zc.anchor);
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.visual_move_down);
    try t.expectEqual(Position{ .y = 10021, .x = 0 }, zc.cursor);
    try t.expectEqual(Position{ .y = 10031, .x = 10 }, zc.anchor);
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.visual_move_down);
    try t.expectEqual(Position{ .y = max - 10, .x = 0 }, zc.cursor);
    try t.expectEqual(Position{ .y = max, .x = 10 }, zc.anchor);
    try zc.doVisualMode(.visual_move_down);
    try t.expectEqual(Position{ .y = max - 10, .x = 0 }, zc.cursor);
    try t.expectEqual(Position{ .y = max, .x = 10 }, zc.anchor);
}
