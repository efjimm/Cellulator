// TODO: Use u32 for coordinates to increase the number of cells
const std = @import("std");
const assert = std.debug.assert;
const Lua = @import("ziglua").Lua;

const Position = @This();
pub const MAX = std.math.maxInt(u16);

x: u16 = 0,
y: u16 = 0,

/// Pushes the string representation of `pos` to the stack of the given Lua
/// state. Also pushes a table containing the `x` and `y` values of `pos`.
pub fn toLua(pos: Position, state: *Lua) !i32 {
    try state.checkStack(3);
    state.createTable(0, 2);
    state.setMetatableRegistry("position");
    state.pushInteger(pos.x);
    state.setField(-2, "x");
    state.pushInteger(pos.y);
    state.setField(-2, "y");
    return 1;
}

pub fn format(
    pos: Position,
    comptime _: []const u8,
    _: std.fmt.FormatOptions,
    writer: anytype,
) !void {
    try pos.writeCellAddress(writer);
}

pub fn hash(position: Position) u32 {
    return @as(u32, position.y) * (MAX + 1) + position.x;
}

pub fn topLeft(pos1: Position, pos2: Position) Position {
    return .{
        .x = @min(pos1.x, pos2.x),
        .y = @min(pos1.y, pos2.y),
    };
}

pub fn bottomRight(pos1: Position, pos2: Position) Position {
    return .{
        .x = @max(pos1.x, pos2.x),
        .y = @max(pos1.y, pos2.y),
    };
}

pub fn area(pos1: Position, pos2: Position) u32 {
    const start = topLeft(pos1, pos2);
    const end = bottomRight(pos1, pos2);

    return (@as(u32, end.x) + 1 - start.x) * (@as(u32, end.y) + 1 - start.y);
}

pub fn intersects(pos: Position, corner1: Position, corner2: Position) bool {
    const tl = topLeft(corner1, corner2);
    const br = bottomRight(corner1, corner2);

    return pos.y >= tl.y and pos.y <= br.y and pos.x >= tl.x and pos.x <= br.x;
}

/// Writes the cell address of this position to the given writer.
pub fn writeCellAddress(pos: Position, writer: anytype) @TypeOf(writer).Error!void {
    try writeColumnAddress(pos.x, writer);
    try writer.print("{d}", .{pos.y});
}

/// Writes the alphabetic bijective base-26 representation of the given number to the passed
/// writer.
pub fn writeColumnAddress(index: u16, writer: anytype) @TypeOf(writer).Error!void {
    if (index < 26) {
        try writer.writeByte('A' + @as(u8, @intCast(index)));
        return;
    }

    // Max value is 'CRXP'
    var buf: [4]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const bufwriter = stream.writer();

    var i = @as(u32, index) + 1;
    while (i > 0) : (i /= 26) {
        i -= 1;
        const r: u8 = @intCast(i % 26);
        bufwriter.writeByte('A' + r) catch unreachable;
    }

    const slice = stream.getWritten();
    std.mem.reverse(u8, slice);
    _ = try writer.writeAll(slice);
}

pub fn columnAddressBuf(index: u16, buf: []u8) []u8 {
    if (index < 26) {
        std.debug.assert(buf.len >= 1);
        buf[0] = 'A' + @as(u8, @intCast(index));
        return buf[0..1];
    }

    var stream = std.io.fixedBufferStream(buf);
    const writer = stream.writer();

    var i = @as(u32, index) + 1;
    while (i > 0) : (i /= 26) {
        i -= 1;
        const r: u8 = @intCast(i % 26);
        writer.writeByte('A' + r) catch break;
    }

    const slice = stream.getWritten();
    std.mem.reverse(u8, slice);
    return slice;
}

pub const FromAddressError = error{
    Overflow,
    InvalidCellAddress,
};

pub fn columnFromAddress(address: []const u8) FromAddressError!u16 {
    assert(address.len > 0);

    var ret: u32 = 0;
    for (address) |c| {
        if (!std.ascii.isAlphabetic(c))
            break;
        ret = ret *| 26 +| (std.ascii.toUpper(c) - 'A' + 1);
    }

    return if (ret > @as(u32, MAX) + 1) error.Overflow else @intCast(ret - 1);
}

pub fn fromAddress(address: []const u8) FromAddressError!Position {
    const letters_end = for (address, 0..) |c, i| {
        if (!std.ascii.isAlphabetic(c))
            break i;
    } else unreachable;

    if (letters_end == 0) return error.InvalidCellAddress;

    return .{
        .x = try columnFromAddress(address[0..letters_end]),
        .y = std.fmt.parseInt(u16, address[letters_end..], 0) catch |err| switch (err) {
            error.Overflow => return error.Overflow,
            error.InvalidCharacter => return error.InvalidCellAddress,
        },
    };
}

test hash {
    const tuples = [_]struct { Position, u32 }{
        .{ Position{ .x = 0, .y = 0 }, 0 },
        .{ Position{ .x = 1, .y = 0 }, 1 },
        .{ Position{ .x = 1, .y = 1 }, MAX + 2 },
        .{ Position{ .x = 500, .y = 300 }, (MAX + 1) * 300 + 500 },
        .{ Position{ .x = 0, .y = 300 }, (MAX + 1) * 300 },
        .{ Position{ .x = MAX, .y = 0 }, MAX },
        .{ Position{ .x = 0, .y = MAX }, (MAX + 1) * MAX },
        .{ Position{ .x = MAX, .y = MAX }, std.math.maxInt(u32) },
    };

    for (tuples) |tuple| {
        try std.testing.expectEqual(tuple[1], tuple[0].hash());
    }
}

test fromAddress {
    const tuples = .{
        .{ "A1", Position{ .y = 1, .x = 0 } },
        .{ "AA7865", Position{ .y = 7865, .x = 26 } },
        .{ "AAA1000", Position{ .y = 1000, .x = 702 } },
        .{ "MM50000", Position{ .y = 50000, .x = 350 } },
        .{ "ZZ0", Position{ .y = 0, .x = 701 } },
        .{ "AAAA0", Position{ .y = 0, .x = 18278 } },
        .{ "CRXO0", Position{ .y = 0, .x = 65534 } },
        .{ "CRXP0", Position{ .y = 0, .x = 65535 } },
    };

    inline for (tuples) |tuple| {
        try std.testing.expectEqual(tuple[1], try Position.fromAddress(tuple[0]));
    }
}
