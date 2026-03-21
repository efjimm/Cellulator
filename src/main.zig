const std = @import("std");
const builtin = @import("builtin");

const ZC = @import("ZC.zig");
const Tui = @import("Tui.zig");
const Repl = @import("Repl.zig");
const Ui = @import("Ui.zig");

const log_level = @import("build").log_level;
const logfile_path = @import("build").logfile_path;
const use_logfile = logfile_path != null;
var logfile: if (use_logfile) std.Io.File else void = undefined;

const zg = @import("zg");

const unicode_data: []const zg.UnicodeData = &.{
    .graphemes,
    .display_width,
};

pub fn initUnicodeData(allocator: std.mem.Allocator) !void {
    try zg.initData(allocator, unicode_data);
}

pub fn deinitUnicodeData(allocator: std.mem.Allocator) void {
    zg.deinitData(allocator, unicode_data);
}

var zc: ZC = undefined;
var global_io: std.Io = undefined;

const UiType = enum {
    tui,
    repl,
};

pub fn main(init: std.process.Init.Minimal) !u8 {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

    const gpa, const is_debug = gpa: {
        if (@import("builtin").os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer _ = if (is_debug) debug_allocator.deinit();

    var filepaths: std.ArrayList([]const u8) = .empty;
    defer filepaths.deinit(gpa);
    var allow_flags = true;

    var ui_type: UiType = .tui;

    for (init.args.vector[1..]) |ptr| {
        const arg = std.mem.span(ptr);
        if (arg.len == 0) continue;

        if (allow_flags and arg[0] == '-') {
            if (arg.len == 2 and arg[1] == '-') {
                allow_flags = false;
            } else if (std.mem.eql(u8, arg, "--repl")) {
                ui_type = .repl;
            }
        } else {
            try filepaths.append(gpa, arg);
        }
    }

    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();
    global_io = io;

    if (logfile_path) |path|
        logfile = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer if (use_logfile) logfile.close(io);

    try initUnicodeData(gpa);
    defer deinitUnicodeData(gpa);

    switch (ui_type) {
        .tui => {
            var tui: Tui = try .init(gpa, io, init.environ);
            try tui.uncook();
            return try run(tui.ui(), gpa, io, init.environ, filepaths.items);
        },
        .repl => {
            var repl = try @import("Repl.zig").init(gpa, io, init.environ);
            return try run(repl.ui(), gpa, io, init.environ, filepaths.items);
        },
    }
}

fn run(
    ui: Ui,
    gpa: std.mem.Allocator,
    io: std.Io,
    env: std.process.Environ,
    filepaths: []const []const u8,
) !u8 {
    try zc.init(ui, gpa, io, env, .{ .filepaths = filepaths });
    defer zc.deinit();

    const exit_code = zc.run();
    if (builtin.mode == .Debug) return exit_code;
    std.process.exit(exit_code);
}

fn panicFn(msg: []const u8, ret_addr: ?usize) noreturn {
    @branchHint(.cold);
    std.debug.defaultPanic(msg, ret_addr);
}

pub const panic = std.debug.FullPanic(panicFn);

pub const std_options: std.Options = .{
    .log_level = @field(std.log.Level, @tagName(log_level)),
    .logFn = log,
};

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    if (!use_logfile) return;
    switch (scope) {
        .shovel_perf => return,
        else => {},
    }
    var buf: [1024]u8 = undefined;
    var writer = logfile.writerStreaming(global_io, &buf);
    writer.interface.print("[{s}] {s}: ", .{ @tagName(scope), @tagName(level) }) catch {};
    writer.interface.print(format, args) catch {};
    writer.interface.writeByte('\n') catch {};
    writer.interface.flush() catch {};
}

// Reference all tests in other modules
test {
    std.testing.refAllDecls(ZC);
    std.testing.refAllDecls(@import("gap_buffer.zig"));
}
