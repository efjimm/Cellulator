//! Basic expression parser. Does not attempt error recovery and returns immediately on fatal
//! errors.

// TODO
// Handle division by zero (seemingly works with @rem but docs say it's ub)

const std = @import("std");
const utils = @import("utils.zig");
const Pos = @import("ZC.zig").Pos;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Self = @This();

const TokenList = std.MultiArrayList(Token);
const NodeList = std.MultiArrayList(Node);

nodes: NodeList.Slice = (NodeList{}).slice(),

fn initParser(allocator: Allocator, source: []const u8) !Parser {
	var tokens = TokenList{};
	errdefer tokens.deinit(allocator);

	var tokenizer = Tokenizer.init(source);

	try tokens.ensureTotalCapacity(allocator, 25);
	while (tokenizer.next()) |token| {
		try tokens.append(allocator, token);
	}
	try tokens.append(allocator, Tokenizer.eofToken());

	return Parser{
		.source = source,
		.tokens = tokens,
		.token_tags = tokens.items(.tag),
		.token_starts = tokens.items(.start),
		.token_ends = tokens.items(.end),
		.allocator = allocator,
	};
}

pub fn parse(allocator: Allocator, source: []const u8) !Self {
	var parser = try initParser(allocator, source);
	defer parser.tokens.deinit(allocator);
	errdefer parser.nodes.deinit(allocator);

	try parser.parse();

	return Self{
		.nodes = parser.nodes.toOwnedSlice(),
	};
}

pub fn parseExpression(allocator: Allocator, source: []const u8) !Self {
	var parser = try initParser(allocator, source);
	defer parser.tokens.deinit(allocator);
	errdefer parser.nodes.deinit(allocator);

	_ = try parser.parseExpression();
	_ = try parser.expectToken(.eof);

	return Self{
		.nodes = parser.nodes.toOwnedSlice(),
	};
}

pub fn deinit(self: *Self, allocator: Allocator) void {
	self.nodes.deinit(allocator);
	self.* = undefined;
}

pub fn isExpression(self: Self) bool {
	for (self.nodes.items(.tags)) |tag| {
		switch (tag) {
			.number, .cell,
			.add, .sub, .mul, .div,
				=> {},
			else => return false,
		}
	}
	return true;
}

pub fn rootNode(self: Self) Node {
	return self.nodes.get(self.rootNodeIndex());
}

pub fn rootNodeIndex(self: Self) u32 {
	return @intCast(u32, self.nodes.len) - 1;
}

pub fn rootTag(self: Self) std.meta.Tag(Node) {
	return self.nodes.items(.tags)[self.nodes.len - 1];
}

/// Removes all nodes except for the given index and its children
pub fn splice(self: *Self, new_root: u32) void {
	var j: u32 = 0;
	var list = self.nodes.toMultiArrayList();

	// The index of children nodes will always lower than the index of their parent
	for (0..new_root) |i| {
		const index = @intCast(u32, i);
		if (self.isChildOf(new_root, index)) {
			list.set(index, self.nodes.get(index));
			j += 1;
		}
	}

	list.len = new_root + 1;
	self.nodes = list.toOwnedSlice();
}

pub fn isChildOf(self: *Self, parent: u32, node: u32) bool {
	const Context = struct {
		target: u32,
		found: bool = false,

		pub fn func(context: *@This(), index: u32) !bool {
			if (index == context.target) {
				context.found = true;
				return false;
			}
			return true;
		}
	};

	var context = Context{ .target = node };
	try self.traverseFrom(parent, &context);

	return context.found;
}

pub fn print(self: *Self, writer: anytype) @TypeOf(writer).Error!void {
	const Context = struct {
		ast: *const Self,
		writer: *const @TypeOf(writer),

		pub fn func(context: @This(), index: u32) !bool {
			const node = context.ast.nodes.get(index);

			switch (node) {
				.number => |n| try context.writer.print("{d}", .{ n }),
				.column => |col| try utils.columnIndexToName(col, context.writer.*),
				.cell => |pos| {
					var buf: [9]u8 = undefined;
					const slice = utils.posToCellName(pos.y, pos.x, &buf);
					try context.writer.writeAll(slice);
				},
				.assignment => try context.writer.writeAll(" = "),
				.add => try context.writer.writeAll(" + "),
				.sub => try context.writer.writeAll(" - "),
				.mul => try context.writer.writeAll(" * "),
				.div => try context.writer.writeAll(" / "),
				.mod => try context.writer.writeAll(" % "),
			}
			return true;
		}
	};

	try self.traverse(Context{ .ast = self, .writer = &writer });
}

pub fn traverse(self: *Self, context: anytype) !void {
	return self.traverseFrom(self.rootNodeIndex(), context);
}

fn traverseFrom(self: *Self, index: u32, context: anytype) !void {
	const node = self.nodes.get(index);

	switch (node) {
		.assignment, .add, .sub, .mul, .div, .mod => |b| {
			try self.traverseFrom(b.lhs, context);
			if (!try context.func(index)) return;
			try self.traverseFrom(b.rhs, context);
		},
		.number, .cell, .column => {
			if (!try context.func(index)) return;
		},
	}
}

