const std = @import("std");
const builtin = @import("builtin");

const zg = @import("zg");

pub const ZC = @import("zc").ZC;

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
    var filepath: ?[]const u8 = null;
    var iter = std.process.args();
    _ = iter.next();
    const iterations_str = iter.next() orelse return error.NotEnoughArguments;
    filepath = iter.next();

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

    try zc.init(gpa, .{ .filepath = filepath, .ui = false });
    defer zc.deinit();

    const iterations = try std.fmt.parseInt(u64, iterations_str, 0);
    for (0..iterations) |_|
        try zc.ui.render2(&zc);
}

pub const std_options: std.Options = .{
    .log_level = .err,
    .logFn = log,
};

pub fn log(
    comptime level: std.log.Level,
    comptime scope: @TypeOf(.EnumLiteral),
    comptime format: []const u8,
    args: anytype,
) void {
    _ = level; // autofix
    _ = scope; // autofix
    _ = format; // autofix
    _ = args; // autofix
    return;
}
