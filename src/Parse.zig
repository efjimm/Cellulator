//! Basic expression parser. Does not attempt error recovery and returns immediately on fatal
//! errors. Contains a `MultiArrayList` of `Node`s that is sorted in reverse topological order.

// TODO
// Handle division by zero (seemingly works with @rem but docs say it's ub)

const std = @import("std");
const Position = @import("Sheet.zig").Position;
const MultiArrayList = @import("multi_array_list.zig").MultiArrayList;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Ast = @This();

const NodeList = MultiArrayList(Node);

nodes: NodeList = .{},

pub fn parse(ast: *Ast, allocator: Allocator, source: []const u8) ParseError!void {
    ast.nodes.len = 0;
    const tokenizer = Tokenizer.init(source);

    var parser = Parser.init(allocator, tokenizer, .{ .nodes = ast.nodes });
    errdefer parser.deinit();
    try parser.parse();

    ast.nodes = parser.nodes;
}

pub fn fromSource(allocator: Allocator, source: []const u8) ParseError!Ast {
    var ast = Ast{};
    errdefer ast.deinit(allocator);
    try ast.parse(allocator, source);
    return ast;
}

pub fn parseExpression(allocator: Allocator, source: []const u8) ParseError!Ast {
    const tokenizer = Tokenizer.init(source);

    var parser = Parser.init(allocator, tokenizer, .{});
    errdefer parser.deinit();

    _ = try parser.parseExpression();
    _ = try parser.expectToken(.eof);

    return Ast{
        .nodes = parser.nodes,
    };
}

pub fn deinit(ast: *Ast, allocator: Allocator) void {
    ast.nodes.deinit(allocator);
    ast.nodes = .{};
}

