const std = @import("std");
const Ui = @import("Ui.zig");
const ZC = @import("ZC.zig");

const shovel = @import("shovel");

const Repl = @This();
const Term = shovel.Term;

term: Term,
last_cmd: ?[:0]const u8,

pub fn ui(repl: *Repl) Ui {
    return .{
        .ptr = repl,
        .vtable = &.{
            .run = run,
            .submitCommand = submitCommand,
            .theme_file_extension = "",
            .ui_name = "repl",
        },
    };
}

pub fn init(gpa: std.mem.Allocator, io: std.Io, env: std.process.Environ) !Repl {
    return .{
        .term = try .init(gpa, io, env, .{
            .truecolour = .check,
            .terminfo = .{
                .fallback = .@"xterm-256color",
                .fallback_mode = .last_resort,
            },
        }),
        .last_cmd = null,
    };
}

pub fn deinit(repl: *Repl, gpa: std.mem.Allocator) void {
    repl.term.deinit(gpa);
}

fn run(ptr: *anyopaque, zc: *ZC) u8 {
    const repl: *Repl = @ptrCast(@alignCast(ptr));
    defer repl.deinit(zc.allocator);

    repl.term.uncook(.{ .alt_screen = false, .hide_cursor = false }) catch return 1;

    while (zc.running) {
        if (!zc.mode.isCommandMode())
            zc.setMode(.command_insert);
        zc.updateCells() catch return 1;
        repl.render(zc) catch return 1;
        repl.handleInput(zc) catch return 1;
    }
    return 0;
}

fn render(repl: *Repl, zc: *ZC) !void {
    var buf: [8192]u8 = undefined;
    var ctx = try repl.term.getRenderContext(&buf);
    const w = &ctx.writer.interface;
    const left = zc.command.left();
    const right = zc.command.right();

    if (repl.last_cmd) |_| {
        repl.last_cmd = null;
        try w.writeAll("\r\n");
    }

    switch (zc.status.tag) {
        .none => {},
        .info, .warn, .err => {
            try w.writeAll(zc.status.msg.items);
            try w.writeAll("\r\n");
            zc.dismissStatusMessage();
        },
        .cmd_info, .cmd_err => {}, // TODO
    }

    try ctx.clearToBol();

    const c = zc.command.cursor;
    try ctx.writer.interface.print("\r{f} > ", .{zc.mode});
    if (c < left.len) {
        try ctx.writer.interface.writeAll(left[0..c]);
        try ctx.saveCursor();
        try ctx.writer.interface.writeAll(left[c..]);
        try ctx.writer.interface.writeAll(right);
    } else {
        try ctx.writer.interface.writeAll(left);
        try ctx.writer.interface.writeAll(right[0 .. c - left.len]);
        try ctx.saveCursor();
        try ctx.writer.interface.writeAll(right[c - left.len ..]);
    }
    try ctx.clearToEol();
    try ctx.restoreCursor();
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
    try repl.term.setCursorShape(w, cursor_shape);
    try ctx.done();
}

fn handleInput(repl: *Repl, zc: *ZC) !void {
    // TODO: Move most of this into the UI implementation.
    var buf: [8192]u8 = undefined;
    const slice = try repl.term.readInputSingleThreadedBlocking(&buf);

    try parse(&repl.term, slice, &zc.input_buf.writer);
    try zc.doInput();
}

/// Parses the raw terminal input in `bytes` into a readable format for keybindings, outputting
/// the results to the given writer.
fn parse(
    term: *shovel.Term,
    bytes: []const u8,
    w: *std.Io.Writer,
) !void {
    var iter = shovel.inputParser(bytes, term);

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

fn submitCommand(ptr: *anyopaque, cmd: [:0]const u8) void {
    const repl: *Repl = @ptrCast(@alignCast(ptr));
    repl.last_cmd = cmd;
}
