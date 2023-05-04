//! Basic expression parser. Does not attempt error recovery and returns immediately on fatal
//! errors. Contains a `MultiArrayList` of `Node`s that is sorted in reverse topological order.

// TODO
// Handle division by zero (seemingly works with @rem but docs say it's ub)

const std = @import("std");
const Position = @import("Sheet.zig").Position;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Ast = @This();

const TokenList = std.MultiArrayList(Token);
const NodeList = std.MultiArrayList(Node);

nodes: NodeList = .{},

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

pub fn parse(allocator: Allocator, source: []const u8) !Ast {
	var parser = try initParser(allocator, source);
	defer parser.tokens.deinit(allocator);
	errdefer parser.nodes.deinit(allocator);

	try parser.parse();

	return Ast{
		.nodes = parser.nodes,
	};
}

pub fn parseExpression(allocator: Allocator, source: []const u8) !Ast {
	var parser = try initParser(allocator, source);
	defer parser.tokens.deinit(allocator);
	errdefer parser.nodes.deinit(allocator);

	_ = try parser.parseExpression();
	_ = try parser.expectToken(.eof);

	return Ast{
		.nodes = parser.nodes,
	};
}

pub fn deinit(ast: *Ast, allocator: Allocator) void {
	ast.nodes.deinit(allocator);
	ast.* = undefined;
}

pub fn isExpression(ast: Ast) bool {
	for (ast.nodes.items(.tags)) |tag| {
		switch (tag) {
			.number, .cell,
			.add, .sub, .mul, .div,
				=> {},
			else => return false,
		}
	}
	return true;
}

pub fn rootNode(ast: Ast) Node {
	return ast.nodes.get(ast.rootNodeIndex());
}

pub fn rootNodeIndex(ast: Ast) u32 {
	return @intCast(u32, ast.nodes.len) - 1;
}

pub fn rootTag(ast: Ast) std.meta.Tag(Node) {
	return ast.nodes.items(.tags)[ast.nodes.len - 1];
}

/// Removes all nodes except for the given index and its children
/// Nodes in the list are already sorted in reverse topological order which allows us to overwrite
/// nodes sequentially without loss. This function preserves reverse topological order.
pub fn splice(ast: *Ast, new_root: u32) void {
	// Gets the index of the left-most node that is a child of the new_root node
	const Context = struct {
		first_node: u32,

		pub fn evalCell(context: *@This(), index: u32) !bool {
			context.first_node = index;
			return false;
		}
	};

	var slice = ast.nodes.slice();
	var context = Context{ .first_node = new_root };
	_ = ast.traverseFrom(new_root, .last, &context) catch unreachable;

	const new_len = new_root + 1 - context.first_node;

	for (0..new_len, context.first_node..new_root + 1) |i, j| {
		var n = slice.get(j);
		switch (n) {
			.assignment, .add, .sub, .mul, .div, .mod => |*b| {
				b.lhs -= context.first_node;
				b.rhs -= context.first_node;
			},
			else => {},
		}
		slice.set(i, n);
	}

	ast.nodes.len = new_len;
}

