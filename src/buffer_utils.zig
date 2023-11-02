//! Utility functions for types that represent sequential data with constant time random access.
//! These functions take an `anytype` parameter, whose type must have certain methods implemented.
//!
//! These functions require a subset of declarations to be defined on their `anytype` parameter,
//! depending on the function. They are:
//!
//! - `ElementType`
//! - `fn get(Self, u32) ElementType` returns the element at the given index
//! - `fn getPtr(*Self, u32) *ElementType` returns a pointer to the element at the given index
//! - `fn length(Self) u32` returns the number of elements

const std = @import("std");
const assert = std.debug.assert;

pub fn Slice(comptime T: type, comptime constant: bool) type {
    return struct {
        slice: if (constant) []const T else []T,

        const Self = @This();
        pub const ElementType = T;
        pub const ElementPtr = if (constant) *const T else *T;

        pub fn get(self: Self, pos: u32) T {
            return self.slice[pos];
        }

        pub fn getPtr(self: Self, pos: u32) ElementPtr {
            return &self.slice[pos];
        }

        pub fn length(self: Self) u32 {
            return @intCast(self.slice.len);
        }
    };
}

pub fn containsAt(t: anytype, pos: u32, needle: []const @TypeOf(t).ElementType) bool {
    const len = t.length();
    const needle_len: u32 = @intCast(needle.len);
    if (len - pos < needle_len) return false;

    var i: u32 = 0;
    return while (i < needle_len) : (i += 1) {
        if (needle[i] != t.get(pos + i)) break false;
    } else true;
}

/// Requires `ElementType`, `length` and `get` to be implemented by `@TypeOf(t)`.
/// Returns the index of the first occurence of `needle` after `pos` in `t`.
pub fn indexOfPos(t: anytype, pos: u32, needle: []const @TypeOf(t).ElementType) ?u32 {
    const len = t.length();
    const needle_len: u32 = @intCast(needle.len);
    assert(pos <= len);
    if (len - pos < needle_len) return null;

    var i = pos;
    while (i <= len - needle_len) : (i += 1) {
        var j: u32 = 0;
        while (j < needle_len) : (j += 1) {
            if (t.get(i + j) != needle[j]) break;
        } else return i;
    }

    return null;
}

pub fn indexOfPosScalar(t: anytype, pos: u32, needle: @TypeOf(t).ElementType) ?u32 {
    const len = t.length();
    assert(pos < len);
    var i = pos;
    return while (i < len) : (i += 1) {
        if (t.get(i) == needle) break i;
    } else null;
}

/// Returns the index of the first instance of `needle` before `pos` in `t`.
pub fn lastIndexOfPos(t: anytype, pos: u32, needle: []const @TypeOf(t).ElementType) ?u32 {
    const len = t.length();
    const needle_len: u32 = @intCast(needle.len);
    if (needle_len > len or pos == 0) return null;
    if (needle_len == 0) return len;

    var i = pos;
    return while (i > 0) {
        i -= 1;
        if (containsAt(t, i, needle)) break i;
    } else null;
}

pub fn lastIndexOfPosScalar(t: anytype, pos: u32, needle: @TypeOf(t).ElementType) ?u32 {
    assert(pos <= t.length());
    var i = pos;
    return while (i > 0) {
        i -= 1;
        if (t.get(i) == needle) break i;
    } else null;
}

pub fn iterator(t: anytype) Iterator(@TypeOf(t)) {
    return .{
        .data = t,
    };
}

pub fn Iterator(comptime T: type) type {
    return struct {
        data: T,
        index: u32 = 0,

        const Self = @This();

        pub fn next(self: *Self) ?T.ElementType {
            if (self.index >= self.data.length()) return null;
            const ret = self.data.get(self.index);
            self.index += 1;
            return ret;
        }
    };
}

pub fn reverseIterator(t: anytype) ReverseIterator(@TypeOf(t)) {
    return .{
        .data = t,
        .index = t.length(),
    };
}

pub fn ReverseIterator(comptime T: type) type {
    return struct {
        data: T,
        index: u32,

        const Self = @This();

        pub fn next(self: *Self) ?T.ElementType {
            if (self.index == 0) return null;
            self.index -= 1;
            return self.data.get(self.index);
        }
    };
}

pub fn utf8Iterator(t: anytype) Utf8Iterator(@TypeOf(t)) {
    return .{
        .data = t,
    };
}

pub fn Utf8Iterator(comptime T: type) type {
    if (T.ElementType != u8)
        @compileError("Utf8Iterator can only be used on types with ElementType == u8");

    return struct {
        data: T,
        cp_buf: [4]u8 = undefined,
        index: u32 = 0,

        const Self = @This();

        pub fn nextCodepointSlice(self: *Self) ?[]const u8 {
            if (self.index >= self.data.length()) return null;
            const first_byte = self.data.get(self.index);
            const len = std.unicode.utf8ByteSequenceLength(first_byte) catch unreachable;
            self.cp_buf[0] = first_byte;
            for (1..len) |i| {
                self.cp_buf[i] = self.data.get(self.index + @as(u32, @intCast(i)));
            }
            self.index += len;
            return self.cp_buf[0..len];
        }

        pub fn nextCodepoint(self: *Self) ?u21 {
            const slice = self.nextCodepointSlice() orelse return null;
            return std.unicode.utf8Decode(slice) catch unreachable;
        }
    };
}

test "indexOfPos" {
    const t = std.testing;
    const buf = Slice(u8, true){
        .slice = "This is epic!",
    };
    try t.expectEqual(@as(?u32, 0), indexOfPos(buf, 0, "This"));
    try t.expectEqual(@as(?u32, 2), indexOfPos(buf, 0, "is"));
    try t.expectEqual(@as(?u32, 2), indexOfPos(buf, 2, "is"));
    try t.expectEqual(@as(?u32, 5), indexOfPos(buf, 3, "is"));
    try t.expectEqual(@as(?u32, 5), indexOfPos(buf, 5, "is"));
    try t.expectEqual(@as(?u32, null), indexOfPos(buf, 6, "is"));
    try t.expectEqual(@as(?u32, buf.length() - 1), indexOfPos(buf, buf.length() - 1, "!"));
}
