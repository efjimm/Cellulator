const std = @import("std");
const Position = @import("Sheet.zig").Position;
const assert = std.debug.assert;

/// Writes the utf-8 representation of a unicode codepoint to the given writer
pub fn writeCodepoint(cp: u21, writer: anytype) !void {
	var buf: [4]u8 = undefined;
	const len = try std.unicode.utf8Encode(cp, &buf);

	try writer.writeAll(buf[0..len]);
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
