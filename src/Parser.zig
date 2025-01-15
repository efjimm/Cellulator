const std = @import("std");
const Position = @import("Position.zig").Position;
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;

const Allocator = std.mem.Allocator;
const NodeList = std.MultiArrayList(Node);
const assert = std.debug.assert;

const Parser = @This();

token_tags: []const Token.Tag,
token_starts: []const u32,
tok_i: u32,

src: [:0]const u8,

nodes: NodeList,

allocator: Allocator,

const String = @import("ast.zig").String;
const Node = @import("ast.zig").Node;
const Index = @import("ast.zig").Index;

pub const BinaryOperator = extern struct {
    lhs: Index,
    rhs: Index,
};

pub const Builtin = extern struct {
    tag: Tag,
    first_arg: Index,

    const Tag = enum(u8) {
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

const builtins = std.StaticStringMap(Builtin.Tag).initComptime(.{
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
    src: [:0]const u8,
    token_tags: []const Token.Tag,
    token_starts: []const u32,
    options: InitOptions,
) Parser {
    return .{
        .nodes = options.nodes,
        .allocator = allocator,
        .token_tags = token_tags,
        .token_starts = token_starts,
        .tok_i = 0,
        .src = src,
    };
}

pub fn parse(parser: *Parser) ParseError!void {
    _ = try parser.parseStatement();
    try parser.expectToken(.eof);
}

/// Statement <- 'let' Assignment
fn parseStatement(parser: *Parser) ParseError!Index {
    try parser.expectToken(.keyword_let);
    return parser.parseAssignment();
}

fn parseStringLiteral(parser: *Parser, comptime expected_tag: Token.Tag) ParseError!Index {
    const start = try parser.expectTokenGet(expected_tag);
    const end_tag = switch (expected_tag) {
        .single_string_literal_start => .single_string_literal_end,
        .double_string_literal_start => .double_string_literal_end,
        else => comptime unreachable,
    };
    const end = try parser.expectTokenGet(end_tag);

    // TODO: Handle escapes of quotes
    return parser.addNode(
        .init(.string_literal, .{
            .start = start + 1,
            .end = end,
        }),
    );
}

/// Assignment <- CellReference '=' Expression
fn parseAssignment(parser: *Parser) ParseError!Index {
    const lhs = try parser.parseCellName();
    try parser.expectToken(.equals_sign);
    const rhs = try parser.parseExpression();

    return parser.addNode(.init(.assignment, .{ .lhs = lhs, .rhs = rhs }));
}

/// Expression <- AddExpr
pub fn parseExpression(parser: *Parser) ParseError!Index {
    return parser.parseAddExpr();
}

/// AddExpr <- MulExpr (('+' / '-' / '#') MulExpr)*
fn parseAddExpr(parser: *Parser) !Index {
    var index = try parser.parseMulExpr();

    while (true) switch (parser.token_tags[parser.tok_i]) {
        inline .plus, .minus, .hash => |tag| {
            parser.tok_i += 1;
            const op = BinaryOperator{
                .lhs = index,
                .rhs = try parser.parseMulExpr(),
            };

            const node: Node = switch (tag) {
                .plus => .init(.add, op),
                .minus => .init(.sub, op),
                .hash => .init(.concat, op),
                else => comptime unreachable,
            };

            index = try parser.addNode(node);
        },
        else => break,
    };

    return index;
}

/// MulExpr <- PrimaryExpr (('*' / '/' / '%') PrimaryExpr)*
fn parseMulExpr(parser: *Parser) !Index {
    var index = try parser.parsePrimaryExpr();

    while (true) switch (parser.token_tags[parser.tok_i]) {
        inline .asterisk, .forward_slash, .percent => |tag| {
            parser.tok_i += 1;
            const op = BinaryOperator{
                .lhs = index,
                .rhs = try parser.parsePrimaryExpr(),
            };

            const node: Node = switch (tag) {
                .asterisk => .init(.mul, op),
                .forward_slash => .init(.div, op),
                .percent => .init(.mod, op),
                else => comptime unreachable,
            };

            index = try parser.addNode(node);
        },
        else => break,
    };

    return index;
}

/// PrimaryExpr <- Number / Range / StsringLiteral / Builtin / '(' Expression ')'
fn parsePrimaryExpr(parser: *Parser) !Index {
    return switch (parser.token_tags[parser.tok_i]) {
        .minus, .plus, .number => parser.parseNumber(),
        .cell_name => parser.parseRange(),
        .lparen => {
            try parser.expectToken(.lparen);
            const ret = parser.parseExpression();
            try parser.expectToken(.rparen);
            return ret;
        },
        .builtin => parser.parseFunction(),
        inline .single_string_literal_start,
        .double_string_literal_start,
        => |tag| parser.parseStringLiteral(tag),
        else => error.UnexpectedToken,
    };
}

/// Range <- CellReference (':' CellReference)?
fn parseRange(parser: *Parser) !Index {
    const lhs = try parser.parseCellName();

    if (parser.eatToken(.colon) == null) return lhs;

    const rhs = try parser.parseCellName();

    return parser.addNode(.init(.range, .{ .lhs = lhs, .rhs = rhs }));
}

/// Builtin <- builtin '(' ArgList? ')'
fn parseFunction(parser: *Parser) !Index {
    const start = try parser.expectTokenGet(.builtin);
    const end = try parser.expectTokenGet(.lparen);

    const identifier = parser.src[start..end];
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
    try parser.expectToken(.rparen);

    return parser.addNode(.init(.builtin, .{
        .tag = builtin,
        .first_arg = args_start,
    }));
}

/// ArgList <- Expression (',' Expression)*
fn parseArgList(parser: *Parser) !Index {
    const start = try parser.parseExpression();

    while (parser.eatToken(.comma)) |_| {
        _ = try parser.parseExpression();
    }

    return start;
}

/// Number <- ('+' / '-')? ('0'-'9')+
fn parseNumber(parser: *Parser) !Index {
    const is_positive = parser.eatToken(.minus) == null;
    if (is_positive) _ = parser.eatToken(.plus);

    const start = try parser.expectTokenGet(.number);
    const raw = parser.src[start..parser.token_starts[parser.tok_i]];
    const text = std.mem.trimRight(u8, raw, " \t\r\n");

    // Correctness of the number is guaranteed because the tokenizer wouldn't have generated a
    // number token on invalid format.
    const num = std.fmt.parseFloat(f64, text) catch unreachable;

    return parser.addNode(.init(.number, if (is_positive) num else -num));
}

/// CellReference <- ('a'-'z' / 'A'-'Z')+ ('0'-'9')+
fn parseCellName(parser: *Parser) !Index {
    const start = try parser.expectTokenGet(.cell_name);
    const raw = parser.src[start..parser.token_starts[parser.tok_i]];
    const text = std.mem.trimRight(u8, raw, " \t\r\n");

    const pos = Position.fromAddress(text) catch return error.InvalidCellAddress;

    return parser.addNode(.init(.pos, pos));
}

fn addNode(noalias parser: *Parser, node: Node) Allocator.Error!Index {
    const ret: Index = .from(@intCast(parser.nodes.len));
    try parser.nodes.append(parser.allocator, node);
    return ret;
}

pub fn expectTokenGet(parser: *Parser, expected_tag: Token.Tag) !u32 {
    if (parser.token_tags[parser.tok_i] != expected_tag) {
        @branchHint(.unlikely);
        return error.UnexpectedToken;
    }
    const ret = parser.token_starts[parser.tok_i];
    parser.tok_i += 1;
    return ret;
}

pub fn expectToken(parser: *Parser, expected_tag: Token.Tag) !void {
    if (parser.token_tags[parser.tok_i] != expected_tag) {
        @branchHint(.unlikely);
        return error.UnexpectedToken;
    }
    parser.tok_i += 1;
}

fn eatToken(parser: *Parser, expected_tag: Token.Tag) ?Token {
    if (parser.token_tags[parser.tok_i] == expected_tag) {
        const ret: Token = .{
            .tag = parser.token_tags[parser.tok_i],
            .start = parser.token_starts[parser.tok_i],
        };
        parser.tok_i += 1;
        return ret;
    }

    return null;
}

test "parser" {
    const t = std.testing;
    const testParser = struct {
        fn func(bytes: [:0]const u8, node_tags: []const Node.Tag) !void {
            var tokens = try Tokenizer.collectTokens(t.allocator, bytes, 0);
            defer tokens.deinit(t.allocator);

            var parser = Parser.init(
                t.allocator,
                bytes,
                tokens.items(.tag),
                tokens.items(.start),
                .{},
            );
            defer parser.nodes.deinit(t.allocator);
            try parser.parse();
            for (node_tags, parser.nodes.items(.tag)) |expected, actual| {
                try t.expectEqual(expected, actual);
            }
        }
    }.func;
    const testParseError = struct {
        fn func(bytes: [:0]const u8, err: ?anyerror) !void {
            var tokens = try Tokenizer.collectTokens(t.allocator, bytes, @intCast(bytes.len / 2));
            defer tokens.deinit(t.allocator);

            var parser = Parser.init(
                t.allocator,
                bytes,
                tokens.items(.tag),
                tokens.items(.start),
                .{},
            );
            defer parser.nodes.deinit(t.allocator);
            if (err) |e| {
                try t.expectError(e, parser.parse());
            } else {
                try parser.parse();
            }
        }
    }.func;

    try testParser("let a0 = 5", &.{ .pos, .number, .assignment });
    try testParser("let a0 = 5.0 + +5.0", &.{ .pos, .number, .number, .add, .assignment });
    try testParser("let a0 = 5.0 + -5.0", &.{ .pos, .number, .number, .add, .assignment });
    try testParser("let a0 = 5.0 - +5.0", &.{ .pos, .number, .number, .sub, .assignment });
    try testParser("let a0 = 5.0 - -5.0", &.{ .pos, .number, .number, .sub, .assignment });
    try testParser("let b0 = 0.0 + 1.123", &.{ .pos, .number, .number, .add, .assignment });
    try testParser("let xxx50000 = 000000 - 11111122222223333333444444", &.{ .pos, .number, .number, .sub, .assignment });
    try testParser("let c30 = 123_123.231 * 2", &.{ .pos, .number, .number, .mul, .assignment });
    try testParser("let crxp65535 = 123_123.321 / 123_123.321", &.{ .pos, .number, .number, .div, .assignment });

    try testParser("let a0 = 3 - 1 * 2", &.{ .pos, .number, .number, .number, .mul, .sub, .assignment });
    try testParser("let a0 = 1 / 2 + 3", &.{ .pos, .number, .number, .div, .number, .add, .assignment });
    try testParser("let a0 = 1 - (3 + 5)", &.{ .pos, .number, .number, .number, .add, .sub, .assignment });
    try testParser("let a0 = (1 + 2) - (2 + 1)", &.{ .pos, .number, .number, .add, .number, .number, .add, .sub, .assignment });
    try testParser("let a0 = 2 / (1 - (1 + 3))", &.{ .pos, .number, .number, .number, .number, .add, .sub, .div, .assignment });

    try testParser("let a0 = 'this is epic' # ' and nice'", &.{ .pos, .string_literal, .string_literal, .concat, .assignment });

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
        fn func(bytes: [:0]const u8, nodes: []const Node) !void {
            var tokens = try Tokenizer.collectTokens(t.allocator, bytes, @intCast(bytes.len / 2));
            defer tokens.deinit(t.allocator);

            var parser: Parser = .init(
                t.allocator,
                bytes,
                tokens.items(.tag),
                tokens.items(.start),
                .{},
            );
            defer parser.nodes.deinit(t.allocator);

            try parser.parse();
            const slice = parser.nodes.slice();
            for (nodes, slice.items(.tag), slice.items(.data)) |expected, tag, data| {
                const actual: Node = .{
                    .tag = tag,
                    .data = data,
                };
                t.expectEqual(expected.get(), actual.get()) catch |err| {
                    std.debug.print("Expected {}, got {}\n", .{ expected.get(), actual.get() });
                    return err;
                };
            }
        }
    }.func;

    try testNodes(
        "let b30 = 5 * (3 - 2) / (2 + 1)",
        &.{
            .init(.pos, .{ .x = 1, .y = 30 }),
            .init(.number, 5.0),
            .init(.number, 3.0),
            .init(.number, 2.0),
            .init(.sub, .{ .lhs = .from(2), .rhs = .from(3) }),
            .init(.mul, .{ .lhs = .from(1), .rhs = .from(4) }),
            .init(.number, 2.0),
            .init(.number, 1.0),
            .init(.add, .{ .lhs = .from(6), .rhs = .from(7) }),
            .init(.div, .{ .lhs = .from(5), .rhs = .from(8) }),
            .init(.assignment, .{ .lhs = .from(0), .rhs = .from(9) }),
        },
    );
    try testNodes(
        "let crxp65535 = 'this is epic' # 'nice'",
        &.{
            .init(.pos, .{ .x = 65535, .y = 65535 }),
            .init(.string_literal, .{
                .start = "let crxp65535 = '".len,
                .end = "let crxp65535 = 'this is epic".len,
            }),
            .init(.string_literal, .{
                .start = "let crxp65535 = 'this is epic' # '".len,
                .end = "let crxp65535 = 'this is epic' # 'nice".len,
            }),
            .init(.concat, .{ .lhs = .from(1), .rhs = .from(2) }),
            .init(.assignment, .{ .lhs = .from(0), .rhs = .from(3) }),
        },
    );
}
