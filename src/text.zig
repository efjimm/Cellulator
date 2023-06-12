const std = @import("std");
const utils = @import("utils.zig");
const spoon = @import("spoon");
const wcWidth = @import("wcwidth").wcWidth;
const inputParser = spoon.inputParser;
const isWhitespace = std.ascii.isWhitespace;
const utf8Encode = std.unicode.utf8Encode;

const assert = std.debug.assert;
const log = std.log.scoped(.text_input);

pub fn isContinuation(c: u8) bool {
    return c & 0xC0 == 0x80;
}

pub fn nextCodepoint(bytes: []const u8, offset: u32) u32 {
    return std.unicode.utf8ByteSequenceLength(bytes[offset]) catch unreachable;
}

pub fn prevCodepoint(bytes: []const u8, offset: u32) u32 {
    if (offset == 0) return 0;

    var iter = std.mem.reverseIterator(bytes[0..offset]);
    while (iter.next()) |c| {
        if (!isContinuation(c)) break;
    }
    return offset - @intCast(u32, iter.index);
}

// TODO: package & use libgrapheme for these
//       waiting for https://github.com/ziglang/zig/issues/14719 to be fixed before this happens
pub fn nextCharacter(bytes: []const u8, offset: u32, count: u32) u32 {
    var iter = std.unicode.Utf8Iterator{
        .bytes = bytes[offset..],
        .i = 0,
    };

    for (0..count) |_| {
        while (iter.nextCodepoint()) |cp| {
            if (wcWidth(cp) != 0) break;
        } else break;
    }

    return @intCast(u32, iter.i);
}

pub fn prevCharacter(bytes: []const u8, offset: u32, count: u32) u32 {
    var i: u32 = offset;
    for (0..count) |_| {
        while (i > 0) {
            const len = prevCodepoint(bytes, i);
            i -= len;

            const cp = std.unicode.utf8Decode(bytes[i .. i + len]) catch continue;
            if (wcWidth(cp) != 0) break;
        } else break;
    }

    return offset - i;
}

pub fn sliceToCp(slice: []const u8) [4]u8 {
    assert(slice.len > 0);
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8ByteSequenceLength(slice[0]) catch 1;
    @memcpy(buf[0..len], slice[0..len]);
    return buf;
}

/// Converts a UTF-8 codepoint array to a slice
pub fn cpToSlice(array: *const [4]u8) []const u8 {
    const len = std.unicode.utf8ByteSequenceLength(array[0]) catch 1;
    return array[0..len];
}

pub const Delimiters = struct {
    left: u21,
    right: u21,
};

pub const Range = struct {
    start: u32,
    end: u32,

    pub inline fn len(range: Range) u32 {
        return range.end - range.start;
    }
};

