// TODO
//  Handle more complicated key sequences using a hashmap
const std = @import("std");
const utils = @import("utils.zig");
const spoon = @import("spoon");
const wcWidth = @import("wcwidth").wcWidth;
const inputParser = spoon.inputParser;
const assert = std.debug.assert;
const isWhitespace = std.ascii.isWhitespace;
const log = std.log.scoped(.text_input);

pub const Action = union(enum) {
	submit_command,
	enter_normal_mode,

	enter_insert_mode,
	enter_insert_mode_after,
	enter_insert_mode_at_eol,
	enter_insert_mode_at_bol,

	backspace,
	delete_char,
	change_to_eol,
	delete_to_eol,
	change_char,
	change_line,
	backwards_delete_word,

	operator_delete,
	operator_change,

	zero,
	count: u4,
	insert: []const u8,
	motion: Motion,
};

/// A wrapper around a buffer that provides cli editing functions. Backed by a fixed size buffer.
pub fn TextInput(comptime size: u16) type {
	return struct {
		const Self = @This();
		const Array = std.BoundedArray(u8, size);

		/// A tagged union representing the state of a TextInput instance.
		pub const Status = union(enum) {
			/// Waiting for more input
			waiting,

			/// Editing was cancelled
			cancelled,

			/// Editing finished and the resulting string is stored in this field
			string: Array,
		};

		pub const Mode = union(enum) {
			normal,
			insert,
			operator_pending: Operator,
		};

		/// Determines what happens when a motion is done.
		pub const Operator = enum {
			change,
			delete,
		};

		pub const WriteError = error{};
		pub const Writer = std.io.Writer(*Self, WriteError, write);

		buf: Array = .{},
		mode: Mode = .insert,
		count: u32 = 0,
		cursor: u16 = 0,

		pub fn do(self: *Self, action: Action) Status {
			switch (self.mode) {
				.normal => switch (action) {
					.submit_command => return .{ .string = self.finish() },
					.enter_normal_mode => {
						self.reset();
						return .cancelled;
					},
					.enter_insert_mode => self.setMode(.insert),
					.enter_insert_mode_after => {
						self.setMode(.insert);
						self.doMotion(.char_next);
					},
					.enter_insert_mode_at_eol => {
						self.setMode(.insert);
						self.doMotion(.eol);
					},
					.enter_insert_mode_at_bol => {
						self.setMode(.insert);
						self.doMotion(.bol);
					},
					.operator_delete => self.setOperator(.delete),
					.operator_change => self.setOperator(.change),

					.delete_char => self.delChar(),
					.change_to_eol => {
						self.buf.len = self.cursor;
						self.setMode(.insert);
					},
					.delete_to_eol => {
						self.buf.len = self.cursor;
					},
					.change_char => {
						self.delChar();
						self.mode = .insert;
					},
					.change_line => self.reset(),

					.zero => {
						if (self.count == 0) {
							_ = self.do(.{ .motion = .bol });
						} else {
							self.setCount(0);
						}
					},
					.motion => |motion| self.doMotion(motion),
					.count => |count| self.setCount(count),
					else => {},
				},
				.insert => switch (action) {
					.insert => |buf| {
						assert(buf.len > 0);
						switch (buf[0]) {
							0...31 => {},
							else => {
								self.buf.insertSlice(self.cursor, buf) catch return .waiting;
								self.cursor += @intCast(u16, buf.len);
							},
						}
					},
					.backspace => self.backspace(),
					.submit_command => return .{ .string = self.finish() },
					.enter_normal_mode => self.setMode(.normal),
					.backwards_delete_word => {
						self.mode = .{ .operator_pending = .change };
						_ = self.do(.{ .motion = .normal_word_start_prev });
					},
					.change_line => self.reset(),
					.motion => |motion| self.doMotion(motion),
					else => {},
				},
				.operator_pending => |op| switch (op) {
					.delete => switch (action) {
						.enter_normal_mode => self.setMode(.normal),
						.operator_delete => self.doMotion(.line),
						.zero => if (self.count == 0) self.doMotion(.bol) else self.setCount(0),
						.count => |count| self.setCount(count),
						.motion => |motion| self.doMotion(motion),
						else => {},
					},
					.change => switch (action) {
						.enter_normal_mode => self.setMode(.normal),
						.operator_change => self.doMotion(.line),
						.zero => if (self.count == 0) self.doMotion(.bol) else self.setCount(0),
						.count => |count| self.setCount(count),
						.motion => |motion| self.doMotion(motion),
						else => {},
					},
				},
			}
			return .waiting;
		}

		pub fn setOperator(self: *Self, operator: Operator) void {
			self.mode = .{
				.operator_pending = operator,
			};
		}

		pub fn setCount(self: *Self, count: u4) void {
			assert(count <= 9);
			self.count = self.count *| 10 +| count;
		}

		pub fn getCount(self: Self) u32 {
			return if (self.count == 0) 1 else self.count;
		}

		pub fn resetCount(self: *Self) void {
			self.count = 0;
		}

		fn doMotion(self: *Self, motion: Motion) void {
			const count = self.getCount();
			switch (self.mode) {
				.normal, .insert => {
					const range = motion.do(self.slice(), self.cursor, count);
					self.cursor = if (range.start == self.cursor)
							range.end
						else
							range.start;
						
				},
				.operator_pending => |op| switch (op) {
					.change => {
						const m = switch (motion) {
							.normal_word_start_next => .normal_word_end_next,
							.long_word_start_next => .long_word_end_next,
							else => motion,
						};

						const range = m.do(self.slice(), self.cursor, count);
						const start = range.start;
						const end = range.end + switch (m) {
							.normal_word_end_next,
							.long_word_end_next,
								=> nextCharacter(self.slice(), range.end),
							else => 0,
						};

						assert(end >= start);
						self.buf.replaceRange(start, end - start, &.{}) catch unreachable;

						self.cursor = start;
						self.setMode(.insert);
					},
					.delete => {
						const range = motion.do(self.slice(), self.cursor, count);
						self.buf.replaceRange(range.start, range.len(), &.{}) catch unreachable;
						self.cursor = range.start;
						self.setMode(.normal);
					},
				},
			}
			self.clampCursor();
			self.resetCount();
		}

		fn delChar(self: *Self) void {
			if (self.buf.len == 0) return;

			const length = nextCharacter(self.slice(), self.cursor);
			self.buf.replaceRange(self.cursor, length, &.{}) catch unreachable;
			self.clampCursor();
		}

		fn endPos(self: Self) u16 {
			return if (self.mode == .normal)
					self.len() - prevCharacter(self.slice(), self.len())
				else
					self.len();
		}

		fn clampCursor(self: *Self) void {
			const end = self.endPos();
			if (self.cursor > end)
				self.cursor = end;
		}

		fn backspace(self: *Self) void {
			self.mode = .{ .operator_pending = .change };
			_ = self.do(.{ .motion = .char_prev });
		}

		fn setMode(self: *Self, mode: Mode) void {
			if (mode == .normal and self.cursor == self.buf.len) {
				const m: Motion = .char_prev;
				self.cursor = m.do(self.slice(), self.len(), 1).start;
			}
			self.resetCount();
			self.mode = mode;
		}

		/// Moves the cursor forward by `n` characters.
		fn cursorForward(self: *Self, n: u16) void {
			const end = self.endPos();
			const bytes = self.slice();
			for (0..n) |_| {
				if (self.cursor >= end) break;
				self.cursor += nextCharacter(bytes, self.cursor);
			}
		}

		/// Moves the cursor backward by `n` characters;
		fn cursorBackward(self: *Self, n: u16) void {
			const bytes = self.slice();
			for (0..n) |_| {
				if (self.cursor == 0) break;
				self.cursor -= prevCharacter(bytes, self.cursor);
			}
		}

		/// Returns a copy of the internal buffer and resets internal buffer
		fn finish(self: *Self) Array {
			defer self.reset();
			return self.buf;
		}

		pub fn write(self: *Self, bytes: []const u8) WriteError!usize {
			self.buf.insertSlice(self.cursor, bytes) catch return bytes.len;
			self.cursor += @intCast(u16, bytes.len);
			return bytes.len;
		}

		/// Writes to the buffer at the current cursor position, updating it accordingly
		pub fn writer(self: *Self) Writer {
			return Writer{
				.context = self,
			};
		}

		pub fn reset(self: *Self) void {
			self.buf.len = 0;
			self.cursor = 0;
			self.setMode(.insert);
		}

		pub fn slice(self: *const Self) []const u8 {
			return self.buf.slice();
		}

		pub fn len(self: Self) u16 {
			return @intCast(u16, self.buf.len);
		}
	};
}

