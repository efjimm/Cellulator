const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const build = @import("build");
const Lua = @import("zlua").Lua;
const wcWidth = @import("wcwidth").wcWidth;

const Ast = @import("Ast.zig");
const CommandLine = @import("Command.zig");
const input = @import("input.zig");
const Action = input.Action;
const CommandAction = input.CommandAction;
const KeyMap = input.KeyMap;
const MapType = input.MapType;
const CommandMapType = input.CommandMapType;
const lua = @import("lua.zig");
const Parser = @import("Parser.zig");
const Position = @import("Position.zig").Position;
const Rect = Position.Rect;
const Sheet = @import("Sheet.zig");
const text = @import("text.zig");
const Motion = text.Motion;
const Tui = @import("Tui.zig");
const utils = @import("utils.zig");
const Ui = @import("Ui.zig");

const Oom = Allocator.Error;

const log = std.log.scoped(.zc);

const ZC = @This();

lua_ptr: *Lua,

running: bool = true,

current_sheet: usize,
max_sheet_n: usize = 1,
sheets: std.StringArrayHashMapUnmanaged(Sheet),

ui: Ui,

prev_mode: Mode = .normal,
mode: Mode = .normal,

anchor: Position = .origin,

prev_cursor: Position = .origin,

/// The cell position of the cursor
cursor: Position = .origin,

count: u32 = 0,

command: CommandLine = .{},

keymaps: input.KeyMaps,

allocator: Allocator,
io: std.Io,
env: std.process.Environ,

input_buf: std.Io.Writer.Allocating,

/// Used as scratch space
arena: std.heap.ArenaAllocator,

yank: ?Rect = null,

had_prefix: bool = false,

selected_completion: ?usize = null,

completions_buffer: std.ArrayListUnmanaged(u8) = .empty,
completion_strings: std.ArrayListUnmanaged(CompletionString) = .empty,

dir_entries: std.ArrayListUnmanaged(DirEntry) = .empty,
last_dirname: []const u8 = "",
recalc_dir_entries_width: bool = true,

status: Status = .{},

const CompletionString = struct {
    offset: usize,
    len: usize,
};

pub const Status = struct {
    /// General status message, used by all tags.
    msg: std.ArrayListUnmanaged(u8) = .empty,

    /// When a command was used incorrectly, stores the command that was used.
    /// This is used for showing where in the command the error was.
    cmd: std.ArrayListUnmanaged(u8) = .empty,

    /// Usage string for a command.
    usage: std.ArrayListUnmanaged(u8) = .empty,

    /// Description for a command. These are all string literals and as such we just store a slice
    /// instead of a list.
    cmd_description: []const u8 = "",

    /// The byte-index
    err_offset: usize = 0,

    /// The number of bytes starting from `err_offset` to underline.
    err_size: usize = 0,

    /// The kind of status message to display.
    tag: Tag = .none,

    /// Determines how the status is displayed
    pub const Tag = enum {
        /// There is no status message right now.
        none,
        info,
        warn,
        err,
        cmd_info,
        cmd_err,
    };

    pub fn deinit(s: *Status, gpa: std.mem.Allocator) void {
        s.msg.deinit(gpa);
        s.cmd.deinit(gpa);
        s.usage.deinit(gpa);
        s.* = undefined;
    }
};

pub const DirEntry = struct {
    offset: usize,
    len: usize,
};

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

    pub fn format(mode: Mode, writer: *std.Io.Writer) !void {
        try writer.writeAll(@tagName(mode));
    }
};

pub const InitOptions = struct {
    filepaths: []const []const u8 = &.{},
};

/// Initialises via a pointer rather than returning an instance, as we need a
/// stable pointer to a ZC instance.
pub fn init(
    zc: *ZC,
    ui: Ui,
    allocator: Allocator,
    io: std.Io,
    env: std.process.Environ,
    options: InitOptions,
) !void {
    errdefer zc.* = undefined;

    zc.allocator = allocator;

    var keys = try input.createKeymaps(allocator);
    errdefer keys.deinit(allocator);

    var lua_state = try lua.init(zc);
    errdefer lua_state.deinit();

    zc.* = .{
        .current_sheet = 0,
        .sheets = .empty,
        .lua_ptr = lua_state,
        .ui = ui,
        .allocator = allocator,
        .io = io,
        .env = env,
        .keymaps = keys,
        .arena = .init(allocator),
        .input_buf = try .initCapacity(allocator, 1),
    };
    zc.clearInput();
    errdefer zc.sheets.deinit(allocator);
    errdefer for (zc.sheets.values()) |*sheet| sheet.deinit();
    const sheet = try zc.openSheet();
    zc.setCurrentSheet(sheet);

    zc.sourceLua() catch |err| log.err("Could not source init.lua: {}", .{err});

    zc.emitEvent("Init", .{});

    if (options.filepaths.len > 0) {
        // try zc.loadFile(zc.current_sheet, options.filepaths[0]);
        for (options.filepaths) |filepath|
            try Command.cmdLoad(zc, .{ .bytes = filepath });
    }

    log.debug("Finished init", .{});
    zc.emitEvent("Start", .{});
}

pub fn sourceLua(zc: *ZC) !void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const allocator = fba.allocator();

    const paths: []const []const u8 = if (zc.env.getPosix("XDG_CONFIG_HOME")) |path|
        &.{ path, "cellulator/init.lua" }
    else if (zc.env.getPosix("HOME")) |path|
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
    // Don't need to free memory on exit, the OS will do it for us :^)
    if (!std.debug.runtime_safety) return;

    zc.status.deinit(zc.allocator);
    zc.lua_ptr.deinit();
    zc.command.deinit(zc.allocator);

    zc.dir_entries.deinit(zc.allocator);
    zc.completions_buffer.deinit(zc.allocator);
    zc.completion_strings.deinit(zc.allocator);

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

pub const QueryType = enum {
    path,
    command,
};

pub fn completionQuery(zc: *ZC) ?struct { type: QueryType, offset: usize, len: usize } {
    if (!zc.mode.isCommandMode()) return null;

    var iter = utils.wordIterator(zc.command.left());
    const in = iter.next() orelse return null;
    if (in.len == 0 or in[0] != ':') return null;

    const map: std.StaticStringMap(void) = .initComptime(.{
        .{":e"},
        .{":w"},
        .{":be"},
        .{":bw"},
    });

    const query_type: QueryType = blk: {
        const first_arg_size = (in.ptr - zc.command.left().ptr) + in.len;
        if (zc.command.cursor <= first_arg_size)
            break :blk .command;

        if (map.has(in))
            break :blk .path;
        return null;
    };

    sw: switch (query_type) {
        .path => {
            const arg = iter.next() orelse blk: {
                const offset = (in.ptr - iter.string.ptr) + in.len;
                if (zc.command.cursor <= offset)
                    continue :sw .command;

                break :blk in[in.len..];
            };

            return .{
                .type = .path,
                .offset = arg.ptr - in.ptr,
                .len = arg.len,
            };
        },
        .command => {
            const arg = in[1..];
            return .{
                .type = .command,
                .offset = arg.ptr - in.ptr,
                .len = arg.len,
            };
        },
    }
}

pub fn inputSentinelSlice(zc: *ZC) Oom![:0]u8 {
    zc.input_buf.writer.writeByte(0) catch return error.OutOfMemory;
    const buffered = zc.input_buf.written();
    const ret = buffered[0 .. buffered.len - 1 :0];
    zc.input_buf.writer.end -= 1;
    return ret;
}

pub fn inputSlice(zc: *const ZC) [:0]u8 {
    return zc.input_buf.writer.buffer[0..zc.input_buf.writer.end :0];
}

fn clearInput(zc: *ZC) void {
    zc.input_buf.clearRetainingCapacity();
    zc.input_buf.writer.writeByte(0) catch unreachable;
    zc.input_buf.writer.end = 0;
}

pub fn run(zc: *ZC) u8 {
    return zc.ui.run(zc);
}

pub const ChangeCellOpts = struct {
    emit_event: bool = true,
    undo_opts: Sheet.UndoOpts = .{},
};

