const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const build = @import("build");
const Lua = @import("zlua").Lua;
const wcWidth = @import("wcwidth").wcWidth;

const ast = @import("ast.zig");
const Command = @import("Command.zig");
const input = @import("input.zig");
const Action = input.Action;
const CommandAction = input.CommandAction;
const KeyMap = input.KeyMap;
const MapType = input.MapType;
const CommandMapType = input.CommandMapType;
const lua = @import("lua.zig");
const Position = @import("Position.zig").Position;
const Rect = Position.Rect;
const Sheet = @import("Sheet.zig");
const text = @import("text.zig");
const Motion = text.Motion;
const Tui = @import("Tui.zig");
const utils = @import("utils.zig");

const log = std.log.scoped(.zc);

const ZC = @This();

pub const Ui = struct {
    ptr: *anyopaque,
    vtable: *const Vtable,

    pub const ApplyThemeError = error{
        Unsupported,
        Failed,
    };

    pub const Vtable = struct {
        /// When a user sets a theme, the path
        /// `${XDG_CONFIG_HOME}/cellulator/themes/${UI}/${THEME_NAME}` is passed to this function.
        /// The UI backend is then responsible for applying the theme in this file.
        applyTheme: *const fn (*anyopaque, [:0]const u8) ApplyThemeError!void,

        /// Apply the default theme.
        applyDefaultTheme: *const fn (*anyopaque) ApplyThemeError!void,

        stringWidth: *const fn (*anyopaque, []const u8, StringWidthOptions) StringWidthResult,

        // Yes these are a little bit cursed to put in a vtable but this is better than calling
        // a virtual function to get these.
        theme_file_extension: []const u8,
        ui_name: []const u8,
    };

    pub const StringWidthOptions = struct {
        max_width: u32 = std.math.maxInt(u32),
    };

    pub const StringWidthResult = struct {
        width: u32,
        len: usize,
    };

    // TODO: Better error handling and reporting
    pub fn applyTheme(ui: Ui, theme_filepath: [:0]const u8) ApplyThemeError!void {
        return ui.vtable.applyTheme(ui.ptr, theme_filepath);
    }

    pub fn applyDefaultTheme(ui: Ui) ApplyThemeError!void {
        return ui.vtable.applyDefaultTheme(ui.ptr);
    }

    /// Returns the file extension for the theme files used by this UI backend. Returned memory
    /// should be statically allocated.
    pub fn getThemeFileExtension(ui: Ui) []const u8 {
        return ui.vtable.theme_file_extension;
    }

    pub fn getUiName(ui: Ui) []const u8 {
        return ui.vtable.ui_name;
    }

    pub fn stringWidth(
        ui: Ui,
        bytes: []const u8,
        opts: StringWidthOptions,
    ) StringWidthResult {
        return ui.vtable.stringWidth(ui.ptr, bytes, opts);
    }
};

lua_ptr: *Lua,

running: bool = true,

current_sheet: usize,
max_sheet_n: usize = 1,
sheets: std.StringArrayHashMapUnmanaged(Sheet),

// TODO: Move all calls from this to the interface and remove this field
ui: Tui,
ui_interface: Ui,

prev_mode: Mode = .normal,
mode: Mode = .normal,

screen_pos: Position = .origin,

anchor: Position = .origin,

prev_cursor: Position = .origin,

/// The cell position of the cursor
cursor: Position = .origin,

count: u32 = 0,

command_screen_pos: u32 = 0,
command: Command = .{},

keymaps: input.KeyMaps,

allocator: Allocator,

input_buf: std.io.Writer.Allocating,

status_message_type: StatusMessageType = .info,
status_message: std.BoundedArray(u8, 256) = .{},

/// Used as scratch space
arena: std.heap.ArenaAllocator,

yank: ?Rect = null,

had_prefix: bool = false,

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

    pub fn isVisual(mode: Mode) bool {
        return switch (mode) {
            .visual, .select => true,
            .normal,
            .command_normal,
            .command_insert,
            .command_change,
            .command_delete,
            .command_to_forwards,
            .command_to_backwards,
            .command_until_forwards,
            .command_until_backwards,
            => false,
        };
    }

    pub fn format(mode: Mode, writer: *std.io.Writer) !void {
        try writer.writeAll(@tagName(mode));
    }
};

pub const InitOptions = struct {
    filepath: ?[]const u8 = null,
    ui: bool = true,
};

/// Initialises via a pointer rather than returning an instance, as we need a
/// stable pointer to a ZC instance.
pub fn init(zc: *ZC, allocator: Allocator, options: InitOptions) !void {
    errdefer zc.* = undefined;

    zc.allocator = allocator;

    var keys = try input.createKeymaps(allocator);
    errdefer keys.deinit(allocator);

    var tui = try Tui.init(allocator);
    errdefer tui.deinit(allocator);

    if (options.ui) try tui.term.uncook(allocator, .{});

    var lua_state = try lua.init(zc);
    errdefer lua_state.deinit();

    zc.* = .{
        .current_sheet = 0,
        .sheets = .empty,
        .lua_ptr = lua_state,
        .ui = tui,
        .ui_interface = undefined,
        .allocator = allocator,
        .keymaps = keys,
        .arena = .init(allocator),
        .input_buf = try .initCapacity(allocator, 1),
    };
    zc.clearInput();
    errdefer zc.sheets.deinit(allocator);
    errdefer for (zc.sheets.values()) |*sheet| sheet.deinit();
    const sheet = try zc.openSheet();
    zc.setCurrentSheet(sheet);

    zc.ui_interface = zc.ui.ui();

    zc.sourceLua() catch |err| log.err("Could not source init.lua: {}", .{err});

    zc.emitEvent("Init", .{});

    if (options.filepath) |filepath| {
        try zc.loadFile(zc.current_sheet, filepath);
    }

    log.debug("Finished init", .{});
    zc.emitEvent("Start", .{});
}

pub fn sourceLua(zc: *ZC) !void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const paths: []const []const u8 = if (std.posix.getenv("XDG_CONFIG_HOME")) |path|
        &.{ path, "cellulator/init.lua" }
    else if (std.posix.getenv("HOME")) |path|
        &.{ path, ".config/cellulator/init.lua" }
    else
        return error.CouldNotDeterminePath;

    const path = try std.fs.path.joinZ(allocator, paths);
    log.debug("Sourcing lua file '{s}'", .{path});
    zc.lua_ptr.doFile(path) catch |err| {
        const msg = zc.lua_ptr.checkString(-1);
        std.log.err("ERROR: {s}", .{msg});
        return err;
    };
}

pub fn deinit(zc: *ZC) void {
    zc.ui.deinit(zc.allocator);

    // Don't need to free memory on exit, the OS will do it for us :^)
    if (!std.debug.runtime_safety) return;

    zc.lua_ptr.deinit();
    zc.command.deinit(zc.allocator);

    zc.input_buf.deinit();
    zc.keymaps.deinit(zc.allocator);

    for (zc.sheets.keys()) |key| zc.allocator.free(key);
    for (zc.sheets.values()) |*sheet| sheet.deinit();
    zc.sheets.deinit(zc.allocator);
    zc.arena.deinit();
    zc.* = undefined;
}

/// Emits the given event, calling it's dispatcher with `args`.
pub fn emitEvent(zc: *ZC, event: [:0]const u8, args: anytype) void {
    log.debug("Emitting event '{s}' with {d} arguments", .{ event, args.len });
    lua.emitEvent(zc.lua_ptr, event, args) catch {}; // TODO: Make sure handled correctly
}

pub fn inputSentinelSlice(zc: *ZC) Allocator.Error![:0]u8 {
    zc.input_buf.writer.writeByte(0) catch return error.OutOfMemory;
    const buffered = zc.input_buf.getWritten();
    const ret = buffered[0 .. buffered.len - 1 :0];
    zc.input_buf.writer.end -= 1;
    return ret;
}

pub fn inputSlice(zc: *const ZC) [:0]u8 {
    return zc.input_buf.writer.buffer[0..zc.input_buf.writer.end :0];
}

fn clearInput(zc: *ZC) void {
    if (zc.had_prefix) zc.ui.update_flags.cells = true;
    zc.input_buf.clearRetainingCapacity();
    zc.input_buf.writer.writeByte(0) catch unreachable;
    zc.input_buf.writer.end = 0;
}

pub fn run(zc: *ZC) !void {
    while (zc.running) {
        try zc.updateCells();
        try zc.ui.render(zc);
        try zc.handleInput();
    }
}

pub const ChangeCellOpts = struct {
    emit_event: bool = true,
    undo_opts: Sheet.UndoOpts = .{},
};

/// Sets the cell at `pos` to the expression represented by `ast`.
pub fn setCell(
    zc: *ZC,
    pos: Position,
    source: []const u8,
    expr_root: ast.Index,
    opts: ChangeCellOpts,
) !void {
    try zc.currentSheet().setCell(pos, source, expr_root, .{});
    zc.ui.update_flags.cursor = true;
    zc.ui.update_flags.cells = true;
    if (opts.emit_event) {
        const expr_string =
            for (source, 0..) |c, i| {
                if (c == '=') break std.mem.trimLeft(
                    u8,
                    source[i + 1 ..],
                    &std.ascii.whitespace,
                );
            } else unreachable;
        zc.emitEvent("SetCell", .{ pos, expr_string });
    }
}

pub fn getSheet(zc: *const ZC, index: usize) *Sheet {
    return &zc.sheets.values()[index];
}

pub fn currentSheet(zc: *const ZC) *Sheet {
    return &zc.sheets.values()[zc.current_sheet];
}

pub fn getSheetName(zc: *const ZC, index: usize) []const u8 {
    return zc.sheets.keys()[index];
}

pub fn setCellString(zc: *ZC, pos: Position, expr: [:0]const u8, opts: ChangeCellOpts) !void {
    // TODO: This leaks memory if `setCell` fails, which can only happen on OOM.
    const expr_root = try ast.parseFromExpression(zc.currentSheet(), expr);

    try zc.setCell(pos, expr, expr_root, opts);
}

