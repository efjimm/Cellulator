const std = @import("std");
const utils = @import("utils.zig");
const spoon = @import("spoon");
const CodepointBuilder = utils.CodepointBuilder;
const wcWidth = @import("wcwidth").wcWidth;
const inputParser = spoon.inputParser;
const isWhitespace = std.ascii.isWhitespace;
const unicode = std.unicode;
const utf8Encode = unicode.utf8Encode;

const assert = std.debug.assert;
const log = std.log.scoped(.text_input);

pub fn isContinuation(c: u8) bool {
    return c & 0xC0 == 0x80;
}

pub fn nextCodepoint(buf: anytype, offset: u32) u32 {
    return unicode.utf8ByteSequenceLength(buf.get(offset)) catch unreachable;
}

pub fn prevCodepoint(buf: anytype, offset: u32) u32 {
    assert(offset <= buf.length());
    var i = offset;
    while (i > 0) {
        i -= 1;
        if (!isContinuation(buf.get(i))) break;
    }
    return offset - i;
}

// TODO: package & use libgrapheme for these
//       waiting for https://github.com/ziglang/zig/issues/14719 to be fixed before this happens
pub fn nextCharacter(buf: anytype, offset: u32, count: u32) u32 {
    var i = offset;
    for (0..count) |_| {
        while (i < buf.length()) : (i += 1) {
            var builder = CodepointBuilder{};
            var j = i;
            while (builder.appendByte(buf.get(j))) : (j += 1) {}
            i += builder.desired_len;
            if (wcWidth(builder.codepoint()) != 0) break;
        } else break;
    }

    return i - offset;
}

pub fn prevCharacter(buf: anytype, offset: u32, count: u32) u32 {
    var i = offset;
    for (0..count) |_| {
        while (i > 0) {
            const len = prevCodepoint(buf, i);
            i -= len;

            var builder = CodepointBuilder{};
            for (i..i + len) |j| _ = builder.appendByte(buf.get(@intCast(j)));
            if (wcWidth(builder.codepoint()) != 0) break;
        } else break;
    }

    return offset - i;
}

pub fn sliceToCp(slice: []const u8) [4]u8 {
    assert(slice.len > 0);
    var buf: [4]u8 = undefined;
    const len = unicode.utf8ByteSequenceLength(slice[0]) catch 1;
    @memcpy(buf[0..len], slice[0..len]);
    return buf;
}

