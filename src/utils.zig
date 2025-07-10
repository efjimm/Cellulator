const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub fn enumFromEnum(E: type, a: anytype) E {
    return switch (a) {
        inline else => |t| @field(E, @tagName(t)),
    };
}

pub fn ptrToIoVec(ptr: anytype) std.posix.iovec_const {
    const p = @typeInfo(@TypeOf(ptr)).pointer;
    const bytes = blk: {
        if (p.size == .slice) break :blk std.mem.sliceAsBytes(ptr);
        comptime assert(p.size == .one);
        break :blk std.mem.asBytes(ptr);
    };
    return .{ .base = bytes.ptr, .len = bytes.len };
}

pub fn arrayListIoVec(list: anytype) std.posix.iovec_const {
    comptime assert(@typeInfo(@TypeOf(list)) == .pointer);
    return ptrToIoVec(list.items);
}

pub fn multiArrayListIoVec(
    comptime T: type,
    list: *std.MultiArrayList(T),
) MultiArrayListIoVecs(T) {
    var iovecs: MultiArrayListIoVecs(T) = undefined;
    const Field = std.MultiArrayList(T).Field;
    inline for (&iovecs, comptime std.enums.values(Field)) |*iovec, field| {
        iovec.* = ptrToIoVec(list.items(field));
    }

    return iovecs;
}

pub fn MultiArrayListIoVecs(comptime T: type) type {
    const fields = @typeInfo(T).@"struct".fields;
    return [fields.len]std.posix.iovec_const;
}

pub fn MultiArrayListIoVecsMut(comptime T: type) type {
    const fields = @typeInfo(T).@"struct".fields;
    return [fields.len]std.posix.iovec;
}

pub fn multiArrayListSliceIoVec(
    comptime T: type,
    slice: *std.MultiArrayList(T).Slice,
) MultiArrayListIoVecs(T) {
    var iovecs: MultiArrayListIoVecs(T) = undefined;
    const Field = std.MultiArrayList(T).Field;
    inline for (&iovecs, comptime std.enums.values(Field)) |*iovec, field| {
        iovec.* = ptrToIoVec(slice.items(field));
    }

    return iovecs;
}

pub fn prepArrayList(list: anytype, allocator: Allocator, len: u32) !std.posix.iovec {
    try list.ensureTotalCapacityPrecise(allocator, len);
    list.items.len = len;
    return @bitCast(arrayListIoVec(list));
}

pub fn prepMultiArrayList(
    comptime T: type,
    list: *std.MultiArrayList(T),
    allocator: Allocator,
    len: u32,
    cap: u32,
) !MultiArrayListIoVecsMut(T) {
    try list.setCapacity(allocator, cap);
    list.len = len;
    return @bitCast(multiArrayListIoVec(T, list));
}

pub fn prepMultiArrayListSlice(
    comptime T: type,
    list: anytype,
    allocator: Allocator,
    len: u32,
    cap: u32,
) !MultiArrayListIoVecsMut(T) {
    var m = list.toMultiArrayList();
    const ret = try prepMultiArrayList(T, &m, allocator, len, cap);
    list.* = m.slice();
    return ret;
}

/// Returns true if the passed type will coerce to []const u8.
/// Any of the following are considered strings:
/// ```
/// []const u8, [:S]const u8, *const [N]u8, *const [N:S]u8,
/// []u8, [:S]u8, *[:S]u8, *[N:S]u8.
/// ```
/// These types are not considered strings:
/// ```
/// u8, [N]u8, [*]const u8, [*:0]const u8,
/// [*]const [N]u8, []const u16, []const i8,
/// *const u8, ?[]const u8, ?*const [N]u8.
/// ```
pub fn isZigString(comptime T: type) bool {
    return comptime blk: {
        // Only pointer types can be strings, no optionals
        const info = @typeInfo(T);
        if (info != .pointer) break :blk false;

        const ptr = &info.pointer;
        // Check for CV qualifiers that would prevent coerction to []const u8
        if (ptr.is_volatile or ptr.is_allowzero) break :blk false;

        // If it's already a slice, simple check.
        if (ptr.size == .slice) {
            break :blk ptr.child == u8;
        }

        // Otherwise check if it's an array type that coerces to slice.
        if (ptr.size == .One) {
            const child = @typeInfo(ptr.child);
            if (child == .Array) {
                const arr = &child.array;
                break :blk arr.child == u8;
            }
        }

        break :blk false;
    };
}

