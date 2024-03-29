const std = @import("std");
const Position = @import("Position.zig").Position;
const MultiArrayList = @import("multi_array_list.zig").MultiArrayList;
const Tokenizer = @import("Tokenizer.zig");

const Allocator = std.mem.Allocator;
const NodeList = MultiArrayList(Node);
const assert = std.debug.assert;

const Parser = @This();

current_token: Tokenizer.Token,

tokenizer: Tokenizer,
nodes: NodeList,

/// Total length of all string literals parsed
strings_len: u32 = 0,

allocator: Allocator,

const String = @import("Ast.zig").String;
const Node = @import("Ast.zig").Node;

pub const BinaryOperator = struct {
    lhs: u32,
    rhs: u32,
};

pub const Builtin = struct {
    tag: Tag,
    first_arg: u32,

    const Tag = enum {
        sum,
        prod,
        avg,
        max,
        min,
        upper,
        lower,
    };

    comptime {
        assert(@sizeOf(Tag) <= 4);
    }
};

const builtins = std.ComptimeStringMap(Builtin.Tag, .{
    .{ "sum", .sum },
    .{ "prod", .prod },
    .{ "avg", .avg },
    .{ "max", .max },
    .{ "min", .min },
    .{ "upper", .upper },
    .{ "lower", .lower },
});

pub const ParseError = error{
    UnexpectedToken,
    InvalidCellAddress,
} || Allocator.Error;

const log = std.log.scoped(.parser);

const InitOptions = struct {
    nodes: NodeList = .{},
};