/// Sets the cell at `pos` to the expression represented by `ast`.
pub fn setCell(
    zc: *ZC,
    pos: Position,
    expr: Parser.Result,
    src: []const u8,
    opts: ChangeCellOpts,
) !void {
    try zc.currentSheet().setCell(pos, expr, .{});
    if (opts.emit_event) {
        const expr_string =
            for (src, 0..) |c, i| {
                if (c == '=') break std.mem.trimStart(
                    u8,
                    src[i + 1 ..],
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

pub fn setCellString(
    zc: *ZC,
    pos: Position,
    src: []const u8,
    diag: ?*Parser.Diagnostics,
    opts: ChangeCellOpts,
) !void {
    const sheet = zc.currentSheet();
    const old_state = sheet.ast.save();
    errdefer sheet.ast.restore(old_state);

    const expr = try sheet.parseFromExpressionDiag(src, diag);
    if (expr.destination != null) {
        return error.UnexpectedToken;
    }

    try zc.setCell(pos, expr, src, opts);
}

pub const StatusMessageType = enum { info, warn, err };

pub fn setStatusMessage(
    zc: *ZC,
    t: StatusMessageType,
    comptime fmt: []const u8,
    args: anytype,
) void {
    zc.dismissStatusMessage();
    zc.status.tag = switch (t) {
        .info => .info,
        .warn => .warn,
        .err => .err,
    };
    zc.status.msg.print(zc.allocator, fmt, args) catch {}; // TODO: Maybe handle this
}

pub fn dismissStatusMessage(zc: *ZC) void {
    zc.status.tag = .none;
    zc.status.msg.clearRetainingCapacity();
    zc.status.cmd.clearRetainingCapacity();
    zc.status.usage.clearRetainingCapacity();
    zc.status.cmd_description = "";
}

pub fn updateCells(zc: *ZC) Oom!void {
    return zc.currentSheet().update();
}

pub fn setMode(zc: *ZC, new_mode: Mode) void {
    zc.prev_mode = zc.mode;
    zc.anchor = zc.cursor;
    zc.mode = new_mode;
    zc.resetCount();
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

pub fn doInput(zc: *ZC) !void {
    const bytes = try zc.inputSentinelSlice();

    switch (zc.mode) {
        inline else => |mode| {
            const map = zc.getKeymap(mode);
            const res = map.get(bytes);
            switch (res) {
                .kv => |kv| {
                    const action = kv.value;
                    _ = switch (mode) {
                        .normal => zc.doNormalMode(action) catch |err| switch (err) {
                            else => std.log.err("Error: {s}", .{@errorName(err)}),
                        },
                        .visual, .select => zc.doVisualMode(action) catch |err| switch (err) {
                            else => std.log.err("Error: {s}", .{@errorName(err)}),
                        },
                        .command_normal,
                        .command_insert,
                        .command_change,
                        .command_delete,
                        .command_to_forwards,
                        .command_to_backwards,
                        .command_until_forwards,
                        .command_until_backwards,
                        => zc.doCommandMode(action, bytes) catch |err| switch (err) {
                            error.InvalidCommand => zc.setStatusMessage(.err, "Invalid command", .{}),
                            error.InvalidSyntax => zc.setStatusMessage(.err, "Invalid syntax", .{}),
                            else => zc.setStatusMessage(.err, "{t}", .{err}),
                        },
                    };

                    zc.clearInput();
                },
                .prefix => {},
                .not_found => {
                    if (comptime mode.isCommandMode()) blk: {
                        // Don't print keycodes to the command line
                        if (bytes.len >= 2 and bytes[0] == '<' and bytes[1] != '<') break :blk;

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

/// Doesn't wrap Command.Writer to avoid an unnecessary layer of indirection.
const CommandWriter = struct {
    interface: std.Io.Writer,
    zc: *ZC,

    pub fn drain(io_writer: *std.Io.Writer, data: []const []const u8, splat: usize) !usize {
        const w: *CommandWriter = @fieldParentPtr("interface", io_writer);

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

pub fn commandWriter(zc: *ZC, buffer: []u8) CommandWriter {
    return .{
        .interface = .{
            .vtable = &.{
                .drain = CommandWriter.drain,
            },
            .buffer = buffer,
        },
        .zc = zc,
    };
}

pub fn setCommandCursor(zc: *ZC, pos: u32) void {
    zc.command.setCursor(pos);
}

pub fn submitCompletion(zc: *ZC, index: usize) !void {
    // TODO: Allow any query
    const query_res = zc.completionQuery() orelse return;
    const query = zc.command.left()[query_res.offset..][0..query_res.len];

    switch (query_res.type) {
        .path => {
            // TODO: Support windows paths
            const basename =
                if (query.len > 0 and query[query.len - 1] == '/')
                    query[query.len..]
                else if (query.len == 1 and query[0] == '/')
                    query[query.len..]
                else
                    utils.basenamePosix(query);
            const off = basename.ptr - zc.command.left().ptr;
            const completion = zc.completion_strings.items[index];
            const ft = zc.completions_buffer.items[completion.offset..][0..completion.len];
            try zc.command.replaceRange(zc.allocator, @intCast(off), @intCast(basename.len), ft);
            zc.command.setCursor(@intCast(zc.command.cursor + (ft.len - basename.len)));
        },
        .command => {
            const completion = zc.completion_strings.items[index];
            const ft = zc.completions_buffer.items[completion.offset..][0..completion.len];
            const off = query.ptr - zc.command.left().ptr;
            try zc.command.replaceRange(zc.allocator, @intCast(off), @intCast(query.len), ft);
            zc.command.setCursor(@intCast(zc.command.cursor + (ft.len - query.len)));
        },
    }
}

pub fn submitCommand(zc: *ZC) !void {
    assert(zc.mode.isCommandMode());
    zc.dismissStatusMessage();
    defer if (zc.mode.isCommandMode()) zc.setMode(.normal);

    const slice = try zc.command.submit(zc.allocator);
    defer zc.commandHistoryNext();
    try zc.parseCommand(slice);
    zc.ui.submitCommand(slice);
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

pub fn doCommandMotion(zc: *ZC, motion: Motion) Oom!void {
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
        .completion_next => try zc.completionNext(),
        .completion_prev => zc.completionPrev(),
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

fn completionNext(zc: *ZC) !void {
    if (zc.completion_strings.items.len == 1) {
        try zc.submitCompletion(0);
    } else if (zc.selected_completion) |*sc| {
        sc.* = (sc.* + 1) % zc.completion_strings.items.len;
    } else if (zc.completion_strings.items.len > 0) {
        zc.selected_completion = 0;
    }
}

fn completionPrev(zc: *ZC) void {
    if (zc.selected_completion == 0 or zc.selected_completion == null) {
        zc.selected_completion = zc.completion_strings.items.len -| 1;
    } else {
        zc.selected_completion.? -= 1;
    }
}

fn doCommandInsertMode(zc: *ZC, action: CommandAction, keys: []const u8) !void {
    switch (action) {
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
        .completion_next => try zc.completionNext(),
        .completion_prev => zc.completionPrev(),
        .submit_command => {
            if (zc.selected_completion) |sc| {
                try zc.submitCompletion(sc);
            } else {
                try zc.submitCommand();
            }
        },
        .enter_normal_mode => {
            if (zc.selected_completion != null) {
                zc.selected_completion = null;
            } else {
                zc.setMode(.command_normal);
            }
        },
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
    }

    switch (action) {
        .completion_next,
        .completion_prev,
        => {},
        else => zc.selected_completion = null,
    }

    try zc.populateCompletions();
}

fn populateCompletions(zc: *ZC) !void {
    zc.completion_strings.clearRetainingCapacity();
    const query_res = zc.completionQuery() orelse return;
    const query = zc.command.left()[query_res.offset..][0..query_res.len];

    switch (query_res.type) {
        .path => {
            try zc.populatePathCompletions(query);
        },
        .command => {
            zc.last_dirname = "";
            try zc.populateCommandCompletions(query);
        },
    }
}

fn populateCommandCompletions(zc: *ZC, query: []const u8) !void {
    const total_commands_size = comptime blk: {
        var total_size: usize = 0;
        for (Command.map.keys()) |key| total_size += key.len;
        break :blk total_size;
    };

    zc.completion_strings.clearRetainingCapacity();
    zc.completions_buffer.clearRetainingCapacity();
    try zc.completion_strings.ensureTotalCapacity(zc.allocator, Command.map.keys().len);
    try zc.completions_buffer.ensureTotalCapacity(zc.allocator, total_commands_size);

    for (Command.map.keys()) |key| {
        if (std.ascii.indexOfIgnoreCase(key, query)) |_| {
            const start = zc.completions_buffer.items.len;
            zc.completions_buffer.appendSliceAssumeCapacity(key);
            zc.completion_strings.appendAssumeCapacity(.{
                .offset = start,
                .len = zc.completions_buffer.items.len - start,
            });
        }
    }
}

fn populatePathCompletions(zc: *ZC, query: []const u8) !void {
    const dirname, const basename =
        if (query.len == 1 and query[0] == '/') .{
            query,
            query[query.len..],
        } else if (query.len > 0 and query[query.len - 1] == '/') .{
            query[0 .. query.len - 1],
            query[query.len..],
        } else .{
            std.fs.path.dirname(query) orelse ".",
            std.fs.path.basename(query),
        };

    if (!std.mem.eql(u8, dirname, zc.last_dirname)) {
        std.log.debug("Repopulating directory entries ({s}) ({s})", .{ dirname, zc.last_dirname });
        zc.dir_entries.clearRetainingCapacity();
        zc.completions_buffer.clearRetainingCapacity();

        // TODO: Update to std.Io.Dir when iterator becomes available
        var dir = std.Io.Dir.cwd().openDir(zc.io, dirname, .{ .iterate = true }) catch {
            zc.last_dirname = dirname;
            return;
        };
        defer dir.close(zc.io);

        var dir_iter = dir.iterate();
        while (try dir_iter.next(zc.io)) |entry| {
            const start = zc.completions_buffer.items.len;
            try zc.dir_entries.ensureUnusedCapacity(zc.allocator, 1);
            try zc.completions_buffer.ensureUnusedCapacity(zc.allocator, entry.name.len + 1);

            zc.completions_buffer.appendSliceAssumeCapacity(entry.name);
            if (entry.kind == .directory)
                zc.completions_buffer.appendAssumeCapacity('/');

            zc.dir_entries.appendAssumeCapacity(.{
                .offset = start,
                .len = zc.completions_buffer.items.len - start,
            });
        }

        zc.last_dirname = std.mem.trimEnd(u8, dirname, "/");

        const Context = struct {
            fn lessThan(z: *ZC, a: DirEntry, b: DirEntry) bool {
                const a_text = z.completions_buffer.items[a.offset..][0..a.len];
                const b_text = z.completions_buffer.items[b.offset..][0..b.len];
                var i: usize = 0;
                while (i < a_text.len and i < b_text.len) : (i += 1) {
                    if (a_text[i] < b_text[i]) return true;
                    if (a_text[i] > b_text[i]) return false;
                }
                return true;
            }
        };

        std.mem.sortUnstable(DirEntry, zc.dir_entries.items, zc, Context.lessThan);
    }

    try zc.completion_strings.ensureTotalCapacity(zc.allocator, zc.dir_entries.items.len);
    zc.completion_strings.clearRetainingCapacity();

    for (zc.dir_entries.items) |entry| {
        const str = zc.completions_buffer.items[entry.offset..][0..entry.len];
        if (std.ascii.indexOfIgnoreCase(str, basename) != null)
            zc.completion_strings.appendAssumeCapacity(.{
                .len = entry.len,
                .offset = entry.offset,
            });
    }
}

/// Handles common actions between operator modes
fn doCommandOperatorPendingMode(zc: *ZC, action: CommandAction) Oom!void {
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
            try zc.populateCompletions();
        },
        .edit_cell => {
            zc.setMode(.command_insert);
            var wr = zc.commandWriter(&.{});
            wr.interface.print("let {f} = ", .{zc.cursor}) catch return error.OutOfMemory;
            zc.currentSheet().printCellExpression(zc.cursor, &wr.interface) catch return error.OutOfMemory;
        },
        .fit_text => {
            try zc.expandWidthAtCursor();
        },
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
            const n = zc.getCount() *| zc.ui.visibleRowCount();
            zc.setCursor(.init(zc.cursor.x, zc.cursor.y +| n));
            zc.resetCount();
        },
        .page_up => {
            const n = zc.getCount() *| zc.ui.visibleRowCount();
            zc.setCursor(.init(zc.cursor.x, zc.cursor.y -| n));
            zc.resetCount();
        },
        .half_page_down => {
            const n = zc.getCount() *| (zc.ui.visibleRowCount() / 2);
            zc.setCursor(.init(zc.cursor.x, zc.cursor.y +| n));
            zc.resetCount();
        },
        .half_page_up => {
            const n = zc.getCount() *| (zc.ui.visibleRowCount() / 2);
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
        },
        .delete_row => {
            defer zc.resetCount();
            const count = zc.getCount() - 1;
            try zc.currentSheet().deleteColOrRowRange(zc.cursor.y, zc.cursor.y + count, .{}, .row);
            zc.currentSheet().endUndoGroup();
        },
        .insert_column => {
            defer zc.resetCount();
            zc.currentSheet().insertColumns(zc.cursor.x, zc.getCount(), .{}) catch |err| switch (err) {
                error.Overflow => zc.setStatusMessage(.err, "Columns would overflow", .{}),
                else => |e| return e,
            };
            zc.currentSheet().endUndoGroup();
        },
        .insert_row => {
            defer zc.resetCount();
            zc.currentSheet().insertRows(zc.cursor.y, zc.getCount(), .{}) catch |err| switch (err) {
                error.Overflow => zc.setStatusMessage(.err, "Rows would overflow", .{}),
                else => |e| return e,
            };
            zc.currentSheet().endUndoGroup();
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

fn doVisualMode(zc: *ZC, action: Action) Oom!void {
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

// TODO: Rename this function
fn parseCommand(zc: *ZC, str: []const u8) !void {
    if (str.len == 0) return;

    if (str[0] == ':')
        return zc.runCommand(str[1..], Command.map);

    const sheet = zc.currentSheet();
    const ast_state = sheet.ast.save();

    var diagnostics: Parser.Diagnostics = .{};
    const res = sheet.parseFromExpressionDiag(str, &diagnostics) catch |err| switch (err) {
        error.UnexpectedToken,
        error.InvalidCellAddress,
        error.InvalidBuiltin,
        error.InvalidEscapeSequence,
        error.UnboundVariable,
        => {
            zc.setStatusMessage(.err, "{f}", .{diagnostics});
            return;
        },
        error.OutOfMemory => |e| return e,
    };

    switch (sheet.ast.tag(res.root)) {
        .assignment => {
            const spliced_root, const pos = sheet.ast.spliceLast();

            try zc.setCell(pos, .{
                .root = spliced_root,
                .is_volatile = res.is_volatile,
                .destination = null,
            }, str, .{});
            sheet.endUndoGroup();
        },
        else => {
            // Evaluate the expression and print the result
            defer sheet.ast.restore(ast_state);
            const value = sheet.evaluate(res.root) catch |err| {
                zc.setStatusMessage(.err, "Error ({t}) evaluating '{s}'", .{ err, str });
                return;
            };
            zc.setStatusMessage(.info, "{s} = {f}", .{ str, sheet.fmtInterpreterValue(value) });
        },
    }
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

pub const Command = enum {
    save,
    save_force,
    save_all,
    load,
    load_force,
    quit,
    quit_force,
    quit_save,
    quit_save_all,
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

    /// Maps the string versions of commands to their corresponding enum tag.
    pub const map = std.StaticStringMap(Command).initComptime(.{
        .{ "w", .save },
        .{ "wa", .save_all },
        .{ "e", .load_force },
        .{ "q", .close_sheet },
        .{ "q!", .close_sheet_force },
        .{ "qa", .quit },
        .{ "qa!", .quit_force },
        .{ "wq", .quit_save },
        .{ "wqa", .quit_save_all },
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
        .{ "y", .yank },
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

    /// These are the only valid commands when loading a file.
    pub const load_map = std.StaticStringMap(Command).initComptime(.{
        .{ "fill", .fill },
        .{ "fill-expr", .fill_expr },
        .{ "text-align", .set_text_align },
        .{ "set", .set },
        .{ "unset", .unset },
        .{ "go", .goto },
    });

    const ArgumentIndex = enum(u8) {
        valid = std.math.maxInt(u8),
        _,

        fn from(n: u8) ArgumentIndex {
            return @enumFromInt(n);
        }
    };

    fn dispatch(
        zc: *ZC,
        iter: *utils.WordIterator,
        comptime tag: Command,
        name: []const u8,
    ) !void {
        const funcs, const description = switch (tag) {
            .save, .save_force => .{
                .{ cmdSave, cmdSavePath },
                \\Save to the given filepath, or to the sheet's filepath if not specified.
            },
            .save_all => .{
                .{cmdSaveAll},
                \\Save all open sheets to disk.
            },
            .quit => .{
                .{cmdQuit},
                "Quit the program only if there are no unsaved changes. Use :q! to discard unsaved changes.",
            },
            .quit_force => .{
                .{cmdQuitForce},
                "Quit the program, discarding any unsaved changes.",
            },
            .quit_save => .{
                .{cmdQuitSave},
                \\Save the current sheet and close it.
            },
            .quit_save_all => .{
                .{cmdQuitAllSave},
                \\Save all open sheets and quit the program.
            },
            .fill => .{
                .{ cmdFill, cmdFillIncrement },
                \\Fills the given range with value, incrementing each cell.
                \\Increment is applied left to right, top to bottom.
                \\The increment defaults to 1 if not specified.
                \\
                \\Example:
                \\  :fill b1:d12 30 0.2
            },
            .fill_expr => .{
                .{cmdFillExpr},
                \\Fills the given range with an expression.
                \\
                \\Example:
                \\  :fill-expr a0:c3 1 / 2 + 3
            },
            .binary_save => .{
                .{cmdSaveBinary},
                \\Save to the given filepath in a binary format. This format
                \\is significantly faster to save/load.
            },
            .binary_load, .binary_load_force => .{
                .{cmdLoadBinary},
                \\Load from the given filepath in a binary format.
                \\Significantly faster to load than a normal file.
                \\
                \\ **WARNING**
                \\Binary files are not validated beyond a simple magic number
                \\and version check. Binary files are loaded directly into the
                \\internal state of the program without modification. It is
                \\conceivable that a malicious file could contain an invalid
                \\state that causes undefined behaviour. Only open binary
                \\files you trust.
            },
            .load, .load_force => .{
                .{ cmdLoadNoPath, cmdLoad },
                \\Creates a new sheet with the given filepath. If the filepath
                \\exists it will load attempt to load the file into the new sheet.
            },
            .undo => .{
                .{ cmdUndoOne, cmdUndoCount },
                \\Undo 1 or count times.
            },
            .redo => .{
                .{ cmdRedoOne, cmdRedoCount },
                \\Redo 1 or count times.
            },
            .delete => .{
                .{ cmdDeleteCursor, cmdDelete },
                \\Delete range or the range underneath the cursor if not specified.
            },
            .delete_columns => .{
                .{ cmdDeleteColumnsCursor, cmdDeleteColumns },
                \\Delete the given columns, or the columns under the cursor
                \\if no arguments are given. The column range is specified
                \\like a cell range but with the row numbers omitted.
                \\
                \\Examples:
                \\  :delete-cols
                \\  :delete-cols A
                \\  :delete-cols C:F
            },
            .delete_rows => .{
                .{ cmdDeleteRowsCursor, cmdDeleteRows },
                \\Delete the given rows, or the rows under the cursor if
                \\no arguments are given. The row range is specified like
                \\a cell range but with the column letters omitted.
                \\
                \\Examples:
                \\  :delete-rows
                \\  :delete-rows 3
                \\  :delete-rows 9:15
            },
            .insert_columns => .{
                .{ cmdInsertColumnsCursor, cmdInsertColumnsCount, cmdInsertColumns },
                \\Insert columns into the sheet. The two argument variant
                \\inserts N columns at column START. The one argument variant
                \\inserts N columns at the cursor, and the zero argument
                \\variant inserts 1 column at the cursor.
            },
            .insert_rows => .{
                .{ cmdInsertRowsCursor, cmdInsertRowsCount, cmdInsertRows },
                \\Insert rows into the sheet. The two argument variant
                \\inserts N rows at row START. The one argument variant
                \\inserts N rows at the cursor, and the zero argument
                \\variant inserts 1 row at the cursor.
            },
            .set_text_align => .{
                .{ cmdTextAlignCursor, cmdTextAlign },
                \\Set the alignment of the text in the specified cells or
                \\under the cursor if not specified. Only cells with a text
                \\value can have be aligned.
            },
            .goto => .{
                .{cmdGoto},
                \\Moves the cursor to the given cell or range. If a range is
                \\given the mode changes to visual and the range is selected.
            },
            .put => .{
                .{ cmdPutCursor, cmdPut },
                \\Pastes the current contents of the range held by the yank
                \\buffer at the given position or at the cursor. Expressions
                \\are copied literally, with no modification. If the range
                \\to copy to is larger than the source range, then the source
                \\range is tiled over the destination range. The full source
                \\range is always pasted, regardless of whether it overflows
                \\the destination range or not.
            },
            .put_adjust => .{
                .{ cmdPutAdjustCursor, cmdPutAdjust },
                \\Same as `:put`, but automatically adjusts cell references
                \\based on the new position.
            },
            .yank => .{
                .{ cmdYankCursor, cmdYank },
                \\Copies the given range or the cursor range to the yank buffer.
            },
            .close_sheet => .{
                .{cmdCloseSheet},
                \\Closes the currently selected sheet
            },
            .close_sheet_force => .{
                .{cmdCloseSheetForce},
                \\Closes the currently selected sheet, discardign unsaved changes.
            },
            .rename_sheet => .{
                .{ cmdRenameSheetCurrent, cmdRenameSheet },
                \\Rename the given or current sheet.
            },
            .set => .{
                .{ cmdSetTrue, cmdSet },
                \\Set a property.
            },
            .unset => .{
                .{cmdUnset},
                \\Unset a property.
            },
        };

        comptime var max_params = 0;
        comptime var min_params = std.math.maxInt(u32);
        comptime var variadic = false;
        comptime for (funcs) |func| {
            const info = @typeInfo(@TypeOf(func)).@"fn";
            if (info.params[info.params.len - 1].type.? == ExpressionArg)
                variadic = true;

            if (info.params.len - 1 > max_params) max_params = info.params.len - 1;
            if (info.params.len - 1 < min_params) min_params = info.params.len - 1;
        };

        var argv: [max_params][]const u8 = undefined;
        var argc: usize = 0;

        for (&argv) |*p| {
            p.* = iter.next() orelse break;
            // TODO: Make flags escapable
            if (std.mem.eql(u8, p.*, "-h")) {
                // Got a -h flag, print help and exit
                try setCommandUsage(zc, name, description, funcs);
                return;
            }
            argc += 1;
        }

        zc.status.msg.clearRetainingCapacity();
        zc.status.cmd.clearRetainingCapacity();
        zc.status.usage.clearRetainingCapacity();

        if (!variadic and iter.peek() != null) {
            const str = iter.peek().?;
            if (std.mem.eql(u8, str, "-h")) {
                try setCommandUsage(zc, name, description, funcs);
                return;
            }

            try zc.status.msg.appendSlice(zc.allocator, "Too many arguments");
            try setCommandError(
                zc,
                iter.index,
                iter.string.len - iter.index,
                name,
                iter.string,
                description,
                funcs,
            );
            return;
        }
        if (argc < min_params) {
            try zc.status.msg.appendSlice(zc.allocator, "Not enough arguments");
            try setCommandError(zc, 0, 0, name, iter.string, description, funcs);
            return;
        }

        inline for (funcs) |func| @"continue": {
            const parameters = @typeInfo(@TypeOf(func)).@"fn".params;

            // Equivalent to `continue`, which doesn't work here due to zig/#9524.
            if (parameters.len - 1 != argc) break :@"continue";

            // This function has the same number of arguments as we passed on the command line.
            // Proceed to parse the command line, populating the function arguments, and call
            // the function.
            var dest_args: std.meta.ArgsTuple(@TypeOf(func)) = undefined;
            dest_args[0] = zc;

            inline for (argv[0 .. parameters.len - 1], 1..) |arg, i| {
                dest_args[i] = parseArg(@TypeOf(dest_args[i]), zc, arg, iter.string) catch |err| {
                    try setCommandError(zc, arg.ptr - iter.string.ptr, arg.len, name, iter.string, description, funcs);
                    return err;
                };
            }

            const ReturnType = @typeInfo(@TypeOf(func)).@"fn".return_type.?;
            switch (@typeInfo(ReturnType)) {
                .error_union => |eu| {
                    const res = try @call(.auto, func, dest_args);
                    if (eu.payload == ArgumentIndex) switch (res) {
                        .valid => {},
                        ArgumentIndex.from(0) => {},
                        else => |arg_index| {
                            const arg = argv[@intFromEnum(arg_index) - 1];
                            const offset = arg.ptr - iter.string.ptr;
                            try setCommandError(
                                zc,
                                offset,
                                arg.len,
                                name,
                                iter.string,
                                description,
                                funcs,
                            );
                        },
                    };
                },
                .void => @call(.auto, func, dest_args),
                else => comptime unreachable,
            }
            return;
        }

        try zc.status.msg.appendSlice(zc.allocator, "Invalid argument count");
        return error.InvalidArgCount;
    }

    fn setCommandUsage(zc: *ZC, name: []const u8, description: []const u8, funcs: anytype) !void {
        zc.status.tag = .cmd_info;
        zc.status.cmd_description = description;

        const s = &zc.status.usage;
        inline for (funcs, 0..) |func, i| {
            s.print(zc.allocator, "  :{s}", .{name}) catch return error.OutOfMemory;
            inline for (@typeInfo(@TypeOf(func)).@"fn".params[1..]) |p| {
                const arg_type_name = switch (p.type.?) {
                    []const u8 => "STRING",
                    f64 => "NUMBER",
                    else => p.type.?.type_name,
                };
                s.print(zc.allocator, " {s}", .{arg_type_name}) catch return error.OutOfMemory;
            }
            if (i < funcs.len - 1)
                s.append(zc.allocator, '\n') catch return error.OutOfMemory;
        }
    }

    fn setCommandError(
        zc: *ZC,
        err_offset: usize,
        err_size: usize,
        name: []const u8,
        command: []const u8,
        description: []const u8,
        funcs: anytype,
    ) !void {
        const s = &zc.status;

        s.tag = .cmd_err;
        s.cmd.appendSlice(zc.allocator, command) catch {};
        s.cmd_description = description;
        s.err_offset = err_offset;
        s.err_size = err_size;

        inline for (funcs, 0..) |func, i| {
            s.usage.print(zc.allocator, "  :{s}", .{name}) catch {};
            inline for (@typeInfo(@TypeOf(func)).@"fn".params[1..]) |p| {
                const arg_type_name = switch (p.type.?) {
                    []const u8 => "STRING",
                    f64 => "NUMBER",
                    else => p.type.?.type_name,
                };
                s.usage.print(zc.allocator, " {s}", .{arg_type_name}) catch {};
            }
            if (i < funcs.len - 1)
                s.usage.append(zc.allocator, '\n') catch {};
        }
    }

    fn parseArg(T: type, zc: *ZC, arg: []const u8, command: []const u8) !T {
        switch (T) {
            []const u8 => return arg,
            f64 => return std.fmt.parseFloat(f64, arg) catch |err| {
                try zc.status.msg.appendSlice(zc.allocator, "Invalid number");
                return err;
            },
            ExpressionArg => {
                var off = arg.ptr - command.ptr;
                while (off > 0 and command[off] != ' ') off -= 1;
                const expr_str = command[off..];

                var diagnostics: Parser.Diagnostics = .{};
                const expr = zc.currentSheet().parseFromExpressionDiag(
                    expr_str,
                    &diagnostics,
                ) catch |err| switch (err) {
                    error.UnexpectedToken,
                    error.InvalidCellAddress,
                    error.InvalidBuiltin,
                    error.InvalidEscapeSequence,
                    error.UnboundVariable,
                    => {
                        try zc.status.msg.print(zc.allocator, "{f}", .{diagnostics});
                        return err;
                    },
                    error.OutOfMemory => return error.OutOfMemory,
                };
                return .{ .expr = expr.toOptional() };
            },
            else => return try .init(zc, arg),
        }
    }

    // Command functions which can error due to invalid usage should return `!ArgumentIndex`.
    // These functions should return the 1-based index of the invalid argument, or 0 if no specific
    // argument is invalid. If the function succeeded, they should return `.valid`. If the function
    // failed in a way unrelated to the usage of the function, they should set a status message
    // manually and return an error.
    //
    // Functions that don't need to display usage information on error can return `void` or `!void`
    // as appropriate and set an error message manually if required.

    fn cmdSave(zc: *ZC) void {
        zc.writeFile(null) catch |err| {
            zc.setStatusMessage(.warn, "Could not write file: {s}", .{@errorName(err)});
            return;
        };
        zc.currentSheet().has_changes = false;
    }

    fn cmdSavePath(zc: *ZC, path: PathArg) void {
        // TODO: Check if already exists
        zc.writeFile(path.bytes) catch |err| {
            zc.setStatusMessage(.warn, "Could not write file: {s}", .{@errorName(err)});
            return;
        };
        zc.currentSheet().has_changes = false;
    }

    fn cmdSaveBinary(zc: *ZC, path: PathArg) !void {
        const file = std.Io.Dir.cwd().createFile(zc.io, path.bytes, .{}) catch |err| {
            zc.setStatusMessage(.warn, "Could not write binary file: {s}", .{
                @errorName(err),
            });
            return;
        };
        defer file.close(zc.io);

        try zc.currentSheet().serialize(zc.io, file);
    }

    fn cmdLoadBinary(zc: *ZC, path: PathArg) Oom!void {
        zc.loadCmdBinary(path.bytes) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => {
                try zc.status.msg.print(zc.allocator, "Could not open file: {t}", .{err});
                return;
            },
        };
    }

    fn cmdLoad(zc: *ZC, path: PathArg) Oom!void {
        if (zc.sheets.entries.len == 1 and
            zc.currentSheet().has_changes == false and
            zc.currentSheet().filepath.items.len == 0)
        {
            zc.loadFile(0, path.bytes) catch |err| {
                zc.setStatusMessage(.err, "Could not open file: {s}", .{@errorName(err)});
                return;
            };
            return;
        }

        zc.loadCmd(path.bytes) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => {
                try zc.status.msg.print(zc.allocator, "Could not open file: {t}", .{err});
                return;
            },
        };
    }

    fn cmdLoadNoPath(zc: *ZC) Oom!void {
        const new_sheet = try zc.openSheet();
        zc.setCurrentSheet(new_sheet);
    }

    fn cmdQuit(zc: *ZC) void {
        for (zc.sheets.values()) |*sheet| {
            if (sheet.has_changes) {
                zc.setStatusMessage(.warn, "No write since last change (add ! to override)", .{});
                break;
            }
        } else {
            zc.running = false;
        }
    }

    fn cmdQuitForce(zc: *ZC) void {
        zc.running = false;
    }

    fn cmdQuitSave(zc: *ZC) void {
        cmdSave(zc);
        cmdQuit(zc);
    }

    fn cmdQuitAllSave(zc: *ZC) !void {
        cmdSaveAll(zc);
        cmdQuit(zc);
    }

    fn cmdSaveAll(zc: *ZC) void {
        for (zc.sheets.values()) |*sheet| {
            zc.writeSheet(sheet, null) catch |err| {
                zc.setStatusMessage(.warn, "Could not write file: {s}", .{@errorName(err)});
                return;
            };
            sheet.has_changes = false;
        }
    }

    fn cmdFill(zc: *ZC, r: RangeOrPointArg, n: NumberArg("initial_number")) Oom!void {
        // No increment was provided, so all cells can share the same expression
        try zc.currentSheet().insertCellRange(r.range, .none, .{
            .value = .{ .number = n.value },
            .tag = .number,
        });
        zc.currentSheet().queued_cells.items.len = 0;
        zc.currentSheet().endUndoGroup();
    }

    fn cmdFillIncrement(
        zc: *ZC,
        r: RangeOrPointArg,
        initial: NumberArg("initial_number"),
        increment: NumberArg("increment"),
    ) Oom!void {
        try zc.currentSheet().insertIncrementingCellRange(r.range, initial.value, increment.value, .{});
        zc.currentSheet().endUndoGroup();
    }

    fn cmdFillExpr(zc: *ZC, r: RangeOrPointArg, arg: ExpressionArg) Oom!void {
        try zc.currentSheet().insertCellRange(r.range, arg.expr, .{});
        zc.currentSheet().endUndoGroup();
    }

    fn cmdUndoCount(zc: *ZC, count: IntegerArg(u32, "count")) Oom!void {
        for (0..count.value) |_| try zc.undo();
    }

    fn cmdRedoCount(zc: *ZC, count: IntegerArg(u32, "count")) Oom!void {
        for (0..count.value) |_| try zc.redo();
    }

    fn cmdUndoOne(zc: *ZC) Oom!void {
        try zc.undo();
    }

    fn cmdRedoOne(zc: *ZC) Oom!void {
        try zc.redo();
    }

    fn cmdDeleteCursor(zc: *ZC) Oom!void {
        try zc.deleteCellRange(zc.anyCursorRange());
    }

    fn cmdDelete(zc: *ZC, r: RangeOrPointArg) Oom!void {
        try zc.deleteCellRange(r.range);
    }

    fn cmdDeleteColumns(zc: *ZC, c: ColumnRangeArg) Oom!void {
        try zc.currentSheet().deleteColOrRowRange(c.start, c.end, .{}, .col);
        zc.currentSheet().endUndoGroup();
    }

    fn cmdDeleteColumnsCursor(zc: *ZC) Oom!void {
        const r = zc.anyCursorRange();
        try zc.currentSheet().deleteColOrRowRange(r.tl.x, r.br.x, .{}, .col);
        zc.currentSheet().endUndoGroup();
    }

    fn cmdDeleteRows(zc: *ZC, c: RowRangeArg) Oom!void {
        try zc.currentSheet().deleteColOrRowRange(c.start, c.end, .{}, .row);
        zc.currentSheet().endUndoGroup();
    }

    fn cmdDeleteRowsCursor(zc: *ZC) Oom!void {
        const r = zc.anyCursorRange();
        try zc.currentSheet().deleteColOrRowRange(r.tl.x, r.br.x, .{}, .row);
        zc.currentSheet().endUndoGroup();
    }

    fn cmdInsertColumnsCursor(zc: *ZC) Oom!void {
        try cmdInsertColumns(zc, .{ .value = zc.cursor.x }, .{ .value = 1 });
    }

    fn cmdInsertColumnsCount(zc: *ZC, count: IntegerArg(u32, "count")) Oom!void {
        try cmdInsertColumns(zc, .{ .value = zc.cursor.x }, count);
    }

    fn cmdInsertColumns(zc: *ZC, start: ColumnArg, count: IntegerArg(u32, "count")) Oom!void {
        if (count.value == 0) return;
        zc.currentSheet().insertColumns(start.value, count.value, .{}) catch |err| switch (err) {
            error.Overflow => {
                zc.setStatusMessage(.err, "Columns would overflow", .{});
                return;
            },
            error.OutOfMemory => |e| return e,
        };
        zc.currentSheet().endUndoGroup();
    }

    fn cmdInsertRowsCursor(zc: *ZC) Oom!void {
        try cmdInsertRows(zc, .{ .value = zc.cursor.y }, .{ .value = 1 });
    }

    fn cmdInsertRowsCount(zc: *ZC, count: IntegerArg(u32, "count")) Oom!void {
        try cmdInsertRows(zc, .{ .value = zc.cursor.y }, count);
    }

    fn cmdInsertRows(zc: *ZC, start: IntegerArg(u32, "row"), count: IntegerArg(u32, "count")) Oom!void {
        if (count.value == 0) return;
        zc.currentSheet().insertRows(start.value, count.value, .{}) catch |err| switch (err) {
            error.Overflow => {
                zc.setStatusMessage(.err, "Rows would overflow", .{});
                return;
            },
            error.OutOfMemory => |e| return e,
        };
        zc.currentSheet().endUndoGroup();
    }

    fn cmdTextAlign(
        zc: *ZC,
        r: RangeOrPointArg,
        alignment: ArgEnum(Sheet.TextAttrs.Alignment, "left|right|center"),
    ) Oom!void {
        try zc.setTextAlignment(r.range, alignment.value);
    }

    fn cmdTextAlignCursor(
        zc: *ZC,
        alignment: ArgEnum(Sheet.TextAttrs.Alignment, "left|right|center"),
    ) Oom!void {
        try zc.setTextAlignment(zc.anyCursorRange(), alignment.value);
    }

    fn cmdYankCursor(zc: *ZC) void {
        zc.yank = zc.anyCursorRange();
    }

    fn cmdYank(zc: *ZC, r: RangeOrPointArg) void {
        zc.yank = r.range;
    }

    fn cmdPutCursor(zc: *ZC) Oom!void {
        try zc.put(zc.anyCursorRange(), .no_adjust);
    }

    fn cmdPut(zc: *ZC, r: RangeOrPointArg) Oom!void {
        try zc.put(r.range, .no_adjust);
    }

    fn cmdPutAdjustCursor(zc: *ZC) Oom!void {
        try zc.put(zc.anyCursorRange(), .adjust);
    }

    fn cmdPutAdjust(zc: *ZC, r: RangeOrPointArg) Oom!void {
        try zc.put(r.range, .adjust);
    }

    fn cmdGoto(zc: *ZC, r: RangeOrPointArg) void {
        if (r.range.area() == 1) {
            zc.setCursor(r.range.tl);
        } else {
            zc.setMode(.visual);
            zc.anchor = r.range.tl;
            zc.setCursor(r.range.br);
        }
    }

    fn cmdCloseSheet(zc: *ZC) Oom!void {
        if (zc.currentSheet().has_changes) {
            zc.setStatusMessage(.warn, "No write since last change (add ! to override)", .{});
        } else {
            try zc.closeSheet(zc.current_sheet);
        }
    }

    fn cmdCloseSheetForce(zc: *ZC) Oom!void {
        try zc.closeSheet(zc.current_sheet);
    }

    fn cmdRenameSheet(
        zc: *ZC,
        target: StringArg("old_name"),
        new_name: StringArg("new_name"),
    ) !ArgumentIndex {
        const index = zc.sheets.getIndex(target.bytes) orelse {
            try zc.status.msg.print(zc.allocator, "Sheet '{s}' does not exist", .{target.bytes});
            return .from(1);
        };
        zc.renameSheet(index, new_name.bytes) catch |err| switch (err) {
            error.InvalidSheetName => {
                try zc.status.msg.appendSlice(zc.allocator, "Sheet name must not be empty");
                return .from(2);
            },
            error.SheetAlreadyExists => {
                try zc.status.msg.print(zc.allocator, "Sheet '{s}' already exists", .{new_name.bytes});
                return .from(2);
            },
            error.OutOfMemory => |e| return e,
        };
        return .valid;
    }

    fn cmdRenameSheetCurrent(zc: *ZC, new_name: StringArg("new_name")) !ArgumentIndex {
        const index = zc.current_sheet;
        zc.renameSheet(index, new_name.bytes) catch |err| switch (err) {
            error.InvalidSheetName => {
                try zc.status.msg.appendSlice(zc.allocator, "Sheet name must not be empty");
                return .from(1);
            },
            error.SheetAlreadyExists => {
                try zc.status.msg.print(zc.allocator, "Sheet '{s}' already exists", .{new_name.bytes});
                return .from(1);
            },
            error.OutOfMemory => |e| return e,
        };
        return .valid;
    }

    fn cmdSet(zc: *ZC, property: ArgEnum(SetProperty, "property"), value: []const u8) !void {
        switch (property.value) {
            .theme => try zc.setTheme(value),
            .truecolor => {
                if (std.ascii.eqlIgnoreCase(value, "true")) {
                    zc.ui.setTrueColour(zc, true);
                } else if (std.ascii.eqlIgnoreCase(value, "false")) {
                    zc.ui.setTrueColour(zc, false);
                }
            },
        }
    }

    // TODO: Make the enum here be a subset containing only boolean properties
    fn cmdSetTrue(zc: *ZC, property: ArgEnum(SetProperty, "property")) !void {
        switch (property.value) {
            .truecolor => zc.ui.setTrueColour(zc, true),
            else => {
                // TODO: Make sure this is reported correctly
                return error.InvalidProperty;
            },
        }
    }

    fn cmdUnset(zc: *ZC, property: ArgEnum(SetProperty, "property")) !void {
        // TODO: Check if the property is actually set before unsetting it.
        switch (property.value) {
            .theme => try zc.setDefaultTheme(),
            .truecolor => {
                zc.ui.setTrueColour(zc, false);
            },
        }
    }

    const PathArg = struct {
        bytes: []const u8,

        const type_name = "filepath";

        fn init(_: *ZC, str: []const u8) !PathArg {
            return .{ .bytes = str };
        }
    };

    const RangeOrPointArg = struct {
        range: Rect,

        const type_name = "range";

        fn init(zc: *ZC, arg: []const u8) !RangeOrPointArg {
            errdefer zc.status.msg.appendSlice(zc.allocator, "Invalid range") catch {};
            return .{ .range = try parseRangeOrPoint(arg) };
        }
    };

    const ExpressionArg = struct {
        expr: Parser.OptionalResult,

        const type_name = "expression";
    };

    const ColumnRangeArg = struct {
        start: u32,
        end: u32,

        const type_name = "column_range";

        fn init(zc: *ZC, arg: []const u8) !ColumnRangeArg {
            errdefer zc.status.msg.appendSlice(zc.allocator, "Invalid column address") catch {};
            var sep = std.mem.tokenizeScalar(u8, arg, ':');
            const first = sep.next().?;
            const first_col = try Position.columnFromAddress(first);
            if (sep.next()) |second| {
                const second_col = try Position.columnFromAddress(second);
                return if (first_col <= second_col)
                    .{ .start = first_col, .end = second_col }
                else
                    .{ .start = second_col, .end = first_col };
            }

            return .{ .start = first_col, .end = first_col };
        }
    };

    const RowRangeArg = struct {
        start: u32,
        end: u32,

        const type_name = "row_range";

        fn init(zc: *ZC, arg: []const u8) !RowRangeArg {
            errdefer zc.status.msg.appendSlice(zc.allocator, "Invalid row address") catch {};
            var sep = std.mem.tokenizeScalar(u8, arg, ':');
            const first = sep.next().?;
            const first_row = try std.fmt.parseInt(u32, first, 0);
            if (sep.next()) |second| {
                const second_row = try std.fmt.parseInt(u32, second, 0);
                return if (first_row <= second_row)
                    .{ .start = first_row, .end = second_row }
                else
                    .{ .start = second_row, .end = first_row };
            }

            return .{ .start = first_row, .end = first_row };
        }
    };

    const ColumnArg = struct {
        value: u32,

        const type_name = "column";

        fn init(zc: *ZC, arg: []const u8) !ColumnArg {
            errdefer zc.status.msg.appendSlice(zc.allocator, "Invalid column") catch {};
            return .{ .value = try Position.columnFromAddress(arg) };
        }
    };

    fn NumberArg(name: []const u8) type {
        return struct {
            value: f64,

            pub const type_name = name;

            pub fn init(zc: *ZC, str: []const u8) !NumberArg(name) {
                errdefer zc.status.msg.appendSlice(zc.allocator, "Invalid number") catch {};
                return .{ .value = try std.fmt.parseFloat(f64, str) };
            }
        };
    }

    fn IntegerArg(T: type, name: []const u8) type {
        return struct {
            value: T,

            pub const type_name = name;

            pub fn init(zc: *ZC, str: []const u8) !IntegerArg(T, name) {
                errdefer zc.status.msg.appendSlice(zc.allocator, "Invalid integer") catch {};
                return .{ .value = try std.fmt.parseInt(T, str, 0) };
            }
        };
    }

    fn StringArg(name: []const u8) type {
        return struct {
            bytes: []const u8,

            pub const type_name = name;

            pub fn init(_: *ZC, str: []const u8) !StringArg(name) {
                return .{ .bytes = str };
            }
        };
    }

    fn ArgEnum(E: type, name: []const u8) type {
        return struct {
            value: E,

            pub const type_name = name;

            pub fn init(zc: *ZC, str: []const u8) !ArgEnum(E, name) {
                errdefer zc.status.msg.appendSlice(zc.allocator, "Invalid option") catch {};
                return .{
                    .value = std.meta.stringToEnum(E, str) orelse return error.InvalidValue,
                };
            }
        };
    }
};

const DebugCmd = enum {
    expect_eql_number,
    expect_eql_string,
    expect_non_extant,
    expect_error,
    expect_expr,
    update_cell,
    expect,
    expect_volatile,
    expect_non_volatile,
};

const debug_cmds: std.StaticStringMap(DebugCmd) = .initComptime(.{
    .{ "expect-eql-string", .expect_eql_string },
    .{ "expect-eql-number", .expect_eql_number },
    .{ "expect-non-extant", .expect_non_extant },
    .{ "expect-error", .expect_error },
    .{ "update-cell", .update_cell },
    .{ "expect-expr", .expect_expr },
    .{ "expect", .expect },
    .{ "expect-volatile", .expect_volatile },
    .{ "expect-non-volatile", .expect_non_volatile },
});

const RunCommandError = error{
    InvalidCommand,
    InvalidSyntax,
    InvalidCellAddress,
    EmptyFileName,
} || Oom;

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

fn argRangeOrPoint(zc: *ZC, iter: *utils.WordIterator) !Rect {
    const bytes = iter.next() orelse {
        zc.setStatusMessage(.err, "Not enough arguments (expected a range or cell)", .{});
        return error.NotEnoughArguments;
    };

    var range_iter = std.mem.splitScalar(u8, bytes, ':');
    const lhs = range_iter.next() orelse {
        zc.setStatusMessage(.err, "Invalid cell address", .{});
        return error.InvalidSyntax;
    };
    const rhs = range_iter.next() orelse {
        const pos = Position.fromAddress(lhs) catch |err| {
            zc.setStatusMessage(.err, "Invalid cell address", .{});
            return err;
        };
        return .initSinglePos(pos);
    };

    errdefer |err| switch (err) {
        error.InvalidCellAddress => zc.setStatusMessage(.err, "Invalid cell address", .{}),
    };

    const p1 = Position.fromAddress(lhs) catch return error.InvalidCellAddress;
    const p2 = Position.fromAddress(rhs) catch return error.InvalidCellAddress;

    return .initPos(
        .topLeft(p1, p2),
        .bottomRight(p1, p2),
    );
}

fn nextArg(zc: *ZC, iter: *utils.WordIterator) ![]const u8 {
    return iter.next() orelse {
        zc.setStatusMessage(.err, "Not enough arguments", .{});
        return error.NotEnoughArguments;
    };
}

fn nextNumber(zc: *ZC, iter: *utils.WordIterator) !f64 {
    const arg = iter.next() orelse {
        zc.setStatusMessage(.err, "Not enough arguments (expected number)", .{});
        return error.NotEnoughArguments;
    };

    return zc.argAsNumber(arg);
}

fn argAsNumber(zc: *ZC, arg: []const u8) !f64 {
    return std.fmt.parseFloat(f64, arg) catch |err| {
        zc.setStatusMessage(.err, "Invalid number '{s}'", .{arg});
        return err;
    };
}

fn runDebugCommand(zc: *ZC, cmd_str: []const u8, iter: *utils.WordIterator) !void {
    const cmd_tag = debug_cmds.get(cmd_str) orelse return error.InvalidCommand;
    switch (cmd_tag) {
        .expect_volatile => {
            const sheet = zc.currentSheet();
            const arg1 = iter.next() orelse return error.InvalidSyntax;
            const pos: Position = try .fromAddress(arg1);
            const cell = sheet.getCell(pos) orelse return error.CellNotFound;
            if (!cell.expr.is_volatile) return error.CellIsNonVolatile;
        },
        .expect_non_volatile => {
            const sheet = zc.currentSheet();
            const arg1 = iter.next() orelse return error.InvalidSyntax;
            const pos: Position = try .fromAddress(arg1);
            const cell = sheet.getCell(pos) orelse return error.CellNotFound;
            if (cell.expr.is_volatile) return error.CellIsVolatile;
        },
        .expect => {
            const sheet = zc.currentSheet();
            const src = iter.string[iter.index..];
            const expr = try sheet.parseFromExpression(src);
            const res = try sheet.evaluate(expr.root);

            if (!res.toBoolean()) {
                return error.UnexpectedResult;
            }
        },
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
            if (zc.currentSheet().getCellHandleByPos(pos)) |handle| {
                try zc.currentSheet().enqueueUpdate(handle);
            }
        },
        .expect_expr => {
            const arg1 = iter.next() orelse return error.InvalidSyntax;
            const rest = iter.string[iter.index..];

            var aw: std.Io.Writer.Allocating = .init(zc.allocator);
            defer aw.deinit();

            const pos: Position = try .fromAddress(arg1);

            const sheet = zc.currentSheet();
            const cell = sheet.getCell(pos) orelse return error.CellNotFound;
            const expected_expr = (try sheet.parseFromExpression(rest)).root;
            const actual_expr = cell.root().unwrap().?;

            const expected_nodes = sheet.exprSlice(expected_expr);
            const actual_nodes = sheet.exprSlice(actual_expr);

            if (actual_nodes.len() != expected_nodes.len())
                return error.TestExpectedEqualExpressions;

            for (0..expected_nodes.len()) |i| {
                const expected = expected_nodes.geti(i).get();
                const actual = actual_nodes.geti(i).get();
                if (!std.meta.eql(expected, actual))
                    return error.TestExpectedEqualExpressions;
            }
        },
    }
}

pub fn runCommand(zc: *ZC, str: []const u8, comptime map: std.StaticStringMap(Command)) !void {
    var iter = utils.wordIterator(str);
    const cmd_str = iter.next() orelse return error.InvalidCommand;
    assert(cmd_str.len > 0);

    std.log.info("Running command '{s}'", .{str});
    const cmd_tag = map.get(cmd_str) orelse {
        if (!@import("builtin").is_test) return error.InvalidCommand;

        return zc.runDebugCommand(cmd_str, &iter);
    };

    switch (cmd_tag) {
        inline else => |t| try Command.dispatch(zc, &iter, t, cmd_str),
    }
}

fn resetArena(zc: *ZC) void {
    _ = zc.arena.reset(.{
        .retain_with_limit = comptime std.math.pow(usize, 2, 20),
    });
}

// TODO: Optimize this.
fn setTextAlignment(zc: *ZC, r: Rect, alignment: Sheet.TextAttrs.Alignment) Oom!void {
    const sheet = zc.currentSheet();
    const n = std.math.cast(usize, r.area()) orelse return error.OutOfMemory;
    try sheet.text_attrs.ensureUnusedCapacity(sheet.gpa, n);

    var iter = r.iterator();
    while (iter.next()) |pos| {
        const res = try sheet.text_attrs.getOrPut(sheet.gpa, &.{ pos.x, pos.y });
        if (!res.found_existing)
            res.value_ptr.* = .default;
        res.value_ptr.alignment = alignment;
    }
}

pub fn loadCmdBinary(zc: *ZC, filepath: []const u8) !void {
    assert(zc.sheets.entries.len > 0);
    if (filepath.len == 0) return error.EmptyFileName;

    const file = try std.Io.Dir.cwd().openFile(zc.io, filepath, .{});
    defer file.close(zc.io);

    const new_sheet = try zc.openSheet();
    errdefer comptime unreachable;

    const sheet = &zc.sheets.values()[new_sheet];
    sheet.deserialize(sheet.gpa, zc.io, file) catch |err| {
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

fn writeSheet(zc: *ZC, sheet: *Sheet, maybe_filepath: ?[]const u8) !void {
    const filepath = maybe_filepath orelse sheet.filepath.items;
    if (filepath.len == 0)
        return error.EmptyFileName;

    // TODO: Upgrade usage of atomic file whenever it gets added to std.Io
    var buf: [8192]u8 = undefined;
    var atomic_file = try std.Io.Dir.cwd().createFileAtomic(zc.io, filepath, .{
        .replace = true,
    });
    defer atomic_file.deinit(zc.io);

    var writer = atomic_file.file.writer(zc.io, &buf);
    const w = &writer.interface;

    if (std.mem.endsWith(u8, filepath, ".csv")) {
        try sheet.writeCsv(w);
    } else {
        try zc.writeZcHeader(w);
        try sheet.writeContents(w);
    }
    try atomic_file.replace(zc.io);

    if (maybe_filepath) |path|
        sheet.setFilePath(path);
}

fn writeFile(zc: *ZC, maybe_filepath: ?[]const u8) !void {
    try zc.writeSheet(zc.currentSheet(), maybe_filepath);
}

fn writeZcHeader(zc: *ZC, w: *std.Io.Writer) !void {
    const sheet = zc.currentSheet();
    try w.writeAll(
        \\-- This file was automatically generated by Cellulator.
        \\
    );
    try w.print(":go {f}\n", .{zc.cursor});
    var iter = sheet.text_attrs.iterator();
    while (iter.next()) |handle| {
        const attr = sheet.text_attrs.getValue(handle);
        const pos: Position = .fromArray(sheet.text_attrs.getPoint(handle).*);
        try w.print(":text-align {f} {s}\n", .{
            pos,
            @tagName(attr.alignment),
        });
    }
}

fn loadFile(zc: *ZC, sheet_index: usize, filepath: []const u8) !void {
    const sheet = zc.getSheet(sheet_index);

    const file = std.Io.Dir.cwd().openFile(zc.io, filepath, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            sheet.setFilePath(filepath);
            sheet.has_changes = false;
            return;
        },
        else => return err,
    };
    defer file.close(zc.io);

    sheet.setFilePath(filepath);
    defer sheet.has_changes = false;

    log.debug("Loading file {s}", .{filepath});

    sheet.clearRetainingCapacity();

    const arena = sheet.arena.allocator();
    const buf = try arena.alloc(u8, 1 << 18);

    var r = file.reader(zc.io, buf);
    if (std.mem.endsWith(u8, filepath, ".csv")) {
        try sheet.loadCsv(&r.interface);
    } else {
        // Parse and run commands first
        zc.loadZcHeader(&r.interface) catch @panic("");
        try sheet.interpretSource(&r.interface);
    }

    sheet.endUndoGroup();
    zc.emitEvent("UpdateFilePath", .{
        zc.getSheetName(sheet_index),
        filepath,
    });
}

fn loadZcHeader(zc: *ZC, r: *std.Io.Reader) !void {
    while (true) {
        const line = r.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => |e| return e,
            error.StreamTooLong => {
                std.log.warn("Line too long, skipping", .{});
                _ = r.discardDelimiterInclusive('\n') catch |err2| switch (err2) {
                    error.ReadFailed => |e| return e,
                    error.EndOfStream => break,
                };
                continue;
            },
        } orelse break;

        // Stop loading the header as soon as we encounter a let statement, putting this line
        // back into the buffer.
        if (std.mem.startsWith(u8, line, "let")) {
            r.seek -= line.len + 1;
            break;
        }

        if (line.len == 0 or line[0] != ':')
            continue;

        zc.runCommand(line[1..], Command.load_map) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => {},
        };
    }
}

fn setCurrentSheet(zc: *ZC, index: usize) void {
    zc.current_sheet = index;
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
    try zc.sheets.ensureUnusedCapacity(zc.allocator, 1);
    const new_sheet_name = try std.fmt.allocPrint(zc.allocator, "Sheet{d}", .{
        zc.max_sheet_n,
    });
    errdefer zc.allocator.free(new_sheet_name);

    const new_sheet: Sheet = try .init(zc.allocator);
    errdefer comptime unreachable;

    zc.max_sheet_n += 1;
    zc.sheets.putAssumeCapacityNoClobber(new_sheet_name, new_sheet);

    return zc.sheets.entries.len - 1;
}

fn closeSheet(zc: *ZC, index: usize) !void {
    var sheet = zc.sheets.values()[index];
    const name = zc.sheets.keys()[index];
    defer zc.allocator.free(name);
    zc.sheets.orderedRemoveAt(index);
    sheet.deinit();
    if (zc.sheets.entries.len == 0) {
        zc.running = false;
    } else if (zc.current_sheet == index) {
        zc.prevSheet();
    }
    zc.setStatusMessage(.info, "Closed {s}", .{name});
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
}

fn setDefaultTheme(zc: *ZC) !void {
    try zc.ui.applyDefaultTheme();
}

fn setTheme(
    zc: *ZC,
    /// Base name of the theme file to set.
    theme_name: []const u8,
) !void {
    const ui_name = zc.ui.getUiName();
    const extension = zc.ui.getThemeFileExtension();

    const dir, const subpath = if (zc.env.getPosix("XDG_CONFIG_HOME")) |path|
        .{ path, "cellulator" }
    else if (zc.env.getPosix("HOME")) |path|
        .{ path, ".config/cellulator" }
    else
        return error.CouldNotDeterminePath;

    var buf: [4096]u8 = undefined;
    var path: std.ArrayListUnmanaged(u8) = .initBuffer(&buf);

    path.printBounded("{s}/{s}/themes/{s}/{s}{s}\x00", .{
        dir,
        subpath,
        ui_name,
        theme_name,
        extension,
    }) catch return error.NameTooLong;

    try zc.ui.applyTheme(path.items[0 .. path.items.len - 1 :0]);
}

fn put(zc: *ZC, dest: Rect, comptime adjust: Sheet.Adjust) !void {
    if (zc.yank) |yank| {
        if (!yank.eql(dest)) {
            try zc.currentSheet().copyRangeTo(yank, dest, adjust);
            zc.currentSheet().endUndoGroup();
        }
    }
}

fn undo(zc: *ZC) Oom!void {
    defer zc.resetCount();

    for (0..zc.getCount()) |_| {
        try zc.currentSheet().undo();
    }
}

fn redo(zc: *ZC) Oom!void {
    defer zc.resetCount();

    for (0..zc.getCount()) |_| {
        try zc.currentSheet().redo();
    }
}

pub fn anyCursorRange(zc: *const ZC) Rect {
    if (zc.mode == .visual or zc.mode == .select)
        return zc.visualRange();
    return .initSinglePos(zc.cursor);
}

fn visualRange(zc: *const ZC) Rect {
    assert(zc.mode == .visual or zc.mode == .select);
    return Rect.initNormalizePos(zc.cursor, zc.anchor);
}

pub fn deleteCell(zc: *ZC) Oom!void {
    assert(zc.mode != .visual);
    try zc.currentSheet().deleteCell(zc.cursor, .{});
    zc.currentSheet().endUndoGroup();
}

pub fn deleteCellRange(zc: *ZC, rect: Rect) Oom!void {
    try zc.currentSheet().deleteCellRange(rect, .{});
    zc.currentSheet().endUndoGroup();
}

pub fn setCursor(zc: *ZC, new_pos: Position) void {
    zc.prev_cursor = zc.cursor;
    zc.cursor = new_pos;
    // zc.clampScreenToCursor(); // TODO
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
pub fn setPrecision(zc: *ZC, column: Position.Int, new_precision: u8) Oom!void {
    try zc.currentSheet().setPrecision(column, new_precision, .{});
    zc.currentSheet().endUndoGroup();
}

pub fn incPrecision(zc: *ZC, column: Position.Int, count: u8) Oom!void {
    try zc.currentSheet().incPrecision(zc.ui, column, count, .{});
    zc.currentSheet().endUndoGroup();
}

pub fn decPrecision(zc: *ZC, column: Position.Int, count: u8) Oom!void {
    try zc.currentSheet().decPrecision(zc.ui, column, count, .{});
    zc.currentSheet().endUndoGroup();
}

pub inline fn cursorIncPrecision(zc: *ZC) Oom!void {
    const count: u8 = @intCast(@min(std.math.maxInt(u8), zc.getCount()));
    try zc.incPrecision(zc.cursor.x, count);
    zc.resetCount();
}

pub inline fn cursorDecPrecision(zc: *ZC) Oom!void {
    const count: u8 = @intCast(@min(std.math.maxInt(u8), zc.getCount()));
    try zc.decPrecision(zc.cursor.x, count);
    zc.resetCount();
}

pub fn incWidth(zc: *ZC, column: Position.Int, n: u8) Oom!void {
    try zc.currentSheet().incWidth(zc.ui, column, n, .{});
    zc.currentSheet().endUndoGroup();
}

pub fn decWidth(zc: *ZC, column: Position.Int, n: u8) Oom!void {
    try zc.currentSheet().decWidth(zc.ui, column, n, .{});
    zc.currentSheet().endUndoGroup();
}

pub inline fn cursorIncWidth(zc: *ZC) Oom!void {
    const count: u8 = @intCast(@min(std.math.maxInt(u8), zc.getCount()));
    try zc.incWidth(zc.cursor.x, count);
    zc.resetCount();
    // zc.clampScreenToCursorX(); // TODO
}

pub inline fn cursorDecWidth(zc: *ZC) Oom!void {
    const count: u8 = @intCast(@min(std.math.maxInt(u8), zc.getCount()));
    try zc.decWidth(zc.cursor.x, count);
    // zc.resetCount(); // TODO
}

pub fn expandWidthAtCursor(zc: *ZC) !void {
    const sheet = zc.currentSheet();
    if (!sheet.columnIsPopulated(zc.cursor.x)) return;
    try sheet.ensureUnusedUndoCapacity(1);

    const res = try sheet.cols.getOrPut(sheet.gpa, &.{zc.cursor.x});
    if (!res.found_existing) res.value_ptr.* = .{
        .width = zc.ui.defaultWidth(),
    };

    const handle = sheet.getColumnHandle(zc.cursor.x) orelse return;
    const col = sheet.cols.getValue(handle);
    const width_needed = zc.ui.widthNeededForColumn(zc, sheet, zc.cursor.x);

    std.log.debug("Width needed for {f}: {d}", .{
        Position.fmtColumnAddress(zc.cursor.x),
        width_needed,
    });

    const old_width = col.width;
    col.width = width_needed;
    sheet.pushUndo(.init(.set_column_width, .{
        .col = zc.cursor.x,
        .width = old_width,
    }), .{}) catch unreachable;

    sheet.endUndoGroup();
    // zc.clampScreenToCursorX();
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
    try zc.init(.none, t.allocator, t.io, t.environ, .{});
    defer zc.deinit();

    try t.expectEqual(Mode.normal, zc.mode);
    try t.expectEqual(Position{ .x = 0, .y = 0 }, zc.cursor);
}

test "Motions normal mode" {
    const t = std.testing;
    const max = std.math.maxInt(Position.Int);

    var zc: ZC = undefined;
    try zc.init(.none, t.allocator, t.io, t.environ, .{});
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
    try zc.init(.none, t.allocator, t.io, t.environ, .{});
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
fn testFile(gpa: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    var zc: ZC = undefined;
    try zc.init(.none, gpa, io, std.testing.environ, .{});
    defer zc.deinit();

    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var buf: [8192]u8 = undefined;
    var reader = file.reader(io, &buf);
    const bytes = try reader.interface.allocRemaining(gpa, .unlimited);
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
            std.debug.print("Error {t} at {s}:{d}\n", .{ err, path, line_number });
            has_errors = true;
        };
        try zc.updateCells();
    }
    if (has_errors) return error.Failed;
}

test "general.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/general.zc");
}

test "undo-redo.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/undo-redo.zc");
}

test "string.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/string.zc");
}

test "fill.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/fill.zc");
}

test "fill-expr.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/fill-expr.zc");
}

test "binary-serialize.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/binary-serialize.zc");
}

test "save-load.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/save-load.zc");
}

test "delete-cols.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/delete-cols.zc");
}

test "delete-rows.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/delete-rows.zc");
}

test "yank-put.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/yank-put.zc");
}

test "yank-put-adjust.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/yank-put-adjust.zc");
}

test "paste.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/paste.zc");
}

test "unary-plus-minus.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/unary-plus-minus.zc");
}

test "csv.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/csv.zc");
}

test "absolute-cell-references.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/absolute-cell-references.zc");
}

test "logic.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/logic.zc");
}

test "average.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/average.zc");
}

test "references.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/references.zc");
}

test "volatile.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/volatile.zc");
}

test "functions.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/functions.zc");
}

test "count.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/count.zc");
}

test "streams.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/streams.zc");
}

test "tuples.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/tuples.zc");
}

test "table.zc" {
    try testFile(std.testing.allocator, std.testing.io, "test/table.zc");
}

test "Invalid reference" {
    var zc: ZC = undefined;
    try zc.init(.none, std.testing.allocator, std.testing.io, std.testing.environ, .{});
    defer zc.deinit();

    try zc.parseCommand("let a0 = &10");
    try zc.updateCells();
}