fn isContinuation(c: u8) bool {
	return c & 0xC0 == 0x80;
}

fn nextCodepoint(bytes: []const u8, offset: u16) u16 {
	return std.unicode.utf8ByteSequenceLength(bytes[offset]) catch unreachable;
}

fn prevCodepoint(bytes: []const u8, offset: u16) u16 {
	if (offset == 0) return 0;

	var iter = std.mem.reverseIterator(bytes[0..offset]);
	while (iter.next()) |c| {
		if (!isContinuation(c)) break;
	}
	return offset - @intCast(u16, iter.index);
}

fn nextCharacter(bytes: []const u8, offset: u16) u16 {
	var iter = std.unicode.Utf8Iterator{
		.bytes = bytes[offset..],
		.i = 0,
	};

	while (iter.nextCodepoint()) |cp| {
		if (wcWidth(cp) != 0) break;
	}

	return @intCast(u16, iter.i);
}

fn prevCharacter(bytes: []const u8, offset: u16) u16 {
	var i: u16 = offset;
	while (i > 0) {
		const len = prevCodepoint(bytes, i);
		i -= len;

		const cp = std.unicode.utf8Decode(bytes[i..i + len]) catch continue;
		if (wcWidth(cp) != 0) break;
	}

	return offset - i;
}

