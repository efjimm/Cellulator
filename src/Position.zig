const std = @import("std");
const assert = std.debug.assert;
const Lua = @import("ziglua").Lua;

pub const Position = extern struct {
    pub const Int = u32;
    pub const HashInt = u64;
    const MAX = std.math.maxInt(Int);
    pub const max_str_len = blk: {
        var buf: [64]u8 = undefined;
        const slice = columnAddressBuf(std.math.maxInt(Int), &buf);
        break :blk slice.len;
    };

    x: Int = 0,
    y: Int = 0,

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

    pub fn hash(position: Position) HashInt {
        return @as(HashInt, position.y) * (MAX + 1) + position.x;
    }

    pub fn eql(p1: Position, p2: Position) bool {
        return @as(HashInt, @bitCast(p1)) == @as(HashInt, @bitCast(p2));
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

    pub fn min(p1: Position, p2: Position) Position {
        return .{
            .x = @min(p1.x, p2.x),
            .y = @min(p1.y, p2.y),
        };
    }

    pub fn max(p1: Position, p2: Position) Position {
        return .{
            .x = @max(p1.x, p2.x),
            .y = @max(p1.y, p2.y),
        };
    }

    pub fn anyMatch(p1: Position, p2: Position) bool {
        return p1.x == p2.x or p1.y == p2.y;
    }

    pub fn area(pos1: Position, pos2: Position) HashInt {
        const start = topLeft(pos1, pos2);
        const end = bottomRight(pos1, pos2);

        return (@as(HashInt, end.x) + 1 - start.x) * (@as(HashInt, end.y) + 1 - start.y);
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
    pub fn writeColumnAddress(index: Int, writer: anytype) @TypeOf(writer).Error!void {
        if (index < 26) {
            try writer.writeByte('A' + @as(u8, @intCast(index)));
            return;
        }

        var buf: [max_str_len]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const bufwriter = stream.writer();

        var i = @as(HashInt, index) + 1;
        while (i > 0) : (i /= 26) {
            i -= 1;
            const r: u8 = @intCast(i % 26);
            bufwriter.writeByte('A' + r) catch unreachable;
        }

        const slice = stream.getWritten();
        std.mem.reverse(u8, slice);
        _ = try writer.writeAll(slice);
    }

    pub fn columnAddressBuf(index: Int, buf: []u8) []u8 {
        if (index < 26) {
            std.debug.assert(buf.len >= 1);
            buf[0] = 'A' + @as(u8, @intCast(index));
            return buf[0..1];
        }

        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        var i = @as(HashInt, index) + 1;
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

    pub fn columnFromAddress(address: []const u8) FromAddressError!Int {
        assert(address.len > 0);

        var ret: HashInt = 0;
        for (address) |c| {
            if (!std.ascii.isAlphabetic(c))
                break;
            ret = ret *| 26 +| (std.ascii.toUpper(c) - 'A' + 1);
        }

        return if (ret > @as(HashInt, MAX) + 1) error.Overflow else @intCast(ret - 1);
    }

    pub fn fromAddress(address: []const u8) FromAddressError!Position {
        const letters_end = for (address, 0..) |c, i| {
            if (!std.ascii.isAlphabetic(c))
                break i;
        } else unreachable;

        if (letters_end == 0) return error.InvalidCellAddress;

        return .{
            .x = try columnFromAddress(address[0..letters_end]),
            .y = std.fmt.parseInt(Int, address[letters_end..], 0) catch |err| switch (err) {
                error.Overflow => return error.Overflow,
                error.InvalidCharacter => return error.InvalidCellAddress,
            },
        };
    }

    pub const Range = extern struct {
        /// Top left
        tl: Position,
        /// Bottom right
        br: Position,

        pub fn init(tl_x: Int, tl_y: Int, br_x: Int, br_y: Int) Range {
            return Range{
                .tl = .{ .x = tl_x, .y = tl_y },
                .br = .{ .x = br_x, .y = br_y },
            };
        }

        pub fn initNormalize(x1: Int, y1: Int, x2: Int, y2: Int) Range {
            return Range{
                .tl = .{ .x = @min(x1, x2), .y = @min(y1, y2) },
                .br = .{ .x = @max(x1, x2), .y = @max(y1, y2) },
            };
        }

        pub fn initNormalizePos(p1: Position, p2: Position) Range {
            return initNormalize(p1.x, p1.y, p2.x, p2.y);
        }

        pub fn initSingle(x: Int, y: Int) Range {
            return Range{
                .tl = .{ .x = x, .y = y },
                .br = .{ .x = x, .y = y },
            };
        }

        pub fn initPos(tl: Position, br: Position) Range {
            return .{ .tl = tl, .br = br };
        }

        pub fn initSinglePos(p: Position) Range {
            return initPos(p, p);
        }

        pub fn format(
            range: Range,
            comptime _: []const u8,
            _: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            try writer.print("[{} -> {}]", .{ range.tl, range.br });
        }

        /// Removes all positions in `m` from `target`, returning 0-4 new ranges, or `null` if
        /// `m` does not intersect `target`.
        pub fn mask(
            target: Range,
            m: Range,
        ) ?std.BoundedArray(Range, 4) {
            if (!m.intersects(target)) return null;

            var ret: std.BoundedArray(Range, 4) = .{};

            // North
            if (m.tl.y > target.tl.y) {
                ret.appendAssumeCapacity(.{
                    .tl = .{ .x = @max(target.tl.x, m.tl.x), .y = target.tl.y },
                    .br = .{ .x = @min(target.br.x, m.br.x), .y = m.tl.y - 1 },
                });
            }

            // West
            if (m.tl.x > target.tl.x) {
                ret.appendAssumeCapacity(.{
                    .tl = .{ .x = target.tl.x, .y = target.tl.y },
                    .br = .{ .x = m.tl.x - 1, .y = target.br.y },
                });
            }

            // South
            if (m.br.y < target.br.y) {
                ret.appendAssumeCapacity(.{
                    .tl = .{ .x = @max(target.tl.x, m.tl.x), .y = m.br.y + 1 },
                    .br = .{ .x = @min(target.br.x, m.br.x), .y = target.br.y },
                });
            }

            // East
            if (m.br.x < target.br.x) {
                ret.appendAssumeCapacity(.{
                    .tl = .{ .x = m.br.x + 1, .y = target.tl.y },
                    .br = .{ .x = target.br.x, .y = target.br.y },
                });
            }

            return if (ret.len > 0) ret else null;
        }

        pub fn eql(r1: Range, r2: Range) bool {
            return r1.tl.x == r2.tl.x and r1.tl.y == r2.tl.y and
                r1.br.x == r2.br.x and r1.br.y == r2.br.y;
        }

        /// Returns true if `r1` contains `r2`.
        pub fn contains(r1: Range, r2: Range) bool {
            return r1.tl.x <= r2.tl.x and r1.tl.y <= r2.tl.y and
                r1.br.x >= r2.br.x and r1.br.y >= r2.br.y;
        }

        /// Returns true if `r1` intersects `r2`
        pub fn intersects(r1: Range, r2: Range) bool {
            return r1.tl.x <= r2.br.x and r1.br.x >= r2.tl.x and
                r1.tl.y <= r2.br.y and r1.br.y >= r2.tl.y;
        }

        pub fn initMax() Range {
            return .{
                .tl = .{ .x = 0, .y = 0 },
                .br = .{ .x = std.math.maxInt(Int), .y = std.math.maxInt(Int) },
            };
        }

        pub fn merge(r1: Range, r2: Range) Range {
            return .{
                .tl = Position.min(r1.tl, r2.tl),
                .br = Position.max(r1.br, r2.br),
            };
        }

        pub fn height(r: Range) Int {
            return r.br.y - r.tl.y;
        }

        pub fn width(r: Range) Int {
            return r.br.x - r.tl.x;
        }

        pub fn area(r: Range) HashInt {
            return @as(HashInt, r.width()) * r.height();
        }

        pub const Iterator = struct {
            range: Range,
            x: Int,
            y: Int,

            pub fn next(it: *Iterator) ?Position {
                if (it.y > it.range.br.y) return null;

                const pos = Position{
                    .x = @intCast(it.x),
                    .y = @intCast(it.y),
                };

                if (it.x >= it.range.br.x) {
                    it.y += 1;
                    it.x = it.range.tl.x;
                } else {
                    it.x += 1;
                }
                return pos;
            }

            pub fn reset(it: *Iterator) void {
                it.x = it.range.tl.x;
                it.y = it.range.tl.y;
            }
        };

        pub fn iterator(range: Range) Iterator {
            return .{
                .range = range,
                .x = range.tl.x,
                .y = range.tl.y,
            };
        }
    };

    test hash {
        const tuples = [_]struct { Position, HashInt }{
            .{ Position{ .x = 0, .y = 0 }, 0 },
            .{ Position{ .x = 1, .y = 0 }, 1 },
            .{ Position{ .x = 1, .y = 1 }, MAX + 2 },
            .{ Position{ .x = 500, .y = 300 }, (MAX + 1) * 300 + 500 },
            .{ Position{ .x = 0, .y = 300 }, (MAX + 1) * 300 },
            .{ Position{ .x = MAX, .y = 0 }, MAX },
            .{ Position{ .x = 0, .y = MAX }, (MAX + 1) * MAX },
            .{ Position{ .x = MAX, .y = MAX }, std.math.maxInt(HashInt) },
        };

        for (tuples) |tuple| {
            try std.testing.expectEqual(tuple[1], tuple[0].hash());
        }
    }

    test fromAddress {
        const data = .{
            .{ "A1", Position{ .y = 1, .x = 0 } },
            .{ "AA7865", Position{ .y = 7865, .x = 26 } },
            .{ "AAA1000", Position{ .y = 1000, .x = 702 } },
            .{ "MM50000", Position{ .y = 50000, .x = 350 } },
            .{ "ZZ0", Position{ .y = 0, .x = 701 } },
            .{ "AAAA0", Position{ .y = 0, .x = 18278 } },
            .{ "CRXO0", Position{ .y = 0, .x = 65534 } },
            .{ "CRXP0", Position{ .y = 0, .x = 65535 } },
            .{ "MWLQKWU0", Position{ .y = 0, .x = std.math.maxInt(u32) - 1 } },
            .{ "MWLQKWV0", Position{ .y = 0, .x = std.math.maxInt(u32) } },
        };

        inline for (data) |tuple| {
            try std.testing.expectEqual(tuple[1], try Position.fromAddress(tuple[0]));
        }
    }

    test columnAddressBuf {
        const t = std.testing;
        var buf: [max_str_len]u8 = undefined;

        try t.expectEqualStrings("A", Position.columnAddressBuf(0, &buf));
        try t.expectEqualStrings("AA", Position.columnAddressBuf(26, &buf));
        try t.expectEqualStrings("AAA", Position.columnAddressBuf(702, &buf));
        try t.expectEqualStrings("AAAA", Position.columnAddressBuf(18278, &buf));
        try t.expectEqualStrings("CRXP", Position.columnAddressBuf(std.math.maxInt(u16), &buf));
        try t.expectEqualStrings("MWLQKWU", Position.columnAddressBuf(std.math.maxInt(u32) - 1, &buf));
        try t.expectEqualStrings("MWLQKWV", Position.columnAddressBuf(std.math.maxInt(u32), &buf));
    }
};