// TODO: merge this and `deleteCell`
pub fn deleteCell2(zc: *ZC, pos: Position, opts: ChangeCellOpts) !void {
    try zc.currentSheet().deleteCell(pos, opts.undo_opts);
    zc.ui.update_flags.cursor = true;
    zc.ui.update_flags.cells = true;
    if (opts.emit_event)
        zc.emitEvent("DeleteCell", .{pos});
}

pub const StatusMessageType = enum { info, warn, err };

// TODO: Use std.log for this, and also output to file in debug mode
pub fn setStatusMessage(
    zc: *ZC,
    t: StatusMessageType,
    comptime fmt: []const u8,
    args: anytype,
) void {
    zc.dismissStatusMessage();
    zc.status_message_type = t;
    const writer = zc.status_message.writer();
    writer.print(fmt, args) catch {};
    zc.ui.update_flags.command = true;
}

pub fn dismissStatusMessage(zc: *ZC) void {
    zc.status_message.len = 0;
    zc.ui.update_flags.command = true;
}

pub fn updateCells(zc: *ZC) Allocator.Error!void {
    return zc.currentSheet().update();
}

pub fn setMode(zc: *ZC, new_mode: Mode) void {
    switch (zc.mode) {
        .normal => {},
        .visual, .select => {
            zc.ui.update_flags.cells = true;
            zc.ui.update_flags.column_headings = true;
            zc.ui.update_flags.row_numbers = true;
        },
        .command_normal,
        .command_insert,
        .command_delete,
        .command_change,
        .command_to_forwards,
        .command_to_backwards,
        .command_until_forwards,
        .command_until_backwards,
        => zc.ui.update_flags.command = true,
    }

    zc.prev_mode = zc.mode;
    zc.anchor = zc.cursor;
    zc.mode = new_mode;

    if (new_mode.isCommandMode()) {
        zc.clampCommandCursor();
    }
}

pub fn getKeymap(zc: *ZC, comptime mode: Mode) switch (mode) {
    .normal, .visual, .select => *input.SheetKeyMap,
    else => *input.CommandKeyMap,
} {
    return switch (mode) {
        .command_normal => &zc.keymaps.command_normal,
        .command_insert => &zc.keymaps.command_insert,
        .command_change, .command_delete => &zc.keymaps.command_operator_pending,
        .command_to_forwards,
        .command_to_backwards,
        .command_until_forwards,
        .command_until_backwards,
        => &zc.keymaps.command_to,
        .normal => &zc.keymaps.sheet_normal,
        .visual => &zc.keymaps.sheet_visual,
        .select => &zc.keymaps.sheet_select,
    };
}

fn handleInput(zc: *ZC) !void {
    assert(zc.currentSheet().undos.len == 0 or zc.currentSheet().undos.items(.tag)[zc.currentSheet().undos.len - 1] == .sentinel);
    assert(zc.currentSheet().redos.len == 0 or zc.currentSheet().redos.items(.tag)[zc.currentSheet().redos.len - 1] == .sentinel);

    var buf: [256]u8 = undefined;
    const slice = try zc.ui.term.readInput(&buf);

    try input.parse(&zc.ui.term, slice, &zc.input_buf.writer);
    const bytes = try zc.inputSentinelSlice();

    switch (zc.mode) {
        inline else => |mode| {
            const map = zc.getKeymap(mode);
            const res = map.get(bytes);
            switch (res) {
                .kv => |kv| {
                    const action = kv.value;
                    _ = switch (mode) {
                        .normal => zc.doNormalMode(action),
                        .visual, .select => zc.doVisualMode(action),
                        .command_normal,
                        .command_insert,
                        .command_change,
                        .command_delete,
                        .command_to_forwards,
                        .command_to_backwards,
                        .command_until_forwards,
                        .command_until_backwards,
                        => zc.doCommandMode(action, bytes),
                    } catch |err| {
                        std.log.err("Error: {s}", .{@errorName(err)});
                    };

                    zc.clearInput();
                },
                .prefix => {},
                .not_found => {
                    if (comptime mode.isCommandMode()) {
                        const n = std.mem.replace(u8, bytes, "<<", "<", bytes);
                        zc.doCommandMode(.none, bytes[0 .. bytes.len - n]) catch |err| switch (err) {
                            else => zc.setStatusMessage(.err, "Unhandled error {}", .{err}),
                        };
                    }
                    zc.clearInput();
                },
            }
            zc.had_prefix = res == .prefix;
        },
    }
}

pub fn doCommandMode(zc: *ZC, action: CommandAction, keys: []const u8) !void {
    defer zc.clampScreenToCommandCursor();
    switch (zc.mode) {
        .command_normal => try zc.doCommandNormalMode(action),
        .command_insert => try zc.doCommandInsertMode(action, keys),
        .command_change, .command_delete => try zc.doCommandOperatorPendingMode(action),
        .command_to_forwards,
        .command_to_backwards,
        .command_until_forwards,
        .command_until_backwards,
        => zc.doCommandToMode(action, keys),
        else => unreachable,
    }
}

pub inline fn doCommandNormalMotion(zc: *ZC, range: text.Range) void {
    zc.setCommandCursor(if (range.start == zc.command.cursor) range.end else range.start);
}

fn clampCommandCursor(zc: *ZC) void {
    if (zc.mode == .command_normal) {
        const len = zc.command.length();
        if (zc.command.cursor == len) {
            const new = len - text.prevCharacter(zc.command, len, 1);
            zc.command.setCursor(new);
        }
    }
}

// TODO: Move this to the tui
fn clampScreenToCommandCursor(zc: *ZC) void {
    if (zc.command.cursor < zc.command_screen_pos) {
        zc.command_screen_pos = zc.command.cursor;
        return;
    }

    const len = zc.command.length();
    var x: u32 = zc.command.cursor;
    // Reserve either the width of the character under the cursor, or 1 column if none.
    var w: u16 = if (zc.command.cursor < len) blk: {
        const grapheme_len = zc.command.nextCharacter(x, 1);
        const grapheme_slice = zc.command.slice(x, grapheme_len);
        break :blk @intCast(zc.ui.term.graphemeWidth(grapheme_slice));
    } else 1;

    while (true) {
        const prev = x;
        x -= text.prevCharacter(&zc.command, x, 1);
        if (prev == x or x < zc.screen_pos.x) break;

        const graphemeSlice = zc.command.slice(x, prev - x);
        w += @intCast(zc.ui.term.graphemeWidth(graphemeSlice));

        if (w > zc.ui.term.width) {
            if (prev > zc.command_screen_pos) zc.command_screen_pos = prev;
            break;
        }
    }
}

/// Doesn't wrap Command.Writer to avoid an unnecessary layer of indirection.
const CmdWriter = struct {
    interface: std.io.Writer,
    zc: *ZC,

    pub fn drain(io_writer: *std.io.Writer, data: []const []const u8, splat: usize) !usize {
        const w: *CmdWriter = @fieldParentPtr("interface", io_writer);
        defer w.zc.clampCommandCursor();
        defer w.zc.clampScreenToCommandCursor();

        const buffered = w.interface.buffered();
        if (buffered.len > 0) {
            const bytes_written = w.zc.command.write(w.zc.allocator, buffered) catch
                return error.WriteFailed;

            const remaining = w.interface.consume(bytes_written);
            if (remaining != 0)
                return 0;
        }

        var total_written: usize = 0;
        for (data[0 .. data.len - 1]) |str| {
            const bytes_written = w.zc.command.write(w.zc.allocator, str) catch
                return error.WriteFailed;

            total_written += bytes_written;
            if (bytes_written < str.len) return total_written;
        }

        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            const bytes_written = w.zc.command.write(w.zc.allocator, pattern) catch
                return error.WriteFailed;

            total_written += bytes_written;
            if (bytes_written < pattern.len) return total_written;
        }

        return total_written;
    }
};

pub fn commandWriter(zc: *ZC, buffer: []u8) CmdWriter {
    return .{
        .interface = .{
            .vtable = &.{
                .drain = CmdWriter.drain,
            },
            .buffer = buffer,
        },
        .zc = zc,
    };
}

pub fn setCommandCursor(zc: *ZC, pos: u32) void {
    zc.command.setCursor(pos);
    zc.clampCommandCursor();
    zc.clampScreenToCommandCursor();
}

pub fn submitCommand(zc: *ZC) !void {
    assert(zc.mode.isCommandMode());
    zc.dismissStatusMessage();
    defer if (zc.mode.isCommandMode()) zc.setMode(.normal);

    const slice = try zc.command.submit(zc.allocator);
    defer zc.commandHistoryNext();
    try zc.parseCommand(slice);
}

pub fn commandHistoryNext(zc: *ZC) void {
    zc.command.next(zc.getCount());
    zc.setCommandCursor(zc.command.length());
    zc.resetCount();
}

pub fn commandHistoryPrev(zc: *ZC) void {
    zc.command.prev(zc.getCount());
    zc.setCommandCursor(zc.command.length());
    zc.resetCount();
}

pub fn doCommandMotion(zc: *ZC, motion: Motion) Allocator.Error!void {
    const count = zc.getCount();
    switch (zc.mode) {
        .normal, .visual, .select => unreachable,
        .command_normal, .command_insert => {
            const range = motion.do(zc.command, zc.command.cursor, count);
            zc.doCommandNormalMotion(range);
        },
        .command_change => {
            const m = switch (motion) {
                .normal_word_start_next => .normal_word_end_next,
                .long_word_start_next => .long_word_end_next,
                else => motion,
            };
            const range = m.do(zc.command, zc.command.cursor, count);

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
                    => text.nextCharacter(zc.command, range.end, 1),
                    else => 0,
                };

                assert(end >= range.start);
                try zc.command.replaceRange(zc.allocator, range.start, end - range.start, &.{});
                zc.setCommandCursor(range.start);
            }
            zc.setMode(.command_insert);
        },
        .command_delete => {
            const range = motion.do(zc.command, zc.command.cursor, count);
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
                    => text.nextCharacter(zc.command, range.end, 1),
                    else => 0,
                };
                try zc.command.replaceRange(zc.allocator, range.start, end - range.start, &.{});
                zc.setCommandCursor(range.start);
            }
            zc.setMode(.command_normal);
        },
        .command_to_forwards,
        .command_to_backwards,
        .command_until_forwards,
        .command_until_backwards,
        => unreachable, // Attempted motion in 'to' mode
    }
    zc.resetCount();
}

