const std = @import("std");
const utils = @import("utils.zig");
const spoon = @import("spoon");
const inputParser = spoon.inputParser;
const assert = std.debug.assert;
const isWhitespace = std.ascii.isWhitespace;

/// A wrapper around a buffer that provides cli editing functions. Backed by a fixed size buf.
pub fn TextInput(comptime size: usize) type {
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

		pub const InputState = enum {
			start,
			pending_change,
		};

		pub const Motion = enum {
			normal_word_start_next,
			normal_word_start_prev,
			normal_word_end_next,
			normal_word_end_prev,
			long_word_start_next,
			long_word_start_prev,
			long_word_end_next,
			long_word_end_prev,
		};

		pub const WriteError = error{};
		pub const Writer = std.io.Writer(*Self, WriteError, write);

		buf: Array = .{},
		mode: Mode = .insert,
		cursor: u16 = 0,
		input_state: InputState = .start,

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
					'e' => {
						self.cursor = self.prevWordEnd(.normal, self.cursor);
						self.clampCursor();
					},
					'E' => {
						self.cursor = self.prevWordEnd(.long, self.cursor);
						self.clampCursor();
					},
					else => {},
				},
				else => {},
			} else switch (in.content) {
				.escape => {
					self.reset();
					return .cancelled;
				},
				.codepoint => |cp| switch (cp) {
					'x' => {
						if (self.buf.len > 0) {
							self.buf.replaceRange(self.cursor, 1, &.{}) catch unreachable;
							if (self.cursor >= self.buf.len)
								self.cursor = @intCast(u16, self.buf.len -| 1);
						}
					},
					'c' => {
						self.input_state = .pending_change;
					},
					'w' => self.doMotion(.normal_word_start_next),
					'W' => self.doMotion(.long_word_start_next),
					'e' => self.doMotion(.normal_word_end_next),
					'E' => self.doMotion(.long_word_end_next),
					'b' => self.doMotion(.normal_word_start_prev),
					'B' => self.doMotion(.long_word_start_prev),
					'i' => self.setMode(.insert),
					'I' => {
						self.setMode(.insert);
						self.cursorToBol();
					},
					'a' => {
						self.setMode(.insert);
						self.cursorForward(1);
					},
					'A' => {
						self.setMode(.insert);
						self.cursorToEol();
					},
					'0' => self.cursorToBol(),
					'$' => self.cursorToEol(),
					'l' => self.cursorForward(1),
					'h' => self.cursorBackward(1),
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
					'f' => self.cursorForward(1),
					'b' => self.cursorBackward(1),
					else => {},
				},
				else => {},
			} else switch (in.content) {
				.escape => self.setMode(.normal),
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

		fn motionOffset(self: Self, motion: Motion, start: u16) u16 {
			return switch (motion) {
				.normal_word_start_next => self.nextWordStart(.normal, start),
				.normal_word_start_prev => self.prevWordStart(.normal, start),
				.normal_word_end_next => self.nextWordEnd(.normal, start),
				.normal_word_end_prev => self.prevWordEnd(.normal, start),
				.long_word_start_next => self.nextWordStart(.long, start),
				.long_word_start_prev => self.prevWordStart(.long, start),
				.long_word_end_next => self.nextWordEnd(.long, start),
				.long_word_end_prev => self.prevWordEnd(.long, start),
			};
		}

		fn doMotion(self: *Self, motion: Motion) void {
			switch (self.input_state) {
				.start => {
					self.cursor = self.motionOffset(motion, self.cursor);
					self.clampCursor();
				},
				.pending_change => {
					const pos = self.motionOffset(motion, self.cursor);
					if (pos > self.cursor) {
						self.buf.replaceRange(self.cursor, pos - self.cursor, &.{}) catch unreachable;
					} else {
						self.buf.replaceRange(pos, self.cursor - pos, &.{}) catch unreachable;
					}
					self.mode = .insert;
					self.input_state = .start;
				},
			}
		}

		fn clampCursor(self: *Self) void {
			const end = @intCast(u16, self.buf.len -| @boolToInt(self.mode == .normal));
			if (self.cursor >= self.buf.len)
				self.cursor = end;
		}

		const WordType = enum {
			normal,
			long,
		};

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

		/// Returns the byte position of the next word
		fn nextWordStart(self: Self, comptime word_type: WordType, start_pos: u16) u16 {
			assert(start_pos <= self.buf.len);
			if (self.buf.len == 0) return 0;

			const boundary = wordBoundaryFn(word_type);
			var pos = start_pos;

			if (boundary(self.buf.buffer[pos])) {
				for (self.buf.slice()[pos..]) |c| {
					if (!boundary(c) or isWhitespace(c)) break;
					pos += 1;
				}
			} else {
				for (self.buf.slice()[pos..]) |c| {
					if (boundary(c)) break;
					pos += 1;
				}
			}

			for (self.buf.slice()[pos..]) |c| {
				if (!isWhitespace(c)) break;
				pos += 1;
			}

			return pos;
		}

		fn prevWordStart(self: Self, comptime word_type: WordType, start_pos: u16) u16 {
			assert(start_pos <= self.buf.len);
			if (self.buf.len == 0) return 0;

			const boundary = wordBoundaryFn(word_type);
			var pos = start_pos;

			var iter = std.mem.reverseIterator(self.buf.buffer[0..pos]);
			const ch = while (iter.next()) |c| {
				pos -= 1;
				if (!isWhitespace(c)) break c;
			} else return 0;

			if (boundary(ch)) {
				while (iter.next()) |c| {
					if (!boundary(c) or isWhitespace(c)) break;
					pos -= 1; 
				}
			} else {
				while (iter.next()) |c| {
					if (boundary(c)) break;
					pos -= 1;
				}
			}

			return pos;
		}

		fn nextWordEnd(self: Self, comptime word_type: WordType, start_pos: u16) u16 {
			assert(start_pos <= self.buf.len);
			if (self.buf.len == 0) return 0;

			const boundary = wordBoundaryFn(word_type);
			var pos: u16 = for (self.buf.slice()[start_pos + 1..], 0..) |c, i| {
				if (!isWhitespace(c)) break start_pos + 1 + @intCast(u16, i);
			} else return @intCast(u16, self.buf.len);

			if (boundary(self.buf.buffer[pos])) {
				for (self.buf.slice()[pos + 1..]) |c| {
					if (!boundary(c) or isWhitespace(c)) break;
					pos += 1;
				}
			} else {
				for (self.buf.slice()[pos + 1..]) |c| {
					if (boundary(c)) break;
					pos += 1;
				}
			}

			return pos;
		}

		fn prevWordEnd(self: Self, comptime word_type: WordType, start_pos: u16) u16 {
			assert(start_pos <= self.buf.len);
			if (self.buf.len == 0) return 0;

			const boundary = wordBoundaryFn(word_type);
			var pos = start_pos;
			var iter = std.mem.reverseIterator(self.buf.slice()[0..pos + 1]);
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

//		fn wordNext(self: Self, comptime: word_type: WordType, start_pos: u16) u16 {
//			assert(start_pos <= self.buf.len);
//			if (self.buf.len == 0) return 0;
//
//			const boundary = wordBoundaryFn(word_type);
//			var pos = start_pos;
//
//			const ch = self.buf.buffer[pos];
//			if (isWhitespace(ch)) {
//				return self.nextWordStart(word_type, start_pos);
//			} else if (!boundary(ch) and pos + 1 <  self.buf.len and
//					boundary(self.buf.buffer[pos + 1])) {
//				return pos + utf8.unicode.utf8ByteSequenceLength(ch);
//			} else {
//			}
//		}

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

		fn cursorToEol(self: *Self) void {
			self.cursor = @intCast(u16, self.buf.len) -| @boolToInt(self.mode == .normal);
		}

		fn cursorToBol(self: *Self) void {
			self.cursor = 0;
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
