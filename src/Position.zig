const std = @import("std");
const assert = std.debug.assert;
const Lua = @import("zlua").Lua;

pub const Position = packed struct {
    pub const Int = u32;
    pub const HashInt = u64;

    const max = std.math.maxInt(Int);

    pub const max_str_len = std.fmt.count("{f}", .{Position.init(
        std.math.maxInt(u32),
        std.math.maxInt(u32),
    )});

    x: Int,
    y: Int,

    pub const origin: Position = .init(0, 0);

    pub fn init(x: Int, y: Int) Position {
        return .{ .x = x, .y = y };
    }

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

    pub const format = formatCellAddress;

    pub fn hash(position: Position) HashInt {
        return @as(HashInt, position.y) * (max + 1) + position.x;
    }

    pub fn eql(p1: Position, p2: Position) bool {
        return p1 == p2;
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

    /// Adds the values of two positions. Asserts that the values do not overflow.
    pub fn add(p1: Position, p2: Position) Position {
        return .{
            .x = p1.x + p2.x,
            .y = p1.y + p2.y,
        };
    }

    pub fn sub(p1: Position, p2: Position) Position {
        return .{
            .x = p1.x - p2.x,
            .y = p1.y - p2.y,
        };
    }

    pub fn diff(p1: Position, p2: Position) [2]i33 {
        return .{ @as(i33, p1.x) - p2.x, @as(i33, p1.y) - p2.y };
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

    pub fn fmtCellAddress(pos: Position) std.fmt.Formatter(formatCellAddress) {
        return .{ .data = pos };
    }

    pub fn formatCellAddress(pos: Position, writer: *std.io.Writer) !void {
        try writer.print("{f}{d}", .{
            fmtColumnAddress(pos.x),
            pos.y,
        });
    }

    pub fn fmtColumnAddress(index: u32) std.fmt.Formatter(u32, formatColumnAddress) {
        return .{ .data = index };
    }

    /// Writes the alphabetic bijective base-26 representation of the given number to the passed
    /// writer.
    pub fn formatColumnAddress(index: Int, writer: *std.io.Writer) !void {
        if (index < 26) {
            try writer.writeByte('A' + @as(u8, @intCast(index)));
            return;
        }

        var buf: [64]u8 = undefined;
        var fixed: std.io.Writer = .fixed(&buf);

        var i = @as(HashInt, index) + 1;
        while (i > 0) : (i /= 26) {
            i -= 1;
            const r: u8 = @intCast(i % 26);
            fixed.writeByte('A' + r) catch unreachable;
        }

        const slice = fixed.buffered();
        std.mem.reverse(u8, slice);
        _ = try writer.writeAll(slice);
    }

    pub fn columnAddressBuf(index: Int, buf: []u8) []u8 {
        var fixed: std.io.Writer = .fixed(buf);
        formatColumnAddress(index, &fixed) catch unreachable;
        return fixed.buffered();
    }

    pub const FromAddressError = error{
        InvalidCellAddress,
    };

    pub fn columnFromAddress(address: []const u8) FromAddressError!Int {
        assert(address.len > 0);
        if (!std.ascii.isAlphabetic(address[0]))
            return error.InvalidCellAddress;

        var ret: HashInt = 0;
        for (address) |c| {
            if (!std.ascii.isAlphabetic(c))
                break;
            ret = ret *| 26 +| (std.ascii.toUpper(c) - 'A' + 1);
        }

        return if (ret > @as(HashInt, max) + 1)
            error.InvalidCellAddress
        else
            @intCast(ret - 1);
    }

    pub fn fromAddress(address: []const u8) FromAddressError!Position {
        const letters_end = for (address, 0..) |c, i| {
            if (!std.ascii.isAlphabetic(c))
                break i;
        } else return error.InvalidCellAddress;

        if (letters_end == 0) return error.InvalidCellAddress;

        return .{
            .x = try columnFromAddress(address[0..letters_end]),
            .y = std.fmt.parseInt(Int, address[letters_end..], 0) catch
                return error.InvalidCellAddress,
        };
    }

    pub fn fromValidAddress(address: []const u8) Position {
        return fromAddress(address) catch unreachable;
    }

    pub const Rect = extern struct {
        /// Top left
        tl: Position,
        /// Bottom right
        br: Position,

        pub fn rect(r: Rect) Rect {
            return r;
        }

        pub fn init(tl_x: Int, tl_y: Int, br_x: Int, br_y: Int) Rect {
            return Rect{
                .tl = .{ .x = tl_x, .y = tl_y },
                .br = .{ .x = br_x, .y = br_y },
            };
        }

        pub fn initNormalize(x1: Int, y1: Int, x2: Int, y2: Int) Rect {
            return Rect{
                .tl = .{ .x = @min(x1, x2), .y = @min(y1, y2) },
                .br = .{ .x = @max(x1, x2), .y = @max(y1, y2) },
            };
        }

        pub fn initNormalizePos(p1: Position, p2: Position) Rect {
            return initNormalize(p1.x, p1.y, p2.x, p2.y);
        }

        pub fn initSingle(x: Int, y: Int) Rect {
            return Rect{
                .tl = .{ .x = x, .y = y },
                .br = .{ .x = x, .y = y },
            };
        }

        pub fn initPos(tl: Position, br: Position) Rect {
            return .{ .tl = tl, .br = br };
        }

        pub fn initSinglePos(p: Position) Rect {
            return initPos(p, p);
        }

        pub fn perimeter(r: Rect) u64 {
            return @as(u64, r.width()) * 2 + @as(u64, r.height() * 2);
        }

        pub fn overlapArea(r1: Rect, r2: Rect) u64 {
            const dx = std.math.sub(
                u64,
                @min(r1.br.x, r2.br.x),
                @max(r1.tl.x, r2.tl.x),
            ) catch 0;
            const dy = std.math.sub(
                u64,
                @min(r1.br.y, r2.br.y),
                @max(r1.tl.y, r2.tl.y),
            ) catch 0;

            return dx * dy;
        }

        pub fn format(range: Rect, writer: *std.io.Writer) !void {
            try writer.print("[{f} -> {f}]", .{ range.tl, range.br });
        }

        pub fn eql(r1: Rect, r2: Rect) bool {
            return r1.tl.x == r2.tl.x and r1.tl.y == r2.tl.y and
                r1.br.x == r2.br.x and r1.br.y == r2.br.y;
        }

        /// Returns true if `r1` contains `r2`.
        pub fn contains(r1: Rect, r2: Rect) bool {
            return r1.tl.x <= r2.tl.x and r1.tl.y <= r2.tl.y and
                r1.br.x >= r2.br.x and r1.br.y >= r2.br.y;
        }

        /// Returns true if `r1` intersects `r2`
        pub fn intersects(r1: Rect, r2: Rect) bool {
            return r1.tl.x <= r2.br.x and r1.br.x >= r2.tl.x and
                r1.tl.y <= r2.br.y and r1.br.y >= r2.tl.y;
        }

        pub fn initMax() Rect {
            return .{
                .tl = .{ .x = 0, .y = 0 },
                .br = .{ .x = std.math.maxInt(Int), .y = std.math.maxInt(Int) },
            };
        }

        // TODO: These functions overflow for ranges that cover the entire width or height of
        //       a sheet.
        pub fn height(r: Rect) Int {
            return r.br.y - r.tl.y + 1;
        }

        pub fn width(r: Rect) Int {
            return r.br.x - r.tl.x + 1;
        }

        pub fn height2(r: Rect) u33 {
            return @as(u33, r.br.y - r.tl.y) + 1;
        }

        pub fn width2(r: Rect) u33 {
            return @as(u33, r.br.x - r.tl.x) + 1;
        }

        pub fn zeroWidth(r: Rect) Int {
            return r.br.x - r.tl.x;
        }

        pub fn zeroHeight(r: Rect) Int {
            return r.br.y - r.tl.y;
        }

        pub fn area(r: Rect) HashInt {
            return @as(HashInt, r.width()) * r.height();
        }

        pub const Iterator = struct {
            range: Rect,
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

        pub fn iterator(range: Rect) Iterator {
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
            .{ Position{ .x = 1, .y = 1 }, max + 2 },
            .{ Position{ .x = 500, .y = 300 }, (max + 1) * 300 + 500 },
            .{ Position{ .x = 0, .y = 300 }, (max + 1) * 300 },
            .{ Position{ .x = max, .y = 0 }, max },
            .{ Position{ .x = 0, .y = max }, (max + 1) * max },
            .{ Position{ .x = max, .y = max }, std.math.maxInt(HashInt) },
        };

        for (tuples) |tuple| {
            try std.testing.expectEqual(tuple[1], tuple[0].hash());
        }
    }

    test "conversions" {
        const cases = .{
            .{ "A1", Position{ .y = 1, .x = 0 } },
            .{ "AA7865", Position{ .y = 7865, .x = 26 } },
            .{ "AAA1000", Position{ .y = 1000, .x = 702 } },
            .{ "MM50000", Position{ .y = 50000, .x = 350 } },
            .{ "ZZ0", Position{ .y = 0, .x = 701 } },
            .{ "AAAA0", Position{ .y = 0, .x = 18278 } },
            .{ "CRXO0", Position{ .y = 0, .x = 65534 } },
            .{ "CRXP0", Position{ .y = 0, .x = 65535 } },
            .{ "MWLQKWU0", Position{ .y = 0, .x = (1 << 32) - 2 } },
            .{ "MWLQKWV0", Position{ .y = 0, .x = (1 << 32) - 1 } },
        };

        inline for (cases) |data| {
            const string, const pos = data;
            try std.testing.expectEqual(pos, try Position.fromAddress(string));
            try std.testing.expectFmt(string, "{f}", .{pos});

            const len = for (string, 0..) |c, i| {
                if (c >= '0' and c <= '9') break i;
            } else unreachable;
            try std.testing.expectFmt(string[0..len], "{f}", .{fmtColumnAddress(pos.x)});
        }
    }
};
