// TODO
//  Handle more complicated key sequences using a hashmap
const std = @import("std");
const utils = @import("utils.zig");
const spoon = @import("spoon");
const wcWidth = @import("wcwidth").wcWidth;
const inputParser = spoon.inputParser;
const assert = std.debug.assert;
const isWhitespace = std.ascii.isWhitespace;

/// A wrapper around a buffer that provides cli editing functions. Backed by a fixed size buf.
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

		pub const Mode = enum {
			normal,
			insert,
		};

		/// Determines what happens when a motion is done.
		pub const Operation = enum {
			move,
			change,
			delete,
		};

		pub const WriteError = error{};
		pub const Writer = std.io.Writer(*Self, WriteError, write);

		buf: Array = .{},
		mode: Mode = .insert,
		cursor: u16 = 0,
		pending_operation: Operation = .move,

		/// Parses the input contained in `buf` and acts accordingly. Returns a tagged union
		/// representing whether we are finished gathering input or not.
		pub fn handleInput(self: *Self, buf: []const u8) Status {
			var iter = inputParser(buf);

			while (iter.next()) |in| {
				const status = switch (self.mode) {
					.normal => self.doNormalMode(in),
					.insert => self.doInsertMode(in),
				};
				if (status != .waiting)
					return status;
			}

			return .waiting;
		}

		fn doNormalMode(self: *Self, in: spoon.Input) Status {
			if (in.mod_ctrl) switch (in.content) {
				else => {},
			} else if (in.mod_alt) switch (in.content) {
				.codepoint => |cp| switch (cp) {
					'j', 'm', '\r', '\n' => return .{ .string = self.finish() },
					'e' => self.doMotion(.normal_word_end_prev),
					'E' => self.doMotion(.long_word_end_prev),
					else => {},
				},
				else => {},
			} else switch (in.content) {
				.escape => {
					if (self.pending_operation == .move) {
						self.reset();
						return .cancelled;
					} else {
						self.pending_operation = .move;
					}
				},
				.arrow_left  => self.doMotion(.char_prev),
				.arrow_right => self.doMotion(.char_next),
				.home => self.doMotion(.bol),
				.end => self.doMotion(.eol),
				.codepoint => |cp| switch (cp) {
					'\r', '\n' => return .{ .string = self.finish() },
					'x' => self.delChar(),
					'S' => self.reset(),
					'l' => self.doMotion(.char_next),
					'h' => self.doMotion(.char_prev),
					'$' => self.doMotion(.eol),
					'0' => self.doMotion(.bol),
					'w' => self.doMotion(.normal_word_start_next),
					'W' => self.doMotion(.long_word_start_next),
					'e' => self.doMotion(.normal_word_end_next),
					'E' => self.doMotion(.long_word_end_next),
					'b' => self.doMotion(.normal_word_start_prev),
					'B' => self.doMotion(.long_word_start_prev),
					'c' => {
						if (self.pending_operation == .change) {
							self.doMotion(.line);
						} else {
							self.pending_operation = .change;
						}
					},
					'C' => {
						self.buf.len = self.cursor;
						self.mode = .insert;
					},
					'd' => {
						if (self.pending_operation == .delete) {
							self.doMotion(.line);
						} else {
							self.pending_operation = .delete;
						}
					},
					'D' => self.buf.len = self.cursor,
					's' => {
						self.delChar();
						self.mode = .insert;
					},
					'i' => self.setMode(.insert),
					'I' => {
						self.setMode(.insert);
						self.doMotion(.bol);
					},
					'a' => {
						self.setMode(.insert);
						self.doMotion(.char_next);
					},
					'A' => {
						self.setMode(.insert);
						self.doMotion(.eol);
					},
					else => {},
				},
				else => {},
			}

			return .waiting;
		}

		fn doInsertMode(self: *Self, in: spoon.Input) Status {
			if (in.mod_ctrl) switch (in.content) {
				.codepoint => |cp| switch (cp) {
					'j', 'm', '\r', '\n' => return .{ .string = self.finish() },
					'h', 127 => self.backspace(),
					'f' => self.doMotion(.char_next),
					'b' => self.doMotion(.char_prev),
					'a' => self.doMotion(.bol),
					'e' => self.doMotion(.eol),
					'w' => {
						self.pending_operation = .change;
						self.doMotion(.normal_word_start_prev);
					},
					'u' => self.reset(),
					else => {},
				},
				else => {},
			} else switch (in.content) {
				.escape => self.setMode(.normal),
				.arrow_left => self.doMotion(.char_prev),
				.arrow_right => self.doMotion(.char_next),
				.home => self.doMotion(.bol),
				.end => self.doMotion(.eol),
				.codepoint => |cp| switch (cp) {
					'\n', '\r' => return .{ .string = self.finish() },
					127 => self.backspace(),

					// ignore control codes
					0...'\n'-1, '\n'+1...'\r'-1, '\r'+1...31 => {},

					else => {
						var buf: [8]u8 = undefined;
						const length = std.unicode.utf8Encode(cp, &buf) catch return .waiting;

						self.buf.insertSlice(self.cursor, buf[0..length]) catch return .waiting;
						self.cursor += length;
					},
				},
				else => {},
			}

			return .waiting;
		}

		fn doMotion(self: *Self, motion: Motion) void {
			switch (self.pending_operation) {
				.move => {
					const range = motion.do(self.slice(), self.cursor);
					self.cursor = if (range.start == self.cursor)
							range.end
						else
							range.start;
						
				},
				.change => {
					const m = switch (motion) {
						.normal_word_start_next => .normal_word_end_next,
						.long_word_start_next => .long_word_end_next,
						else => motion,
					};

					const range = m.do(self.slice(), self.cursor);
					const start = range.start;
					const end = range.end + switch (m) {
						.normal_word_end_next,
						.long_word_end_next,
							=> nextCharacter(self.slice(), range.end),
						else => 0,
					};

					self.buf.replaceRange(start, end - start, &.{}) catch unreachable;

					self.cursor = start;
					self.mode = .insert;
					self.pending_operation = .move;
				},
				.delete => {
					const range = motion.do(self.buf.slice(), self.cursor);
					self.buf.replaceRange(range.start, range.end - range.start, &.{}) catch unreachable;
					self.cursor = range.start;
					self.pending_operation = .move;
				},
			}
			self.clampCursor();
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
			self.pending_operation = .change;
			self.doMotion(.char_prev);
		}

		fn setMode(self: *Self, mode: Mode) void {
			if (mode == .normal and self.cursor == self.buf.len) {
				self.cursor = Motion.char_prev.do(self.slice(), self.len()).start;
			}
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

pub const Motion = enum {
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

	pub const Range = struct {
		start: u16,
		end: u16,
	};

	pub fn do(motion: Motion, bytes: []const u8, pos: u16) Range {
		return switch (motion) {
			.normal_word_start_next => .{
				.start = pos,
				.end = nextWordStart(bytes, .normal, pos),
			},
			.normal_word_start_prev => .{
				.start = prevWordStart(bytes, .normal, pos),
				.end = pos,
			},
			.normal_word_end_next => .{
				.start = pos,
				.end = nextWordEnd(bytes, .normal, pos),
			},
			.normal_word_end_prev => .{
				.start = prevWordEnd(bytes, .normal, pos),
				.end = pos,
			},
			.long_word_start_next => .{
				.start = pos,
				.end = nextWordStart(bytes, .long, pos),
			},
			.long_word_start_prev => .{
				.start = prevWordStart(bytes, .long, pos),
				.end = pos,
			},
			.long_word_end_next => .{
				.start = pos,
				.end = nextWordEnd(bytes, .long, pos),
			},
			.long_word_end_prev => .{
				.start = prevWordEnd(bytes, .long, pos),
				.end = pos,
			},
			.char_next => .{
				.start = pos,
				.end = pos + nextCharacter(bytes, pos),
			},
			.char_prev => .{
				.start = pos - prevCharacter(bytes, pos),
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

test "Text Input" {
	const t = std.testing;

	const testInput = struct {
		fn func(
			comptime size: usize,
			input: []const u8,
			status: std.meta.Tag(TextInput(size).Status),
		) !TextInput(size).Status {
			var buf = TextInput(size){};
			const ret = buf.handleInput(input);
			try t.expectEqual(status, ret);
			return ret;
		}
	}.func;

	var r = try testInput(1, "this is epic\n", .string);
	try t.expectEqualStrings("t", r.string.slice());

	_ = try testInput(1024, "hmmm", .waiting);
	_ = try testInput(1, "hmmmmmm", .waiting);
	_ = try testInput(1, "hmmmmmm\x1b\x1b", .cancelled);
}

test "Cursor Movements" {
	const t = std.testing;

	const T = TextInput(1024);
	var buf = T{};

	try t.expectEqual(@as(u16, 0), buf.cursor);
	try t.expectEqual(T.Status.waiting, buf.handleInput("filler text\x1b"));
	try t.expectEqual(@intCast(u16, buf.buf.len - 1), buf.cursor);
	try t.expectEqual(T.Status.waiting, buf.handleInput("llllll"));
	try t.expectEqual(@intCast(u16, buf.buf.len - 1), buf.cursor);
	try t.expectEqual(T.Status.waiting, buf.handleInput("0"));
	try t.expectEqual(@as(u16, 0), buf.cursor);
	try t.expectEqual(T.Status.waiting, buf.handleInput("$"));
	try t.expectEqual(@intCast(u16, buf.buf.len - 1), buf.cursor);
	try t.expectEqual(T.Status.waiting, buf.handleInput("0"));
	try t.expectEqual(@as(u16, 0), buf.cursor);
	try t.expectEqual(T.Status.waiting, buf.handleInput("h"));
	try t.expectEqual(@as(u16, 0), buf.cursor);
	try t.expectEqual(T.Status.waiting, buf.handleInput("hhhhh"));
	try t.expectEqual(@as(u16, 0), buf.cursor);
	try t.expectEqual(T.Status.waiting, buf.handleInput("ll"));
	try t.expectEqual(@as(u16, 2), buf.cursor);
	try t.expectEqual(T.Status.waiting, buf.handleInput("lll"));
	try t.expectEqual(@as(u16, 5), buf.cursor);
	try t.expectEqual(T.Status.waiting, buf.handleInput("h"));
	try t.expectEqual(@as(u16, 4), buf.cursor);
	try t.expectEqual(T.Status.waiting, buf.handleInput("h"));
	try t.expectEqual(@as(u16, 3), buf.cursor);
	try t.expectEqual(T.Status.waiting, buf.handleInput("hh"));
	try t.expectEqual(@as(u16, 1), buf.cursor);

	try t.expectEqual(T.Status.waiting, buf.handleInput("0w"));
	try t.expectEqual("filler ".len, buf.cursor);
	try t.expectEqual(T.Status.waiting, buf.handleInput("w"));
	try t.expectEqual("filler text".len - 1, buf.cursor);
}

test "Motions" {
	const t = std.testing;
	var buf = TextInput(1024){};

	_ = buf.handleInput("漢字漢字");
	try t.expectEqual("漢字漢字".len, buf.cursor);
	_ = buf.handleInput("\x1b");
	try t.expectEqual("漢字漢".len, buf.cursor);
	_ = buf.handleInput("hh");
	try t.expectEqual("漢".len, buf.cursor);
	_ = buf.handleInput("h");
	try t.expectEqual(@as(u16, 0), buf.cursor);
	_ = buf.handleInput("e");
	try t.expectEqual("漢字漢".len, buf.cursor);
	_ = buf.handleInput("b");
	try t.expectEqual(@as(u16, 0), buf.cursor);
	_ = buf.handleInput("w");
	try t.expectEqual("漢字漢".len, buf.cursor);
	_ = buf.handleInput("0");
	try t.expectEqual(@as(u16, 0), buf.cursor);
	_ = buf.handleInput("$");
	try t.expectEqual("漢字漢".len, buf.cursor);
	_ = buf.handleInput("i\x06");
	try t.expectEqual("漢字漢字".len, buf.cursor);

	_ = buf.handleInput("\x1b");
	_ = buf.handleInput("ccthis 漢字is epic");
	try t.expectEqual("this 漢字is epic".len, buf.cursor);
	_ = buf.handleInput("\x1b");
	try t.expectEqual("this 漢字is epi".len, buf.cursor);
	_ = buf.handleInput("b");
	try t.expectEqual("this 漢字is ".len, buf.cursor);
	_ = buf.handleInput("b");
	try t.expectEqual("this ".len, buf.cursor);
	_ = buf.handleInput("b");
	try t.expectEqual(@as(u16, 0), buf.cursor);
	_ = buf.handleInput("e");
	try t.expectEqual("thi".len, buf.cursor);
	_ = buf.handleInput("e");
	try t.expectEqual("this 漢字i".len, buf.cursor);
	_ = buf.handleInput("e");
	try t.expectEqual("this 漢字is epi".len, buf.cursor);

	// Alt-e
	_ = buf.handleInput("\x1be");
	try t.expectEqual("this 漢字i".len, buf.cursor);
	_ = buf.handleInput("\x1be");
	try t.expectEqual("thi".len, buf.cursor);
	_ = buf.handleInput("\x1be");
	try t.expectEqual(@as(u16, 0), buf.cursor);

	// Inserting and deleting text
	_ = buf.handleInput("wl");
	try t.expectEqual("this 漢".len, buf.cursor);
	_ = buf.handleInput("itest");
	try t.expectEqual("this 漢test".len, buf.cursor);
	_ = buf.handleInput("\x06"); // Ctrl-f
	try t.expectEqual("this 漢test字".len, buf.cursor);
	try t.expectEqualStrings("this 漢test字", buf.slice()[0..buf.cursor]);
	_ = buf.handleInput("\x02\x7f\x7f\x7f\x7f"); // Ctrl-b, delete 4 times
	try t.expectEqual("this 漢".len, buf.cursor);
	_ = buf.handleInput("漢字");
	try t.expectEqual("this 漢漢字".len, buf.cursor);
	_ = buf.handleInput("\x7f"); // Delete
	try t.expectEqual("this 漢漢".len, buf.cursor);
	_ = buf.handleInput("\x06"); // Ctrl-f
	try t.expectEqualStrings("this 漢漢字", buf.slice()[0..buf.cursor]);
}