pub fn doCommandNormalMode(zc: *ZC, action: CommandAction) !void {
    switch (action) {
        .history_next => zc.commandHistoryNext(),
        .history_prev => zc.commandHistoryPrev(),
        .submit_command => try zc.submitCommand(),
        .enter_normal_mode => {
            zc.command.resetBuffer();
            zc.setMode(.normal);
        },
        .enter_insert_mode => zc.setMode(.command_insert),
        .enter_insert_mode_after => {
            zc.setMode(.command_insert);
            zc.doCommandMotion(.char_next) catch unreachable;
        },
        .enter_insert_mode_at_eol => {
            zc.setMode(.command_insert);
            zc.doCommandMotion(.eol) catch unreachable;
        },
        .enter_insert_mode_at_bol => {
            zc.setMode(.command_insert);
            zc.doCommandMotion(.bol) catch unreachable;
        },
        .operator_delete => zc.setMode(.command_delete),
        .operator_change => zc.setMode(.command_change),
        inline .delete_char, .change_char => |_, a| {
            const len = text.nextCharacter(zc.command, zc.command.cursor, 1);
            try zc.command.replaceRange(zc.allocator, zc.command.cursor, len, &.{});
            if (a == .change_char) zc.setMode(.command_insert);
            zc.clampCommandCursor();
        },
        .change_to_eol => {
            try zc.command.copyIfNeeded(zc.allocator);
            zc.command.buffer.shrinkRetainingCapacity(zc.command.cursor);
            zc.setMode(.command_insert);
        },
        .delete_to_eol => {
            try zc.command.copyIfNeeded(zc.allocator);
            zc.command.buffer.shrinkRetainingCapacity(zc.command.cursor);
        },
        .change_line => {
            zc.command.resetBuffer();
            zc.setMode(.command_insert);
        },
        .operator_to_forwards => zc.setMode(.command_to_forwards),
        .operator_to_backwards => zc.setMode(.command_to_backwards),
        .operator_until_forwards => zc.setMode(.command_until_forwards),
        .operator_until_backwards => zc.setMode(.command_until_backwards),
        .zero => {
            if (zc.count == 0) {
                zc.setCommandCursor(0);
            } else {
                zc.setCount(0);
            }
        },
        .count => |count| zc.setCount(count),
        else => {
            if (action.isMotion()) {
                zc.doCommandMotion(action.toMotion()) catch unreachable;
            }
        },
    }
}

fn doCommandInsertMode(zc: *ZC, action: CommandAction, keys: []const u8) !void {
    defer zc.clampScreenToCommandCursor();
    try switch (action) {
        .none => {
            var writer = zc.commandWriter(&.{});
            writer.interface.writeAll(keys) catch return error.OutOfMemory;
        },
        .history_next => zc.commandHistoryNext(),
        .history_prev => zc.commandHistoryPrev(),
        .backspace => {
            const len = text.prevCharacter(zc.command, zc.command.cursor, 1);
            try zc.command.deleteBackwards(zc.allocator, len);
        },
        .submit_command => zc.submitCommand(),
        .enter_normal_mode => zc.setMode(.command_normal),
        .enter_select_mode => zc.setMode(.select),
        .backwards_delete_word => {
            zc.setMode(.command_change);
            zc.doCommandMotion(.normal_word_start_prev) catch unreachable;
        },
        .change_line => zc.command.resetBuffer(),
        .delete_to_eol => {
            try zc.command.copyIfNeeded(zc.allocator);
            zc.command.buffer.shrinkRetainingCapacity(zc.command.cursor);
        },
        .delete_to_bol => {
            try zc.command.deleteBackwards(zc.allocator, zc.command.cursor);
        },
        else => {
            if (action.isMotion()) {
                zc.doCommandMotion(action.toMotion()) catch unreachable;
            }
        },
    };
}

/// Handles common actions between operator modes
fn doCommandOperatorPendingMode(zc: *ZC, action: CommandAction) Allocator.Error!void {
    switch (action) {
        .enter_normal_mode => zc.setMode(.command_normal),

        .operator_to_forwards => zc.setMode(.command_to_forwards),
        .operator_to_backwards => zc.setMode(.command_to_backwards),
        .operator_until_forwards => zc.setMode(.command_until_forwards),
        .operator_until_backwards => zc.setMode(.command_until_backwards),

        .zero => if (zc.count == 0) try zc.doCommandMotion(.bol) else zc.setCount(0),
        .count => |count| zc.setCount(count),

        .operator_delete => if (zc.mode == .command_delete) try zc.doCommandMotion(.line),
        .operator_change => if (zc.mode == .command_change) try zc.doCommandMotion(.line),
        inline else => |_, tag| {
            if (comptime CommandAction.isMotionTag(tag)) {
                try zc.doCommandMotion(action.toMotion());
            }
        },
    }
}

pub fn doCommandToMode(zc: *ZC, action: CommandAction, keys: []const u8) void {
    switch (action) {
        .enter_normal_mode => zc.setMode(.command_normal),
        .none => {
            if (keys.len == 0) return;
            zc.setMode(zc.prev_mode);
            const motion: Motion = switch (zc.prev_mode) {
                .command_to_forwards => .{ .to_forwards_utf8 = keys },
                .command_to_backwards => .{ .to_backwards_utf8 = keys },
                .command_until_forwards => .{ .until_forwards_utf8 = keys },
                .command_until_backwards => .{ .until_backwards_utf8 = keys },
                else => unreachable,
            };
            zc.doCommandMotion(motion) catch unreachable;
        },
        else => {},
    }
}

pub fn doNormalMode(zc: *ZC, action: Action) !void {
    switch (action) {
        .enter_command_mode => {
            zc.setMode(.command_insert);
            var writer = zc.commandWriter(&.{});
            writer.interface.writeByte(':') catch return error.OutOfMemory;
        },
        .edit_cell => {
            zc.setMode(.command_insert);
            var wr = zc.commandWriter(&.{});
            wr.interface.print("let {f} = ", .{zc.cursor}) catch return error.OutOfMemory;
            zc.currentSheet().printCellExpression(zc.cursor, &wr.interface) catch return error.OutOfMemory;
        },
        .fit_text => try zc.expandWidthAtCursor(),
        .enter_visual_mode => zc.setMode(.visual),
        .enter_normal_mode => {},
        .dismiss_count_or_status_message => {
            if (zc.count != 0) {
                zc.resetCount();
            } else {
                zc.dismissStatusMessage();
            }
        },

        .goto_next_sheet => zc.nextSheet(),
        .goto_prev_sheet => zc.prevSheet(),
        .close_sheet => try zc.closeSheet(zc.current_sheet),
        .undo => try zc.undo(),
        .redo => try zc.redo(),
        .yank_cell => {
            zc.yank = zc.anyCursorRange();
        },
        .put_cell => try zc.put(zc.anyCursorRange(), .no_adjust),
        .put_cell_adjust => try zc.put(zc.anyCursorRange(), .adjust),
        .page_down => {
            const n = zc.getCount() *| zc.ui.cellViewHeight();
            zc.setCursor(.init(zc.cursor.x, zc.cursor.y +| n));
            zc.resetCount();
        },
        .page_up => {
            const n = zc.getCount() *| zc.ui.cellViewHeight();
            zc.setCursor(.init(zc.cursor.x, zc.cursor.y -| n));
            zc.resetCount();
        },
        .half_page_down => {
            const n = zc.getCount() *| (zc.ui.cellViewHeight() / 2);
            zc.setCursor(.init(zc.cursor.x, zc.cursor.y +| n));
            zc.resetCount();
        },
        .half_page_up => {
            const n = zc.getCount() *| (zc.ui.cellViewHeight() / 2);
            zc.setCursor(.init(zc.cursor.x, zc.cursor.y -| n));
            zc.resetCount();
        },
        .cell_cursor_up => zc.cursorUp(),
        .cell_cursor_down => zc.cursorDown(),
        .cell_cursor_left => zc.cursorLeft(),
        .cell_cursor_right => zc.cursorRight(),
        .cell_cursor_row_first => zc.cursorToFirstCellInColumn(),
        .cell_cursor_row_last => zc.cursorToLastCellInColumn(),
        .cell_cursor_col_first => zc.cursorToFirstCellInRow(),
        .cell_cursor_col_last => zc.cursorToLastCellInRow(),
        .goto_col => zc.cursorGotoCol(),
        .goto_row => zc.cursorGotoRow(),
        .delete_column => {
            defer zc.resetCount();
            const count = zc.getCount() - 1;
            try zc.currentSheet().deleteColOrRowRange(zc.cursor.x, zc.cursor.x + count, .{}, .col);
            zc.currentSheet().endUndoGroup();
            zc.ui.update(&.{ .column_headings, .cells });
        },
        .delete_row => {
            defer zc.resetCount();
            const count = zc.getCount() - 1;
            try zc.currentSheet().deleteColOrRowRange(zc.cursor.y, zc.cursor.y + count, .{}, .row);
            zc.currentSheet().endUndoGroup();
            zc.ui.update(&.{ .row_numbers, .cells });
        },
        .insert_column => {
            defer zc.resetCount();
            zc.currentSheet().insertColumns(zc.cursor.x, zc.getCount(), .{}) catch |err| switch (err) {
                error.Overflow => zc.setStatusMessage(.err, "Columns would overflow", .{}),
                else => |e| return e,
            };
            zc.currentSheet().endUndoGroup();
            zc.ui.update(&.{ .column_headings, .cells });
        },
        .insert_row => {
            defer zc.resetCount();
            zc.currentSheet().insertRows(zc.cursor.y, zc.getCount(), .{}) catch |err| switch (err) {
                error.Overflow => zc.setStatusMessage(.err, "Rows would overflow", .{}),
                else => |e| return e,
            };
            zc.currentSheet().endUndoGroup();
            zc.ui.update(&.{ .row_numbers, .cells });
        },

        .delete_cell => zc.deleteCell() catch |err| switch (err) {
            error.OutOfMemory => zc.setStatusMessage(.err, "Out of memory!", .{}),
        },
        .next_populated_cell => zc.cursorNextPopulatedCell(),
        .prev_populated_cell => zc.cursorPrevPopulatedCell(),
        .increase_precision => try zc.cursorIncPrecision(),
        .decrease_precision => try zc.cursorDecPrecision(),
        .increase_width => try zc.cursorIncWidth(),
        .decrease_width => try zc.cursorDecWidth(),
        .assign_cell => {
            zc.setMode(.command_insert);
            var w = zc.commandWriter(&.{});
            w.interface.print("let {f} = ", .{zc.cursor}) catch return error.OutOfMemory;
        },

        .zero => {
            if (zc.count == 0) {
                zc.cursorToFirstCellInRow();
            } else {
                zc.setCount(0);
            }
        },
        .count => |count| zc.setCount(count),

        .text_align_left => try zc.setTextAlignment(zc.anyCursorRange(), .left),
        .text_align_right => try zc.setTextAlignment(zc.anyCursorRange(), .right),
        .text_align_center => try zc.setTextAlignment(zc.anyCursorRange(), .center),
        else => {},
    }
}