pub fn print(ast: *Ast, writer: anytype) @TypeOf(writer).Error!void {
	const Context = struct {
		ast: *const Ast,
		writer: *const @TypeOf(writer),

		pub fn evalCell(context: @This(), index: u32) !bool {
			const node = context.ast.nodes.get(index);

			switch (node) {
				.number => |n| try context.writer.print("{d}", .{ n }),
				.column => |col| try Position.writeColumnAddress(col, context.writer.*),
				.cell => |pos| try pos.writeCellAddress(context.writer.*),
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

	_ = try ast.traverse(.middle, Context{ .ast = ast, .writer = &writer });
}

/// The order in which nodes are evaluated.
const TraverseOrder = enum {
	/// Nodes with children will be evaluated before their children
	first,
	/// Nodes with children will have their left child evaluated first, then themselves, then their
	/// right child.
	middle,
	/// Nodes with children will be evaluated after all their children.
	last,
};

/// Recursively visits every node in the tree. `context` is an instance of a type which must have
/// the function `fn evalCell(@TypeOf(context), u32) !bool`. This function is run on every leaf
/// node in the tree, with `index` being the index of the node in the `nodes` array. If the
/// function returns false, traversal stops immediately.
pub fn traverse(ast: Ast, order: TraverseOrder, context: anytype) !bool {
	return ast.traverseFrom(ast.rootNodeIndex(), order, context);
}

/// Same as `traverse`, but starting from the node at the given index.
fn traverseFrom(ast: Ast, index: u32, order: TraverseOrder, context: anytype) !bool {
	const node = ast.nodes.get(index);

	switch (node) {
		.assignment, .add, .sub, .mul, .div, .mod => |b| {
			switch (order) {
				.first => {
					if (!try context.evalCell(index)) return false;
					if (!try ast.traverseFrom(b.lhs, order, context)) return false;
					if (!try ast.traverseFrom(b.rhs, order, context)) return false;
				},
				.middle => {
					if (!try ast.traverseFrom(b.lhs, order, context)) return false;
					if (!try context.evalCell(index)) return false;
					if (!try ast.traverseFrom(b.rhs, order, context)) return false;
				},
				.last => {
					if (!try ast.traverseFrom(b.lhs, order, context)) return false;
					if (!try ast.traverseFrom(b.rhs, order, context)) return false;
					if (!try context.evalCell(index)) return false;
				},
			}
		},
		.number, .cell, .column => {
			if (!try context.evalCell(index)) return false;
		},
	}

	return true;
}

pub fn eval(
	ast: Ast,
	/// An instance of a type which has the function `fn evalCell(@TypeOf(context), Position) f64`.
	/// This function should return the value of the cell at the given position. It may do this
	/// by calling this function.
	context: anytype,
) f64 {
	return ast.evalNode(ast.rootNodeIndex(), 0, context);
}

pub fn evalNode(ast: Ast, index: u32, total: f64, context: anytype) f64 {
	const node = ast.nodes.get(index);

	return switch (node) {
		.number => |n| n,
		.cell => |pos| total + context.evalCell(pos),
		.add => |op| total + (ast.evalNode(op.lhs, total, context) + ast.evalNode(op.rhs, total, context)),
		.sub => |op| total + (ast.evalNode(op.lhs, total, context) - ast.evalNode(op.rhs, total, context)),
		.mul => |op| total + (ast.evalNode(op.lhs, total, context) * ast.evalNode(op.rhs, total, context)),
		.div => |op| total + (ast.evalNode(op.lhs, total, context) / ast.evalNode(op.rhs, total, context)),
		.mod => |op| total + @rem(ast.evalNode(op.lhs, total, context), ast.evalNode(op.rhs, total, context)),
		else => unreachable,
	};
}

pub const Node = union(enum) {
	number: f64,
	column: u16,
	cell: Position,
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

	fn parse(ast: *Parser) !void {
		_ = try ast.parseStatement();
		_ = try ast.expectToken(.eof);
	}

	/// Statement <- Assignment
	fn parseStatement(ast: *Parser) !u32 {
		return ast.parseAssignment();
	}

	/// Assignment <- CellName '=' Expression
	fn parseAssignment(ast: *Parser) !u32 {
		const lhs = try ast.parseCellName();
		_ = try ast.expectToken(.equals_sign);
		const rhs = try ast.parseExpression();

		return ast.addNode(.{
			.assignment = .{
				.lhs = lhs,
				.rhs = rhs,
			},
		});
	}

	const ParseError = error{ UnexpectedToken } || Allocator.Error;

	/// Expression <- AddExpr
	fn parseExpression(ast: *Parser) ParseError!u32 {
		return ast.parseAddExpr();
	}

	/// AddExpr <- MulExpr (('+' / '-') MulExpr)*
	fn parseAddExpr(ast: *Parser) !u32 {
		var index = try ast.parseMulExpr();

		while (ast.eatTokenMulti(.{ .plus, .minus })) |i| {
			log.info("INDEX: {d}", .{ index });
			const op = BinaryOperator{
				.lhs = index,
				.rhs = try ast.parseMulExpr(),
			};

			const node: Node = switch (ast.token_tags[i]) {
				.plus => .{ .add = op },
				.minus => .{ .sub = op },
				else => unreachable,
			};

			index = try ast.addNode(node);
		}

		log.info("RETURNING {d}", .{ index });
		return index;
	}

	/// MulExpr <- PrimaryExpr (('*' / '/' / '%') PrimaryExpr)*
	fn parseMulExpr(ast: *Parser) !u32 {
		var index = try ast.parsePrimaryExpr();

		while (ast.eatTokenMulti(.{ .asterisk, .forward_slash, .percent })) |i| {
			const op = BinaryOperator{
				.lhs = index,
				.rhs = try ast.parsePrimaryExpr(),
			};

			const node: Node = switch (ast.token_tags[i]) {
				.asterisk => .{ .mul = op },
				.forward_slash => .{ .div = op },
				.percent => .{ .mod = op },
				else => unreachable,
			};

			index = try ast.addNode(node);
		}

		return index;
	}

	/// PrimaryExpr <- Number / CellName / '(' Expression ')'
	fn parsePrimaryExpr(ast: *Parser) !u32 {
		return switch (ast.token_tags[ast.tok_i]) {
			.number => ast.parseNumber(),
			.cell_name => ast.parseCellName(),
			.lparen => {
				_ = try ast.expectToken(.lparen);
				const ret = ast.parseExpression();
				_ = try ast.expectToken(.rparen);
				return ret;
			},
			else => error.UnexpectedToken,
		};
	}

	fn parseNumber(ast: *Parser) !u32 {
		const i = try ast.expectToken(.number);
		const text = ast.tokenContent(i).text(ast.source);

		// Correctness of the number is guaranteed because the tokenizer wouldn't have generated a
		// number token on invalid format.
		const num = std.fmt.parseFloat(f64, text) catch unreachable;

		return ast.addNode(.{
			.number = num,
		});
	}

	/// CellName <- ('a'-'z' / 'A'-'Z')+ ('0'-'9')+
	fn parseCellName(ast: *Parser) !u32 {
		const i = try ast.expectToken(.cell_name);
		const text = ast.tokenContent(i).text(ast.source);

		// TODO: check bounds
		const pos = Position.fromCellAddress(text);

		return ast.addNode(.{
			.cell = pos,
		});
	}

	fn tokenContent(ast: Parser, index: u32) Token {
		return .{
			.tag = ast.token_tags[index],
			.start = ast.token_starts[index],
			.end = ast.token_ends[index],
		};
	}

	fn addNode(ast: *Parser, data: Node) Allocator.Error!u32 {
		const ret = @intCast(u32, ast.nodes.len);
		try ast.nodes.append(ast.allocator, data);
		return ret;
	}

	fn expectToken(ast: *Parser, expected_tag: Token.Tag) !u32 {
		return ast.eatToken(expected_tag) orelse error.UnexpectedToken;
	}

	fn eatToken(ast: *Parser, expected_tag: Token.Tag) ?u32 {
		return if (ast.token_tags[ast.tok_i] == expected_tag) ast.nextToken() else null;
	}

	fn eatTokenMulti(ast: *Parser, tags: anytype) ?u32 {
		inline for (tags) |tag| {
			if (ast.eatToken(tag)) |token|
				return token;
		}

		return null;
	}

	fn nextToken(ast: *Parser) u32 {
		const ret = ast.tok_i;
		ast.tok_i += 1;
		return ret;
	}
};

pub const Token = struct {
	tag: Tag,
	start: u32,
	end: u32,

	pub fn text(ast: Token, source: []const u8) []const u8 {
		return source[ast.start..ast.end];
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

	pub fn next(tokenizer: *Tokenizer) ?Token {
		var start = tokenizer.pos;

		var state = State.start;
		var tag = Token.Tag.eof;

		while (tokenizer.pos < tokenizer.bytes.len) : (tokenizer.pos += 1) {
			const c = tokenizer.bytes[tokenizer.pos];

			switch (state) {
				.start => switch (c) {
					'0'...'9' => {
						state = .number;
						tag = .number;
					},
					'=' => {
						tag = .equals_sign;
						tokenizer.pos += 1;
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
						tokenizer.pos += 1;
						break;
					},
					'-' => {
						tag = .minus;
						tokenizer.pos += 1;
						break;
					},
					'*' => {
						tag = .asterisk;
						tokenizer.pos += 1;
						break;
					},
					'/' => {
						tag = .forward_slash;
						tokenizer.pos += 1;
						break;
					},
					'%' => {
						tag = .percent;
						tokenizer.pos += 1;
						break;
					},
					'(' => {
						tag = .lparen;
						tokenizer.pos += 1;
						break;
					},
					')' => {
						tag = .rparen;
						tokenizer.pos += 1;
						break;
					},
					else => {
						defer tokenizer.pos += 1;
						return .{
							.tag = .invalid,
							.start = start,
							.end = tokenizer.pos,
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
			.end = tokenizer.pos,
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
		pub fn evalCell(_: @This(), _: Position) f64 {
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

	{
		var ast = try parseExpression(t.allocator, "(3 + 1) - (4 * 2)");
		defer ast.deinit(t.allocator);

		const res = ast.eval(Context{});
		try t.expectApproxEqRel(@as(f64, -4), res, 0.00001);
	}
}
