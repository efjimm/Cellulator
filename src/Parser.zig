//! Basic expression parser. Does not attempt error recovery and returns immediately on fatal
//! errors.

const std = @import("std");
const utils = @import("utils.zig");
const Pos = @import("ZC.zig").Pos;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Self = @This();

const TokenList = std.MultiArrayList(Token);
const NodeList = std.MultiArrayList(Node);

source: []const u8,
tokens: TokenList.Slice,
nodes: NodeList.Slice,

pub fn parse(allocator: Allocator, source: []const u8) !Self {
	var tokens = TokenList{};
	defer tokens.deinit(allocator);
	var tokenizer = Tokenizer.init(source);

	try tokens.ensureTotalCapacity(allocator, 25);
	while (tokenizer.next()) |token| {
		try tokens.append(allocator, token);
	}
	try tokens.append(allocator, Tokenizer.eofToken());

	var parser = Parser{
		.source = source,
		.token_tags = tokens.items(.tag),
		.token_starts = tokens.items(.start),
		.token_ends = tokens.items(.end),
		.allocator = allocator,
	};
	defer parser.nodes.deinit(allocator);

	try parser.parse();

	return Self{
		.source = source,
		.nodes = parser.nodes.toOwnedSlice(),
		.tokens = tokens.toOwnedSlice(),
	};
}

pub fn deinit(self: *Self, allocator: Allocator) void {
	self.tokens.deinit(allocator);
	self.nodes.deinit(allocator);
	self.* = undefined;
}

pub fn print(self: *Self, index: u32, writer: anytype) !void {
	const node = self.nodes.get(index);
	switch (node) {
		.add => |t| {
			try self.print(t.lhs, writer);
			try writer.writeAll(" + ");
			try self.print(t.rhs, writer);
		},
		.sub => |t| {
			try self.print(t.lhs, writer);
			try writer.writeAll(" - ");
			try self.print(t.rhs, writer);
		},
		.mul => |t| {
			try self.print(t.lhs, writer);
			try writer.writeAll(" * ");
			try self.print(t.rhs, writer);
		},
		.div => |t| {
			try self.print(t.lhs, writer);
			try writer.writeAll(" / ");
			try self.print(t.rhs, writer);
		},
		.assignment => |t| {
			try self.print(t.lhs, writer);
			try writer.writeAll(" = ");
			try self.print(t.rhs, writer);
		},
		.cell => |t| {
			var buf: [16]u8 = undefined;
			try writer.writeAll(utils.posToCellName(t.y, t.x, &buf));
		},
		.column => |t| {
			var buf: [16]u8 = undefined;
			try writer.writeAll(utils.columnIndexToName(t, &buf));
		},
		.number => |t| {
			try writer.print("{d}", .{ t });
		},
	}
}

pub fn printAll(self: *Self, writer: anytype) !void {
	try self.print(@intCast(u32, self.nodes.len) - 1, writer);
}

pub fn evalNode(self: *Self, index: u32, total: f64) f64 {
	const node = self.nodes.get(index);

	return switch (node) {
		.number => |n| n,
		.add => |a| total + (self.evalNode(a.lhs, total) + self.evalNode(a.rhs, total)),
		.sub => |s| total + (self.evalNode(s.lhs, total) - self.evalNode(s.rhs, total)),
		.mul => |m| total + (self.evalNode(m.lhs, total) * self.evalNode(m.rhs, total)),
		.div => |d| total + (self.evalNode(d.lhs, total) / self.evalNode(d.rhs, total)),
		.assignment => |a| total + self.evalNode(a.rhs, total),
		else => 0,
	};
}

const Node = union(enum) {
	number: f64,
	column: u16,
	cell: Pos,
	assignment: BinaryOperator,
	add: BinaryOperator,
	sub: BinaryOperator,
	mul: BinaryOperator,
	div: BinaryOperator,
};

const BinaryOperator = struct {
	lhs: u32,
	rhs: u32,
};