fn doVisualMode(zc: *ZC, action: Action) Allocator.Error!void {
    assert(zc.mode == .visual or zc.mode == .select);
    switch (action) {
        .enter_normal_mode => zc.setMode(.normal),
        .swap_anchor => {
            const temp = zc.anchor;
            zc.anchor = zc.cursor;
            zc.setCursor(temp);
        },

        .select_cancel => zc.setMode(.command_insert),
        .select_submit => {
            defer zc.setMode(.command_insert);
            var writer = zc.commandWriter(&.{});

            const tl = Position.topLeft(zc.cursor, zc.anchor);
            const br = Position.bottomRight(zc.cursor, zc.anchor);

            writer.interface.print("{f}:{f}", .{ tl, br }) catch return error.OutOfMemory;
        },

        .yank_cell => {
            zc.yank = zc.anyCursorRange();
            zc.setMode(.normal);
        },
        .put_cell => {
            try zc.put(zc.anyCursorRange(), .no_adjust);
            zc.setMode(.normal);
        },
        .put_cell_adjust => {
            try zc.put(zc.anyCursorRange(), .adjust);
            zc.setMode(.normal);
        },

        .cell_cursor_up => zc.cursorUp(),
        .cell_cursor_down => zc.cursorDown(),
        .cell_cursor_left => zc.cursorLeft(),
        .cell_cursor_right => zc.cursorRight(),
        .cell_cursor_row_first => zc.cursorToFirstCellInColumn(),
        .cell_cursor_row_last => zc.cursorToLastCellInColumn(),
        .cell_cursor_col_first => zc.cursorToFirstCellInRow(),
        .cell_cursor_col_last => zc.cursorToLastCellInRow(),
        .next_populated_cell => zc.cursorNextPopulatedCell(),
        .prev_populated_cell => zc.cursorPrevPopulatedCell(),

        .zero => zc.setCount(0),
        .count => |count| zc.setCount(count),

        .visual_move_up => zc.selectionUp(),
        .visual_move_down => zc.selectionDown(),
        .visual_move_left => zc.selectionLeft(),
        .visual_move_right => zc.selectionRight(),

        .text_align_left => try zc.setTextAlignment(zc.anyCursorRange(), .left),
        .text_align_right => try zc.setTextAlignment(zc.anyCursorRange(), .right),
        .text_align_center => try zc.setTextAlignment(zc.anyCursorRange(), .center),

        .delete_cell => {
            defer zc.setMode(.normal);
            try zc.deleteCellRange(zc.visualRange());
        },
        else => {},
    }
}

fn parseCommand(zc: *ZC, str: []const u8) !void {
    if (str.len == 0) return;

    // TODO: Unify command and assignment parsing and handling
    //       One issue is that AST nodes get appended to the underlying sheet's ast_nodes list,
    //       which is useless for anything other than assignments. I suppose we could append them
    //       no matter what and decrement ast_nodes.len if it's not an assignment?
    if (str[0] == ':')
        return zc.runCommand(str[1..]);

    const Tokenizer = @import("Tokenizer.zig");
    const Parser = @import("Parser.zig");
    var reader: std.io.Reader = .fixed(str);
    var tokens = try Tokenizer.collectTokens(zc.allocator, &reader, @intCast(str.len / 2));
    defer tokens.deinit(zc.allocator);

    if (tokens.items(.tag)[0] == .eof)
        return;

    const nodes = &zc.currentSheet().ast_nodes;
    var parser: Parser = .init(
        zc.allocator,
        str,
        tokens.items(.tag),
        tokens.items(.start),
        .{ .nodes = nodes.toMultiArrayList() },
    );

    {
        const old_len = nodes.len;

        // The parser could re-allocate the underlying nodes
        defer nodes.* = parser.nodes.slice();
        errdefer nodes.len = old_len;

        parser.parse() catch |err| switch (err) {
            error.UnexpectedToken,
            error.InvalidCellAddress,
            error.InvalidBuiltin,
            => {
                zc.setStatusMessage(.err, "{f}", .{parser.fmtError()});
                return;
            },
            else => |e| return e,
        };
    }

    const expr_root: ast.Index = .from(@intCast(nodes.len - 1));
    const pos = zc.currentSheet().ast_nodes.items(.data)[expr_root.n].assignment;

    zc.currentSheet().ast_nodes.len -= 1;
    const spliced_root: ast.Index = .from(expr_root.n - 1);

    try zc.setCell(pos, str, spliced_root, .{});
    zc.currentSheet().endUndoGroup();
}

fn interpretCommands(zc: *ZC, commands: []const u8) !void {
    var lines = std.mem.tokenizeScalar(u8, commands, '\n');
    while (lines.next()) |line| {
        try zc.parseCommand(line);
        try zc.updateCells();
    }
}

pub fn isSelectedCell(zc: *const ZC, pos: Position) bool {
    return switch (zc.mode) {
        .visual, .select => pos.intersects(zc.anchor, zc.cursor),
        else => zc.cursor.hash() == pos.hash(),
    };
}

pub fn isSelectedCol(zc: *const ZC, x: Position.Int) bool {
    return switch (zc.mode) {
        .visual, .select => {
            const min = @min(zc.cursor.x, zc.anchor.x);
            const max = @max(zc.cursor.x, zc.anchor.x);
            return x >= min and x <= max;
        },
        else => zc.cursor.x == x,
    };
}

pub fn isSelectedRow(zc: *const ZC, y: Position.Int) bool {
    return switch (zc.mode) {
        .visual, .select => {
            const min = @min(zc.cursor.y, zc.anchor.y);
            const max = @max(zc.cursor.y, zc.anchor.y);
            return y >= min and y <= max;
        },
        else => zc.cursor.y == y,
    };
}

pub fn nextPopulatedCell(zc: *ZC, start_pos: Position, count: u32) Position {
    var pos = start_pos;
    for (0..count) |_| {
        pos = zc.currentSheet().nextPopulatedCell(pos) orelse return pos;
    }
    return pos;
}

pub fn prevPopulatedCell(zc: *ZC, start_pos: Position, count: u32) Position {
    var pos = start_pos;
    for (0..count) |_| {
        pos = zc.currentSheet().prevPopulatedCell(pos) orelse return pos;
    }
    return pos;
}

pub fn cursorNextPopulatedCell(zc: *ZC) void {
    const new_pos = zc.nextPopulatedCell(zc.cursor, zc.getCount());
    zc.setCursor(new_pos);
    zc.resetCount();
}

pub fn cursorPrevPopulatedCell(zc: *ZC) void {
    const new_pos = zc.prevPopulatedCell(zc.cursor, zc.getCount());
    zc.setCursor(new_pos);
    zc.resetCount();
}

pub fn setCount(zc: *ZC, count: u4) void {
    assert(count <= 9);
    zc.count = zc.count *| 10 +| count;
}

pub fn getCount(zc: *const ZC) u32 {
    return if (zc.count == 0) 1 else zc.count;
}

pub fn getCountPos(zc: *const ZC) Position.Int {
    return @intCast(@min(std.math.maxInt(Position.Int), zc.getCount()));
}

pub fn resetCount(zc: *ZC) void {
    zc.count = 0;
}

const Cmd = enum {
    save,
    save_force,
    load,
    load_force,
    quit,
    quit_force,
    fill,
    fill_expr,
    binary_save,
    binary_load,
    binary_load_force,
    undo,
    redo,
    delete,
    delete_columns,
    delete_rows,
    insert_columns,
    insert_rows,
    set_text_align,
    set,
    unset,
    yank,
    put,
    put_adjust,
    close_sheet,
    close_sheet_force,
    rename_sheet,
    goto,
};

const cmds = std.StaticStringMap(Cmd).initComptime(.{
    .{ "w", .save },
    .{ "e", .load_force },
    .{ "q", .quit },
    .{ "q!", .quit_force },
    .{ "fill", .fill },
    .{ "fill-expr", .fill_expr },
    .{ "bw", .binary_save },
    .{ "be", .binary_load_force },
    .{ "undo", .undo },
    .{ "redo", .redo },
    .{ "delete", .delete },
    .{ "delete-cols", .delete_columns },
    .{ "delete-rows", .delete_rows },
    .{ "insert-cols", .insert_columns },
    .{ "insert-rows", .insert_rows },
    .{ "text-align", .set_text_align },
    .{ "set", .set },
    .{ "unset", .unset },
    .{ "yank", .yank },
    .{ "put", .put },
    .{ "p", .put },
    .{ "put-adjust", .put_adjust },
    .{ "pa", .put_adjust },
    .{ "sheet-close", .close_sheet },
    .{ "sheet-close!", .close_sheet_force },
    .{ "sc", .close_sheet },
    .{ "sc!", .close_sheet_force },
    .{ "sheet-rename", .rename_sheet },
    .{ "go", .goto },
});

const DebugCmd = enum {
    expect_eql_number,
    expect_eql_string,
    expect_non_extant,
    expect_error,
    expect_expr,
    update_cell,
};