pub fn init(
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

pub fn deinit(parser: *Parser) void {
    parser.nodes.deinit(parser.allocator);
    parser.* = undefined;
}

pub fn source(parser: Parser) []const u8 {
    return parser.tokenizer.bytes;
}

pub fn parse(parser: *Parser) ParseError!void {
    _ = try parser.parseStatement();
    _ = try parser.expectToken(.eof);
}

/// Statement <- 'let' Assignment
fn parseStatement(parser: *Parser) ParseError!u32 {
    const token = parser.eatTokenMulti(.{
        .keyword_let,
    }) orelse return error.UnexpectedToken;
    return switch (token.tag) {
        .keyword_let => parser.parseAssignment(),
        else => unreachable,
    };
}

fn parseStringLiteral(parser: *Parser) ParseError!u32 {
    const token = parser.eatTokenMulti(.{
        .double_string_literal,
        .single_string_literal,
    }) orelse return error.UnexpectedToken;

    parser.strings_len += token.end - token.start;

    // TODO: Handle escapes of quotes
    return parser.addNode(.{
        .string_literal = .{
            .start = token.start,
            .end = token.end,
        },
    });
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
pub fn parseExpression(parser: *Parser) ParseError!u32 {
    return parser.parseAddExpr();
}

/// AddExpr <- MulExpr (('+' / '-' / '#') MulExpr)*
fn parseAddExpr(parser: *Parser) !u32 {
    var index = try parser.parseMulExpr();

    while (parser.eatTokenMulti(.{ .plus, .minus, .hash })) |token| {
        const op = BinaryOperator{
            .lhs = index,
            .rhs = try parser.parseMulExpr(),
        };

        const node: Node = switch (token.tag) {
            .plus => .{ .add = op },
            .minus => .{ .sub = op },
            .hash => .{ .concat = op },
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

/// PrimaryExpr <- Number / Range / StsringLiteral / Builtin / '(' Expression ')'
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
        .single_string_literal,
        .double_string_literal,
        => parser.parseStringLiteral(),
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

    const args_start = switch (builtin) {
        // These builtins take only one argument
        .upper,
        .lower,
        => try parser.parseExpression(),
        // These builtins require at least one argument
        .sum,
        .max,
        .prod,
        .avg,
        .min,
        => try parser.parseArgList(),
    };
    _ = try parser.expectToken(.rparen);

    return parser.addNode(.{
        .builtin = .{
            .tag = builtin,
            .first_arg = args_start,
        },
    });
}

/// ArgList <- Expression (',' Expression)*
fn parseArgList(parser: *Parser) !u32 {
    const start = try parser.parseExpression();

    while (parser.eatToken(.comma)) |_| {
        _ = try parser.parseExpression();
    }

    return start;
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

    const pos = Position.fromAddress(text) catch return error.InvalidCellAddress;

    return parser.addNode(.{
        .cell = pos,
    });
}

fn addNode(parser: *Parser, data: Node) Allocator.Error!u32 {
    const ret: u32 = @intCast(parser.nodes.len);
    try parser.nodes.append(parser.allocator, data);
    return ret;
}

pub fn expectToken(parser: *Parser, expected_tag: Tokenizer.Token.Tag) !Tokenizer.Token {
    return parser.eatToken(expected_tag) orelse error.UnexpectedToken;
}

fn eatToken(parser: *Parser, expected_tag: Tokenizer.Token.Tag) ?Tokenizer.Token {
    return if (parser.current_token.tag == expected_tag)
        parser.nextToken()
    else
        null;
}

fn eatTokenMulti(parser: *Parser, tags: anytype) ?Tokenizer.Token {
    inline for (tags) |tag| {
        if (parser.eatToken(tag)) |token|
            return token;
    }

    return null;
}

fn nextToken(parser: *Parser) Tokenizer.Token {
    const ret = parser.current_token;
    parser.current_token = parser.tokenizer.next() orelse Tokenizer.eofToken();
    return ret;
}

test "parser" {
    const t = std.testing;
    const testParser = struct {
        fn func(bytes: []const u8, node_tags: []const std.meta.Tag(Node)) !void {
            var parser = Parser.init(t.allocator, .{ .bytes = bytes }, .{});
            defer parser.deinit();
            try parser.parse();
            for (node_tags, parser.nodes.items(.tags)) |expected, actual| {
                t.expectEqual(expected, actual) catch |err| {
                    for (parser.nodes.items(.tags)) |tag| {
                        std.debug.print("{s}\n", .{@tagName(tag)});
                    }
                    return err;
                };
            }
        }
    }.func;
    const testParseError = struct {
        fn func(bytes: []const u8, err: ?anyerror) !void {
            var parser = Parser.init(t.allocator, .{ .bytes = bytes }, .{});
            defer parser.deinit();
            if (err) |e| {
                try t.expectError(e, parser.parse());
            } else {
                try parser.parse();
            }
        }
    }.func;

    try testParser("let a0 = 5", &.{ .cell, .number, .assignment });
    try testParser("let a0 = 5.0 + +5.0", &.{ .cell, .number, .number, .add, .assignment });
    try testParser("let a0 = 5.0 + -5.0", &.{ .cell, .number, .number, .add, .assignment });
    try testParser("let a0 = 5.0 - +5.0", &.{ .cell, .number, .number, .sub, .assignment });
    try testParser("let a0 = 5.0 - -5.0", &.{ .cell, .number, .number, .sub, .assignment });
    try testParser("let b0 = 0.0 + 1.123", &.{ .cell, .number, .number, .add, .assignment });
    try testParser("let xxx50000 = 000000 - 11111122222223333333444444", &.{ .cell, .number, .number, .sub, .assignment });
    try testParser("let c30 = 123_123.231 * 2", &.{ .cell, .number, .number, .mul, .assignment });
    try testParser("let crxp65535 = 123_123.321 / 123_123.321", &.{ .cell, .number, .number, .div, .assignment });

    try testParser("let a0 = 3 - 1 * 2", &.{ .cell, .number, .number, .number, .mul, .sub, .assignment });
    try testParser("let a0 = 1 / 2 + 3", &.{ .cell, .number, .number, .div, .number, .add, .assignment });
    try testParser("let a0 = 1 - (3 + 5)", &.{ .cell, .number, .number, .number, .add, .sub, .assignment });
    try testParser("let a0 = (1 + 2) - (2 + 1)", &.{ .cell, .number, .number, .add, .number, .number, .add, .sub, .assignment });
    try testParser("let a0 = 2 / (1 - (1 + 3))", &.{ .cell, .number, .number, .number, .number, .add, .sub, .div, .assignment });

    try testParser("let a0 = 'this is epic' # ' and nice'", &.{ .cell, .string_literal, .string_literal, .concat, .assignment });

    try testParseError("unga bunga", error.UnexpectedToken);
    try testParseError("let", error.UnexpectedToken);
    try testParseError("let a0 = ", error.UnexpectedToken);
    try testParseError("a0 = 5", error.UnexpectedToken);
    try testParseError("let a0 = ", error.UnexpectedToken);
    try testParseError("let a0 = 'string!'", null);
    try testParseError("let a0 = 1 # 1", null);
    try testParseError("let a0 = 1 # 'string'", null);
    try testParseError("let a0 = 'strings' # 'string'", null);
    try testParseError("let a0 = @upper(1)", null);
    try testParseError("let a0 = @lower(1)", null);
    try testParseError("let a0 = (5", error.UnexpectedToken);
    try testParseError("let a0 = 5)", error.UnexpectedToken);
    try testParseError("let a0 = 5 + ", error.UnexpectedToken);
    try testParseError("let a0 = ++ 5", error.UnexpectedToken);
    try testParseError("let a0 = 5 - ", error.UnexpectedToken);
    try testParseError("let a0 = -- 5", error.UnexpectedToken);

    try testParseError("let", error.UnexpectedToken);
    try testParseError("let a0", error.UnexpectedToken);
    try testParseError("let a0 =", error.UnexpectedToken);
    try testParseError("let a0 = 5", null);
    try testParseError("let a0 = 'string'", null);
    try testParseError("let a0 = 'string' + 'string'", null); // Parses but does not eval
    try testParseError("let a0 = 'string' - 'string'", null);
    try testParseError("let a0 = 'string' * 'string'", null);
    try testParseError("let a0 = 'string' / 'string'", null);
    try testParseError("let a0 = 'string' % 'string'", null);

    try testParseError("let a0 = @upper()", error.UnexpectedToken);
    try testParseError("let a0 = @lower()", error.UnexpectedToken);
    try testParseError("let a0 = @upper(a0:b0)", null);
    try testParseError("let a0 = @lower(a0:b0)", null);
    try testParseError("let a0 = @upper(a0, b0)", error.UnexpectedToken); // Should only have one arg
    try testParseError("let a0 = @lower(a0, b0)", error.UnexpectedToken); // Should only have one arg

    try testParseError("let a0 = @sum('string1')", null);
    try testParseError("let a0 = @prod('string1')", null);
    try testParseError("let a0 = @avg('string1')", null);
    try testParseError("let a0 = @min('string1')", null);
    try testParseError("let a0 = @max('string1')", null);
    try testParseError("let a0 = 'string' # 'string'", null);
    try testParseError("let a0 = 'string' 5", error.UnexpectedToken);
    try testParseError("let a0 = 'string' 'string'", error.UnexpectedToken);

    try testParseError("let crxp0 = 5", null);
    // try testParseError("let crxq0 = 5", error.InvalidCellAddress);
    try testParseError("let crxp0 = 'string'", null);
    // try testParseError("let crxq0 = 'string'", error.InvalidCellAddress);
}

test "Node contents" {
    const t = std.testing;
    const testNodes = struct {
        fn func(bytes: []const u8, nodes: []const Node) !void {
            var parser = Parser.init(t.allocator, .{ .bytes = bytes }, .{});
            defer parser.deinit();

            try parser.parse();
            const slice = parser.nodes.slice();
            for (nodes, slice.items(.tags), slice.items(.data)) |expected, tag, data| {
                const actual = switch (tag) {
                    inline else => |t_| @unionInit(Node, @tagName(t_), @field(data, @tagName(t_))),
                };
                try t.expectEqual(expected, actual);
            }
        }
    }.func;

    try testNodes(
        "let b30 = 5 * (3 - 2) / (2 + 1)",
        &.{
            .{ .cell = .{ .x = 1, .y = 30 } },
            .{ .number = 5.0 },
            .{ .number = 3.0 },
            .{ .number = 2.0 },
            .{ .sub = .{ .lhs = 2, .rhs = 3 } },
            .{ .mul = .{ .lhs = 1, .rhs = 4 } },
            .{ .number = 2.0 },
            .{ .number = 1.0 },
            .{ .add = .{ .lhs = 6, .rhs = 7 } },
            .{ .div = .{ .lhs = 5, .rhs = 8 } },
            .{ .assignment = .{ .lhs = 0, .rhs = 9 } },
        },
    );
    try testNodes(
        "let crxp65535 = 'this is epic' # 'nice'",
        &.{
            .{ .cell = .{ .x = 65535, .y = 65535 } },
            .{
                .string_literal = .{
                    .start = "let crxp65535 = '".len,
                    .end = "let crxp65535 = 'this is epic".len,
                },
            },
            .{
                .string_literal = .{
                    .start = "let crxp65535 = 'this is epic' # '".len,
                    .end = "let crxp65535 = 'this is epic' # 'nice".len,
                },
            },
            .{ .concat = .{ .lhs = 1, .rhs = 2 } },
            .{ .assignment = .{ .lhs = 0, .rhs = 3 } },
        },
    );
}
