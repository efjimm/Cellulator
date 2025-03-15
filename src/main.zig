const std = @import("std");
const builtin = @import("builtin");

const ZC = @import("ZC.zig");

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

    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;

    const gpa, const is_debug = gpa: {
        if (@import("builtin").os.tag == .wasi) break :gpa .{ std.heap.wasm_allocator, false };
        break :gpa switch (builtin.mode) {
            .Debug, .ReleaseSafe => .{ debug_allocator.allocator(), true },
            .ReleaseFast, .ReleaseSmall => .{ std.heap.smp_allocator, false },
        };
    };
    defer if (is_debug) {
        _ = debug_allocator.deinit();
    };

    try zc.init(gpa, .{ .filepath = filepath, .ui = true });
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
