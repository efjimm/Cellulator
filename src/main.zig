const std = @import("std");
const builtin = @import("builtin");

pub const ZC = @import("ZC.zig");

const log_level = @import("build").log_level;
const logfile_path = @import("build").logfile_path;
const use_logfile = logfile_path != null;
var logfile: if (use_logfile) std.fs.File else void = undefined;

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

pub fn main() !void {
    if (logfile_path) |path| {
        logfile = try std.fs.cwd().createFile(path, .{});
    }
    defer if (use_logfile) {
        logfile.close();
    };

    var filepath: ?[]const u8 = null;
    var iter = std.process.args();
    _ = iter.next();
    while (iter.next()) |arg| {
        if (arg.len == 0) continue;

        switch (arg[0]) {
            '-' => {},
            else => {
                if (filepath) |_| {
                    return error.InvalidArguments;
                }
                filepath = arg;
            },
        }
    }

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

    const gpa, const is_debug = gpa: {
        if (@import("builtin").os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer _ = if (is_debug) debug_allocator.deinit();

    try initUnicodeData(gpa);
    defer if (is_debug) deinitUnicodeData(gpa);

    try zc.init(gpa, .{ .filepath = filepath, .ui = true });
    defer zc.deinit();

    try zc.run();
}

fn panicFn(msg: []const u8, ret_addr: ?usize) noreturn {
    @branchHint(.cold);
    zc.ui.term.cook() catch {};
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
    var writer = logfile.writerStreaming(&buf);
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
