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
						const len = std.unicode.utf8Encode(cp, &buf) catch return .waiting;

						self.buf.insertSlice(self.cursor, buf[0..len]) catch return .waiting;
						self.cursor += len;
					},
				},
				else => {},
			}

			return .waiting;
		}

		fn doMotion(self: *Self, motion: Motion) void {
			switch (self.pending_operation) {
				.move => {
					const range = motion.do(self.buf.slice(), self.cursor);
					self.cursor = if (range.start == self.cursor)
							range.end
						else
							range.start;
						
				},
				.change => {
					var extra: u16 = 0;
					const m = switch (motion) {
						.normal_word_start_next => blk: {
							extra += 1;
							break :blk .normal_word_end_next;
						},
						.long_word_start_next => blk: {
							extra += 1;
							break :blk .long_word_end_next;
						},
						else => motion,
					};

					const range = m.do(self.buf.slice(), self.cursor);
					const start = range.start;
					const end = range.end + extra;

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

			self.buf.replaceRange(self.cursor, 1, &.{}) catch unreachable;
			self.clampCursor();
		}

		fn clampCursor(self: *Self) void {
			if (self.buf.len == 0) {
				self.cursor = 0;
				return;
			}

			const end = @intCast(u16, switch (self.mode) {
				.normal => self.buf.len - 1,
				else => self.buf.len,
			});

			if (self.cursor > end)
				self.cursor = end;
		}

		fn backspace(self: *Self) void {
			const old_cursor = self.cursor;
			self.cursorBackward(1);
			self.buf.replaceRange(self.cursor, old_cursor - self.cursor, &.{}) catch unreachable;
		}

		fn setMode(self: *Self, mode: Mode) void {
			if (mode == .normal and self.cursor == self.buf.len) {
				self.cursor = @intCast(u16, self.buf.len) -| 1;
			}
			self.mode = mode;
		}

		/// Moves the cursor forward by `n` codepoints.
		fn cursorForward(self: *Self, n: u16) void {
			const end = self.buf.len -| @boolToInt(self.mode == .normal);
			for (0..n) |_| {
				if (self.cursor >= end) break;

				const len = std.unicode.utf8ByteSequenceLength(self.buf.buffer[self.cursor]) catch unreachable;
				self.cursor += len;
			}
		}

		/// Moves the cursor backward by `n` codepoints;
		fn cursorBackward(self: *Self, n: u16) void {
			for (0..n) |_| {
				if (self.cursor == 0) break;

				self.cursor -= 1;
				while (std.unicode.utf8ByteSequenceLength(self.buf.buffer[self.cursor]) == error.Utf8InvalidStartByte) {
					self.cursor -= 1;
				}
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

		pub fn slice(self: *Self) []const u8 {
			return self.buf.slice();
		}
	};
}

fn isContinuation(c: u8) bool {
	return std.unicode.utf8ByteSequenceLength(c) == error.Utf8InvalidStartByte;
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
		var pos = start_pos -| 1;

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

		var pos = start_pos + 1;
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
		var iter = std.mem.reverseIterator(bytes[0..pos + 1]);
		var c = iter.next() orelse return 0;

		if (boundary(c)) {
			while (boundary(c) and !isWhitespace(c)) : (pos -= 1) {
				c = iter.next() orelse break;
			}
		} else {
			while (!boundary(c)) : (pos -= 1) {
				 c = iter.next() orelse break;
			}
		}
		while (isWhitespace(c)) : (pos -= 1) {
			c = iter.next() orelse break;
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
