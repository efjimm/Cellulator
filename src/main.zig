const std = @import("std");
const builtin = @import("builtin");

const spoon = @import("spoon");
const Sheet = @import("Sheet.zig");
const Position = @import("Position.zig").Position;
const Tui = @import("Tui.zig");
const ZC = @import("ZC.zig");

const Allocator = std.mem.Allocator;

// TODO: Move this to build.zig
const use_logfile = builtin.mode == .Debug;

var zc: ZC = undefined;
var logfile: if (use_logfile) std.fs.File else void = undefined;

pub fn main() !void {
    if (use_logfile) {
        logfile = try std.fs.cwd().createFile("log.txt", .{});
    }
    defer {
        if (use_logfile) {
            logfile.close();
        }
    }

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

    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const a = gpa.allocator();

    // const a = std.heap.c_allocator;

    try zc.init(a, .{ .filepath = filepath, .ui = true });
    defer zc.deinit();

    try zc.run();
}

fn panic(msg: []const u8, ret_addr: ?usize) noreturn {
    @branchHint(.cold);
    zc.tui.term.cook() catch {};
    std.debug.defaultPanic(msg, ret_addr);
}

pub const Panic = std.debug.FullPanic(panic);

pub const std_options: std.Options = if (use_logfile) .{
    .log_level = .debug,
    .logFn = log,
} else .{};

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    const writer = logfile.writer();
    writer.print("[{s}] {s}: ", .{ @tagName(scope), @tagName(level) }) catch {};
    writer.print(format, args) catch {};
    writer.writeByte('\n') catch {};
}

// Reference all tests in other modules
test {
    if (comptime builtin.is_test) {
        std.testing.refAllDecls(ZC);
    }
}