const Parser = struct {
	source: []const u8,
	tok_i: u32 = 0,

	token_tags: []const Token.Tag,
	token_starts: []const u32,
	token_ends: []const u32,

	nodes: std.MultiArrayList(Node) = .{},

	allocator: Allocator,

	const log = std.log.scoped(.parser);

	fn parse(self: *Parser) !void {
		_ = try self.parseStatement();
		_ = try self.expectToken(.eof);
	}

	/// Statement <- Assignment
	fn parseStatement(self: *Parser) !u32 {
		return self.parseAssignment();
	}

	/// Assignment <- CellName '=' Expression
	fn parseAssignment(self: *Parser) !u32 {
		const lhs = try self.parseCellName();

		_ = try self.expectToken(.equals_sign);

		const rhs = try self.parseExpression();

		return self.addNode(.{
			.assignment = .{
				.lhs = lhs,
				.rhs = rhs,
			},
		});
	}

	const ParseError = error{ UnexpectedToken } || Allocator.Error;

	/// Expression <- AddExpr
	fn parseExpression(self: *Parser) ParseError!u32 {
		return self.parseAddExpr();
	}

	/// AddExpr <- MulExpr ('+' MulExpr)*
	fn parseAddExpr(self: *Parser) !u32 {
		var index = try self.parseMulExpr();

		while (self.eatTokenMulti(.{ .plus, .minus })) |i| {
			const op = BinaryOperator{
				.lhs = index,
				.rhs = try self.parseMulExpr(),
			};

			const node: Node = switch (self.token_tags[i]) {
				.plus => .{ .add = op },
				.minus => .{ .sub = op },
				else => unreachable,
			};

			index = try self.addNode(node);
		}

		return index;
	}

	/// MulExpr <- PrimaryExpr ('*' PrimaryExpr)*
	fn parseMulExpr(self: *Parser) !u32 {
		var index = try self.parsePrimaryExpr();

		while (self.eatTokenMulti(.{ .asterisk, .forward_slash })) |i| {
			const op = BinaryOperator{
				.lhs = index,
				.rhs = try self.parsePrimaryExpr(),
			};

			const node: Node = switch (self.token_tags[i]) {
				.asterisk => .{ .mul = op },
				.forward_slash => .{ .div = op },
				else => unreachable,
			};

			index = try self.addNode(node);
		}

		return index;
	}

	/// PrimaryExpr <- Number / CellName
	fn parsePrimaryExpr(self: *Parser) !u32 {
		return switch (self.token_tags[self.tok_i]) {
			.number => self.parseNumber(),
			.cell_name => self.parseCellName(),
			else => error.UnexpectedToken,
		};
	}

	fn parseNumber(self: *Parser) !u32 {
		const i = try self.expectToken(.number);
		const text = self.tokenContent(i).text(self.source);

		// Correctness of the number is guaranteed because the tokenizer wouldn't have generated a
		// number token on invalid format.
		const num = std.fmt.parseFloat(f64, text) catch unreachable;

		return self.addNode(.{
			.number = num,
		});
	}

	/// CellName <- ('a'-'z' / 'A'-'Z')+ ('0'-'9')+
	fn parseCellName(self: *Parser) !u32 {
		const i = try self.expectToken(.cell_name);
		const text = self.tokenContent(i).text(self.source);

		// TODO: check bounds
		const pos = utils.cellNameToPosition(text);

		return self.addNode(.{
			.cell = pos,
		});
	}

	fn tokenContent(self: Parser, index: u32) Token {
		return .{
			.tag = self.token_tags[index],
			.start = self.token_starts[index],
			.end = self.token_ends[index],
		};
	}

	fn addNode(self: *Parser, data: Node) Allocator.Error!u32 {
		const ret = @intCast(u32, self.nodes.len);
		try self.nodes.append(self.allocator, data);
		return ret;
	}

	fn expectToken(self: *Parser, expected_tag: Token.Tag) !u32 {
		return self.eatToken(expected_tag) orelse error.UnexpectedToken;
	}

	fn eatToken(self: *Parser, expected_tag: Token.Tag) ?u32 {
		return if (self.token_tags[self.tok_i] == expected_tag) self.nextToken() else null;
	}

	fn eatTokenMulti(self: *Parser, tags: anytype) ?u32 {
		inline for (tags) |tag| {
			if (self.eatToken(tag)) |token|
				return token;
		}

		return null;
	}

	fn nextToken(self: *Parser) u32 {
		const ret = self.tok_i;
		self.tok_i += 1;
		return ret;
	}
};