pub const Slice = struct {
    nodes: NodeList.Slice,

    pub fn toAst(ast: *Slice) Ast {
        return .{
            .nodes = ast.nodes.toMultiArrayList(),
        };
    }

    pub fn rootNodeIndex(ast: Slice) u32 {
        return @intCast(u32, ast.nodes.len) - 1;
    }

    pub fn rootTag(ast: Slice) u32 {
        return ast.nodes.items(.tags)[ast.nodes.len - 1];
    }

    pub fn rootNode(ast: Slice) Node {
        return ast.nodes.get(ast.rootNodeIndex());
    }

    pub fn leftMostChild(ast: Slice, index: u32) u32 {
        assert(index < ast.nodes.len);

        const node = ast.nodes.get(index);

        return switch (node) {
            .number, .column, .cell => index,
            .assignment, .add, .sub, .mul, .div, .mod, .range => |b| ast.leftMostChild(b.lhs),
            .builtin => |b| ast.leftMostChild(b.args),
            .arg_list => |args| ast.leftMostChild(args.start),
        };
    }

    /// Removes all nodes except for the given index and its children
    /// Nodes in the list are already sorted in reverse topological order which allows us to overwrite
    /// nodes sequentially without loss. This function preserves reverse topological order.
    pub fn splice(ast: *Slice, new_root: u32) void {
        const first_node = ast.leftMostChild(new_root);
        const new_len = new_root + 1 - first_node;

        for (0..new_len, first_node..new_root + 1) |i, j| {
            var n = ast.nodes.get(@intCast(u32, j));
            switch (n) {
                .assignment, .add, .sub, .mul, .div, .mod, .range => |*b| {
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
            ast.nodes.set(@intCast(u32, i), n);
        }

        ast.nodes.len = new_len;
    }

    pub fn printFrom(ast: Slice, index: u32, writer: anytype) !void {
        const node = ast.nodes.get(index);

        switch (node) {
            .number => |n| try writer.print("{d}", .{n}),
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
            .range => |b| {
                try ast.printFrom(b.lhs, writer);
                try writer.writeByte(':');
                try ast.printFrom(b.rhs, writer);
            },

            .builtin => |b| {
                switch (b.tag) {
                    inline else => |tag| try writer.print("@{s}(", .{@tagName(tag)}),
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

    /// Same as `traverse`, but starting from the node at the given index.
    fn traverseFrom(ast: Slice, index: u32, order: TraverseOrder, context: anytype) !bool {
        const node = ast.nodes.get(index);

        switch (node) {
            .assignment, .add, .sub, .mul, .div, .mod, .range => |b| {
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
        ast: *const Slice,
        args: ArgList,
        index: u32,

        pub fn next(iter: *ArgIterator) ?u32 {
            if (iter.index <= iter.args.start) return null;
            const ret = iter.index - 1;
            iter.index = iter.ast.leftMostChild(ret);
            return ret;
        }
    };

    pub fn argIterator(ast: *const Slice, args: ArgList) ArgIterator {
        return ArgIterator{
            .ast = ast,
            .args = args,
            .index = args.end,
        };
    }

    pub fn evalNode(ast: Slice, index: u32, context: anytype) !f64 {
        const node = ast.nodes.get(index);

        return switch (node) {
            .number => |n| n,
            .cell => |pos| try context.evalCell(pos) orelse 0,
            .add => |op| (try ast.evalNode(op.lhs, context) + try ast.evalNode(op.rhs, context)),
            .sub => |op| (try ast.evalNode(op.lhs, context) - try ast.evalNode(op.rhs, context)),
            .mul => |op| (try ast.evalNode(op.lhs, context) * try ast.evalNode(op.rhs, context)),
            .div => |op| (try ast.evalNode(op.lhs, context) / try ast.evalNode(op.rhs, context)),
            .mod => |op| @rem(try ast.evalNode(op.lhs, context), try ast.evalNode(op.rhs, context)),
            .builtin => |b| ast.evalBuiltin(b, context),
            .range, .column, .assignment, .arg_list => EvalError.NotEvaluable,
        };
    }

    fn evalBuiltin(ast: Slice, builtin: Builtin, context: anytype) !f64 {
        const args = ast.nodes.items(.data)[builtin.args].arg_list;
        return switch (builtin.tag) {
            .sum => try ast.evalSum(args, context),
            .prod => try ast.evalProd(args, context),
            .avg => try ast.evalAvg(args, context),
            .max => try ast.evalMax(args, context),
            .min => try ast.evalMin(args, context),
        };
    }

    pub fn evalSum(ast: Slice, args: ArgList, context: anytype) !f64 {
        var iter = ast.argIterator(args);

        var total: f64 = 0;
        while (iter.next()) |i| {
            const tag = ast.nodes.items(.tags)[i];
            total += if (tag == .range) try ast.sumRange(ast.nodes.items(.data)[i].range, context) else try ast.evalNode(i, context);
        }
        return total;
    }

    pub fn sumRange(ast: Slice, range: BinaryOperator, context: anytype) !f64 {
        const pos1 = ast.nodes.items(.data)[range.lhs].cell;
        const pos2 = ast.nodes.items(.data)[range.rhs].cell;

        const start = Position.topLeft(pos1, pos2);
        const end = Position.bottomRight(pos1, pos2);

        var total: f64 = 0;
        for (start.y..end.y + @as(u32, 1)) |y| {
            for (start.x..end.x + @as(u32, 1)) |x| {
                total += try context.evalCell(.{ .x = @intCast(u16, x), .y = @intCast(u16, y) }) orelse 0;
            }
        }
        return total;
    }

    pub fn evalProd(ast: Slice, args: ArgList, context: anytype) !f64 {
        var iter = ast.argIterator(args);
        var total: f64 = 1;

        while (iter.next()) |i| {
            const tag = ast.nodes.items(.tags)[i];
            total *= if (tag == .range) try ast.prodRange(ast.nodes.items(.data)[i].range, context) else try ast.evalNode(i, context);
        }
        return total;
    }

    pub fn prodRange(ast: Slice, range: BinaryOperator, context: anytype) !f64 {
        const pos1 = ast.nodes.items(.data)[range.lhs].cell;
        const pos2 = ast.nodes.items(.data)[range.rhs].cell;

        const start = Position.topLeft(pos1, pos2);
        const end = Position.bottomRight(pos1, pos2);

        var total: f64 = 1;
        for (start.y..end.y + @as(u32, 1)) |y| {
            for (start.x..end.x + @as(u32, 1)) |x| {
                total *= try context.evalCell(.{ .x = @intCast(u16, x), .y = @intCast(u16, y) }) orelse continue;
            }
        }
        return total;
    }

    pub fn evalAvg(ast: Slice, args: ArgList, context: anytype) !f64 {
        var iter = ast.argIterator(args);
        var total: f64 = 0;
        var total_items: u32 = 0;

        while (iter.next()) |i| {
            const tag = ast.nodes.items(.tags)[i];
            if (tag == .range) {
                const range = ast.nodes.items(.data)[i].range;
                total += try ast.sumRange(range, context);

                const p1 = ast.nodes.items(.data)[range.lhs].cell;
                const p2 = ast.nodes.items(.data)[range.rhs].cell;
                total_items += Position.area(p1, p2);
            } else {
                total += try ast.evalNode(i, context);
                total_items += 1;
            }
        }

        return total / @intToFloat(f64, total_items);
    }

    pub fn evalMax(ast: Slice, args: ArgList, context: anytype) !f64 {
        var iter = ast.argIterator(args);
        var max: ?f64 = null;

        while (iter.next()) |i| {
            const tag = ast.nodes.items(.tags)[i];
            const res = if (tag == .range) try ast.maxRange(ast.nodes.items(.data)[i].range, context) orelse continue else try ast.evalNode(i, context);
            if (max == null or res > max.?)
                max = res;
        }

        return max orelse 0;
    }

    pub fn maxRange(ast: Slice, range: BinaryOperator, context: anytype) !?f64 {
        const pos1 = ast.nodes.items(.data)[range.lhs].cell;
        const pos2 = ast.nodes.items(.data)[range.rhs].cell;

        const start = Position.topLeft(pos1, pos2);
        const end = Position.bottomRight(pos1, pos2);

        var max: ?f64 = null;
        for (start.y..end.y + @as(u32, 1)) |y| {
            for (start.x..end.x + @as(u32, 1)) |x| {
                const res = try context.evalCell(.{ .x = @intCast(u16, x), .y = @intCast(u16, y) }) orelse continue;
                if (max == null or res > max.?)
                    max = res;
            }
        }
        return max;
    }

    pub fn evalMin(ast: Slice, args: ArgList, context: anytype) !f64 {
        var iter = ast.argIterator(args);
        var min: ?f64 = null;

        while (iter.next()) |i| {
            const tag = ast.nodes.items(.tags)[i];
            const res = if (tag == .range) try ast.minRange(ast.nodes.items(.data)[i].range, context) orelse continue else try ast.evalNode(i, context);
            if (min == null or res < min.?)
                min = res;
        }

        return min orelse 0;
    }

    pub fn minRange(ast: Slice, range: BinaryOperator, context: anytype) !?f64 {
        const pos1 = ast.nodes.items(.data)[range.lhs].cell;
        const pos2 = ast.nodes.items(.data)[range.rhs].cell;

        const start = Position.topLeft(pos1, pos2);
        const end = Position.bottomRight(pos1, pos2);

        var min: ?f64 = null;
        for (start.y..end.y + @as(u32, 1)) |y| {
            for (start.x..end.x + @as(u32, 1)) |x| {
                const res = try context.evalCell(.{ .x = @intCast(u16, x), .y = @intCast(u16, y) }) orelse continue;
                if (min == null or res < min.?)
                    min = res;
            }
        }
        return min;
    }
};

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
    var slice = ast.toSlice();
    slice.splice(new_root);
    ast.* = slice.toAst();
}

pub fn toSlice(ast: Ast) Slice {
    return .{
        .nodes = ast.nodes.slice(),
    };
}

pub fn print(ast: *Ast, writer: anytype) @TypeOf(writer).Error!void {
    const slice = ast.toSlice();
    return slice.printFrom(slice.rootNodeIndex(), writer);
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
    const slice = ast.toSlice();
    return slice.traverseFrom(slice.rootNodeIndex(), order, context);
}

pub fn leftMostChild(ast: Ast, index: u32) u32 {
    assert(index < ast.nodes.len);

    const node = ast.nodes.get(index);

    return switch (node) {
        .number, .column, .cell => index,
        .assignment, .add, .sub, .mul, .div, .mod, .range => |b| ast.leftMostChild(b.lhs),
        .builtin => |b| ast.leftMostChild(b.args),
        .arg_list => |args| ast.leftMostChild(args.start),
    };
}

pub const EvalError = error{
    NotEvaluable,
};

pub fn eval(
    ast: Ast,
    /// An instance of a type which has the function `fn evalCell(@TypeOf(context), Position) ?f64`.
    /// This function should return the value of the cell at the given position. It may do this
    /// by calling this function.
    context: anytype,
) !f64 {
    const slice = ast.toSlice();
    return slice.evalNode(slice.rootNodeIndex(), context);
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
    range: BinaryOperator,
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

    pub fn count(args: ArgList) u32 {
        return args.end - args.start;
    }
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

pub const ParseError = error{
    UnexpectedToken,
    InvalidCellAddress,
} || Allocator.Error;

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

    fn deinit(parser: *Parser) void {
        parser.nodes.deinit(parser.allocator);
        parser.* = undefined;
    }

    fn source(parser: Parser) []const u8 {
        return parser.tokenizer.bytes;
    }

    fn parse(parser: *Parser) ParseError!void {
        _ = try parser.parseStatement();
        _ = try parser.expectToken(.eof);
    }

    /// Statement <- Assignment
    fn parseStatement(parser: *Parser) ParseError!u32 {
        return parser.parseAssignment();
    }

    /// Assignment <- CellName '=' Expression
    fn parseAssignment(parser: *Parser) ParseError!u32 {
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

    /// PrimaryExpr <- Number / Range / Builtin / '(' Expression ')'
    fn parsePrimaryExpr(parser: *Parser) !u32 {
        return switch (parser.current_token.tag) {
            .minus, .plus, .number => parser.parseNumber(),
            .cell_name => parser.parseRange(),
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

    /// Range <- CellName (':' CellName)?
    fn parseRange(parser: *Parser) !u32 {
        const lhs = try parser.parseCellName();

        if (parser.eatToken(.colon) == null) return lhs;

        const rhs = try parser.parseCellName();

        return parser.addNode(.{
            .range = .{
                .lhs = lhs,
                .rhs = rhs,
            },
        });
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
        const pos = Position.fromAddress(text) catch return error.InvalidCellAddress;

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
            parser.nextToken()
        else
            null;
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
        colon,

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

    const State = union(enum) {
        start,
        number: bool,
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

        var state: State = .start;
        var tag = Token.Tag.eof;

        while (tokenizer.pos < tokenizer.bytes.len) : (tokenizer.pos += 1) {
            const c = tokenizer.bytes[tokenizer.pos];

            switch (state) {
                .start => switch (c) {
                    '0'...'9' => {
                        state = .{ .number = false };
                        tag = .number;
                    },
                    '.' => {
                        state = .{ .number = true };
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
                    ':' => {
                        tag = .colon;
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
                    '.' => {
                        if (state.number) break;
                        state.number = true;
                    },
                    else => break,
                },
                .column_or_cell_name => switch (c) {
                    'a'...'z', 'A'...'Z' => {},
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
    const testTokens = struct {
        fn func(bytes: []const u8, tokens: []const Token.Tag) !void {
            var tokenizer = Tokenizer.init(bytes);
            for (tokens) |tag| {
                if (tag == .eof) {
                    try t.expectEqual(@as(?Token, null), tokenizer.next());
                } else {
                    try t.expectEqual(tag, tokenizer.next().?.tag);
                }
            }
            try t.expectEqual(@as(?Token, null), tokenizer.next());
        }
    }.func;

    try testTokens("a = 3", &.{ .column_name, .equals_sign, .number, .eof });
    try testTokens("@max(34, 100 + 45, @min(3, 1))", &.{ .builtin, .lparen, .number, .comma, .number, .plus, .number, .comma, .builtin, .lparen, .number, .comma, .number, .rparen, .rparen, .eof });
    try testTokens("", &.{.eof});
}

test "Parse and Eval Expression" {
    const t = std.testing;
    const Context = struct {
        pub fn evalCell(_: @This(), _: Position) !?f64 {
            unreachable;
        }
    };

    const Error = EvalError || ParseError;

    const testExpr = struct {
        fn func(expected: Error!f64, expr: []const u8) !void {
            var ast = parseExpression(t.allocator, expr) catch |err| {
                return if (err != expected) err else {};
            };
            defer ast.deinit(t.allocator);

            const res = ast.eval(Context{}) catch |err| return if (err != expected) err else {};
            const val = try expected;
            std.testing.expectApproxEqRel(val, res, 0.0001) catch |err| {
                for (0..ast.nodes.len) |i| {
                    const u = ast.nodes.get(@intCast(u32, i));
                    std.debug.print("{}\n", .{u});
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

    // Cannot evaluate a range on its own
    try testExpr(error.NotEvaluable, "a0:a0");
    try testExpr(error.NotEvaluable, "a0:crxo65535");
    try testExpr(error.NotEvaluable, "z10:xxx500");
}

test "Functions on Ranges" {
    const Sheet = @import("Sheet.zig");
    const Cell = Sheet.Cell;
    const t = std.testing;
    const Test = struct {
        sheet: *Sheet,

        fn evalCell(context: @This(), pos: Position) !?f64 {
            const cell = context.sheet.getCellPtr(pos) orelse return null;
            return try cell.eval(context.sheet);
        }

        fn testSheetExpr(expected: f64, expr: []const u8) !void {
            var sheet = Sheet.init(t.allocator);
            defer sheet.deinit();

            try sheet.setCell(.{ .x = 0, .y = 0 }, try Cell.fromExpression(t.allocator, "0"), .{});
            try sheet.setCell(.{ .x = 1, .y = 0 }, try Cell.fromExpression(t.allocator, "100"), .{});
            try sheet.setCell(.{ .x = 0, .y = 1 }, try Cell.fromExpression(t.allocator, "500"), .{});
            try sheet.setCell(.{ .x = 1, .y = 1 }, try Cell.fromExpression(t.allocator, "333.33"), .{});

            var ast = try parseExpression(t.allocator, expr);
            defer ast.deinit(t.allocator);

            try sheet.update();
            const res = try ast.eval(@This(){ .sheet = &sheet });
            try std.testing.expectApproxEqRel(expected, res, 0.0001);
        }
    };

    try Test.testSheetExpr(0, "@sum(a0:a0)");
    try Test.testSheetExpr(100, "@sum(a0:b0)");
    try Test.testSheetExpr(500, "@sum(a0:a1)");
    try Test.testSheetExpr(933.33, "@sum(a0:b1)");
    try Test.testSheetExpr(933.33, "@sum(a0:z10)");
    try Test.testSheetExpr(833.33, "@sum(a1:z10)");
    try Test.testSheetExpr(0, "@sum(c3:z10)");
    try Test.testSheetExpr(953.33, "@sum(5, a0:z10, 5, 10)");
    try Test.testSheetExpr(35, "@sum(5, 30 / 2, c3:z10, 5, 10)");
    try t.expectError(error.UnexpectedToken, Test.testSheetExpr(0, "@sum()"));

    try Test.testSheetExpr(0, "@prod(a0:a0)");
    try Test.testSheetExpr(0, "@prod(a0:b0)");
    try Test.testSheetExpr(0, "@prod(a0:a1)");
    try Test.testSheetExpr(0, "@prod(a0:b1)");
    try Test.testSheetExpr(166665, "@prod(a1:b1)");
    try Test.testSheetExpr(166665, "@prod(a1:z10)");
    try Test.testSheetExpr(333.33, "@prod(b1:z10)");
    try Test.testSheetExpr(0, "@prod(100, -1, a0:z10, 50)");
    try Test.testSheetExpr(-166665000, "@prod(100, -1, b0:b1, 50)");
    try t.expectError(error.UnexpectedToken, Test.testSheetExpr(0, "@prod()"));

    try Test.testSheetExpr(0, "@avg(a0:a0)");
    try Test.testSheetExpr(50, "@avg(a0:b0)");
    try Test.testSheetExpr(250, "@avg(a0:a1)");
    try Test.testSheetExpr(233.3325, "@avg(a0:b1)");
    try Test.testSheetExpr(135.47571428571428571428, "@avg(5, 5, a0:b1, 5)");
    try t.expectError(error.UnexpectedToken, Test.testSheetExpr(0, "@avg()"));

    try Test.testSheetExpr(0, "@max(a0:a0)");
    try Test.testSheetExpr(100, "@max(a0:b0)");
    try Test.testSheetExpr(500, "@max(a0:a1)");
    try Test.testSheetExpr(500, "@max(a0:b1)");
    try Test.testSheetExpr(100, "@max(a0:z0)");
    try Test.testSheetExpr(500, "@max(a0:z10)");
    try Test.testSheetExpr(0, "@max(c3:z10)");
    try Test.testSheetExpr(3, "@max(3, c3:z10, 1, 2)");
    try Test.testSheetExpr(500, "@max(3, a0:b1, 1, 2)");
    try t.expectError(error.UnexpectedToken, Test.testSheetExpr(0, "@max()"));

    try Test.testSheetExpr(0, "@min(a0:a0)");
    try Test.testSheetExpr(0, "@min(a0:b0)");
    try Test.testSheetExpr(0, "@min(a0:a1)");
    try Test.testSheetExpr(0, "@min(a0:b1)");
    try Test.testSheetExpr(333.33, "@min(a1:z10)");
    try Test.testSheetExpr(0, "@min(c3:z10)");
    try Test.testSheetExpr(1, "@min(3, c3:z10, 1, 2)");
    try Test.testSheetExpr(0, "@min(3, a0:b1, 1, 2)");
    try t.expectError(error.UnexpectedToken, Test.testSheetExpr(0, "@min()"));
}

test "Splice" {
    const t = std.testing;
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Context = struct {
        pub fn evalCell(_: @This(), _: Position) !?f64 {
            return null;
        }
    };

    var ast = try fromSource(allocator, "a0 = 100 * 3 + 5 / 2 + @avg(1, 10)");

    ast.splice(ast.rootNode().assignment.rhs);
    try t.expectApproxEqRel(@as(f64, 308), try ast.eval(Context{}), 0.0001);
    try t.expectEqual(@as(usize, 12), ast.nodes.len);

    ast.splice(ast.rootNode().add.rhs);
    try t.expectApproxEqRel(@as(f64, 5.5), try ast.eval(Context{}), 0.0001);
    try t.expectEqual(@as(usize, 4), ast.nodes.len);
}