const debug_cmds: std.StaticStringMap(DebugCmd) = .initComptime(.{
    .{ "expect-eql-string", .expect_eql_string },
    .{ "expect-eql-number", .expect_eql_number },
    .{ "expect-non-extant", .expect_non_extant },
    .{ "expect-error", .expect_error },
    .{ "update-cell", .update_cell },
    .{ "expect-expr", .expect_expr },
});

const RunCommandError = error{
    InvalidCommand,
    InvalidSyntax,
    InvalidCellAddress,
    EmptyFileName,
} || Allocator.Error;

const SetProperty = enum {
    theme,
    truecolor,
};

// TODO: This parses differently than ranges in assignments, due to using a WordIterator
fn parseRangeOrPoint(bytes: []const u8) !Rect {
    var range_iter = std.mem.splitScalar(u8, bytes, ':');
    const lhs = range_iter.next() orelse return error.InvalidSyntax;
    const rhs = range_iter.next() orelse
        return .initSinglePos(try Position.fromAddress(lhs));

    const p1 = Position.fromAddress(lhs) catch return error.InvalidCellAddress;
    const p2 = Position.fromAddress(rhs) catch return error.InvalidCellAddress;

    return .initPos(
        .topLeft(p1, p2),
        .bottomRight(p1, p2),
    );
}

fn runDebugCommand(zc: *ZC, cmd_str: []const u8, iter: *utils.WordIterator) !void {
    const cmd = debug_cmds.get(cmd_str) orelse return error.InvalidCommand;
    switch (cmd) {
        .expect_eql_number => {
            const arg1 = iter.next() orelse return error.InvalidSyntax;
            const arg2 = iter.next() orelse return error.InvalidSyntax;
            const n = try std.fmt.parseFloat(f64, arg2);
            try zc.currentSheet().expectCellEquals(arg1, n);
        },
        .expect_eql_string => {
            const arg1 = iter.next() orelse return error.InvalidSyntax;
            const arg2 = iter.next() orelse return error.InvalidSyntax;
            try zc.currentSheet().expectCellEqualsString(arg1, arg2);
        },
        .expect_non_extant => {
            const arg1 = iter.next() orelse return error.InvalidSyntax;
            if (std.mem.containsAtLeast(u8, arg1, 1, ":")) {
                // Argument is a range
                try zc.currentSheet().expectRangeNonExtant(arg1);
            } else {
                try zc.currentSheet().expectCellNonExtant(arg1);
            }
        },
        .expect_error => {
            const arg1 = iter.next() orelse return error.InvalidSyntax;
            try zc.currentSheet().expectCellError(arg1);
        },
        .update_cell => {
            const pos = zc.cursor;
            if (zc.currentSheet().getCellHandleByPosOrNull(pos)) |handle| {
                try zc.currentSheet().enqueueUpdate(handle);
                zc.ui.update(&.{.cells});
            }
        },
        .expect_expr => {
            const arg1 = iter.next() orelse return error.InvalidSyntax;
            const rest = iter.string[iter.index..];

            var aw: std.io.Writer.Allocating = .init(zc.allocator);
            defer aw.deinit();

            const pos = try Position.fromAddress(arg1);

            // try zc.currentSheet().printCellExpression(pos, &aw.writer);

            // Normalize the passed in expression
            const sheet = zc.currentSheet();
            const start = sheet.ast_nodes.len;
            const expr = try ast.parseFromExpression(sheet, rest);
            const cell = sheet.getCell(pos) orelse return error.CellNotFound;
            const cell_left = ast.leftMostChild(sheet.ast_nodes, cell.expr_root);
            errdefer std.debug.print("Expected '{f}', found '{f}'\n", .{
                ast.fmtAst(sheet.ast_nodes, expr, rest),
                sheet.fmtCellExpr(pos),
            });

            if (cell.expr_root.n - cell_left.n != expr.n - start)
                return error.TestExpectedEqualExpressions;

            for (start..expr.n + 1, cell_left.n..) |i, j| {
                const n1 = sheet.ast_nodes.get(i).get();
                const n2 = sheet.ast_nodes.get(j).get();
                if (!std.meta.eql(n1, n2))
                    return error.TestExpectedEqualExpressions;
            }
        },
    }
}