pub const Motion = union(enum(u8)) {
    normal_word_inside = 0,
    long_word_inside = 1,
    normal_word_around = 2,
    long_word_around = 3,

    inside_delimiters: Delimiters = 4,
    around_delimiters: Delimiters = 5,
    inside_single_delimiter: u21 = 6,
    around_single_delimiter: u21 = 7,

    to_forwards: u21 = 8,
    to_backwards: u21 = 9,
    until_forwards: u21 = 10,
    until_backwards: u21 = 11,

    normal_word_start_next = 12,
    normal_word_start_prev = 13,
    normal_word_end_next = 14,
    normal_word_end_prev = 15,
    long_word_start_next = 16,
    long_word_start_prev = 17,
    long_word_end_next = 18,
    long_word_end_prev = 19,
    char_next = 20,
    char_prev = 21,
    line = 22,
    eol = 23,
    bol = 24,

    to_forwards_utf8: []const u8,
    to_backwards_utf8: []const u8,
    until_forwards_utf8: []const u8,
    until_backwards_utf8: []const u8,

    pub const WordType = enum {
        normal,
        long,
    };

    pub fn do(motion: Motion, bytes: []const u8, pos: u32, count: u32) Range {
        return switch (motion) {
            .normal_word_start_next => .{
                .start = pos,
                .end = nextWordStart(bytes, .normal, pos, count),
            },
            .normal_word_start_prev => .{
                .start = prevWordStart(bytes, .normal, pos, count),
                .end = pos,
            },
            .normal_word_end_next => .{
                .start = pos,
                .end = nextWordEnd(bytes, .normal, pos, count),
            },
            .normal_word_end_prev => .{
                .start = prevWordEnd(bytes, .normal, pos, count),
                .end = pos,
            },
            .long_word_start_next => .{
                .start = pos,
                .end = nextWordStart(bytes, .long, pos, count),
            },
            .long_word_start_prev => .{
                .start = prevWordStart(bytes, .long, pos, count),
                .end = pos,
            },
            .long_word_end_next => .{
                .start = pos,
                .end = nextWordEnd(bytes, .long, pos, count),
            },
            .long_word_end_prev => .{
                .start = prevWordEnd(bytes, .long, pos, count),
                .end = pos,
            },
            .char_next => .{
                .start = pos,
                .end = pos + nextCharacter(bytes, pos, count),
            },
            .char_prev => .{
                .start = pos - prevCharacter(bytes, pos, count),
                .end = pos,
            },
            .line => .{
                .start = 0,
                .end = @intCast(u32, bytes.len),
            },
            .eol => .{
                .start = pos,
                .end = @intCast(u32, bytes.len),
            },
            .bol => .{
                .start = 0,
                .end = pos,
            },
            .normal_word_inside => insideWord(bytes, .normal, pos),
            .long_word_inside => insideWord(bytes, .long, pos),

            .normal_word_around => aroundWord(bytes, .normal, pos),
            .long_word_around => aroundWord(bytes, .long, pos),

            .inside_delimiters => |d| insideDelimitersCp(bytes, d.left, d.right, pos),
            .around_delimiters => |d| aroundDelimitersCp(bytes, d.left, d.right, pos),
            .inside_single_delimiter => |cp| insideSingleDelimiterCp(bytes, cp, pos),
            .around_single_delimiter => |cp| aroundSingleDelimiterCp(bytes, cp, pos),

            .to_forwards => |cp| .{
                .start = pos,
                .end = toForwardsCp(bytes, cp, pos, count) orelse pos,
            },
            .to_backwards => |cp| .{
                .start = toBackwardsCp(bytes, cp, pos, count) orelse pos,
                .end = pos,
            },
            .until_forwards => |cp| .{
                .start = pos,
                .end = untilForwardsCp(bytes, cp, pos +| 1, count) orelse pos,
            },
            .until_backwards => |cp| .{
                .start = untilBackwardsCp(bytes, cp, pos -| 1, count) orelse pos,
                .end = pos,
            },

            .to_forwards_utf8 => |needle| .{
                .start = pos,
                .end = toForwards(bytes, needle, pos, count) orelse pos,
            },
            .to_backwards_utf8 => |needle| .{
                .start = toBackwards(bytes, needle, pos, count) orelse pos,
                .end = pos,
            },
            .until_forwards_utf8 => |needle| .{
                .start = pos,
                .end = untilForwards(bytes, needle, pos +| 1, count) orelse pos,
            },
            .until_backwards_utf8 => |needle| .{
                .start = untilBackwards(bytes, needle, pos -| 1, count) orelse pos,
                .end = pos,
            },
        };
    }

    /// Returns the byte position of the next word
    fn nextWordStart(
        bytes: []const u8,
        comptime word_type: WordType,
        start_pos: u32,
        count: u32,
    ) u32 {
        const boundary = wordBoundaryFn(word_type);
        var pos = start_pos;

        for (0..count) |_| {
            if (pos >= bytes.len) break;

            if (boundary(bytes[pos])) {
                while (pos < bytes.len) : (pos += nextCharacter(bytes, pos, 1)) {
                    if (!boundary(bytes[pos]) or isWhitespace(bytes[pos])) break;
                }
            } else {
                while (pos < bytes.len) : (pos += nextCharacter(bytes, pos, 1)) {
                    if (boundary(bytes[pos])) break;
                }
            }

            while (pos < bytes.len) : (pos += nextCharacter(bytes, pos, 1)) {
                if (!isWhitespace(bytes[pos])) break;
            }
        }

        return pos;
    }

    fn prevWordStart(
        bytes: []const u8,
        comptime word_type: WordType,
        start_pos: u32,
        count: u32,
    ) u32 {
        if (bytes.len == 0) return 0;

        const boundary = wordBoundaryFn(word_type);
        var pos = start_pos;

        for (0..count) |_| {
            while (pos > 0) {
                pos -= prevCharacter(bytes, pos, 1);
                if (!isWhitespace(bytes[pos])) break;
            } else break;

            var p = pos;
            if (boundary(bytes[p])) {
                while (p > 0) {
                    p -= prevCharacter(bytes, p, 1);
                    if (!boundary(bytes[p]) or isWhitespace(bytes[p])) break;
                    pos = p;
                }
            } else {
                while (p > 0) {
                    p -= prevCharacter(bytes, p, 1);
                    if (boundary(bytes[p])) break;
                    pos = p;
                }
            }
        }

        return pos;
    }

    fn nextWordEnd(
        bytes: []const u8,
        comptime word_type: WordType,
        start_pos: u32,
        count: u32,
    ) u32 {
        if (bytes.len == 0) return 0;

        const boundary = wordBoundaryFn(word_type);
        var pos = start_pos;

        for (0..count) |_| {
            pos += nextCodepoint(bytes, pos);
            while (pos < bytes.len and isWhitespace(bytes[pos])) {
                pos += nextCodepoint(bytes, pos);
            }
            if (pos == bytes.len) return pos;

            var p = pos;
            if (boundary(bytes[pos])) {
                while (p < bytes.len) : (p += nextCharacter(bytes, p, 1)) {
                    if (!boundary(bytes[p]) or isWhitespace(bytes[p])) break;
                    pos = p;
                }
            } else {
                while (p < bytes.len) : (p += nextCharacter(bytes, p, 1)) {
                    if (boundary(bytes[p])) break;
                    pos = p;
                }
            }
        }

        return pos;
    }

    fn prevWordEnd(
        bytes: []const u8,
        comptime word_type: WordType,
        start_pos: u32,
        count: u32,
    ) u32 {
        if (bytes.len == 0) return 0;

        const len = @intCast(u32, bytes.len);
        if (start_pos >= bytes.len)
            return prevWordEnd(bytes, word_type, len - prevCharacter(bytes, len, 1), count - 1);

        const boundary = wordBoundaryFn(word_type);
        var pos = start_pos;

        for (0..count) |_| {
            if (boundary(bytes[pos])) {
                while (pos > 0 and boundary(bytes[pos]) and !isWhitespace(bytes[pos])) {
                    pos -= prevCodepoint(bytes, pos);
                }
            } else {
                while (pos > 0 and !boundary(bytes[pos])) {
                    pos -= prevCodepoint(bytes, pos);
                }
            }
            while (pos > 0 and isWhitespace(bytes[pos])) {
                pos -= prevCodepoint(bytes, pos);
            }
        }

        return pos;
    }

    fn insideWord(bytes: []const u8, comptime word_type: WordType, pos: u32) Range {
        if (bytes.len == 0) return .{ .start = 0, .end = 0 };

        var iter = std.mem.reverseIterator(bytes[0..pos]);
        var start: u32 = pos;
        var end: u32 = pos;

        const boundary = wordBoundaryFn(word_type);

        if (!boundary(bytes[pos])) {
            while (iter.next()) |c| : (start -= 1) {
                if (boundary(c)) break;
            }

            for (bytes[pos..]) |c| {
                if (boundary(c)) break;
                end += 1;
            }
        } else {
            while (iter.next()) |c| : (start -= 1) {
                if (!boundary(c)) break;
            }

            for (bytes[pos..]) |c| {
                if (!boundary(c)) break;
                end += 1;
            }
        }

        return .{
            .start = start,
            .end = end,
        };
    }

    fn aroundWord(bytes: []const u8, comptime word_type: WordType, pos: u32) Range {
        if (bytes.len == 0) return .{ .start = 0, .end = 0 };

        var iter = std.mem.reverseIterator(bytes[0..pos]);
        var start = pos;
        var end = pos;

        const boundary = wordBoundaryFn(word_type);

        if (!boundary(bytes[pos])) {
            while (iter.next()) |c| : (start -= 1) {
                if (boundary(c)) break;
            }

            for (bytes[pos..]) |c| {
                if (boundary(c)) break;
                end += 1;
            }

            for (bytes[end..]) |c| {
                if (!isWhitespace(c)) break;
                end += 1;
            }
        } else {
            while (iter.next()) |c| : (start -= 1) {
                if (!boundary(c)) break;
            }

            for (bytes[pos..]) |c| {
                if (!boundary(c)) break;
                end += 1;
            }

            for (bytes[end..]) |c| {
                if (isWhitespace(c)) break;
                end += 1;
            }
        }

        return .{
            .start = start,
            .end = end,
        };
    }

    fn insideDelimitersCp(
        bytes: []const u8,
        left_cp: u21,
        right_cp: u21,
        pos: u32,
    ) Range {
        const err_ret = Range{
            .start = pos,
            .end = pos,
        };
        var buf: [8]u8 = undefined;
        const left_len = utf8Encode(left_cp, &buf) catch return err_ret;
        const left = buf[0..left_len];

        const right_len = utf8Encode(right_cp, buf[4..]) catch return err_ret;
        const right = buf[4 .. 4 + right_len];

        return insideDelimiters(bytes, left, right, pos);
    }

    fn insideDelimiters(bytes: []const u8, left: []const u8, right: []const u8, pos: u32) Range {
        if (bytes.len == 0) return .{ .start = 0, .end = 0 };

        var ret = aroundDelimiters(bytes, left, right, pos);
        if (ret.start == ret.end) return ret;
        ret.start += nextCodepoint(bytes, ret.start);
        ret.end -= prevCodepoint(bytes, ret.end);
        return ret;
    }

    fn aroundDelimitersCp(
        bytes: []const u8,
        left_cp: u21,
        right_cp: u21,
        pos: u32,
    ) Range {
        const err_ret = Range{
            .start = pos,
            .end = pos,
        };
        var buf: [8]u8 = undefined;
        const left_len = utf8Encode(left_cp, &buf) catch return err_ret;
        const left = buf[0..left_len];

        const right_len = utf8Encode(right_cp, buf[4..]) catch return err_ret;
        const right = buf[4 .. 4 + right_len];
        return aroundDelimiters(bytes, left, right, pos);
    }

    // TODO: this is pretty inefficient
    fn aroundDelimiters(
        bytes: []const u8,
        left: []const u8,
        right: []const u8,
        pos: u32,
    ) Range {
        if (bytes.len == 0) return .{ .start = 0, .end = 0 };
        assert(pos < bytes.len);
        assert((std.unicode.utf8ByteSequenceLength(left[0]) catch unreachable) == left.len);
        assert((std.unicode.utf8ByteSequenceLength(right[0]) catch unreachable) == right.len);

        var i = pos;
        var depth: i32 = if (std.mem.startsWith(u8, bytes[pos..], right)) -1 else 0;
        while (true) : (i -= 1) {
            if (std.mem.startsWith(u8, bytes[i..], left)) {
                if (depth == 0) break;
                depth -= 1;
            } else if (std.mem.startsWith(u8, bytes[i..], right)) {
                depth += 1;
            }

            if (i == 0) return .{
                .start = pos,
                .end = pos,
            };
        }

        var j = pos;
        depth = if (std.mem.startsWith(u8, bytes[pos..], left)) -1 else 0;

        while (j < bytes.len) : (j += 1) {
            if (std.mem.startsWith(u8, bytes[j..], right)) {
                if (depth == 0) {
                    j += @intCast(u32, right.len);
                    break;
                }
                depth -= 1;
            } else if (std.mem.startsWith(u8, bytes[j..], left)) {
                depth += 1;
            }
        } else return .{
            .start = pos,
            .end = pos,
        };

        assert(i <= j);

        return .{
            .start = i,
            .end = j,
        };
    }

    fn insideSingleDelimiterCp(bytes: []const u8, delim_cp: u21, pos: u32) Range {
        var buf: [4]u8 = undefined;
        const len = utf8Encode(delim_cp, &buf) catch return .{
            .start = pos,
            .end = pos,
        };
        return insideSingleDelimiter(bytes, buf[0..len], pos);
    }

    fn insideSingleDelimiter(bytes: []const u8, delim: []const u8, pos: u32) Range {
        if (bytes.len == 0) return .{ .start = 0, .end = 0 };

        var ret = aroundSingleDelimiter(bytes, delim, pos);
        if (ret.start == ret.end) return ret;
        ret.start += nextCodepoint(bytes, ret.start);
        ret.end -= prevCodepoint(bytes, ret.end);
        return ret;
    }

    fn aroundSingleDelimiterCp(
        bytes: []const u8,
        delim_cp: u21,
        pos: u32,
    ) Range {
        var buf: [4]u8 = undefined;
        const len = utf8Encode(delim_cp, &buf) catch return .{
            .start = pos,
            .end = pos,
        };
        return aroundSingleDelimiter(bytes, buf[0..len], pos);
    }

    fn aroundSingleDelimiter(
        bytes: []const u8,
        delim: []const u8,
        pos: u32,
    ) Range {
        const len = @intCast(u32, delim.len);
        if (std.mem.startsWith(u8, bytes[pos..], delim)) {
            const start = std.mem.lastIndexOf(u8, bytes[0..pos], delim) orelse pos;
            const end = std.mem.indexOf(u8, bytes[pos + len ..], delim) orelse pos;

            return .{
                .start = @intCast(u32, start),
                .end = len + @intCast(u32, end),
            };
        } else {
            const start = std.mem.lastIndexOf(u8, bytes[0..pos], delim) orelse pos;
            const end = if (std.mem.indexOf(u8, bytes[pos..], delim)) |x| pos + x else pos;
            if (start == end) return .{ .start = pos, .end = pos };
            return .{
                .start = @intCast(u32, start),
                .end = len + @intCast(u32, end),
            };
        }
    }

    fn toForwardsCp(bytes: []const u8, cp: u21, pos: u32, count: u32) ?u32 {
        var buf: [4]u8 = undefined;
        const len = utf8Encode(cp, &buf) catch 1;
        return toForwards(bytes, buf[0..len], pos, count);
    }

    fn toBackwardsCp(bytes: []const u8, cp: u21, pos: u32, count: u32) ?u32 {
        var buf: [4]u8 = undefined;
        const len = utf8Encode(cp, &buf) catch 1;
        return toBackwards(bytes, buf[0..len], pos, count);
    }

    fn untilForwardsCp(bytes: []const u8, cp: u21, pos: u32, count: u32) ?u32 {
        var buf: [4]u8 = undefined;
        const len = utf8Encode(cp, &buf) catch 1;
        return untilForwards(bytes, buf[0..len], pos, count);
    }

    fn untilBackwardsCp(bytes: []const u8, cp: u21, pos: u32, count: u32) ?u32 {
        var buf: [4]u8 = undefined;
        const len = utf8Encode(cp, &buf) catch 1;
        return untilBackwards(bytes, buf[0..len], pos, count);
    }

    fn toForwards(bytes: []const u8, needle: []const u8, pos: u32, count: u32) ?u32 {
        if (pos >= bytes.len or count == 0) return pos;

        const first = 1 + (std.mem.indexOf(u8, bytes[pos + 1 ..], needle) orelse return null);
        var p = pos + first;

        for (1..count) |_| {
            if (p >= bytes.len) break;
            p += 1 + (std.mem.indexOf(u8, bytes[p + 1 ..], needle) orelse break);
        }

        return @intCast(u32, p);
    }

    fn toBackwards(bytes: []const u8, needle: []const u8, pos: u32, count: u32) ?u32 {
        assert(pos <= bytes.len);
        if (count == 0) return pos;

        var p = std.mem.lastIndexOf(u8, bytes[0..pos], needle) orelse return null;

        for (1..count) |_| {
            p = std.mem.lastIndexOf(u8, bytes[0..p], needle) orelse break;
        }

        return @intCast(u32, p);
    }

    fn untilForwards(bytes: []const u8, needle: []const u8, pos: u32, count: u32) ?u32 {
        const ret = toForwards(bytes, needle, pos, count) orelse return null;
        return ret - prevCharacter(bytes, ret, 1);
    }

    fn untilBackwards(bytes: []const u8, needle: []const u8, pos: u32, count: u32) ?u32 {
        const ret = toBackwards(bytes, needle, pos, count) orelse return null;
        return ret + nextCharacter(bytes, ret, 1);
    }

    fn wordBoundaryFn(comptime word_type: WordType) (fn (u8) bool) {
        return switch (word_type) {
            .normal => struct {
                fn func(_c: u8) bool {
                    return _c < 0x80 and !utils.isWord(_c);
                }
            }.func,
            .long => isWhitespace,
        };
    }
};

