const std = @import("std");
const Position = @import("ZC.zig").Position;
const assert = std.debug.assert;

/// Writes the utf-8 representation of a unicode codepoint to the given writer
pub fn writeCodepoint(cp: u21, writer: anytype) !void {
	var buf: [4]u8 = undefined;
	const len = try std.unicode.utf8Encode(cp, &buf);

	try writer.writeAll(buf[0..len]);
}

pub fn columnIndexToName(index: u16, writer: anytype) @TypeOf(writer).Error!void {
	if (index < 26) {
		try writer.writeByte('A' + @intCast(u8, index));
		return;
	}

	// Max value is 'CRXO'
	var buf: [4]u8 = undefined;
	var stream = std.io.fixedBufferStream(&buf);
	const bufwriter = stream.writer();

	var i = index +| 1;
	while (i > 0) : (i /= 26) {
		i -= 1;
		const r = @intCast(u8, i % 26);
		bufwriter.writeByte('A' + r) catch unreachable;
	}

	const slice = stream.getWritten();
	std.mem.reverse(u8, slice);
	_ = try writer.writeAll(slice);
}

pub fn columnIndexToNameBuf(index: u16, buf: []u8) []const u8 {
	if (index < 26) {
		std.debug.assert(buf.len >= 1);
		buf[0] = 'A' + @intCast(u8, index);
		return buf[0..1];
	}

	var stream = std.io.fixedBufferStream(buf);
	const writer = stream.writer();

	var i = index +| 1;
	while (i > 0) : (i /= 26) {
		i -= 1;
		const r = @intCast(u8, i % 26);
		writer.writeByte('A' + r) catch break;
	}

	const slice = stream.getWritten();
	std.mem.reverse(u8, slice);
	return slice;
}

pub fn posToCellName(y: u16, x: u16, buf: []u8) []const u8 {
	var _buf: [4]u8 = undefined;
	const col_name = columnIndexToNameBuf(x, &_buf);

	return std.fmt.bufPrint(buf, "{s}{d}", .{ col_name, y }) catch buf[0..0];
}

pub fn columnNameToIndex(name: []const u8) u16 {
	var ret: u16 = 0;
	for (name) |c| {
		assert(std.ascii.isAlphabetic(c));
		ret = ret * 26 + (std.ascii.toUpper(c) - 'A' + 1);
	}

	return ret - 1;
}

pub fn cellNameToPosition(name: []const u8) Position {
	assert(name.len > 1);
	assert(std.ascii.isAlphabetic(name[0]));
	assert(std.ascii.isDigit(name[name.len-1]));

	const letters_end = for (name, 0..) |c, i| {
		if (!std.ascii.isAlphabetic(c))
			break i;
	} else unreachable;

	return .{
		.x = columnNameToIndex(name[0..letters_end]),
		.y = std.fmt.parseInt(u16, name[letters_end..], 0) catch unreachable,
	};
}

pub fn cellNameToPositionSafe(name: []const u8) !Position {
	if (
		name.len <= 1 or
		!std.ascii.isAlphabetic(name[0]) or
		!std.ascii.isDigit(name[name.len - 1])
	) {
		return error.InvalidSyntax;
	}

	const letters_end = for (name, 0..) |c, i| {
		if (!std.ascii.isAlphabetic(c))
			break i;
	} else unreachable;

	return .{
		.x = columnNameToIndex(name[0..letters_end]),
		.y = std.fmt.parseInt(u16, name[letters_end..], 0) catch return error.InvalidSyntax,
	};
}

test "cellNameToPosition" {
	const t = std.testing;

	{
		const pos = cellNameToPosition("A1");
		try t.expectEqual(Position{ .y = 1, .x = 0 }, pos);
	}

	{
		const pos = cellNameToPosition("AA7865");
		try t.expectEqual(Position{ .y = 7865, .x = 26 }, pos);
	}

	{
		const pos = cellNameToPosition("AAA100");
		try t.expectEqual(Position{ .y = 100, .x = 702 }, pos);
	}

	{
		const pos = cellNameToPosition("MM50000");
		try t.expectEqual(Position{ .y = 50000, .x = 350 }, pos);
	}

	{
		const pos = cellNameToPosition("ZZ0");
		try t.expectEqual(Position{ .y = 0, .x = 701 }, pos);
	}

	{
		const pos = cellNameToPosition("AAAA0");
		try t.expectEqual(Position{ .y = 0, .x = 18278 }, pos);
	}
}

test "columnIndexToNameBuf" {
	const t = std.testing;
	var buf: [4]u8 = undefined;

	try t.expectEqualStrings("A", columnIndexToNameBuf(0, &buf));
	try t.expectEqualStrings("AA", columnIndexToNameBuf(26, &buf));
	try t.expectEqualStrings("AAA", columnIndexToNameBuf(702, &buf));
	try t.expectEqualStrings("AAAA", columnIndexToNameBuf(18278, &buf));
}