pub fn dupeZ(comptime T: type, buf: anytype) [buf.len:0]T {
    var ret: [buf.len:0]T = undefined;
    @memcpy(&ret, &buf);
    ret[ret.len] = 0;
    return ret;
}

pub fn packDoubleCp(cp1: u21, cp2: u21) [7]u8 {
    var buf: [7]u8 align(4) = undefined;
    @memcpy(buf[0..3], std.mem.asBytes(&cp1)[0..3]);
    buf[3] = 0;
    @memcpy(buf[4..7], std.mem.asBytes(&cp2)[0..3]);
    return buf;
}

pub fn unpackDoubleCp(buf: []align(4) const u8) struct { u21, u21 } {
    return .{
        @as(*const u21, @ptrCast(buf[0..3])).*,
        @as(*const u21, @ptrCast(buf[4..7])).*,
    };
}

pub fn wordIterator(string: []const u8) WordIterator {
    return .{ .string = string };
}

/// An iterator over the words in a string. A word is defined as a continuous sequence of
/// non-whitespace characters, or a sequence of characters wrapped in quotes. If a word is a quoted
/// sequence of characters, the quotes are retained in the returned string.
pub const WordIterator = struct {
    string: []const u8,
    index: usize = 0,

    pub fn init(string: []const u8) WordIterator {
        return WordIterator{
            .string = std.mem.trim(u8, string, &std.ascii.whitespace),
        };
    }

    pub fn next(self: *WordIterator) ?[]const u8 {
        if (self.index >= self.string.len)
            return null;

        const str = std.mem.trimLeft(u8, self.string[self.index..], &std.ascii.whitespace);
        self.index = @intFromPtr(str.ptr) - @intFromPtr(self.string.ptr);

        if (str.len == 0)
            return null;

        const QuoteState = enum(u2) {
            none,
            single,
            double,
            backtick,

            fn fromChar(char: u8) @This() {
                return switch (char) {
                    '\'' => .single,
                    '"' => .double,
                    '`' => .backtick,
                    else => .none,
                };
            }
        };

        var quote_state: QuoteState = .none;
        var quote_index: usize = 0;
        var possible_comment_start = false;

        const end_index = for (str, 0..) |c, i| {
            if (std.ascii.isWhitespace(c)) {
                if (quote_state == .none)
                    break i;

                quote_index = i;
            }

            if (c == '-') {
                if (possible_comment_start) break i - 1;
                possible_comment_start = true;
            } else {
                possible_comment_start = false;
            }

            const new_quote_state = QuoteState.fromChar(c);

            if (quote_state == .none) {
                quote_state = new_quote_state;
            } else if (new_quote_state == quote_state) {
                quote_state = .none;
            }
        } else str.len;

        // Quote was not terminated
        if (quote_state != .none) {
            self.index += quote_index;
            return str[0..quote_index];
        }

        self.index += end_index + 1;
        return trimMatchingQuotes(str[0..end_index]);
    }

    pub fn reset(self: *WordIterator) void {
        self.index = 0;
    }
};

pub fn isQuote(c: u8) bool {
    return c == '`' or c == '"' or c == '\'';
}

pub fn trimMatchingQuotes(string: []const u8) []const u8 {
    if (string.len == 0)
        return string;

    var str = string;

    while (str.len >= 2 and isQuote(str[0]) and str[0] == str[str.len - 1]) {
        str = str[1 .. str.len - 1];
    }

    return str;
}

/// Given a list, sets the length to `new_length` and moves each old element to a new index
/// calculated from the function `ctx.newIndex`. Sets every other index to `empty_value`.
pub fn padList(
    comptime T: type,
    list: anytype,
    empty_value: T,
    new_length: usize,
    ctx: anytype,
) void {
    const old_len = list.items.len;
    var i = old_len;
    assert(new_length >= old_len);
    list.items.len = new_length;
    @memset(list.items[old_len..], empty_value);
    while (i > 0) {
        i -= 1;
        const value = list.items[i];
        const new_index = ctx.newIndex(value);
        assert(new_index >= i);
        list.items[i] = empty_value;
        list.items[new_index] = value;
    }
}