fn testMotion(
    text: []const u8,
    start: u32,
    start_pos: u32,
    end_pos: u32,
    motion: Motion,
    count: u32,
) !void {
    const range = motion.do(text, start, count);
    try std.testing.expectEqual(start_pos, range.start);
    try std.testing.expectEqual(end_pos, range.end);
}

test "Motions" {
    const text = "this漢字is .my. epic漢字. .漢字text";

    try testMotion(text, 0, 0, "th".len, .{ .to_forwards = 'i' }, 1);
    try testMotion(text, 0, 0, "this漢字".len, .{ .to_forwards = 'i' }, 2);
    try testMotion(text, 0, 0, "this漢字is .my. ep".len, .{ .to_forwards = 'i' }, 3);
    try testMotion(text, 0, 0, "this漢字is .my. ep".len, .{ .to_forwards = 'i' }, 4);
    try testMotion(text, 0, 0, "this漢字is .my. ep".len, .{ .to_forwards = 'i' }, 5);

    try testMotion(text, 0, 0, "this漢".len, .{ .to_forwards = '字' }, 1);
    try testMotion(text, 0, 0, "this漢字is .my. epic漢".len, .{ .to_forwards = '字' }, 2);
    try testMotion(text, 0, 0, "this漢字is .my. epic漢字. .漢".len, .{ .to_forwards = '字' }, 3);
    try testMotion(text, 0, 0, "this漢字is .my. epic漢字. .漢".len, .{ .to_forwards = '字' }, 4);
    try testMotion(text, 0, 0, "this漢字is .my. epic漢字. .漢".len, .{ .to_forwards = '字' }, 5);

    try testMotion(text, text.len, "this漢字is .my. ep".len, text.len, .{ .to_backwards = 'i' }, 1);
    try testMotion(text, text.len, "this漢字".len, text.len, .{ .to_backwards = 'i' }, 2);
    try testMotion(text, text.len, "th".len, text.len, .{ .to_backwards = 'i' }, 3);
    try testMotion(text, text.len, "th".len, text.len, .{ .to_backwards = 'i' }, 4);
    try testMotion(text, text.len, "th".len, text.len, .{ .to_backwards = 'i' }, 5);

    try testMotion(text, text.len, "this漢字is .my. epic漢字. .漢".len, text.len, .{ .to_backwards = '字' }, 1);
    try testMotion(text, text.len, "this漢字is .my. epic漢".len, text.len, .{ .to_backwards = '字' }, 2);
    try testMotion(text, text.len, "this漢".len, text.len, .{ .to_backwards = '字' }, 3);
    try testMotion(text, text.len, "this漢".len, text.len, .{ .to_backwards = '字' }, 4);
    try testMotion(text, text.len, "this漢".len, text.len, .{ .to_backwards = '字' }, 5);

    try testMotion(text, 0, 0, "t".len, .{ .until_forwards = 'i' }, 1);
    try testMotion(text, 0, 0, "this漢".len, .{ .until_forwards = 'i' }, 2);
    try testMotion(text, 0, 0, "this漢字is .my. e".len, .{ .until_forwards = 'i' }, 3);
    try testMotion(text, 0, 0, "this漢字is .my. e".len, .{ .until_forwards = 'i' }, 4);
    try testMotion(text, 0, 0, "this漢字is .my. e".len, .{ .until_forwards = 'i' }, 5);

    try testMotion(text, 0, 0, "this".len, .{ .until_forwards = '字' }, 1);
    try testMotion(text, 0, 0, "this漢字is .my. epic".len, .{ .until_forwards = '字' }, 2);
    try testMotion(text, 0, 0, "this漢字is .my. epic漢字. .".len, .{ .until_forwards = '字' }, 3);
    try testMotion(text, 0, 0, "this漢字is .my. epic漢字. .".len, .{ .until_forwards = '字' }, 4);
    try testMotion(text, 0, 0, "this漢字is .my. epic漢字. .".len, .{ .until_forwards = '字' }, 5);

    try testMotion(text, text.len, "this漢字is .my. epi".len, text.len, .{ .until_backwards = 'i' }, 1);
    try testMotion(text, text.len, "this漢字i".len, text.len, .{ .until_backwards = 'i' }, 2);
    try testMotion(text, text.len, "thi".len, text.len, .{ .until_backwards = 'i' }, 3);
    try testMotion(text, text.len, "thi".len, text.len, .{ .until_backwards = 'i' }, 4);
    try testMotion(text, text.len, "thi".len, text.len, .{ .until_backwards = 'i' }, 5);

    try testMotion(text, text.len, "this漢字is .my. epic漢字. .漢字".len, text.len, .{ .until_backwards = '字' }, 1);
    try testMotion(text, text.len, "this漢字is .my. epic漢字".len, text.len, .{ .until_backwards = '字' }, 2);
    try testMotion(text, text.len, "this漢字".len, text.len, .{ .until_backwards = '字' }, 3);
    try testMotion(text, text.len, "this漢字".len, text.len, .{ .until_backwards = '字' }, 4);
    try testMotion(text, text.len, "this漢字".len, text.len, .{ .until_backwards = '字' }, 5);

    try testMotion(text, 0, 0, "t".len, .char_next, 1);
    try testMotion(text, 0, 0, "th".len, .char_next, 2);
    try testMotion(text, 0, 0, "thi".len, .char_next, 3);
    try testMotion(text, 0, 0, "this".len, .char_next, 4);
    try testMotion(text, 0, 0, "this漢".len, .char_next, 5);
    try testMotion(text, 0, 0, "this漢字".len, .char_next, 6);
    try testMotion(text, 0, 0, "this漢字i".len, .char_next, 7);

    try testMotion(text, "this漢字i".len, "this漢字".len, "this漢字i".len, .char_prev, 1);
    try testMotion(text, "this漢字i".len, "this漢".len, "this漢字i".len, .char_prev, 2);
    try testMotion(text, "this漢字i".len, "this".len, "this漢字i".len, .char_prev, 3);
    try testMotion(text, "this漢字i".len, "thi".len, "this漢字i".len, .char_prev, 4);
    try testMotion(text, "this漢字i".len, "th".len, "this漢字i".len, .char_prev, 5);
    try testMotion(text, "this漢字i".len, "t".len, "this漢字i".len, .char_prev, 6);
    try testMotion(text, "this漢字i".len, 0, "this漢字i".len, .char_prev, 7);
    try testMotion(text, "this漢字i".len, 0, "this漢字i".len, .char_prev, 8);

    try testMotion(text, 0, 0, "this漢字is ".len, .normal_word_start_next, 1);
    try testMotion(text, 0, 0, "this漢字is .".len, .normal_word_start_next, 2);
    try testMotion(text, 0, 0, "this漢字is .my".len, .normal_word_start_next, 3);
    try testMotion(text, 0, 0, "this漢字is .my. ".len, .normal_word_start_next, 4);
    try testMotion(text, 0, 0, "this漢字is .my. epic漢字".len, .normal_word_start_next, 5);
    try testMotion(text, 0, 0, "this漢字is .my. epic漢字. ".len, .normal_word_start_next, 6);
    try testMotion(text, 0, 0, "this漢字is .my. epic漢字. .".len, .normal_word_start_next, 7);
    try testMotion(text, 0, 0, text.len, .normal_word_start_next, 8);

    try testMotion(text, 0, 0, "this漢字i".len, .normal_word_end_next, 1);
    try testMotion(text, 0, 0, "this漢字is ".len, .normal_word_end_next, 2);
    try testMotion(text, 0, 0, "this漢字is .m".len, .normal_word_end_next, 3);
    try testMotion(text, 0, 0, "this漢字is .my".len, .normal_word_end_next, 4);
    try testMotion(text, 0, 0, "this漢字is .my. epic漢".len, .normal_word_end_next, 5);
    try testMotion(text, 0, 0, "this漢字is .my. epic漢字".len, .normal_word_end_next, 6);
    try testMotion(text, 0, 0, "this漢字is .my. epic漢字. ".len, .normal_word_end_next, 7);
    try testMotion(text, 0, 0, "this漢字is .my. epic漢字. .漢字tex".len, .normal_word_end_next, 8);
    try testMotion(text, 0, 0, text.len, .normal_word_end_next, 9);

    try testMotion(text, text.len, "this漢字is .my. epic漢字. .".len, text.len, .normal_word_start_prev, 1);
    try testMotion(text, text.len, "this漢字is .my. epic漢字. ".len, text.len, .normal_word_start_prev, 2);
    try testMotion(text, text.len, "this漢字is .my. epic漢字".len, text.len, .normal_word_start_prev, 3);
    try testMotion(text, text.len, "this漢字is .my. ".len, text.len, .normal_word_start_prev, 4);
    try testMotion(text, text.len, "this漢字is .my".len, text.len, .normal_word_start_prev, 5);
    try testMotion(text, text.len, "this漢字is .".len, text.len, .normal_word_start_prev, 6);
    try testMotion(text, text.len, "this漢字is ".len, text.len, .normal_word_start_prev, 7);
    try testMotion(text, text.len, 0, text.len, .normal_word_start_prev, 8);

    try testMotion(text, text.len, "this漢字is .my. epic漢字. .漢字tex".len, text.len, .normal_word_end_prev, 1);
    try testMotion(text, text.len, "this漢字is .my. epic漢字. ".len, text.len, .normal_word_end_prev, 2);
    try testMotion(text, text.len, "this漢字is .my. epic漢字".len, text.len, .normal_word_end_prev, 3);
    try testMotion(text, text.len, "this漢字is .my. epic漢".len, text.len, .normal_word_end_prev, 4);
    try testMotion(text, text.len, "this漢字is .my".len, text.len, .normal_word_end_prev, 5);
    try testMotion(text, text.len, "this漢字is .m".len, text.len, .normal_word_end_prev, 6);
    try testMotion(text, text.len, "this漢字is ".len, text.len, .normal_word_end_prev, 7);
    try testMotion(text, text.len, "this漢字i".len, text.len, .normal_word_end_prev, 8);
    try testMotion(text, text.len, 0, text.len, .normal_word_start_prev, 9);

    try testMotion(text, 0, 0, "this漢字is ".len, .long_word_start_next, 1);
    try testMotion(text, 0, 0, "this漢字is .my. ".len, .long_word_start_next, 2);
    try testMotion(text, 0, 0, "this漢字is .my. epic漢字. ".len, .long_word_start_next, 3);
    try testMotion(text, 0, 0, text.len, .long_word_start_next, 4);

    try testMotion(text, 0, 0, "this漢字i".len, .long_word_end_next, 1);
    try testMotion(text, 0, 0, "this漢字is .my".len, .long_word_end_next, 2);
    try testMotion(text, 0, 0, "this漢字is .my. epic漢字".len, .long_word_end_next, 3);
    try testMotion(text, 0, 0, "this漢字is .my. epic漢字. .漢字tex".len, .long_word_end_next, 4);
    try testMotion(text, 0, 0, text.len, .long_word_end_next, 5);

    try testMotion(text, text.len, "this漢字is .my. epic漢字. ".len, text.len, .long_word_start_prev, 1);
    try testMotion(text, text.len, "this漢字is .my. ".len, text.len, .long_word_start_prev, 2);
    try testMotion(text, text.len, "this漢字is ".len, text.len, .long_word_start_prev, 3);
    try testMotion(text, text.len, 0, text.len, .long_word_start_prev, 4);

    try testMotion(text, text.len, "this漢字is .my. epic漢字. .漢字tex".len, text.len, .long_word_end_prev, 1);
    try testMotion(text, text.len, "this漢字is .my. epic漢字".len, text.len, .long_word_end_prev, 2);
    try testMotion(text, text.len, "this漢字is .my".len, text.len, .long_word_end_prev, 3);
    try testMotion(text, text.len, "this漢字i".len, text.len, .long_word_end_prev, 4);
    try testMotion(text, text.len, 0, text.len, .long_word_end_prev, 5);

    try testMotion(text, 0, 0, text.len, .line, 1);
    try testMotion(text, 5, 0, text.len, .line, 1);
    try testMotion(text, text.len, 0, text.len, .line, 1);

    try testMotion(text, 0, 0, text.len, .eol, 1);
    try testMotion(text, 5, 5, text.len, .eol, 1);
    try testMotion(text, text.len, text.len, text.len, .eol, 1);

    try testMotion(text, 0, 0, 0, .bol, 1);
    try testMotion(text, 5, 0, 5, .bol, 1);
    try testMotion(text, text.len, 0, text.len, .bol, 1);

    try testMotion(text, 3, 0, "this漢字is".len, .normal_word_inside, 1);
    try testMotion("  ..word..  ", 6, "  ..".len, "  ..word".len, .normal_word_inside, 1);

    try testMotion(text, 3, 0, "this漢字is".len, .long_word_inside, 1);
    try testMotion("  ..word..  word", 6, 2, "  ..word..".len, .long_word_inside, 1);
    try testMotion(" word   word ", 6, " word".len, " word   ".len, .normal_word_inside, 1);
    try testMotion(" word   word ", 6, " word".len, " word   word".len, .normal_word_around, 1);
    try testMotion("  .. word ..  ", "  .. w".len, "  .. ".len, "  .. word ".len, .normal_word_around, 1);
    try testMotion("  ..word..  word", 6, 2, "  ..word..  ".len, .long_word_around, 1);

    try testMotion(" ''word'' ", 5, " ''".len, " ''word".len, .{ .inside_single_delimiter = '\'' }, 1);
    try testMotion(" ''word'' ", 5, " '".len, " ''word'".len, .{ .around_single_delimiter = '\'' }, 1);

    const delims = .{ .left = '(', .right = ')' };
    try testMotion("((word))", 5, "((".len, "((word".len, .{ .inside_delimiters = delims }, 1);
    try testMotion("((word))", 5, "(".len, "((word)".len, .{ .around_delimiters = delims }, 1);
}