pub fn runCommand(zc: *ZC, str: []const u8) !void {
    var iter = utils.wordIterator(str);
    const cmd_str = iter.next() orelse return error.InvalidCommand;
    assert(cmd_str.len > 0);

    const cmd = cmds.get(cmd_str) orelse {
        if (@import("builtin").mode != .Debug) return error.InvalidCommand;

        return zc.runDebugCommand(cmd_str, &iter);
    };

    // TODO: Implement a better system for displaying usage information for commands, which is
    //       invoked whenver a malformed command is encountered.
    switch (cmd) {
        .goto => {
            const arg1 = iter.next() orelse {
                std.log.err("Not enough arguments (expected a cell or range)", .{});
                return;
            };
            const r = parseRangeOrPoint(arg1) catch {
                std.log.err("Invalid cell or range", .{});
                return;
            };
            if (r.area() == 1) {
                zc.setCursor(r.tl);
            } else {
                zc.setMode(.visual);
                zc.anchor = r.tl;
                zc.setCursor(r.br);
            }
        },
        .close_sheet => {
            if (zc.currentSheet().has_changes) {
                zc.setStatusMessage(.warn, "No write since last change (add ! to override)", .{});
            } else {
                try zc.closeSheet(zc.current_sheet);
            }
        },
        .close_sheet_force => try zc.closeSheet(zc.current_sheet),
        .rename_sheet => {
            const index, const new_name = blk: {
                const arg1 = iter.next() orelse return error.InvalidSyntax;
                const arg2 = iter.next() orelse break :blk .{ zc.current_sheet, arg1 };
                const index = zc.sheets.getIndex(arg1) orelse {
                    zc.setStatusMessage(.err, "Sheet '{s}' does not exist", .{arg1});
                    return;
                };
                break :blk .{ index, arg2 };
            };

            const old_name = zc.sheets.keys()[index];
            zc.setStatusMessage(.info, "Renamed '{s}' to '{s}'", .{ old_name, new_name });
            zc.renameSheet(index, new_name) catch |err| switch (err) {
                error.InvalidSheetName => {
                    zc.setStatusMessage(
                        .err,
                        "Invalid sheet name. sheet name cannot be empty",
                        .{},
                    );
                },
                error.SheetAlreadyExists => {
                    zc.setStatusMessage(
                        .err,
                        "Sheet '{s}' already exists",
                        .{new_name},
                    );
                },
                else => |e| return e,
            };
        },
        .yank => {
            const range = if (iter.next()) |arg|
                try parseRangeOrPoint(arg)
            else
                zc.anyCursorRange();

            zc.yank = range;
        },
        .put => {
            const range = if (iter.next()) |arg|
                try parseRangeOrPoint(arg)
            else
                zc.anyCursorRange();
            try zc.put(range, .no_adjust);
        },
        .put_adjust => {
            const range = if (iter.next()) |arg|
                try parseRangeOrPoint(arg)
            else
                zc.anyCursorRange();
            try zc.put(range, .adjust);
        },
        // Set a property back to its default value
        .unset => {
            const usage = "Usage: `:unset PROPERTY`";
            const arg1 = iter.next() orelse {
                zc.setStatusMessage(.err, "{s}", .{usage});
                return;
            };

            const property = std.meta.stringToEnum(SetProperty, arg1) orelse {
                zc.setStatusMessage(.err, "Invalid property '{s}'", .{arg1});
                return;
            };

            // TODO: Check if the property is actually set before unsetting it.
            switch (property) {
                .theme => {
                    zc.setDefaultTheme() catch |err| switch (err) {
                        error.Unsupported => {
                            zc.setStatusMessage(
                                .err,
                                "User interface '{s}' does not support themes",
                                .{zc.ui_interface.getUiName()},
                            );
                        },
                        error.Failed => {
                            zc.setStatusMessage(.err, "Could not restore default theme", .{});
                        },
                    };
                },
                .truecolor => {
                    zc.ui.term.truecolor_enabled = false;
                    zc.ui.update_flags = .all;
                },
            }
        },
        .set => {
            const usage = "Usage: `:set PROPERTY VALUE`";
            const arg1 = iter.next() orelse {
                zc.setStatusMessage(.err, "{s}", .{usage});
                return;
            };

            const property = std.meta.stringToEnum(SetProperty, arg1) orelse {
                zc.setStatusMessage(.err, "Invalid property '{s}': " ++ usage, .{arg1});
                return;
            };

            const arg2 = iter.next() orelse {
                switch (property) {
                    .truecolor => {
                        zc.ui.term.truecolor_enabled = true;
                        zc.ui.update_flags = .all;
                    },
                    else => {
                        zc.setStatusMessage(.err, "{s}", .{usage});
                    },
                }
                return;
            };

            switch (property) {
                .theme => {
                    zc.setTheme(arg2) catch {
                        zc.setStatusMessage(.err, "Couldn't set theme", .{});
                    };
                },
                .truecolor => {
                    if (std.ascii.eqlIgnoreCase(arg2, "true")) {
                        zc.ui.term.truecolor_enabled = true;
                    } else if (std.ascii.eqlIgnoreCase(arg2, "false")) {
                        zc.ui.term.truecolor_enabled = false;
                    } else return;

                    zc.ui.update_flags = .all;
                },
            }
        },
        .quit => {
            for (zc.sheets.values()) |*sheet| {
                if (sheet.has_changes) {
                    zc.setStatusMessage(.warn, "No write since last change (add ! to override)", .{});
                    break;
                }
            } else {
                zc.running = false;
            }
        },
        .quit_force => zc.running = false,
        .save, .save_force => {
            // TODO: Check if already exists
            zc.writeFile(iter.next()) catch |err| {
                zc.setStatusMessage(.warn, "Could not write file: {s}", .{@errorName(err)});
                return;
            };
            zc.currentSheet().has_changes = false;
            zc.ui.update(&.{.sheet_list});
        },
        .binary_save => {
            const filepath = iter.next() orelse {
                zc.setStatusMessage(.err, "Not enough arguments (expected a path)", .{});
                return;
            };

            const file = std.fs.cwd().createFile(filepath, .{}) catch |err| {
                zc.setStatusMessage(.warn, "Could not write binary file: {s}", .{
                    @errorName(err),
                });
                return;
            };
            defer file.close();

            try zc.currentSheet().serialize(file);
        },
        .binary_load => {
            if (zc.currentSheet().has_changes) {
                zc.setStatusMessage(.warn, "No write since last change (add ! to override)", .{});
            } else {
                try zc.loadCmdBinary(iter.next() orelse "");
            }
        },
        .binary_load_force => {
            const path = iter.next() orelse {
                zc.setStatusMessage(.err, "Not enough arguments (expected a path)", .{});
                return;
            };
            try zc.loadCmdBinary(path);
        },
        .load => {
            if (zc.currentSheet().has_changes) {
                zc.setStatusMessage(.warn, "No write since last change (add ! to override)", .{});
            } else {
                if (iter.next()) |path| {
                    try zc.loadCmd(path);
                } else {
                    const new_sheet = try zc.openSheet();
                    zc.setCurrentSheet(new_sheet);
                }
            }
        },
        .load_force => {
            if (iter.next()) |path| {
                try zc.loadCmd(path);
            } else {
                const new_sheet = try zc.openSheet();
                zc.setCurrentSheet(new_sheet);
            }
        },
        .fill => {
            const range = try parseRangeOrPoint(iter.next() orelse return error.InvalidSyntax);
            const arg1_start = iter.index;
            const arg1 = iter.next() orelse return error.InvalidSyntax;

            const arg2 = iter.next() orelse {
                // TODO: Clean this up on failure
                // No increment was provided, so all cells can share the same expression
                const expr = try ast.parseFromExpression(zc.currentSheet(), str[arg1_start..]);
                const node = zc.currentSheet().ast_nodes.get(expr.n);
                if (node.tag != .number) return error.InvalidSyntax;

                const n = node.data.number;
                try zc.currentSheet().bulkSetCellExpr(range, arg1, expr, .{
                    .value = .{ .number = n },
                    .tag = .number,
                });
                zc.currentSheet().queued_cells.items.len = 0;
                zc.currentSheet().endUndoGroup();
                zc.ui.update(&.{.cells});
                return;
            };

            const value = std.fmt.parseFloat(f64, arg1) catch return error.InvalidSyntax;
            const increment = std.fmt.parseFloat(f64, arg2) catch return error.InvalidSyntax;

            try zc.currentSheet().insertIncrementingCellRange(range, value, increment, .{});
            zc.currentSheet().endUndoGroup();
            zc.ui.update(&.{.cells});
        },
        .fill_expr => {
            const arg1 = iter.next() orelse {
                zc.setStatusMessage(.err, "Not enough arguments (expected a range or cell)", .{});
                return;
            };
            const expr_str = str[iter.index..];
            const range = try parseRangeOrPoint(arg1);

            const expr = ast.parseFromExpression(zc.currentSheet(), expr_str) catch |err| switch (err) {
                error.UnexpectedToken => {
                    zc.setStatusMessage(.err, "Invalid expression (unexpected token)", .{});
                    return;
                },
                else => |e| return e,
            };
            try zc.currentSheet().bulkSetCellExpr(range, expr_str, expr, .{});
            zc.currentSheet().endUndoGroup();
            zc.ui.update(&.{ .cursor, .cells });
        },
        inline .undo, .redo => |tag| {
            const count = blk: {
                const arg_string = iter.next() orelse break :blk 1;
                const count = std.fmt.parseInt(u32, arg_string, 0) catch |err| {
                    const err_msg = switch (err) {
                        error.Overflow => "Must be between 1 and 4294967295",
                        error.InvalidCharacter => "Expected integer",
                    };
                    zc.setStatusMessage(.err, "Invalid argument '{s}'. {s}", .{
                        arg_string,
                        err_msg,
                    });
                    return;
                };

                break :blk @max(count, 1);
            };

            for (0..count) |_| switch (tag) {
                .undo => try zc.undo(),
                .redo => try zc.redo(),
                else => comptime unreachable,
            };
        },
        .delete => {
            const range = if (iter.next()) |arg_string|
                try parseRangeOrPoint(arg_string)
            else
                zc.anyCursorRange();

            try zc.deleteCellRange(range);
        },
        .delete_columns => {
            const start, const end = blk: {
                const arg = iter.next() orelse {
                    const range = zc.anyCursorRange();
                    break :blk .{ range.tl.x, range.br.x };
                };

                var sep = std.mem.tokenizeScalar(u8, arg, ':');
                const first = sep.next().?;
                const first_col = try Position.columnFromAddress(first);
                if (sep.next()) |second| {
                    const second_col = try Position.columnFromAddress(second);
                    break :blk if (first_col <= second_col)
                        .{ first_col, second_col }
                    else
                        .{ second_col, first_col };
                }

                break :blk .{ first_col, first_col };
            };

            try zc.currentSheet().deleteColOrRowRange(start, end, .{}, .col);
            zc.currentSheet().endUndoGroup();
            zc.ui.update(&.{ .cells, .column_headings, .cursor });
        },
        .delete_rows => {
            const start, const end = blk: {
                const arg = iter.next() orelse {
                    const range = zc.anyCursorRange();
                    break :blk .{ range.tl.x, range.br.x };
                };

                var sep = std.mem.tokenizeScalar(u8, arg, ':');
                const first = sep.next().?;
                const first_row = try std.fmt.parseInt(u32, first, 0);
                if (sep.next()) |second| {
                    const second_row = try std.fmt.parseInt(u32, second, 0);
                    break :blk if (first_row <= second_row)
                        .{ first_row, second_row }
                    else
                        .{ second_row, first_row };
                }

                break :blk .{ first_row, first_row };
            };

            try zc.currentSheet().deleteColOrRowRange(start, end, .{}, .row);
            zc.currentSheet().endUndoGroup();
            zc.ui.update(&.{ .cells, .row_numbers, .cursor });
        },
        .insert_columns => {
            const column, const count = blk: {
                const arg1 = iter.next() orelse
                    break :blk .{ zc.cursor.x, 1 };

                const arg2 = iter.next() orelse {
                    // Only provided one argument, which is the number of cols to delete
                    const count = try std.fmt.parseInt(u32, arg1, 0);
                    break :blk .{ zc.cursor.x, count };
                };

                const column = try Position.columnFromAddress(arg1);
                const count = try std.fmt.parseInt(u32, arg2, 0);
                break :blk .{ column, count };
            };

            if (count > 0) {
                zc.currentSheet().insertColumns(column, count, .{}) catch |err| switch (err) {
                    error.Overflow => {
                        zc.setStatusMessage(.err, "Columns would overflow", .{});
                        return;
                    },
                    else => |e| return e,
                };
                zc.currentSheet().endUndoGroup();
                zc.ui.update(&.{ .cells, .column_headings, .cursor });
            }
        },
        .insert_rows => {
            const row, const count = blk: {
                const arg1 = iter.next() orelse
                    break :blk .{ zc.cursor.y, 1 };

                const arg2 = iter.next() orelse {
                    // Only provided one argument, which is the number of cols to delete
                    const count = try std.fmt.parseInt(u32, arg1, 0);
                    break :blk .{ zc.cursor.y, count };
                };

                const row = try std.fmt.parseInt(u32, arg1, 0);
                const count = try std.fmt.parseInt(u32, arg2, 0);
                break :blk .{ row, count };
            };

            if (count > 0) {
                zc.currentSheet().insertRows(row, count, .{}) catch |err| switch (err) {
                    error.Overflow => {
                        zc.setStatusMessage(.err, "Rows would overflow", .{});
                        return;
                    },
                    else => |e| return e,
                };
                zc.currentSheet().endUndoGroup();
                zc.ui.update(&.{ .cells, .row_numbers, .cursor });
            }
        },
        .set_text_align => {
            const usage = "Usage: text-align [cell address or range] left|right|center";
            const map = std.StaticStringMap(Sheet.TextAttrs.Alignment).initComptime(.{
                .{ "left", .left },
                .{ "right", .right },
                .{ "center", .center },
            });

            const arg1 = iter.next() orelse {
                zc.setStatusMessage(.err, usage, .{});
                return;
            };

            const rect, const value_str =
                if (iter.next()) |arg2|
                    .{ try parseRangeOrPoint(arg1), arg2 }
                else
                    .{ zc.anyCursorRange(), arg1 };

            const new_alignment = map.get(value_str) orelse {
                zc.setStatusMessage(.err, usage, .{});
                return;
            };
            try zc.setTextAlignment(rect, new_alignment);
        },
    }
}

fn resetArena(zc: *ZC) void {
    _ = zc.arena.reset(.{
        .retain_with_limit = comptime std.math.pow(usize, 2, 20),
    });
}

// TODO: Integrate with undos and serialization
fn setTextAlignment(zc: *ZC, r: Rect, alignment: Sheet.TextAttrs.Alignment) !void {
    var cells: std.ArrayList(Sheet.Cell.Handle) = .init(zc.arena.allocator());
    defer zc.resetArena();

    try zc.currentSheet().cell_tree.queryWindow(&.{ r.tl.x, r.tl.y }, &.{ r.br.x, r.br.y }, &cells);
    try zc.currentSheet().text_attrs.ensureUnusedCapacity(zc.currentSheet().allocator, cells.items.len);

    for (cells.items) |cell|
        zc.currentSheet().setTextAlignment(cell, alignment) catch unreachable;

    zc.ui.update(&.{.cells});
}

pub fn loadCmdBinary(zc: *ZC, filepath: []const u8) !void {
    assert(zc.sheets.entries.len > 0);
    if (filepath.len == 0) return error.EmptyFileName;

    const file = try std.fs.cwd().openFile(filepath, .{});
    defer file.close();

    const new_sheet = try zc.openSheet();
    errdefer comptime unreachable;

    const sheet = &zc.sheets.values()[new_sheet];
    sheet.deserialize(sheet.allocator, file) catch |err| {
        zc.setStatusMessage(.err, "Could not open file: {s}", .{@errorName(err)});
        zc.closeSheet(new_sheet) catch unreachable;
        return;
    };

    zc.setCurrentSheet(new_sheet);
}

