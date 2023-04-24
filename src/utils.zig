const std = @import("std");
const Position = @import("Sheet.zig").Position;

const mem = std.mem;
const assert = std.debug.assert;

/// Writes the utf-8 representation of a unicode codepoint to the given writer
pub fn writeCodepoint(cp: u21, writer: anytype) !void {
	var buf: [4]u8 = undefined;
	const len = try std.unicode.utf8Encode(cp, &buf);

	try writer.writeAll(buf[0..len]);
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
		self.index = @ptrToInt(str.ptr) - @ptrToInt(self.string.ptr);

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
		str = str[1..str.len - 1];
	}

	return str;
}

test "Position.fromCellAddress" {
	const t = std.testing;

	const tuples = .{
		.{ "A1",      Position{ .y = 1,     .x = 0     } },
		.{ "AA7865",  Position{ .y = 7865,  .x = 26    } },
		.{ "AAA1000", Position{ .y = 1000,  .x = 702   } },
		.{ "MM50000", Position{ .y = 50000, .x = 350   } },
		.{ "ZZ0",     Position{ .y = 0,     .x = 701   } },
		.{ "AAAA0",   Position{ .y = 0,     .x = 18278 } },
	};

	inline for (tuples) |tuple| {
		try t.expectEqual(tuple[1], Position.fromCellAddress(tuple[0]));
	}
}

test "Position.columnAddressBuf" {
	const t = std.testing;
	var buf: [4]u8 = undefined;

	try t.expectEqualStrings("A",    Position.columnAddressBuf(0, &buf));
	try t.expectEqualStrings("AA",   Position.columnAddressBuf(26, &buf));
	try t.expectEqualStrings("AAA",  Position.columnAddressBuf(702, &buf));
	try t.expectEqualStrings("AAAA", Position.columnAddressBuf(18278, &buf));
}
