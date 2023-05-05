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
			.builtin => |*b| {
				b.args -= context.first_node;
			},
			.arg_list => |*b| {
				b.start -= context.first_node;
				b.end -= context.first_node;
			},
			.number, .column, .cell => {},
		}
		slice.set(i, n);
	}

	ast.nodes.len = new_len;
}

pub fn print(ast: *Ast, writer: anytype) @TypeOf(writer).Error!void {
	return ast.printFrom(ast.rootNodeIndex(), writer);
}

pub fn printFrom(ast: *Ast, index: u32, writer: anytype) !void {
	const node = ast.nodes.get(index);

	switch (node) {
		.number => |n| try writer.print("{d}", .{ n }),
		.column => |col| try Position.writeColumnAddress(col, writer),
		.cell => |pos| try pos.writeCellAddress(writer),

		.assignment => |b| {
			try ast.printFrom(b.lhs, writer);
			try writer.writeAll(" = ");
			try ast.printFrom(b.rhs, writer);
		},
		.add => |b| {
			try ast.printFrom(b.lhs, writer);
			try writer.writeAll(" + ");
			try ast.printFrom(b.rhs, writer);
		},
		.sub => |b| {
			try ast.printFrom(b.lhs, writer);
			try writer.writeAll(" - ");
			try ast.printFrom(b.rhs, writer);
		},
		.mul => |b| {
			try ast.printFrom(b.lhs, writer);
			try writer.writeAll(" * ");
			try ast.printFrom(b.rhs, writer);
		},
		.div => |b| {
			try ast.printFrom(b.lhs, writer);
			try writer.writeAll(" / ");
			try ast.printFrom(b.rhs, writer);
		},
		.mod => |b| {
			try ast.printFrom(b.lhs, writer);
			try writer.writeAll(" % ");
			try ast.printFrom(b.rhs, writer);
		},

		.builtin => |b| {
			switch (b.tag) {
				inline else => |tag| try writer.print("@{s}(", .{ @tagName(tag) }),
			}
			try ast.printFrom(b.args, writer);
			try writer.writeByte(')');
		},

		.arg_list => |args| {
			try ast.printFrom(args.start, writer);
			for (args.start + 1..args.end) |i| {
				try writer.writeAll(", ");
				try ast.printFrom(@intCast(u32, i), writer);
			}
		},
	}
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
		.builtin => |b| {
			if (!try ast.traverseFrom(b.args, order, context)) return false;
		},
		.arg_list => |b| switch (order) {
			.first, .middle => {
				if (!try context.evalCell(index)) return false;
				for (b.start..b.end) |i| {
					if (!try ast.traverseFrom(@intCast(u32, i), order, context)) return false;
				}
			},
			.last => {
				for (b.start..b.end) |i| {
					if (!try ast.traverseFrom(@intCast(u32, i), order, context)) return false;
				}
				if (!try context.evalCell(index)) return false;
			},
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
		.builtin => |b| {
			const args = ast.nodes.items(.data)[b.args].arg_list;
			switch (b.tag) {
				.sum => {
					var sum_total: f64 = 0;
					for (args.start..args.end) |i| {
						sum_total += ast.evalNode(@intCast(u32, i), sum_total, context);
					}
					return total + sum_total;
				},
				.prod => {
					var prod_total: f64 = 1;
					for (args.start..args.end) |i| {
						prod_total *= ast.evalNode(@intCast(u32, i), prod_total, context);
					}
					return total + prod_total;
				},
				.avg => {
					var sum_total: f64 = 0;
					for (args.start..args.end) |i| {
						sum_total = ast.evalNode(@intCast(u32, i), sum_total, context);
					}
					return total + sum_total / @intToFloat(f64, (args.end - args.start));
				},
				.max => {
					var max = ast.evalNode(args.start, 0, context);
					for (args.start + 1..args.end) |i| {
						const val = ast.evalNode(@intCast(u32, i), 0, context);
						if (val > max)
							max = val;
					}
					return total + max;
				},
				.min => {
					var min = ast.evalNode(args.start, 0, context);
					for (args.start + 1..args.end) |i| {
						const val = ast.evalNode(@intCast(u32, i), 0, context);
						if (val < min)
							min = val;
					}
					return total + min;
				},
			}
		},
		.column, .assignment, .arg_list => unreachable,
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
	builtin: Builtin,
	arg_list: ArgList,
};

comptime {
	assert(@sizeOf(Node) == 16);
}

const Builtin = struct {
	tag: Tag,
	args: u32,

	const Tag = enum {
		sum,
		prod,
		avg,
		max,
		min,
	};

	comptime {
		assert(@sizeOf(Tag) <= 4);
	}
};

const ArgList = packed struct(u64) {
	start: u32,
	end: u32,
};

const BinaryOperator = struct {
	lhs: u32,
	rhs: u32,
};

const builtins = std.ComptimeStringMap(Builtin.Tag, .{
	.{ "sum", .sum },
	.{ "prod", .prod },
	.{ "avg", .avg },
	.{ "max", .max },
	.{ "min", .min },
});

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

	fn parse(parser: *Parser) !void {
		_ = try parser.parseStatement();
		_ = try parser.expectToken(.eof);
	}

	/// Statement <- Assignment
	fn parseStatement(parser: *Parser) !u32 {
		return parser.parseAssignment();
	}

	/// Assignment <- CellName '=' Expression
	fn parseAssignment(parser: *Parser) !u32 {
		const lhs = try parser.parseCellName();
		_ = try parser.expectToken(.equals_sign);
		const rhs = try parser.parseExpression();

		return parser.addNode(.{
			.assignment = .{
				.lhs = lhs,
				.rhs = rhs,
			},
		});
	}

	const ParseError = error{ UnexpectedToken } || Allocator.Error;

	/// Expression <- AddExpr
	fn parseExpression(parser: *Parser) ParseError!u32 {
		return parser.parseAddExpr();
	}

	/// AddExpr <- MulExpr (('+' / '-') MulExpr)*
	fn parseAddExpr(parser: *Parser) !u32 {
		var index = try parser.parseMulExpr();

		while (parser.eatTokenMulti(.{ .plus, .minus })) |i| {
			const op = BinaryOperator{
				.lhs = index,
				.rhs = try parser.parseMulExpr(),
			};

			const node: Node = switch (parser.token_tags[i]) {
				.plus => .{ .add = op },
				.minus => .{ .sub = op },
				else => unreachable,
			};

			index = try parser.addNode(node);
		}

		return index;
	}

	/// MulExpr <- PrimaryExpr (('*' / '/' / '%') PrimaryExpr)*
	fn parseMulExpr(parser: *Parser) !u32 {
		var index = try parser.parsePrimaryExpr();

		while (parser.eatTokenMulti(.{ .asterisk, .forward_slash, .percent })) |i| {
			const op = BinaryOperator{
				.lhs = index,
				.rhs = try parser.parsePrimaryExpr(),
			};

			const node: Node = switch (parser.token_tags[i]) {
				.asterisk => .{ .mul = op },
				.forward_slash => .{ .div = op },
				.percent => .{ .mod = op },
				else => unreachable,
			};

			index = try parser.addNode(node);
		}

		return index;
	}

	/// PrimaryExpr <- Number / CellName / Builtin / '(' Expression ')'
	fn parsePrimaryExpr(parser: *Parser) !u32 {
		return switch (parser.token_tags[parser.tok_i]) {
			.minus, .plus, .number => parser.parseNumber(),
			.cell_name => parser.parseCellName(),
			.lparen => {
				_ = try parser.expectToken(.lparen);
				const ret = parser.parseExpression();
				_ = try parser.expectToken(.rparen);
				return ret;
			},
			.builtin => parser.parseFunction(),
			else => error.UnexpectedToken,
		};
	}

	/// Builtin <- builtin '(' ArgList? ')'
	fn parseFunction(parser: *Parser) !u32 {
		const token_index = try parser.expectToken(.builtin);
		_ = try parser.expectToken(.lparen);

		const identifier = parser.tokenContent(token_index).text(parser.source);
		const builtin = builtins.get(identifier) orelse return error.UnexpectedToken;

		const args = try parser.parseArgList();
		_ = try parser.expectToken(.rparen);
		return parser.addNode(.{
			.builtin = .{
				.tag = builtin,
				.args = args,
			},
		});
	}

	/// ArgList <- Expression (',' Expression)*
	fn parseArgList(parser: *Parser) !u32 {
		const start = try parser.parseExpression();
		var end = start + 1;

		while (parser.eatToken(.comma)) |_| {
			end = 1 + try parser.parseExpression();
		}

		return parser.addNode(.{
			.arg_list = .{
				.start = start,
				.end = end,
			},
		});
	}

	/// Number <- ('+' / '-')? ('0'-'9')+
	fn parseNumber(parser: *Parser) !u32 {
		const is_positive = parser.eatToken(.minus) == null;
		if (is_positive) _ = parser.eatToken(.plus);

		const i = try parser.expectToken(.number);
		const text = parser.tokenContent(i).text(parser.source);

		// Correctness of the number is guaranteed because the tokenizer wouldn't have generated a
		// number token on invalid format.
		const num = std.fmt.parseFloat(f64, text) catch unreachable;

		return parser.addNode(.{
			.number = if (is_positive) num else -num,
		});
	}

	/// CellName <- ('a'-'z' / 'A'-'Z')+ ('0'-'9')+
	fn parseCellName(parser: *Parser) !u32 {
		const i = try parser.expectToken(.cell_name);
		const text = parser.tokenContent(i).text(parser.source);

		// TODO: check bounds
		const pos = Position.fromCellAddress(text);

		return parser.addNode(.{
			.cell = pos,
		});
	}

	fn tokenContent(parser: Parser, index: u32) Token {
		return .{
			.tag = parser.token_tags[index],
			.start = parser.token_starts[index],
			.end = parser.token_ends[index],
		};
	}

	fn addNode(parser: *Parser, data: Node) Allocator.Error!u32 {
		const ret = @intCast(u32, parser.nodes.len);
		try parser.nodes.append(parser.allocator, data);
		return ret;
	}

	fn expectToken(parser: *Parser, expected_tag: Token.Tag) !u32 {
		return parser.eatToken(expected_tag) orelse {
			log.warn("Unexpected token {s}, expected {s}", .{
				@tagName(parser.token_tags[parser.tok_i]),
				@tagName(expected_tag),
			});
			return error.UnexpectedToken;
		};
	}

	fn eatToken(parser: *Parser, expected_tag: Token.Tag) ?u32 {
		return if (parser.token_tags[parser.tok_i] == expected_tag) parser.nextToken() else null;
	}

	fn eatTokenMulti(parser: *Parser, tags: anytype) ?u32 {
		inline for (tags) |tag| {
			if (parser.eatToken(tag)) |token|
				return token;
		}

		return null;
	}

	fn nextToken(parser: *Parser) u32 {
		const ret = parser.tok_i;
		parser.tok_i += 1;
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
		comma,

		lparen,
		rparen,

		column_name,
		cell_name,
		builtin,

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
		builtin,
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
					'@' => {
						state = .builtin;
						tag = .builtin;
						start += 1;
					},
					',' => {
						tag = .comma;
						tokenizer.pos += 1;
						break;
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
				.builtin => switch (c) {
					'a'...'z', 'A'...'Z', '_' => {},
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