pub const Token = struct {
	tag: Tag,
	start: u32,
	end: u32,

	pub fn text(self: Token, source: []const u8) []const u8 {
		return source[self.start..self.end];
	}

	pub const Tag = enum {
		number,
		equals_sign,

		plus,
		minus,
		asterisk,
		forward_slash,

		column_name,
		cell_name,

		eof,
		invalid,
	};
};

pub const Tokenizer = struct {
	bytes: []const u8,
	pos: u32 = 0,

	const State = enum {
		start,
		number,
		column_or_cell_name,
	};

	pub fn init(bytes: []const u8) Tokenizer {
		return .{
			.bytes = bytes,
		};
	}

	pub fn next(self: *Tokenizer) ?Token {
		var start = self.pos;

		var state = State.start;
		var tag = Token.Tag.eof;

		while (self.pos < self.bytes.len) : (self.pos += 1) {
			const c = self.bytes[self.pos];

			switch (state) {
				.start => switch (c) {
					'0'...'9' => {
						state = .number;
						tag = .number;
					},
					'=' => {
						tag = .equals_sign;
						self.pos += 1;
						break;
					},
					' ', '\t', '\r', '\n' => {
						start += 1;
					},
					'a'...'z', 'A'...'Z' => {
						state = .column_or_cell_name;
						tag = .column_name;
					},
					'+' => {
						tag = .plus;
						self.pos += 1;
						break;
					},
					'-' => {
						tag = .minus;
						self.pos += 1;
						break;
					},
					'*' => {
						tag = .asterisk;
						self.pos += 1;
						break;
					},
					'/' => {
						tag = .forward_slash;
						self.pos += 1;
						break;
					},
					else => {
						defer self.pos += 1;
						return .{
							.tag = .invalid,
							.start = start,
							.end = self.pos,
						};
					},
				},
				.number => switch (c) {
					'0'...'9' => {},
					else => break,
				},
				.column_or_cell_name => switch (c) {
					'a'...'z', 'A'...'Z' => { },
					'0'...'9' => {
						tag = .cell_name;
					},
					else => break,
				},
			}
		}

		if (tag == .eof)
			return null;

		return Token{
			.tag = tag,
			.start = start,
			.end = self.pos,
		};
	}

	pub fn eofToken() Token {
		return Token{
			.tag = .eof,
			.start = undefined,
			.end = undefined,
		};
	}
};

test "Tokenizer" {
	const t = std.testing;
	var tokenizer = Tokenizer.init("a = 3");

	try t.expectEqual(Token.Tag.column_name, tokenizer.next().?.tag);
	try t.expectEqual(Token.Tag.equals_sign, tokenizer.next().?.tag);
	try t.expectEqual(Token.Tag.number, tokenizer.next().?.tag);
	try t.expectEqual(@as(?Token, null), tokenizer.next());
}

test "Parse" {
	const t = std.testing;

	{
		var ast = try parse(t.allocator, "a0 = 3");
		defer ast.deinit(t.allocator);

		const tags = ast.nodes.items(.tags);
		try t.expectEqual(@as(usize, 3), tags.len);
		try t.expectEqual(std.meta.Tag(Node).cell, tags[0]);
		try t.expectEqual(std.meta.Tag(Node).number, tags[1]);
		try t.expectEqual(std.meta.Tag(Node).assignment, tags[2]);

		try t.expectError(error.UnexpectedToken, parse(t.allocator, "a = 3"));
	}

	{
		var ast = try parse(t.allocator, "a0 = 3 - 5 - 2");
		defer ast.deinit(t.allocator);

		var arr = std.ArrayList(u8).init(t.allocator);
		defer arr.deinit();

		try ast.printAll(arr.writer());

		const res = ast.evalNode(@intCast(u32, ast.nodes.len) - 1, 0);
		try t.expectEqual(@as(f64, -4), res);
	}

	{
		var ast = try parse(t.allocator, "a0 = 8 / 2 / 2");
		defer ast.deinit(t.allocator);

		var arr = std.ArrayList(u8).init(t.allocator);
		defer arr.deinit();

		try ast.printAll(arr.writer());

		const res = ast.evalNode(@intCast(u32, ast.nodes.len) - 1, 0);
		try t.expectEqual(@as(f64, 2), res);
	}
}
