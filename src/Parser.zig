const std = @import("std");
const Position = @import("Sheet.zig").Position;
const MultiArrayList = @import("multi_array_list.zig").MultiArrayList;
const HeaderList = @import("header_list.zig").HeaderList;
const Tokenizer = @import("Tokenizer.zig");

const Allocator = std.mem.Allocator;
const NodeList = MultiArrayList(Node);
const assert = std.debug.assert;

const Parser = @This();

pub const String = struct {
    start: u32,
    len: u32,
};

pub const BinaryOperator = struct {
    lhs: u32,
    rhs: u32,
};

pub const Builtin = struct {
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

const builtins = std.ComptimeStringMap(Builtin.Tag, .{
    .{ "sum", .sum },
    .{ "prod", .prod },
    .{ "avg", .avg },
    .{ "max", .max },
    .{ "min", .min },
});

pub const ArgList = packed struct(u64) {
    start: u32,
    end: u32,

    pub fn count(args: ArgList) u32 {
        return args.end - args.start;
    }
};

pub const ParseError = error{
    UnexpectedToken,
    InvalidCellAddress,
} || Allocator.Error;

pub const Node = union(enum) {
    number: f64,
    column: u16,
    cell: Position,
    assignment: BinaryOperator,
    label: BinaryOperator,
    add: BinaryOperator,
    sub: BinaryOperator,
    mul: BinaryOperator,
    div: BinaryOperator,
    mod: BinaryOperator,
    builtin: Builtin,
    arg_list: ArgList,
    range: BinaryOperator,
    string_literal: String,
};

current_token: Tokenizer.Token,

tokenizer: Tokenizer,
nodes: NodeList,

strings: ?*HeaderList(u8, u32) = null,

allocator: Allocator,

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

/// Statement <- ('let' Assignment) / ('label' Label)
fn parseStatement(parser: *Parser) ParseError!u32 {
    const token = parser.eatTokenMulti(.{
        .keyword_let,
        .keyword_label,
    }) orelse return error.UnexpectedToken;
    return switch (token.tag) {
        .keyword_let => parser.parseAssignment(),
        .keyword_label => parser.parseLabel(),
        else => unreachable,
    };
}

/// Label <- CellName '=' StringExpression
fn parseLabel(parser: *Parser) ParseError!u32 {
    const lhs = try parser.parseCellName();
    _ = try parser.expectToken(.equals_sign);
    const rhs = try parser.parseStringExpression();

    return parser.addNode(.{
        .label = .{
            .lhs = lhs,
            .rhs = rhs,
        },
    });
}

/// StringExpression <- StringLiteral
fn parseStringExpression(parser: *Parser) ParseError!u32 {
    return parser.parseStringLiteral();
}

fn parseStringLiteral(parser: *Parser) ParseError!u32 {
    const token = parser.eatTokenMulti(.{
        .double_string_literal,
        .single_string_literal,
    }) orelse return error.UnexpectedToken;

    // TODO: Handle escapes of quotes
    const text = token.text(parser.source());
    const str = try parser.addString(text);

    errdefer for (0..text.len) |_| {
        _ = parser.strings.?.pop();
    };

    const ret = try parser.addNode(.{
        .string_literal = str,
    });
    return ret;
}

fn addString(parser: *Parser, bytes: []const u8) ParseError!String {
    const len = @intCast(u32, bytes.len);
    if (parser.strings) |strings| {
        const start = strings.len;
        parser.strings = try strings.appendSlice(parser.allocator, bytes);
        return .{
            .start = start,
            .len = len,
        };
    } else {
        parser.strings = try HeaderList(u8, u32).create(parser.allocator, len);
        return .{
            .start = 0,
            .len = len,
        };
    }
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