pub fn loadCmd(zc: *ZC, filepath: []const u8) !void {
    assert(zc.sheets.entries.len > 0);
    if (filepath.len == 0) return error.EmptyFileName;

    const new_sheet = try zc.openSheet();
    errdefer comptime unreachable;

    zc.loadFile(new_sheet, filepath) catch |err| {
        zc.setStatusMessage(.err, "Could not open file: {s}", .{@errorName(err)});
        zc.closeSheet(new_sheet) catch unreachable;
        return;
    };

    zc.setCurrentSheet(new_sheet);
}

fn writeFile(zc: *ZC, filepath: ?[]const u8) !void {
    try zc.currentSheet().writeFile(.{ .filepath = filepath });
}

fn loadFile(zc: *ZC, sheet_index: usize, filepath: []const u8) !void {
    const sheet = zc.getSheet(sheet_index);
    try sheet.loadFile(filepath);
    sheet.endUndoGroup();
    zc.emitEvent("UpdateFilePath", .{
        zc.getSheetName(sheet_index),
        filepath,
    });
}

fn setCurrentSheet(zc: *ZC, index: usize) void {
    zc.current_sheet = index;
    zc.ui.update_flags = .all;
}

fn prevSheet(zc: *ZC) void {
    const new_sheet = if (zc.current_sheet == 0)
        zc.sheets.entries.len - 1
    else
        zc.current_sheet - 1;
    zc.setCurrentSheet(new_sheet);
}

fn nextSheet(zc: *ZC) void {
    const new_sheet = (zc.current_sheet + 1) % zc.sheets.entries.len;
    zc.setCurrentSheet(new_sheet);
}

fn openSheet(zc: *ZC) !usize {
    // TODO: Could we use an adapter for the default sheet names to avoid allocating memory?
    try zc.sheets.ensureUnusedCapacity(zc.allocator, 1);
    const new_sheet_name = try std.fmt.allocPrint(zc.allocator, "Sheet{d}", .{
        zc.max_sheet_n,
    });
    errdefer zc.allocator.free(new_sheet_name);

    const new_sheet: Sheet = try .init(zc.allocator);
    errdefer comptime unreachable;

    zc.max_sheet_n += 1;
    zc.sheets.putAssumeCapacityNoClobber(new_sheet_name, new_sheet);
    zc.ui.update(&.{.sheet_list});

    return zc.sheets.entries.len - 1;
}

fn closeSheet(zc: *ZC, index: usize) !void {
    var sheet = zc.sheets.values()[index];
    const name = zc.sheets.keys()[index];
    defer zc.allocator.free(name);
    zc.sheets.orderedRemoveAt(index);
    sheet.deinit();
    if (zc.sheets.entries.len == 0) {
        const new_sheet = try zc.openSheet();
        zc.setCurrentSheet(new_sheet);
    } else if (zc.current_sheet == index) {
        zc.prevSheet();
    }

    zc.setStatusMessage(.info, "Closed '{s}'", .{name});
}

fn renameSheet(zc: *ZC, index: usize, new_name: []const u8) !void {
    if (new_name.len == 0) return error.InvalidSheetName;
    if (zc.sheets.get(new_name) != null) {
        return error.SheetAlreadyExists;
    }

    const new_name_owned = try zc.allocator.dupe(u8, new_name);
    const old_key = zc.sheets.keys()[index];

    zc.sheets.setKey(zc.allocator, index, new_name_owned) catch |err| {
        zc.allocator.free(new_name_owned);
        zc.sheets.keys()[index] = old_key;
        return err;
    };

    zc.allocator.free(old_key);
    zc.ui.update_flags.sheet_list = true;
}

fn setDefaultTheme(zc: *ZC) !void {
    try zc.ui_interface.applyDefaultTheme();
}

fn setTheme(
    zc: *ZC,
    /// Base name of the theme file to set.
    theme_name: []const u8,
) !void {
    const ui_name = zc.ui_interface.getUiName();
    const extension = zc.ui_interface.getThemeFileExtension();

    var name_buf: std.BoundedArray(u8, std.fs.max_name_bytes) = .{};
    name_buf.writer().print("{s}{s}", .{ theme_name, extension }) catch
        return error.NameTooLong;

    const file_name = name_buf.constSlice();

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const path = std.fs.path.joinZ(fba.allocator(), &.{
        "/home/evan/.config/cellulator",
        "themes",
        ui_name,
        file_name,
    }) catch return error.NameTooLong;

    try zc.ui_interface.applyTheme(path);
}

fn put(zc: *ZC, dest: Rect, comptime adjust: Sheet.Adjust) !void {
    if (zc.yank) |yank| {
        if (!yank.eql(dest)) {
            try zc.currentSheet().copyRangeTo(yank, dest, adjust);
            zc.currentSheet().endUndoGroup();
            zc.ui.update(&.{.cells});
        }
    }
}

fn undo(zc: *ZC) Allocator.Error!void {
    defer zc.resetCount();
    zc.ui.update(&.{ .cells, .column_headings, .row_numbers });

    for (0..zc.getCount()) |_| {
        try zc.currentSheet().undo();
    }
}

fn redo(zc: *ZC) Allocator.Error!void {
    defer zc.resetCount();
    zc.ui.update(&.{ .cells, .column_headings, .row_numbers });

    for (0..zc.getCount()) |_| {
        try zc.currentSheet().redo();
    }
}

fn anyCursorRange(zc: *const ZC) Rect {
    if (zc.mode == .visual or zc.mode == .select)
        return zc.visualRange();
    return .initSinglePos(zc.cursor);
}

fn visualRange(zc: *const ZC) Rect {
    assert(zc.mode == .visual or zc.mode == .select);
    return Rect.initNormalizePos(zc.cursor, zc.anchor);
}

pub fn deleteCell(zc: *ZC) Allocator.Error!void {
    assert(zc.mode != .visual);
    try zc.currentSheet().deleteCell(zc.cursor, .{});
    zc.currentSheet().endUndoGroup();

    zc.ui.update(&.{ .cells, .cursor });
}

pub fn deleteCellRange(zc: *ZC, rect: Rect) Allocator.Error!void {
    try zc.currentSheet().deleteCellRange(rect, .{});
    zc.currentSheet().endUndoGroup();

    zc.ui.update(&.{ .cells, .cursor });
}

pub fn setCursor(zc: *ZC, new_pos: Position) void {
    zc.prev_cursor = zc.cursor;
    zc.cursor = new_pos;
    zc.clampScreenToCursor();

    if (zc.mode.isVisual()) zc.ui.update(&.{ .cells, .column_headings, .row_numbers });
    zc.ui.update(&.{.cursor});
}

pub fn cursorUp(zc: *ZC) void {
    zc.setCursor(.{ .y = zc.cursor.y -| zc.getCountPos(), .x = zc.cursor.x });
    zc.resetCount();
}

pub fn cursorDown(zc: *ZC) void {
    zc.setCursor(.{ .y = zc.cursor.y +| zc.getCountPos(), .x = zc.cursor.x });
    zc.resetCount();
}

pub fn cursorLeft(zc: *ZC) void {
    zc.setCursor(.{ .y = zc.cursor.y, .x = zc.cursor.x -| zc.getCountPos() });
    zc.resetCount();
}

pub fn cursorRight(zc: *ZC) void {
    zc.setCursor(.{ .y = zc.cursor.y, .x = zc.cursor.x +| zc.getCountPos() });
    zc.resetCount();
}

pub fn selectionUp(zc: *ZC) void {
    assert(zc.mode == .visual or zc.mode == .select);
    const count = zc.getCountPos();
    if (zc.anchor.y < zc.cursor.y) {
        const len = zc.cursor.y - zc.anchor.y;
        zc.setCursor(.{ .y = @max(zc.cursor.y -| count, len), .x = zc.cursor.x });
        zc.anchor.y -|= count;
    } else {
        const len = zc.anchor.y - zc.cursor.y;
        zc.anchor.y = @max(zc.anchor.y -| count, len);
        zc.setCursor(.{ .y = zc.cursor.y -| count, .x = zc.cursor.x });
    }
    zc.resetCount();
}

pub fn selectionDown(zc: *ZC) void {
    assert(zc.mode == .visual or zc.mode == .select);
    const count = zc.getCountPos();

    if (zc.anchor.y < zc.cursor.y) {
        const len = zc.cursor.y - zc.anchor.y;
        zc.setCursor(.{ .y = zc.cursor.y +| count, .x = zc.cursor.x });
        zc.anchor.y = @min(zc.anchor.y +| count, std.math.maxInt(Position.Int) - len);
    } else {
        const len = zc.anchor.y - zc.cursor.y;
        zc.setCursor(.{
            .y = @min(zc.cursor.y +| count, std.math.maxInt(Position.Int) - len),
            .x = zc.cursor.x,
        });
        zc.anchor.y +|= count;
    }
    zc.resetCount();
}

pub fn selectionLeft(zc: *ZC) void {
    assert(zc.mode == .visual or zc.mode == .select);
    const count = zc.getCountPos();
    if (zc.anchor.x < zc.cursor.x) {
        const len = zc.cursor.x - zc.anchor.x;
        zc.setCursor(.{ .x = @max(zc.cursor.x -| count, len), .y = zc.cursor.y });
        zc.anchor.x -|= count;
    } else {
        const len = zc.anchor.x - zc.cursor.x;
        zc.anchor.x = @max(zc.anchor.x -| count, len);
        zc.setCursor(.{ .x = zc.cursor.x -| count, .y = zc.cursor.y });
    }
    zc.resetCount();
}

pub fn selectionRight(zc: *ZC) void {
    assert(zc.mode == .visual or zc.mode == .select);
    const count = zc.getCountPos();

    if (zc.anchor.x < zc.cursor.x) {
        const len = zc.cursor.x - zc.anchor.x;
        zc.setCursor(.{ .x = zc.cursor.x +| count, .y = zc.cursor.y });
        zc.anchor.x = @min(zc.anchor.x +| count, std.math.maxInt(Position.Int) - len);
    } else {
        const len = zc.anchor.x - zc.cursor.x;
        zc.setCursor(.{
            .x = @min(zc.cursor.x +| count, std.math.maxInt(Position.Int) - len),
            .y = zc.cursor.y,
        });
        zc.anchor.x +|= count;
    }
    zc.resetCount();
}

