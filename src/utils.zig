const std = @import("std");
const Position = @import("Position.zig").Position;
const wcWidth = @import("wcwidth").wcWidth;

const unicode = std.unicode;
const mem = std.mem;
const assert = std.debug.assert;

pub usingnamespace @import("buffer_utils.zig");

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
        if (info != .Pointer) break :blk false;

        const ptr = &info.Pointer;
        // Check for CV qualifiers that would prevent coerction to []const u8
        if (ptr.is_volatile or ptr.is_allowzero) break :blk false;

        // If it's already a slice, simple check.
        if (ptr.size == .Slice) {
            break :blk ptr.child == u8;
        }

        // Otherwise check if it's an array type that coerces to slice.
        if (ptr.size == .One) {
            const child = @typeInfo(ptr.child);
            if (child == .Array) {
                const arr = &child.Array;
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

pub const CodepointBuilder = struct {
    buf: [4]u8 = undefined,
    desired_len: u3 = 0,
    len: u3 = 0,

    pub fn appendByte(builder: *CodepointBuilder, byte: u8) bool {
        if (builder.desired_len == 0) {
            builder.desired_len = unicode.utf8ByteSequenceLength(byte) catch unreachable;
        }
        assert(builder.len + 1 <= builder.desired_len);
        builder.buf[builder.len] = byte;
        builder.len += 1;
        return !(builder.len == builder.desired_len);
    }

    pub fn slice(builder: *const CodepointBuilder) []const u8 {
        assert(builder.len == builder.desired_len);
        return builder.buf[0..builder.len];
    }

    pub fn codepoint(builder: CodepointBuilder) u21 {
        return unicode.utf8Decode(builder.slice()) catch unreachable;
    }
};

pub fn strWidth(bytes: []const u8, max: u16) u16 {
    var width: u16 = 0;
    var cp_iter = std.unicode.Utf8Iterator{
        .bytes = bytes,
        .i = 0,
    };
    while (cp_iter.nextCodepoint()) |cp| {
        width += wcWidth(cp);
        if (width >= max) break;
    }
    return width;
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

/// Writes the utf-8 representation of a unicode codepoint to the given writer
pub fn writeCodepoint(cp: u21, writer: anytype) !void {
    var buf: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(cp, &buf);

    try writer.writeAll(buf[0..len]);
}

pub fn isWord(c: u8) bool {
    return switch (c) {
        '_', 'a'...'z', 'A'...'Z', '0'...'9' => true,
        else => false,
    };
}

pub fn wordIterator(string: []const u8) WordIterator {
    return WordIterator{
        .string = string,
    };
}

/// An iterator over the words in a string. A word is defined as a continuous sequence of
/// non-whitespace characters, or a sequence of characters wrapped in quotes. If a word is a quoted
/// sequence of characters, the quotes are retained in the returned string.
pub const WordIterator = struct {
    string: []const u8,
    index: usize = 0,

    pub fn init(string: []const u8) WordIterator {
        return WordIterator{
            .string = mem.trim(u8, string, &std.ascii.whitespace),
        };
    }

    pub fn next(self: *WordIterator) ?[]const u8 {
        if (self.index >= self.string.len)
            return null;

        const str = mem.trimLeft(u8, self.string[self.index..], &std.ascii.whitespace);
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