/// Converts a UTF-8 codepoint array to a slice
pub fn cpToSlice(array: *const [4]u8) []const u8 {
    const len = unicode.utf8ByteSequenceLength(array[0]) catch 1;
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
    normal_word_inside,
    long_word_inside,
    normal_word_around,
    long_word_around,

    inside_delimiters: Delimiters,
    around_delimiters: Delimiters,
    inside_delimiters_scalar: [2]u8,
    around_delimiters_scalar: [2]u8,
    inside_single_delimiter_scalar: u8,
    around_single_delimiter_scalar: u8,
    inside_single_delimiter: u21,
    around_single_delimiter: u21,

    to_forwards: u21,
    to_backwards: u21,
    until_forwards: u21,
    until_backwards: u21,

    normal_word_start_next,
    normal_word_start_prev,
    normal_word_end_next,
    normal_word_end_prev,
    long_word_start_next,
    long_word_start_prev,
    long_word_end_next,
    long_word_end_prev,
    char_next,
    char_prev,
    line,
    eol,
    bol,

    to_forwards_utf8: []const u8,
    to_backwards_utf8: []const u8,
    until_forwards_utf8: []const u8,
    until_backwards_utf8: []const u8,

    pub const WordType = enum {
        normal,
        long,
    };

    pub fn do(motion: Motion, buf: anytype, pos: u32, count: u32) Range {
        return switch (motion) {
            .normal_word_start_next => .{
                .start = pos,
                .end = nextWordStart(buf, .normal, pos, count),
            },
            .normal_word_start_prev => .{
                .start = prevWordStart(buf, .normal, pos, count),
                .end = pos,
            },
            .normal_word_end_next => .{
                .start = pos,
                .end = nextWordEnd(buf, .normal, pos, count),
            },
            .normal_word_end_prev => .{
                .start = prevWordEnd(buf, .normal, pos, count),
                .end = pos,
            },
            .long_word_start_next => .{
                .start = pos,
                .end = nextWordStart(buf, .long, pos, count),
            },
            .long_word_start_prev => .{
                .start = prevWordStart(buf, .long, pos, count),
                .end = pos,
            },
            .long_word_end_next => .{
                .start = pos,
                .end = nextWordEnd(buf, .long, pos, count),
            },
            .long_word_end_prev => .{
                .start = prevWordEnd(buf, .long, pos, count),
                .end = pos,
            },
            .char_next => .{
                .start = pos,
                .end = pos + nextCharacter(buf, pos, count),
            },
            .char_prev => .{
                .start = pos - prevCharacter(buf, pos, count),
                .end = pos,
            },
            .line => .{
                .start = 0,
                .end = buf.length(),
            },
            .eol => .{
                .start = pos,
                .end = buf.length(),
            },
            .bol => .{
                .start = 0,
                .end = pos,
            },
            .normal_word_inside => insideWord(buf, .normal, pos),
            .long_word_inside => insideWord(buf, .long, pos),

            .normal_word_around => aroundWord(buf, .normal, pos),
            .long_word_around => aroundWord(buf, .long, pos),

            .inside_delimiters => |d| insideDelimitersCp(buf, d.left, d.right, pos),
            .around_delimiters => |d| aroundDelimitersCp(buf, d.left, d.right, pos),
            .inside_delimiters_scalar => |c| insideDelimitersScalar(buf, c[0], c[1], pos),
            .around_delimiters_scalar => |c| aroundDelimitersScalar(buf, c[0], c[1], pos),
            .inside_single_delimiter => |cp| insideDelimitersCp(buf, cp, cp, pos),
            .around_single_delimiter => |cp| aroundDelimitersCp(buf, cp, cp, pos),
            .inside_single_delimiter_scalar => |c| insideSingleDelimiterScalar(buf, c, pos),
            .around_single_delimiter_scalar => |c| aroundSingleDelimiterScalar(buf, c, pos),

            .to_forwards => |cp| .{
                .start = pos,
                .end = toForwardsCp(buf, cp, pos, count) orelse pos,
            },
            .to_backwards => |cp| .{
                .start = toBackwardsCp(buf, cp, pos, count) orelse pos,
                .end = pos,
            },
            .until_forwards => |cp| .{
                .start = pos,
                .end = untilForwardsCp(buf, cp, pos +| 1, count) orelse pos,
            },
            .until_backwards => |cp| .{
                .start = untilBackwardsCp(buf, cp, pos -| 1, count) orelse pos,
                .end = pos,
            },

            .to_forwards_utf8 => |needle| .{
                .start = pos,
                .end = toForwards(buf, needle, pos, count) orelse pos,
            },
            .to_backwards_utf8 => |needle| .{
                .start = toBackwards(buf, needle, pos, count) orelse pos,
                .end = pos,
            },
            .until_forwards_utf8 => |needle| .{
                .start = pos,
                .end = untilForwards(buf, needle, pos +| 1, count) orelse pos,
            },
            .until_backwards_utf8 => |needle| .{
                .start = untilBackwards(buf, needle, pos -| 1, count) orelse pos,
                .end = pos,
            },
        };
    }

    /// Returns the byte position of the next word
    fn nextWordStart(
        buf: anytype,
        comptime word_type: WordType,
        start_pos: u32,
        count: u32,
    ) u32 {
        const boundary = wordBoundaryFn(word_type);
        var pos = start_pos;

        for (0..count) |_| {
            if (pos >= buf.length()) break;

            if (boundary(buf.get(pos))) {
                while (pos < buf.length()) : (pos += nextCharacter(buf, pos, 1)) {
                    if (!boundary(buf.get(pos)) or isWhitespace(buf.get(pos))) break;
                }
            } else {
                while (pos < buf.length()) : (pos += nextCharacter(buf, pos, 1)) {
                    if (boundary(buf.get(pos))) break;
                }
            }

            while (pos < buf.length()) : (pos += nextCharacter(buf, pos, 1)) {
                if (!isWhitespace(buf.get(pos))) break;
            }
        }

        return pos;
    }

    fn prevWordStart(
        buf: anytype,
        comptime word_type: WordType,
        start_pos: u32,
        count: u32,
    ) u32 {
        if (buf.length() == 0) return 0;

        const boundary = wordBoundaryFn(word_type);
        var pos = start_pos;

        for (0..count) |_| {
            while (pos > 0) {
                pos -= prevCharacter(buf, pos, 1);
                if (!isWhitespace(buf.get(pos))) break;
            } else break;

            var p = pos;
            if (boundary(buf.get(p))) {
                while (p > 0) {
                    p -= prevCharacter(buf, p, 1);
                    if (!boundary(buf.get(p)) or isWhitespace(buf.get(p))) break;
                    pos = p;
                }
            } else {
                while (p > 0) {
                    p -= prevCharacter(buf, p, 1);
                    if (boundary(buf.get(p))) break;
                    pos = p;
                }
            }
        }

        return pos;
    }

    fn nextWordEnd(
        buf: anytype,
        comptime word_type: WordType,
        start_pos: u32,
        count: u32,
    ) u32 {
        if (buf.length() == 0) return 0;

        const boundary = wordBoundaryFn(word_type);
        var pos = start_pos;

        for (0..count) |_| {
            pos += nextCodepoint(buf, pos);
            while (pos < buf.length() and isWhitespace(buf.get(pos))) {
                pos += nextCodepoint(buf, pos);
            }
            if (pos == buf.length()) return pos;

            var p = pos;
            if (boundary(buf.get(pos))) {
                while (p < buf.length()) : (p += nextCharacter(buf, p, 1)) {
                    if (!boundary(buf.get(p)) or isWhitespace(buf.get(p))) break;
                    pos = p;
                }
            } else {
                while (p < buf.length()) : (p += nextCharacter(buf, p, 1)) {
                    if (boundary(buf.get(p))) break;
                    pos = p;
                }
            }
        }

        return pos;
    }

    fn prevWordEnd(
        buf: anytype,
        comptime word_type: WordType,
        start_pos: u32,
        count: u32,
    ) u32 {
        if (buf.length() == 0) return 0;

        if (start_pos >= buf.length())
            return prevWordEnd(buf, word_type, buf.length() - prevCharacter(buf, buf.length(), 1), count - 1);

        const boundary = wordBoundaryFn(word_type);
        var pos = start_pos;

        for (0..count) |_| {
            if (boundary(buf.get(pos))) {
                while (pos > 0 and boundary(buf.get(pos)) and !isWhitespace(buf.get(pos))) {
                    pos -= prevCodepoint(buf, pos);
                }
            } else {
                while (pos > 0 and !boundary(buf.get(pos))) {
                    pos -= prevCodepoint(buf, pos);
                }
            }
            while (pos > 0 and isWhitespace(buf.get(pos))) {
                pos -= prevCodepoint(buf, pos);
            }
        }

        return pos;
    }

    fn insideWord(buf: anytype, comptime word_type: WordType, pos: u32) Range {
        if (buf.length() == 0) return .{ .start = 0, .end = 0 };

        var iter = utils.reverseIterator(buf);
        iter.index = pos;
        var start: u32 = pos;
        var end: u32 = pos;

        const boundary = wordBoundaryFn(word_type);

        if (!boundary(buf.get(pos))) {
            while (iter.next()) |c| : (start -= 1) {
                if (boundary(c)) break;
            }

            var forward_iter = utils.Iterator(@TypeOf(buf)){
                .data = buf,
                .index = pos,
            };
            while (forward_iter.next()) |c| {
                if (boundary(c)) break;
                end += 1;
            }
        } else {
            while (iter.next()) |c| : (start -= 1) {
                if (!boundary(c)) break;
            }

            var forward_iter = utils.Iterator(@TypeOf(buf)){
                .data = buf,
                .index = pos,
            };
            while (forward_iter.next()) |c| {
                if (!boundary(c)) break;
                end += 1;
            }
        }

        return .{
            .start = start,
            .end = end,
        };
    }

    fn aroundWord(buf: anytype, comptime word_type: WordType, pos: u32) Range {
        if (buf.length() == 0) return .{ .start = 0, .end = 0 };

        var iter = utils.ReverseIterator(@TypeOf(buf)){
            .data = buf,
            .index = pos,
        };
        var start = pos;
        var end = pos;

        const boundary = wordBoundaryFn(word_type);

        if (!boundary(buf.get(pos))) {
            while (iter.next()) |c| : (start -= 1) {
                if (boundary(c)) break;
            }

            var forward_iter = utils.Iterator(@TypeOf(buf)){
                .data = buf,
                .index = pos,
            };
            while (forward_iter.next()) |c| {
                if (boundary(c)) break;
                end += 1;
            }

            forward_iter.index = end;
            while (forward_iter.next()) |c| {
                if (!isWhitespace(c)) break;
                end += 1;
            }
        } else {
            while (iter.next()) |c| : (start -= 1) {
                if (!boundary(c)) break;
            }

            var forward_iter = utils.Iterator(@TypeOf(buf)){
                .data = buf,
                .index = pos,
            };
            while (forward_iter.next()) |c| {
                if (!boundary(c)) break;
                end += 1;
            }

            forward_iter.index = end;
            while (forward_iter.next()) |c| {
                if (isWhitespace(c)) break;
                end += 1;
            }
        }

        return .{
            .start = start,
            .end = end,
        };
    }

    fn insideDelimitersScalar(buf: anytype, left: u8, right: u8, pos: u32) Range {
        const range = aroundDelimitersScalar(buf, left, right, pos);
        return if (range.start == range.end)
            range
        else
            .{
                .start = range.start + nextCodepoint(buf, range.start),
                .end = range.end - prevCodepoint(buf, range.end),
            };
    }

    fn aroundDelimitersScalar(buf: anytype, left: u8, right: u8, pos: u32) Range {
        const len = buf.length();
        if (len == 0) return .{ .start = 0, .end = 0 };
        assert(pos < len);

        const start = blk: {
            if (buf.get(pos) == left) break :blk pos;
            var i = pos;
            var depth: u32 = 0;
            while (i > 0) {
                i -= 1;
                const c = buf.get(i);
                if (c == left) {
                    if (depth == 0) break;
                    depth -= 1;
                } else if (c == right) {
                    depth += 1;
                }
            } else return .{ .start = pos, .end = pos };

            break :blk i;
        };

        const end = 1 + blk: {
            if (buf.get(pos) == right) break :blk pos;
            var i = pos + 1;
            var depth: u32 = 0;
            while (i < len) : (i += 1) {
                const c = buf.get(i);
                if (c == right) {
                    if (depth == 0) break;
                    depth -= 1;
                } else if (c == left) {
                    depth += 1;
                }
            } else return .{ .start = pos, .end = pos };

            break :blk i;
        };

        return .{
            .start = start,
            .end = end,
        };
    }

    fn insideSingleDelimiterScalar(buf: anytype, delim: u8, pos: u32) Range {
        const range = aroundSingleDelimiterScalar(buf, delim, pos);
        return if (range.start == range.end)
            range
        else
            .{
                .start = range.start + nextCodepoint(buf, range.start),
                .end = range.end - prevCodepoint(buf, range.end),
            };
    }

    fn aroundSingleDelimiterScalar(buf: anytype, delim: u8, pos: u32) Range {
        const len = buf.length();
        if (len == 0) return .{ .start = 0, .end = 0 };

        // This is ambiguous
        if (buf.get(pos) == delim) return .{ .start = pos, .end = pos };

        const start = utils.lastIndexOfPosScalar(buf, pos, delim) orelse return .{
            .start = pos,
            .end = pos,
        };

        const end = 1 + (utils.indexOfPosScalar(buf, pos, delim) orelse return .{
            .start = pos,
            .end = pos,
        });

        return .{
            .start = start,
            .end = end,
        };
    }

    fn insideDelimitersCp(
        buf: anytype,
        left_cp: u21,
        right_cp: u21,
        pos: u32,
    ) Range {
        const err_ret = Range{
            .start = pos,
            .end = pos,
        };
        var b: [8]u8 = undefined;
        const left_len = utf8Encode(left_cp, &b) catch return err_ret;
        const left = b[0..left_len];

        const right_len = utf8Encode(right_cp, b[4..]) catch return err_ret;
        const right = b[4 .. 4 + right_len];

        return insideDelimiters(buf, left, right, pos);
    }

    fn insideDelimiters(buf: anytype, left: []const u8, right: []const u8, pos: u32) Range {
        if (buf.length() == 0) return .{ .start = 0, .end = 0 };

        var ret = aroundDelimiters(buf, left, right, pos);
        if (ret.start == ret.end) return ret;
        ret.start += nextCodepoint(buf, ret.start);
        ret.end -= prevCodepoint(buf, ret.end);
        return ret;
    }

    fn aroundDelimitersCp(
        buf: anytype,
        left_cp: u21,
        right_cp: u21,
        pos: u32,
    ) Range {
        const err_ret = Range{
            .start = pos,
            .end = pos,
        };
        var b: [8]u8 = undefined;
        const left_len = utf8Encode(left_cp, &b) catch return err_ret;
        const left = b[0..left_len];

        const right_len = utf8Encode(right_cp, b[4..]) catch return err_ret;
        const right = b[4 .. 4 + right_len];
        return aroundDelimiters(buf, left, right, pos);
    }

    // TODO: this is pretty inefficient
    fn aroundDelimiters(
        buf: anytype,
        left: []const u8,
        right: []const u8,
        pos: u32,
    ) Range {
        if (buf.length() == 0) return .{ .start = 0, .end = 0 };
        assert(pos < buf.length());
        assert((unicode.utf8ByteSequenceLength(left[0]) catch unreachable) == left.len);
        assert((unicode.utf8ByteSequenceLength(right[0]) catch unreachable) == right.len);

        var i = pos;
        var depth: i32 = if (utils.containsAt(buf, pos, right)) -1 else 0;
        while (true) : (i -= 1) {
            if (utils.containsAt(buf, i, left)) {
                if (depth == 0) break;
                depth -= 1;
            } else if (utils.containsAt(buf, i, right)) {
                depth += 1;
            }

            if (i == 0) return .{
                .start = pos,
                .end = pos,
            };
        }

        var j = pos;
        depth = if (utils.containsAt(buf, pos, left)) -1 else 0;

        while (j < buf.length()) : (j += 1) {
            if (utils.containsAt(buf, j, right)) {
                if (depth == 0) {
                    j += @intCast(right.len);
                    break;
                }
                depth -= 1;
            } else if (utils.containsAt(buf, j, left)) {
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

    fn toForwardsCp(buf: anytype, cp: u21, pos: u32, count: u32) ?u32 {
        var b: [4]u8 = undefined;
        const len = utf8Encode(cp, &b) catch 1;
        return toForwards(buf, b[0..len], pos, count);
    }

    fn toBackwardsCp(buf: anytype, cp: u21, pos: u32, count: u32) ?u32 {
        var b: [4]u8 = undefined;
        const len = utf8Encode(cp, &b) catch 1;
        return toBackwards(buf, b[0..len], pos, count);
    }

    fn untilForwardsCp(buf: anytype, cp: u21, pos: u32, count: u32) ?u32 {
        var b: [4]u8 = undefined;
        const len = utf8Encode(cp, &b) catch 1;
        return untilForwards(buf, b[0..len], pos, count);
    }

    fn untilBackwardsCp(buf: anytype, cp: u21, pos: u32, count: u32) ?u32 {
        var b: [4]u8 = undefined;
        const len = utf8Encode(cp, &b) catch 1;
        return untilBackwards(buf, b[0..len], pos, count);
    }

    fn toForwards(buf: anytype, needle: []const u8, pos: u32, count: u32) ?u32 {
        if (pos >= buf.length() or count == 0) return pos;

        const first = 1 + (utils.indexOfPos(buf, pos + 1, needle) orelse return null) - (pos + 1);
        var p = pos + first;

        for (1..count) |_| {
            if (p >= buf.length()) break;
            p += 1 + (utils.indexOfPos(buf, p + 1, needle) orelse break) - (p + 1);
        }

        return @intCast(p);
    }

    fn toBackwards(buf: anytype, needle: []const u8, pos: u32, count: u32) ?u32 {
        assert(pos <= buf.length());
        if (count == 0) return pos;

        var p = (utils.lastIndexOfPos(buf, pos, needle) orelse return null);

        for (1..count) |_| {
            p = (utils.lastIndexOfPos(buf, p, needle) orelse break);
        }

        return p;
    }

    fn untilForwards(buf: anytype, needle: []const u8, pos: u32, count: u32) ?u32 {
        const ret = toForwards(buf, needle, pos, count) orelse return null;
        return ret - prevCharacter(buf, ret, 1);
    }

    fn untilBackwards(buf: anytype, needle: []const u8, pos: u32, count: u32) ?u32 {
        const ret = toBackwards(buf, needle, pos, count) orelse return null;
        return ret + nextCharacter(buf, ret, 1);
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

const GapBuffer = @import("GapBuffer.zig");

fn testMotion(
    text: []const u8,
    start: u32,
    start_pos: u32,
    end_pos: u32,
    motion: Motion,
    count: u32,
) !void {
    var buf = GapBuffer{};
    defer buf.deinit(std.testing.allocator);

    try buf.appendSlice(std.testing.allocator, text);

    const range = motion.do(buf, start, count);
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