pub const Motion = union(enum) {
	normal_word_inside,
	long_word_inside,
	normal_word_around,
	long_word_around,

	inside_delimiters: Delimiters,
	around_delimiters: Delimiters,
	inside_single_delimiter: []const u8,
	around_single_delimiter: []const u8,

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

	pub const WordType = enum {
		normal,
		long,
	};

	pub const Delimiters = struct {
		left: []const u8,
		right: []const u8,
	};

	pub const Range = struct {
		start: u16,
		end: u16,

		pub inline fn len(range: Range) u16 {
			return range.end - range.start;
		}
	};

	pub fn do(motion: Motion, bytes: []const u8, pos: u16, count: u32) Range {
		return switch (motion) {
			.normal_word_start_next => .{
				.start = pos,
				.end = blk: {
					var p = pos;
					for (0..count) |_| {
						if (p >= bytes.len) break;
						p = nextWordStart(bytes, .normal, p);
					}
					break :blk p;
				},
			},
			.normal_word_start_prev => .{
				.start = blk: {
					var p = pos;
					for (0..count) |_| {
						if (p == 0) break;
						p = prevWordStart(bytes, .normal, p);
					}
					break :blk p;
				},
				.end = pos,
			},
			.normal_word_end_next => .{
				.start = pos,
				.end = blk: {
					var p = pos;
					for (0..count) |_| {
						if (p >= bytes.len) break;
						p = nextWordEnd(bytes, .normal, p);
					}
					break :blk p;
				},
			},
			.normal_word_end_prev => .{
				.start = blk: {
					var p = pos;
					for (0..count) |_| {
						if (p == 0) break;
						p = prevWordEnd(bytes, .normal, p);
					}
					break :blk p;
				},
				.end = pos,
			},
			.long_word_start_next => .{
				.start = pos,
				.end = blk: {
					var p = pos;
					for (0..count) |_| {
						if (p >= bytes.len) break;
						p = nextWordStart(bytes, .long, p);
					}
					break :blk p;
				},
			},
			.long_word_start_prev => .{
				.start = blk: {
					var p = pos;
					for (0..count) |_| {
						if (p == 0) break;
						p = prevWordStart(bytes, .long, p);
					}
					break :blk p;
				},
				.end = pos,
			},
			.long_word_end_next => .{
				.start = pos,
				.end = blk: {
					var p = pos;
					for (0..count) |_| {
						if (p >= bytes.len) break;
						p = nextWordEnd(bytes, .long, p);
					}
					break :blk p;
				},
			},
			.long_word_end_prev => .{
				.start = blk: {
					var p = pos;
					for (0..count) |_| {
						if (p == 0) break;
						p = prevWordEnd(bytes, .long, p);
					}
					break :blk p;
				},
				.end = pos,
			},
			.char_next => .{
				.start = pos,
				.end = blk: {
					var p = pos;
					for (0..count) |_| {
						if (p >= bytes.len) break;
						p += nextCharacter(bytes, p);
					}
					break :blk p;
				},
			},
			.char_prev => .{
				.start = blk: {
					var p = pos;
					for (0..count) |_| {
						if (p == 0) break;
						p -= prevCharacter(bytes, p);
					}
					break :blk p;
				},
				.end = pos,
			},
			.line => .{
				.start = 0,
				.end = @intCast(u16, bytes.len),
			},
			.eol => .{
				.start = pos,
				.end = @intCast(u16, bytes.len),
			},
			.bol => .{
				.start = 0,
				.end = pos,
			},
			.normal_word_inside => insideWord(bytes, .normal, pos),
			.long_word_inside => insideWord(bytes, .long, pos),
			.normal_word_around => aroundWord(bytes, .normal, pos),
			.long_word_around => aroundWord(bytes, .long, pos),

			.inside_delimiters => |d| insideDelimiters(bytes, d.left, d.right, pos),
			.around_delimiters => |d| aroundDelimiters(bytes, d.left, d.right, pos),
			.inside_single_delimiter => |d| insideSingleDelimiter(bytes, d, pos),
			.around_single_delimiter => |d| aroundSingleDelimiter(bytes, d, pos),
		};
	}

	/// Returns the byte position of the next word
	fn nextWordStart(bytes: []const u8, comptime word_type: WordType, start_pos: u16) u16 {
		if (bytes.len == 0) return 0;

		const boundary = wordBoundaryFn(word_type);
		var pos = start_pos;

		if (boundary(bytes[pos])) {
			while (pos < bytes.len) : (pos += nextCharacter(bytes, pos)) {
				if (!boundary(bytes[pos]) or isWhitespace(bytes[pos])) break;
			}
		} else {
			while (pos < bytes.len) : (pos += nextCharacter(bytes, pos)) {
				if (boundary(bytes[pos])) break;
			}
		}

		while (pos < bytes.len) : (pos += nextCharacter(bytes, pos)) {
			if (!isWhitespace(bytes[pos])) break;
		}

		return pos;
	}

	fn prevWordStart(bytes: []const u8, comptime word_type: WordType, start_pos: u16) u16 {
		if (bytes.len == 0) return 0;

		const boundary = wordBoundaryFn(word_type);
		var pos = start_pos - prevCharacter(bytes, start_pos);

		while (pos > 0) : (pos -= prevCharacter(bytes, pos)) {
			if (!isWhitespace(bytes[pos])) break;
		} else return 0;

		var p = pos;
		if (boundary(bytes[pos])) {
			while (p > 0) : (p -= prevCharacter(bytes, p)) {
				if (!boundary(bytes[p]) or isWhitespace(bytes[p])) return pos;
				pos = p;
			}
			if (!boundary(bytes[p]) or isWhitespace(bytes[p])) return pos;
		} else {
			while (p > 0) : (p -= prevCharacter(bytes, p)) {
				if (boundary(bytes[p])) return pos;
				pos = p;
			}
			if (boundary(bytes[p])) return pos;
		}

		return 0;
	}

	fn nextWordEnd(bytes: []const u8, comptime word_type: WordType, start_pos: u16) u16 {
		if (bytes.len == 0) return 0;

		const boundary = wordBoundaryFn(word_type);

		var pos = start_pos + nextCodepoint(bytes, start_pos);
		while (pos < bytes.len and isWhitespace(bytes[pos])) : (pos += nextCodepoint(bytes, pos)) {}
		if (pos == bytes.len) return pos;

		var p = pos;
		if (boundary(bytes[pos])) {
			while (p < bytes.len) : (p += nextCharacter(bytes, p)) {
				if (!boundary(bytes[p]) or isWhitespace(bytes[p])) break;
				pos = p;
			}
		} else {
			while (p < bytes.len) : (p += nextCharacter(bytes, p)) {
				if (boundary(bytes[p])) break;
				pos = p;
			}
		}

		return pos;
	}

	fn prevWordEnd(bytes: []const u8, comptime word_type: WordType, start_pos: u16) u16 {
		if (bytes.len == 0) return 0;
		if (start_pos >= bytes.len) return @intCast(u16, bytes.len) - 1;

		const boundary = wordBoundaryFn(word_type);
		var pos = start_pos;

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

		return pos;
	}

	fn insideWord(bytes: []const u8, comptime word_type: WordType, pos: u16) Range {
		if (bytes.len == 0) return .{ .start = 0, .end = 0 };

		var iter = std.mem.reverseIterator(bytes[0..pos]);
		var start: u16 = pos;
		var end: u16 = pos;

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

	fn aroundWord(bytes: []const u8, comptime word_type: WordType, pos: u16) Range {
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

	fn insideDelimiters(bytes: []const u8, left: []const u8, right: []const u8, pos: u16) Range {
		if (bytes.len == 0) return .{ .start = 0, .end = 0 };

		var ret = aroundDelimiters(bytes, left, right, pos);
		if (ret.start == ret.end) return ret;
		ret.start += @intCast(u16, left.len);
		ret.end -= @intCast(u16, right.len);
		return ret;
	}

	// TODO: this is pretty inefficient
	fn aroundDelimiters(bytes: []const u8, left: []const u8, right: []const u8, pos: u16) Range {
		assert(left.len > 0);
		assert(right.len > 0);

		if (bytes.len == 0) return .{ .start = 0, .end = 0 };

		assert(pos < bytes.len);


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
					j += @intCast(u16, right.len);
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

	fn insideSingleDelimiter(bytes: []const u8, delim: []const u8, pos: u16) Range {
		if (bytes.len == 0) return .{ .start = 0, .end = 0 };

		var ret = aroundSingleDelimiter(bytes, delim, pos);
		if (ret.start == ret.end) return ret;
		ret.start += @intCast(u16, delim.len);
		ret.end -= @intCast(u16, delim.len);
		return ret;
	}

	fn aroundSingleDelimiter(
		bytes: []const u8,
		delim: []const u8,
		pos: u16,
	) Range {
		const len = @intCast(u16, delim.len);

		if (std.mem.startsWith(u8, bytes[pos..], delim)) {
			const start = std.mem.lastIndexOf(u8, bytes[0..pos], delim) orelse pos;
			const end = std.mem.indexOf(u8, bytes[pos + len..], delim) orelse pos;

			return .{
				.start = @intCast(u16, start),
				.end = len + @intCast(u16, end),
			};
		} else {
			const start = std.mem.lastIndexOf(u8, bytes[0..pos], delim) orelse pos;
			const end = if (std.mem.indexOf(u8, bytes[pos..], delim)) |x| pos + x else pos;
			return .{
				.start = @intCast(u16, start),
				.end = len + @intCast(u16, end),
			};
		}
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
	start: u16,
	start_pos: u16,
	end_pos: u16,
	motion: Motion,
	count: u32,
) !void {
	const range = motion.do(text, start, count);
	try std.testing.expectEqual(start_pos, range.start);
	try std.testing.expectEqual(end_pos, range.end);
}

test "Motions" {
	const text = "this漢字is .my. epic漢字. .漢字text";
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

	try testMotion(" ''word'' ", 5, " ''".len, " ''word".len, .{ .inside_single_delimiter = "'" }, 1);
	try testMotion(" ''word'' ", 5, " '".len, " ''word'".len, .{ .around_single_delimiter = "'" }, 1);

	const delims = .{ .left = "(", .right = ")" };
	try testMotion("((word))", 5, "((".len, "((word".len, .{ .inside_delimiters = delims }, 1);
	try testMotion("((word))", 5, "(".len, "((word)".len, .{ .around_delimiters = delims }, 1);
}