// FIXME: The Y value is incorrect when clamping screen to cursor?
pub fn leftReservedColumns(zc: *const ZC) u16 {
    const y = zc.screen_pos.y +| zc.ui.cellViewHeight() -| 1;

    if (y == 0)
        return 2;

    return @intCast(std.math.log10(y) + 2);
}

pub fn clampScreenToCursor(zc: *ZC) void {
    zc.clampScreenToCursorY();
    zc.clampScreenToCursorX();
}

pub fn clampScreenToCursorY(zc: *ZC) void {
    const height = zc.ui.cellViewHeight();
    if (height == 0) return;

    if (zc.cursor.y < zc.screen_pos.y) {
        zc.screen_pos.y = zc.cursor.y;
    } else if (zc.cursor.y - zc.screen_pos.y >= height) {
        zc.screen_pos.y = zc.cursor.y - (height - 1);
    } else {
        return;
    }
    zc.ui.update(&.{ .column_headings, .row_numbers, .cells });
}

pub fn clampScreenToCursorX(zc: *ZC) void {
    if (zc.cursor.x < zc.screen_pos.x) {
        zc.screen_pos.x = zc.cursor.x;
        zc.ui.update(&.{ .column_headings, .cells });
        return;
    }

    var w = zc.leftReservedColumns();
    var x = zc.cursor.x;

    const view_width = zc.ui.term.width -| zc.leftReservedColumns();
    while (x >= zc.screen_pos.x) : (x -= 1) {
        const col: Sheet.Column = zc.currentSheet().getColumn(x) orelse .{};
        w += @min(view_width, col.width);

        if (w > zc.ui.term.width) {
            if (x < zc.cursor.x) {
                zc.screen_pos.x = x +| 1;
                zc.ui.update(&.{ .column_headings, .cells });
            }
            break;
        }
        if (x == 0) break;
    }
}
pub fn setPrecision(zc: *ZC, column: Position.Int, new_precision: u8) Allocator.Error!void {
    try zc.currentSheet().setPrecision(column, new_precision, .{});
    zc.currentSheet().endUndoGroup();
    zc.ui.update_flags.cells = true;
}

pub fn incPrecision(zc: *ZC, column: Position.Int, count: u8) Allocator.Error!void {
    try zc.currentSheet().incPrecision(column, count, .{});
    zc.currentSheet().endUndoGroup();
    zc.ui.update_flags.cells = true;
}

pub fn decPrecision(zc: *ZC, column: Position.Int, count: u8) Allocator.Error!void {
    try zc.currentSheet().decPrecision(column, count, .{});
    zc.currentSheet().endUndoGroup();
    zc.ui.update_flags.cells = true;
}

pub inline fn cursorIncPrecision(zc: *ZC) Allocator.Error!void {
    const count: u8 = @intCast(@min(std.math.maxInt(u8), zc.getCount()));
    try zc.incPrecision(zc.cursor.x, count);
    zc.resetCount();
}

pub inline fn cursorDecPrecision(zc: *ZC) Allocator.Error!void {
    const count: u8 = @intCast(@min(std.math.maxInt(u8), zc.getCount()));
    try zc.decPrecision(zc.cursor.x, count);
    zc.resetCount();
}

pub fn incWidth(zc: *ZC, column: Position.Int, n: u8) Allocator.Error!void {
    try zc.currentSheet().incWidth(column, n, .{});
    zc.currentSheet().endUndoGroup();
    zc.ui.update_flags.cells = true;
    zc.ui.update_flags.column_headings = true;
}

pub fn decWidth(zc: *ZC, column: Position.Int, n: u8) Allocator.Error!void {
    try zc.currentSheet().decWidth(column, n, .{});
    zc.currentSheet().endUndoGroup();
    zc.ui.update_flags.cells = true;
    zc.ui.update_flags.column_headings = true;
}

pub inline fn cursorIncWidth(zc: *ZC) Allocator.Error!void {
    const count: u8 = @intCast(@min(std.math.maxInt(u8), zc.getCount()));
    try zc.incWidth(zc.cursor.x, count);
    zc.resetCount();
    zc.clampScreenToCursorX();
}

pub inline fn cursorDecWidth(zc: *ZC) Allocator.Error!void {
    const count: u8 = @intCast(@min(std.math.maxInt(u8), zc.getCount()));
    try zc.decWidth(zc.cursor.x, count);
    zc.resetCount();
}

fn widthNeededForColumn(
    zc: *ZC,
    sheet: *Sheet,
    column_index: Position.Int,
    precision: u8,
    max_width: u16,
) !u16 {
    var width: u16 = Sheet.Column.default_width;

    var results: std.ArrayList(Sheet.Cell.Handle) = .init(sheet.allocator);
    defer results.deinit();

    try sheet.cell_tree.queryWindow(
        &.{ column_index, 0 },
        &.{ column_index, std.math.maxInt(u32) },
        &results,
    );

    var buf: std.BoundedArray(u8, 512) = .{};
    const writer = buf.writer();
    for (results.items) |handle| {
        const cell = sheet.getCellFromHandle(handle);
        switch (cell.value_tag) {
            .err => {},
            .number => {
                const n = cell.value.number;
                buf.len = 0;
                writer.print("{d:.[1]}", .{ n, precision }) catch unreachable;
                // Numbers are all ASCII, so 1 byte = 1 column
                const len: u16 = @intCast(buf.len);
                if (len > width) {
                    width = len;
                    if (width >= max_width) return width;
                }
            },
            .string => {
                const str = sheet.cellStringValue(cell);
                const w: u16 = @intCast(zc.ui_interface.stringWidth(str, .{
                    .max_width = zc.ui.term.width,
                }).width); // TODO: Make all widths u32
                if (w > width) {
                    width = w;
                    if (width >= max_width) return width;
                }
            },
        }
    }

    return width;
}

pub fn expandWidthAtCursor(zc: *ZC) Allocator.Error!void {
    const handle = zc.currentSheet().getColumnHandle(zc.cursor.x) orelse return;
    const col = zc.currentSheet().cols.getValue(handle);

    const max_width = zc.ui.term.width - zc.leftReservedColumns();
    const width_needed = try zc.widthNeededForColumn(
        zc.currentSheet(),
        zc.cursor.x,
        col.precision,
        max_width,
    );
    try zc.currentSheet().setColWidth(handle, zc.cursor.x, width_needed, .{});
    zc.currentSheet().endUndoGroup();
    zc.clampScreenToCursorX();
    zc.ui.update(&.{ .cells, .column_headings });
}

pub fn cursorToFirstCellInRow(zc: *ZC) void {
    const pos = zc.currentSheet().firstCellInRow(zc.cursor.y) orelse return;
    zc.setCursor(pos);
}

pub fn cursorToLastCellInRow(zc: *ZC) void {
    const pos = zc.currentSheet().lastCellInRow(zc.cursor.y) orelse return;
    zc.setCursor(pos);
}

pub fn cursorToFirstCellInColumn(zc: *ZC) void {
    const pos = zc.currentSheet().firstCellInColumn(zc.cursor.x) orelse return;
    zc.setCursor(pos);
}

pub fn cursorToLastCellInColumn(zc: *ZC) void {
    const pos = zc.currentSheet().lastCellInColumn(zc.cursor.x) orelse return;
    zc.setCursor(pos);
}

pub fn cursorGotoRow(zc: *ZC) void {
    const count: Position.Int = @intCast(@min(std.math.maxInt(Position.Int), zc.count));
    zc.resetCount();
    zc.setCursor(.{ .x = zc.cursor.x, .y = count });
}

pub fn cursorGotoCol(zc: *ZC) void {
    const count: Position.Int = @intCast(@min(std.math.maxInt(Position.Int), zc.count));
    zc.resetCount();
    zc.setCursor(.{ .x = count, .y = zc.cursor.y });
}

test "Sheet mode counts" {
    const t = std.testing;
    var zc: ZC = undefined;
    try zc.init(t.allocator, .{ .ui = false });
    defer zc.deinit();

    try t.expectEqual(Mode.normal, zc.mode);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
}

test "Motions normal mode" {
    const t = std.testing;
    const max = std.math.maxInt(Position.Int);

    var zc: ZC = undefined;
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
    const max = std.math.maxInt(Position.Int);

    var zc: ZC = undefined;
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
    for (0..20) |_| {
        try zc.doVisualMode(.{ .count = 9 });
    }
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
    for (0..20) |_| try zc.doVisualMode(.{ .count = 9 });
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
    for (0..20) |_| try zc.doVisualMode(.{ .count = 9 });
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
    for (0..20) |_| try zc.doVisualMode(.{ .count = 9 });
    try zc.doVisualMode(.visual_move_down);
    try t.expectEqual(Position{ .y = max - 10, .x = 0 }, zc.cursor);
    try t.expectEqual(Position{ .y = max, .x = 10 }, zc.anchor);
    try zc.doVisualMode(.visual_move_down);
    try t.expectEqual(Position{ .y = max - 10, .x = 0 }, zc.cursor);
    try t.expectEqual(Position{ .y = max, .x = 10 }, zc.anchor);
}

// Test files at runtime so no recompilation is needed if the data changes
fn testFile(gpa: std.mem.Allocator, path: []const u8) !void {
    var zc: ZC = undefined;
    try zc.init(gpa, .{ .ui = false });
    defer zc.deinit();

    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    const bytes = try file.readToEndAlloc(gpa, 100_000_000);
    defer gpa.free(bytes);

    const content = try std.mem.replaceOwned(u8, gpa, bytes, "$BUILD_TEMP_DIR", build.temp_dir);
    defer gpa.free(content);

    var has_errors = false;
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |line| {
        zc.parseCommand(line) catch |err| {
            var line_number: usize = 1;
            for (content[0..lines.index]) |c| {
                if (c == '\n') line_number += 1;
            }
            std.debug.print("Error {} at {s}:{d}\n", .{ err, path, line_number });
            has_errors = true;
        };
        try zc.updateCells();
    }
    if (has_errors) return error.Failed;
}

test "Sheet operations" {
    for (build.test_files) |path| {
        try testFile(std.testing.allocator, path);
    }
}
