const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// Provides an `eql` method for `deduplicate` that works with any types supporting the `==`
/// operator.
pub const DeduplicateSimpleContext = struct {
    pub fn eql(_: @This(), a: anytype, b: anytype) bool {
        return a == b;
    }
};

pub fn basenamePosix(path: []const u8) []const u8 {
    if (path.len == 0)
        return path[path.len..];

    var end_index: usize = path.len - 1;
    while (path[end_index] == '/') {
        if (end_index == 0)
            return path[path.len..];
        end_index -= 1;
    }
    var start_index: usize = end_index;
    end_index += 1;
    while (path[start_index] != '/') {
        if (start_index == 0)
            return path[0..end_index];
        start_index -= 1;
    }

    return path[start_index + 1 .. end_index];
}

/// Collapse consecutive duplicate elements into one entry (the last one.)
///
/// `context` should provide a method with signature
/// `fn eql(@TypeOf(context), a: T, b:T) bool`.
pub fn collapseRepeats(T: type, items: []T, context: anytype) usize {
    var i: usize = 0;
    var copyback: usize = 0;

    // Find the first duplicate
    while (i + 1 < items.len) : (i += 1) {
        if (context.eql(items[i], items[i + 1])) break;
    }

    while (i + 1 < items.len) : (i += 1) {
        items[i - copyback] = items[i];

        if (context.eql(items[i], items[i + 1])) {
            copyback += 1;
        }
    }
    items[i - copyback] = items[i];
    return items.len - copyback;
}

test collapseRepeats {
    var items = [_]u8{ 1, 1, 2, 3, 3, 4, 4, 4, 4, 5, 7, 7 };
    const len = collapseRepeats(u8, &items, DeduplicateSimpleContext{});
    const slice = items[0..len];
    const expected = &[_]u8{ 1, 2, 3, 4, 5, 7 };
    try std.testing.expectEqualSlices(u8, expected, slice);
}

pub fn enumFromEnum(E: type, a: anytype) E {
    return switch (a) {
        inline else => |t| @field(E, @tagName(t)),
    };
}

pub fn ptrToIoVec(ptr: anytype) [1][]u8 {
    const p = @typeInfo(@TypeOf(ptr)).pointer;
    const bytes = blk: {
        if (p.size == .slice) break :blk std.mem.sliceAsBytes(ptr);
        comptime assert(p.size == .one);
        break :blk std.mem.asBytes(ptr);
    };
    return .{@constCast(bytes)};
}

pub fn multiArrayListIoVec(
    list: anytype,
) MultiArrayListIoVecs(@TypeOf(list)) {
    var slice = list.slice();
    return multiArrayListSliceIoVec(&slice);
}

pub fn MultiArrayListIoVecs(T: type) type {
    return [@typeInfo(MultiArrayListField(T)).@"enum".fields.len][]u8;
}

fn MultiArrayListField(T: type) type {
    const get_fn = @field(std.meta.Child(T), "items");
    return @typeInfo(@TypeOf(get_fn)).@"fn".params[1].type.?;
}

pub fn multiArrayListSliceIoVec(
    slice: anytype,
) MultiArrayListIoVecs(@TypeOf(slice)) {
    const Field = MultiArrayListField(@TypeOf(slice));
    const len = @typeInfo(Field).@"enum".fields.len;
    var iovecs: [len][]u8 = undefined;
    inline for (&iovecs, comptime std.enums.values(Field)) |*iovec, field| {
        iovec.* = ptrToIoVec(slice.items(field))[0];
    }

    return iovecs;
}

pub fn setAndExpandCapacity(
    list: anytype,
    allocator: Allocator,
    len: u32,
    cap: u32,
) !void {
    try list.setCapacity(allocator, cap);
    list.len = len;
}

pub fn setAndExpandCapacitySlice(
    list: anytype,
    allocator: Allocator,
    len: u32,
    cap: u32,
) !void {
    var m = list.toMultiArrayList();
    try setAndExpandCapacity(&m, allocator, len, cap);
    list.* = m.slice();
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

    pub fn peek(self: *WordIterator) ?[]const u8 {
        var temp = self.*;
        return temp.next();
    }

    pub fn next(self: *WordIterator) ?[]const u8 {
        if (self.index >= self.string.len)
            return null;

        const str = std.mem.trimStart(u8, self.string[self.index..], &std.ascii.whitespace);
        self.index = str.ptr - self.string.ptr;

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

        if (std.mem.startsWith(u8, str, "--")) {
            // We got a comment, nothing else can come after
            self.index = self.string.len;
            return null;
        }

        const end_index = for (str, 0..) |c, i| {
            if (std.ascii.isWhitespace(c)) {
                if (quote_state == .none)
                    break i;

                quote_index = i;
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

test "WordIterator comment" {
    var iter = wordIterator("this -- is epic");
    try std.testing.expectEqualStrings("this", iter.next().?);
    try std.testing.expectEqual(null, iter.next());
}

pub fn FieldEnum(T: type, IntType: ?type) type {
    const field_names = std.meta.fieldNames(T);
    const Int = IntType orelse std.math.IntFittingRange(0, field_names.len -| 1);
    return @Enum(Int, .exhaustive, field_names, &std.simd.iota(Int, field_names.len));
}
