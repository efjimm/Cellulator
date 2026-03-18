const std = @import("std");
const builtin = @import("builtin");

pub const ZC = @import("ZC.zig");

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

pub fn main(init: std.process.Init.Minimal) !void {
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

    for (init.args.vector[1..]) |ptr| {
        const arg = std.mem.span(ptr);
        if (arg.len == 0) continue;

        if (allow_flags and arg[0] == '-') {
            if (arg.len == 2 and arg[1] == '-') {
                allow_flags = false;
            }
            // No flags are implemented yet
        } else {
            try filepaths.append(gpa, arg);
        }
    }

    var threaded: std.Io.Threaded = .init_single_threaded;
    defer threaded.deinit();
    const io = threaded.io();
    global_io = io;

    if (logfile_path) |path| {
        logfile = try std.Io.Dir.cwd().createFile(io, path, .{});
    }
    defer if (use_logfile) {
        logfile.close(io);
    };

    try initUnicodeData(gpa);
    defer if (is_debug) deinitUnicodeData(gpa);

    try zc.init(gpa, io, init.environ, .{ .filepaths = filepaths.items, .ui = true });
    defer zc.deinit();

    try zc.run();
}

fn panicFn(msg: []const u8, ret_addr: ?usize) noreturn {
    @branchHint(.cold);
    // TODO: Ui interface
    zc.ui.?.term.cook() catch {};
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
