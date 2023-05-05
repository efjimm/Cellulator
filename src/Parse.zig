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

pub fn parse(allocator: Allocator, source: []const u8) !Ast {
	const tokenizer = Tokenizer.init(source);
	var parser = Parser.init(allocator, tokenizer, .{});

	errdefer parser.nodes.deinit(allocator);

	try parser.parse();

	return Ast{
		.nodes = parser.nodes,
	};
}

pub fn parseExpression(allocator: Allocator, source: []const u8) !Ast {
	const tokenizer = Tokenizer.init(source);
	var parser = Parser.init(allocator, tokenizer, .{});

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
	var slice = ast.nodes.slice();

	const first_node = ast.leftMostChild(new_root);
	const new_len = new_root + 1 - first_node;

	for (0..new_len, first_node..new_root + 1) |i, j| {
		var n = slice.get(j);
		switch (n) {
			.assignment, .add, .sub, .mul, .div, .mod => |*b| {
				b.lhs -= first_node;
				b.rhs -= first_node;
			},
			.builtin => |*b| {
				b.args -= first_node;
			},
			.arg_list => |*b| {
				b.start -= first_node;
				b.end -= first_node;
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
		.arg_list => |args| {
			var iter = ast.argIterator(args);

			if (order != .last and !try context.evalCell(index)) return false;
			while (iter.next()) |arg| {
				if (!try ast.traverseFrom(arg, order, context)) return false;
			}
			if (order == .last and !try context.evalCell(index)) return false;
		},
	}

	return true;
}

/// Iterates over the arguments in an ArgList backwards
pub const ArgIterator = struct {
	ast: *const Ast,
	args: ArgList,
	index: i33,

	pub fn next(iter: *ArgIterator) ?u32 {
		if (iter.index < iter.args.start) return null;
		const ret = @intCast(u32, iter.index);
		iter.index = @as(i33, iter.ast.leftMostChild(ret)) - 1;
		return ret;
	}
};

pub fn argIterator(ast: *const Ast, args: ArgList) ArgIterator {
	return ArgIterator{
		.ast = ast,
		.args = args,
		.index = args.end - 1,
	};
}

pub fn leftMostChild(ast: Ast, index: u32) u32 {
	assert(index < ast.nodes.len);

	const node = ast.nodes.get(index);

	return switch (node) {
		.number, .column, .cell => index,
		.assignment, .add, .sub, .mul, .div, .mod => |b| ast.leftMostChild(b.lhs),
		.builtin => |b| ast.leftMostChild(b.args),
		.arg_list => |args| ast.leftMostChild(args.start),
	};
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
			var iter = ast.argIterator(ast.nodes.items(.data)[b.args].arg_list);

			switch (b.tag) {
				.sum => {
					var sum_total: f64 = 0;
					while (iter.next()) |i| {
						sum_total += ast.evalNode(@intCast(u32, i), 0, context);
					}
					return total + sum_total;
				},
				.prod => {
					var prod_total: f64 = 1;
					while (iter.next()) |i| {
						prod_total *= ast.evalNode(@intCast(u32, i), 0, context);
					}
					return total + prod_total;
				},
				.avg => {
					var sum_total: f64 = 0;
					while (iter.next()) |i| {
						sum_total += ast.evalNode(@intCast(u32, i), 0, context);
					}
					return total + sum_total / @intToFloat(f64, (iter.args.end - iter.args.start));
				},
				.max => {
					var max = ast.evalNode(iter.next().?, 0, context);
					while (iter.next()) |i| {
						const val = ast.evalNode(@intCast(u32, i), 0, context);
						if (val > max)
							max = val;
					}
					return total + max;
				},
				.min => {
					var min = ast.evalNode(iter.next().?, 0, context);
					while (iter.next()) |i| {
						const val = ast.evalNode(@intCast(u32, i), 0, context);
						if (val < min)
							min = val;
					}
					return total + min;
				},
			}
		},
		.column, .assignment, .arg_list => {
			unreachable; // Attempted to eval non-expression
		},
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
	assert(@sizeOf(Node) <= 16);
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
	current_token: Token,

	tokenizer: Tokenizer,
	nodes: NodeList,

	allocator: Allocator,

	const log = std.log.scoped(.parser);

	const InitOptions = struct {
		nodes: NodeList = .{},
	};

	fn init(
		allocator: Allocator,
		tokenizer: Tokenizer,
		options: InitOptions,
	) Parser {
		var ret = Parser{
			.tokenizer = tokenizer,
			.nodes = options.nodes,
			.allocator = allocator,
			.current_token = undefined,
		};

		ret.current_token = ret.tokenizer.next() orelse Tokenizer.eofToken();
		return ret;
	}

	fn source(parser: Parser) []const u8 {
		return parser.tokenizer.bytes;
	}

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

		while (parser.eatTokenMulti(.{ .plus, .minus })) |token| {
			const op = BinaryOperator{
				.lhs = index,
				.rhs = try parser.parseMulExpr(),
			};

			const node: Node = switch (token.tag) {
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

		while (parser.eatTokenMulti(.{ .asterisk, .forward_slash, .percent })) |token| {
			const op = BinaryOperator{
				.lhs = index,
				.rhs = try parser.parsePrimaryExpr(),
			};

			const node: Node = switch (token.tag) {
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
		return switch (parser.current_token.tag) {
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
		const token = try parser.expectToken(.builtin);
		_ = try parser.expectToken(.lparen);

		const identifier = token.text(parser.source());
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

		const token = try parser.expectToken(.number);
		const text = token.text(parser.source());

		// Correctness of the number is guaranteed because the tokenizer wouldn't have generated a
		// number token on invalid format.
		const num = std.fmt.parseFloat(f64, text) catch unreachable;

		return parser.addNode(.{
			.number = if (is_positive) num else -num,
		});
	}

	/// CellName <- ('a'-'z' / 'A'-'Z')+ ('0'-'9')+
	fn parseCellName(parser: *Parser) !u32 {
		const token = try parser.expectToken(.cell_name);
		const text = token.text(parser.source());

		// TODO: check bounds
		const pos = Position.fromCellAddress(text);

		return parser.addNode(.{
			.cell = pos,
		});
	}

	fn addNode(parser: *Parser, data: Node) Allocator.Error!u32 {
		const ret = @intCast(u32, parser.nodes.len);
		try parser.nodes.append(parser.allocator, data);
		return ret;
	}

	fn expectToken(parser: *Parser, expected_tag: Token.Tag) !Token {
		return parser.eatToken(expected_tag) orelse error.UnexpectedToken;
	}

	fn eatToken(parser: *Parser, expected_tag: Token.Tag) ?Token {
		return if (parser.current_token.tag == expected_tag)
				parser.nextToken() else null;
	}

	fn eatTokenMulti(parser: *Parser, tags: anytype) ?Token {
		inline for (tags) |tag| {
			if (parser.eatToken(tag)) |token|
				return token;
		}

		return null;
	}

	fn nextToken(parser: *Parser) Token {
		const ret = parser.current_token;
		parser.current_token = parser.tokenizer.next() orelse Tokenizer.eofToken();
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

test "Parse and Eval Expression" {
	const t = std.testing;
	const Context = struct {
		pub fn evalCell(_: @This(), _: Position) f64 {
			unreachable;
		}
	};

	const testExpr = struct {
		fn func(expected: Parser.ParseError!f64, expr: []const u8) !void {
			var ast = parseExpression(t.allocator, expr) catch |err| {
				return if (err != expected) err else {};
			};
			defer ast.deinit(t.allocator);

			const val = expected catch unreachable;
			const res = ast.eval(Context{});
			std.testing.expectApproxEqRel(val, res, 0.0001) catch |err| {
				for (0..ast.nodes.len) |i| {
					const u = ast.nodes.get(i);
					std.debug.print("{}\n", .{ u });
				}
				return err;
			};
		}
	}.func;


	try testExpr(-4, "3 - 5 - 2");
	try testExpr(2, "8 / 2 / 2");
	try testExpr(15.833333, "8 + 5 / 2 * 3 - 5 / 3 + 2");
	try testExpr(-4, "(3 + 1) - (4 * 2)");
	try testExpr(2, "1 + 1");
	try testExpr(0, "100 - 100");
	try testExpr(100, "50 - -50");
	try testExpr(3, "@max(-500, -50000, 3, 1, 2, 0, 100 - 100, 4 / 2)");
	try testExpr(-50000, "@min(-500, -50000, 3, 1, 2, 0, 100 - 100, 4 / 2)");
	try testExpr(-50492, "@sum(-500, -50000, 3, 1, 2, 0, 100 - 100, 4 / 2)");
	try testExpr(0, "@prod(-500, -50000, 3, 1, 2, 0, 100 - 100, 4 / 2)");
	try testExpr(5.5, "@avg(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)");
	try testExpr(5, "@max(3, 5, 100 - 100)");
}

test "Splice" {
	const t = std.testing;
	var arena = std.heap.ArenaAllocator.init(t.allocator);
	defer arena.deinit();
	const allocator = arena.allocator();

	const Context = struct {
		pub fn evalCell(_: @This(), _: Position) f64 {
			return 0;
		}
	};

	var ast = try parse(allocator, "a0 = 100 * 3 + 5 / 2 + @avg(1, 10)");

	ast.splice(ast.rootNode().assignment.rhs);
	try t.expectApproxEqRel(@as(f64, 308), ast.eval(Context{}), 0.0001);
	try t.expectEqual(@as(usize, 12), ast.nodes.len);

	ast.splice(ast.rootNode().add.rhs);
	try t.expectApproxEqRel(@as(f64, 5.5), ast.eval(Context{}), 0.0001);
	try t.expectEqual(@as(usize, 4), ast.nodes.len);
}