pub fn eval(self: Self, context: anytype) f64 {
	return self.evalNode(self.rootNodeIndex(), 0, context);
}

pub fn evalNode(self: Self, index: u32, total: f64, context: anytype) f64 {
	const node = self.nodes.get(index);

	return switch (node) {
		.number => |n| n,
		.cell => |pos| total + context.evalCell(pos),
		.add => |op| total + (self.evalNode(op.lhs, total, context) + self.evalNode(op.rhs, total, context)),
		.sub => |op| total + (self.evalNode(op.lhs, total, context) - self.evalNode(op.rhs, total, context)),
		.mul => |op| total + (self.evalNode(op.lhs, total, context) * self.evalNode(op.rhs, total, context)),
		.div => |op| total + (self.evalNode(op.lhs, total, context) / self.evalNode(op.rhs, total, context)),
		.mod => |op| total + @rem(self.evalNode(op.lhs, total, context), self.evalNode(op.rhs, total, context)),
		else => unreachable,
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
	mod: BinaryOperator,
};

const BinaryOperator = struct {
	lhs: u32,
	rhs: u32,
};

const Parser = struct {
	source: []const u8,
	tok_i: u32 = 0,

	tokens: TokenList,
	token_tags: []const Token.Tag,
	token_starts: []const u32,
	token_ends: []const u32,

	nodes: NodeList = .{},

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

	/// AddExpr <- MulExpr (('+' / '-') MulExpr)*
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

	/// MulExpr <- PrimaryExpr (('*' / '/' / '%') PrimaryExpr)*
	fn parseMulExpr(self: *Parser) !u32 {
		var index = try self.parsePrimaryExpr();

		while (self.eatTokenMulti(.{ .asterisk, .forward_slash, .percent })) |i| {
			const op = BinaryOperator{
				.lhs = index,
				.rhs = try self.parsePrimaryExpr(),
			};

			const node: Node = switch (self.token_tags[i]) {
				.asterisk => .{ .mul = op },
				.forward_slash => .{ .div = op },
				.percent => .{ .mod = op },
				else => unreachable,
			};

			index = try self.addNode(node);
		}

		return index;
	}

	/// PrimaryExpr <- Number / CellName / '(' Expression ')'
	fn parsePrimaryExpr(self: *Parser) !u32 {
		return switch (self.token_tags[self.tok_i]) {
			.number => self.parseNumber(),
			.cell_name => self.parseCellName(),
			.lparen => {
				_ = try self.expectToken(.lparen);
				const ret = self.parseExpression();
				_ = try self.expectToken(.rparen);
				return ret;
			},
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
		percent,

		lparen,
		rparen,

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
					'%' => {
						tag = .percent;
						self.pos += 1;
						break;
					},
					'(' => {
						tag = .lparen;
						self.pos += 1;
						break;
					},
					')' => {
						tag = .rparen;
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
	const Context = struct {
		pub fn evalCell(_: @This(), _: Pos) f64 {
			return 0;
		}
	};

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
		var ast = try parseExpression(t.allocator, "3 - 5 - 2");
		defer ast.deinit(t.allocator);

		const res = ast.eval(Context{});
		try t.expectEqual(@as(f64, -4), res);
	}

	{
		var ast = try parseExpression(t.allocator, "8 / 2 / 2");
		defer ast.deinit(t.allocator);

		const res = ast.eval(Context{});
		try t.expectEqual(@as(f64, 2), res);
	}

	{
		var ast = try parseExpression(t.allocator, "8 + 5 / 2 * 3 - 5 / 3 + 2");
		defer ast.deinit(t.allocator);

		const res = ast.eval(Context{});
		try t.expectApproxEqRel(@as(f64, 15.833333), res, 0.00001);
	}

	{
		var ast = try parseExpression(t.allocator, "8 + 5 / 2 * 3 - 5 / 3 + 2");
		defer ast.deinit(t.allocator);

		const res = ast.eval(Context{});
		try t.expectApproxEqRel(@as(f64, 15.833333), res, 0.00001);
	}
}

test "isChildOf" {
	const t = std.testing;
	var ast = try parse(t.allocator, "a0 = 50 + 10 * 2");
	defer ast.deinit(t.allocator);

	const root = ast.rootNodeIndex();
	for (0..ast.nodes.len - 1) |i| {
		try t.expect(ast.isChildOf(root, @intCast(u32, i)));
	}

	const add = ast.rootNodeIndex() - 1;
	for (ast.nodes.items(.tags), 0..) |tag, i| {
		if (tag == .number or tag == .mul or tag == .add) {
			try t.expect(ast.isChildOf(add, @intCast(u32, i)));
		} else {
			try t.expect(!ast.isChildOf(add, @intCast(u32, i)));
		}
	}
}
