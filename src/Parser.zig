const std = @import("std");
const Position = @import("Position.zig").Position;
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Parser = @This();

token_tags: []const Token.Tag,
token_starts: []const u32,
tok_i: u32,

/// Total byte length of all parsed string literals.
strings_len: usize,

src: []const u8,

nodes: std.MultiArrayList(Node),

// TODO: When custom Lua functions are implemented, they could have volatile behaviour.
//       It should be possible to explicitly mark a function as volatile. It should also be
//       allowed for the volatility of a function to depend on it's arguments, e.g. a function
//       that is passed a dynamic range only needs to be volatile if there is cell accesses through
//       that range.
//
/// A volatile expression is always re-evaluated whenever anything in the sheet changes.
/// Any expression that accesses cells dynamically is volatile.
is_volatile: bool = false,

allocator: Allocator,

diagnostics: ?*Diagnostics = null,

pub const Result = struct { Index, Type };

pub const Type = packed struct {
    none: bool = false,
    num: bool = false,
    str: bool = false,
    cell_ref: bool = false,
    range_ref: bool = false,

    const any: Type = .{
        .none = true,
        .num = true,
        .str = true,
        .cell_ref = true,
        .range_ref = true,
    };

    const number: Type = .{ .num = true };
    const string: Type = .{ .str = true };
    const cell: Type = .{ .cell_ref = true };
    const range: Type = .{ .range_ref = true };

    fn @"union"(a: Type, b: Type) Type {
        var ret: Type = .{};
        inline for (@typeInfo(Type).@"struct".fields) |f| {
            @field(ret, f.name) = @field(a, f.name) or @field(b, f.name);
        }
        return ret;
    }
};

pub const ExpressionContext = enum { value, reference };

pub const Diagnostics = struct {
    payload: Payload = .none,
    actual: Token.Tag = .eof,
    prev: Token.Tag = .eof,

    const Payload = union(enum) {
        none,
        expected_token: Token.Tag,
        expected_string: []const u8,
        invalid_builtin: []const u8,
        invalid_cell_address: []const u8,
    };

    pub fn format(info: *const Diagnostics, writer: *std.io.Writer) !void {
        switch (info.payload) {
            .none => {},
            .expected_token => |token| {
                if (info.prev != .eof) {
                    try writer.print("expected {f} after {f}, found {f}", .{
                        token, info.prev, info.actual,
                    });
                } else {
                    try writer.print("expected {f}, found {f}", .{ token, info.actual });
                }
            },
            .expected_string => |str| {
                if (info.prev != .eof) {
                    try writer.print("expected {s} after {f}, found {f}", .{
                        str, info.prev, info.actual,
                    });
                } else {
                    try writer.print("expected {s}, found {f}", .{ str, info.actual });
                }
            },
            .invalid_builtin => |str| {
                try writer.print("invalid builtin '{s}'", .{str});
            },
            .invalid_cell_address => |str| {
                try writer.print("invalid cell address '{s}'", .{str});
            },
        }
    }
};

const Node = @import("ast.zig").Node;
const Index = @import("ast.zig").Index;
const NegativeOffset = @import("ast.zig").NegativeOffset;

pub const BinaryOperator = extern struct {
    lhs: NegativeOffset,
    rhs: NegativeOffset,

    pub fn args(b: BinaryOperator, from: Index) [2]Index {
        return .{ from.sub(b.lhs), from.sub(b.rhs) };
    }
};

pub const Builtin = extern struct {
    tag: Tag,
    first_arg: NegativeOffset,

    const Tag = enum(u8) {
        sum,
        prod,
        avg,
        max,
        min,
        upper,
        lower,
        sqrt,
        round,
        floor,
        ceil,
        len,
        count,
        count_all,
        log,
        pi,
        e,
        width,
        height,

        pub fn format(tag: Tag, w: *std.io.Writer) !void {
            switch (tag) {
                .count_all => try w.writeAll("countAll"),
                else => try w.writeAll(@tagName(tag)),
            }
        }
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
    .{ "sqrt", .sqrt },
    .{ "round", .round },
    .{ "floor", .floor },
    .{ "ceil", .ceil },
    .{ "len", .len },
    .{ "count", .count },
    .{ "countAll", .count_all },
    .{ "log", .log },
    .{ "pi", .pi },
    .{ "e", .e },
    .{ "width", .width },
    .{ "height", .height },
});

pub const ParseError = error{
    UnexpectedToken,
    InvalidCellAddress,
    InvalidBuiltin,
} || Allocator.Error;

const InitOptions = struct {
    nodes: std.MultiArrayList(Node) = .{},
    diagnostics: ?*Diagnostics = null,
};

pub fn init(
    allocator: Allocator,
    src: []const u8,
    token_tags: []const Token.Tag,
    token_starts: []const u32,
    options: InitOptions,
) Parser {
    return .{
        .nodes = options.nodes,
        .allocator = allocator,
        .token_tags = token_tags,
        .token_starts = token_starts,
        .strings_len = 0,
        .tok_i = 0,
        .src = src,
        .diagnostics = options.diagnostics,
    };
}

pub fn root(parser: *const Parser) Index {
    return .from(@intCast(parser.nodes.len - 1));
}

/// <- Statement / Expression
pub fn parse(parser: *Parser) ParseError!void {
    _ = try parser.parseStatement();
    try parser.expectToken(.eof);
}

/// Statement <- 'let' Assignment
pub fn parseStatement(parser: *Parser) ParseError!Index {
    switch (parser.token_tags[parser.tok_i]) {
        .keyword_let => {
            parser.tok_i += 1;
            return try parser.parseAssignment();
        },
        else => {
            const index, _ = try parser.parseExpression(.value);
            return index;
        },
    }
}

/// Assignment <- CellReference '=' Expression
pub fn parseAssignment(parser: *Parser) ParseError!Index {
    switch (parser.token_tags[parser.tok_i]) {
        .rel_rel, .rel_abs, .abs_rel, .abs_abs => {},
        else => return error.UnexpectedToken,
    }
    const start = parser.token_starts[parser.tok_i];
    parser.tok_i += 1;
    const raw = parser.src[start..parser.token_starts[parser.tok_i]];
    const text = std.mem.trimRight(u8, raw, " \t\r\n");

    const pos = Position.fromAddress(text) catch return parser.setError(
        error.InvalidCellAddress,
        .{ .invalid_cell_address = text },
    );

    try parser.expectToken(.equals_sign);
    _ = try parser.parseExpression(.value);

    return parser.addNode(.init(.assignment, pos));
}

/// Expression <- OrExpr
pub fn parseExpression(parser: *Parser, ctx: ExpressionContext) ParseError!Result {
    return try parser.parseOrExpr(ctx);
}

/// OrExpr <- AndExpr ('or' AndExpr)*
fn parseOrExpr(parser: *Parser, ctx: ExpressionContext) !Result {
    var index, var result_type = try parser.parseAndExpr(ctx);

    while (parser.eatToken(.keyword_or)) |_| {
        const rhs, _ = try parser.parseAndExpr(ctx);
        const len: u32 = @intCast(parser.nodes.len);
        const op = BinaryOperator{
            .lhs = @enumFromInt(len - index.n),
            .rhs = @enumFromInt(len - rhs.n),
        };

        index = try parser.addNode(.init(.logical_or, op));
        result_type = .number;
    }

    return .{ index, result_type };
}

/// AndExpr <- EqualityExpr ('and' EqualityExpr)*
fn parseAndExpr(parser: *Parser, ctx: ExpressionContext) !Result {
    var index, var result_type = try parser.parseEqualityExpr(ctx);

    while (parser.eatToken(.keyword_and)) |_| {
        const rhs, _ = try parser.parseEqualityExpr(ctx);
        const len: u32 = @intCast(parser.nodes.len);
        const op = BinaryOperator{
            .lhs = @enumFromInt(len - index.n),
            .rhs = @enumFromInt(len - rhs.n),
        };

        index = try parser.addNode(.init(.logical_and, op));
        result_type = .number;
    }

    return .{ index, result_type };
}

/// EqualityExpr <- AddExpr (('==' / '!=' / '<' / '>') AddExpr)*
fn parseEqualityExpr(parser: *Parser, ctx: ExpressionContext) !Result {
    var index, var result_type = try parser.parseAddExpr(ctx);

    while (true) switch (parser.token_tags[parser.tok_i]) {
        inline .double_equals,
        .exclamation_equals,
        .greater_than,
        .less_than,
        .greater_equals,
        .less_equals,
        => |tag| {
            parser.tok_i += 1;
            const rhs, _ = try parser.parseAddExpr(ctx);
            const len: u32 = @intCast(parser.nodes.len);
            const op = BinaryOperator{
                .lhs = @enumFromInt(len - index.n),
                .rhs = @enumFromInt(len - rhs.n),
            };

            const node_tag: Node.Tag = switch (tag) {
                .double_equals => .equals,
                .exclamation_equals => .not_equals,
                .greater_than => .greater_than,
                .less_than => .less_than,
                .greater_equals => .greater_equals,
                .less_equals => .less_equals,
                else => comptime unreachable,
            };

            index = try parser.addNode(.init(node_tag, op));
            result_type = .number;
        },
        else => break,
    };

    return .{ index, result_type };
}

/// AddExpr <- MulExpr (('+' / '-' / '#') MulExpr)*
fn parseAddExpr(parser: *Parser, ctx: ExpressionContext) !Result {
    var index, var result_type = try parser.parseMulExpr(ctx);

    while (true) switch (parser.token_tags[parser.tok_i]) {
        inline .plus, .minus, .hash => |tag| {
            parser.tok_i += 1;
            const rhs, _ = try parser.parseMulExpr(ctx);
            const len: u32 = @intCast(parser.nodes.len);
            const op = BinaryOperator{
                .lhs = @enumFromInt(len - index.n),
                .rhs = @enumFromInt(len - rhs.n),
            };

            const node: Node = switch (tag) {
                .plus => .init(.add, op),
                .minus => .init(.sub, op),
                .hash => .init(.concat, op),
                else => comptime unreachable,
            };

            index = try parser.addNode(node);
            result_type = switch (tag) {
                .plus, .minus => .number,
                .hash => .string,
                else => comptime unreachable,
            };
        },
        else => break,
    };

    return .{ index, result_type };
}

/// MulExpr <- PowExpr (('*' / '/' / '%') PowExpr)*
fn parseMulExpr(parser: *Parser, ctx: ExpressionContext) !Result {
    var index, var result_type = try parser.parsePowExpr(ctx);

    while (true) switch (parser.token_tags[parser.tok_i]) {
        inline .asterisk, .forward_slash, .percent => |tag| {
            parser.tok_i += 1;
            const rhs, _ = try parser.parsePowExpr(ctx);
            const len: u32 = @intCast(parser.nodes.len);
            const op = BinaryOperator{
                .lhs = @enumFromInt(len - index.n),
                .rhs = @enumFromInt(len - rhs.n),
            };

            const node: Node = switch (tag) {
                .asterisk => .init(.mul, op),
                .forward_slash => .init(.div, op),
                .percent => .init(.mod, op),
                else => comptime unreachable,
            };

            index = try parser.addNode(node);
            result_type = .number;
        },
        else => break,
    };

    return .{ index, result_type };
}

/// PowExpr <- UnaryExpr ('^' UnaryExpr)*
fn parsePowExpr(parser: *Parser, ctx: ExpressionContext) !Result {
    var index, var result_type = try parser.parseUnaryExpr(ctx);

    while (parser.eatToken(.caret)) |_| {
        const rhs, _ = try parser.parseUnaryExpr(ctx);
        const len: u32 = @intCast(parser.nodes.len);
        const op: BinaryOperator = .{
            .lhs = @enumFromInt(len - index.n),
            .rhs = @enumFromInt(len - rhs.n),
        };

        const node: Node = .init(.pow, op);
        index = try parser.addNode(node);
        result_type = .number;
    }

    return .{ index, result_type };
}

/// UnaryExpr <- ('+' / '-' / '!')* RangeExpr
fn parseUnaryExpr(parser: *Parser, ctx: ExpressionContext) !Result {
    return switch (parser.token_tags[parser.tok_i]) {
        inline .minus, .plus, .exclamation => |t| {
            const tag: Node.Tag = switch (t) {
                .minus => .minus,
                .plus => .plus,
                .exclamation => .not,
                else => comptime unreachable,
            };
            parser.tok_i += 1;
            _ = try parser.parseUnaryExpr(ctx);
            const index = try parser.addNode(.init(tag, {}));
            return .{ index, .number };
        },
        else => try parser.parseRangeExpr(ctx),
    };
}

/// RangeExpr <- ReferenceExpr (':' ReferenceExpr)?
fn parseRangeExpr(parser: *Parser, ctx: ExpressionContext) !Result {
    const lhs, const lhs_type = try parser.parseReferenceExpr(ctx);

    _ = parser.eatToken(.colon) orelse return .{ lhs, lhs_type };
    const rhs, _ = try parser.parseReferenceExpr(ctx);

    const len: u32 = @intCast(parser.nodes.len);
    var node: Node = .init(.range, .{
        .lhs = @enumFromInt(len - lhs.n),
        .rhs = @enumFromInt(len - rhs.n),
    });

    assert(node.data.range.rhs.int() == 1);

    // If either of the operands are anything other than a cell literal or a reference to a cell
    // literal, then this expression must be marked volatile.
    if (parser.isDynamicReference(lhs) or parser.isDynamicReference(rhs)) {
        // TODO: remove dynamic range tag
        node.tag = .dynamic_range;
    }

    const index = try parser.addNode(node);
    return .{ index, .range };
}

fn parseReferenceExpr(parser: *Parser, ctx: ExpressionContext) !Result {
    return switch (parser.token_tags[parser.tok_i]) {
        .ampersand => {
            parser.tok_i += 1;
            _ = try parser.parsePrimaryExpr(ctx);
            const index = try parser.addNode(.init(.reference, {}));
            return .{ index, .cell };
        },
        .asterisk => {
            parser.tok_i += 1;
            const operand, _ = try parser.parseReferenceExpr(ctx);

            // Accessing the value of a cell dynamically requires volatile
            if (parser.isDynamicReference(operand))
                parser.is_volatile = true;

            const index = try parser.addNode(.init(.dereference, {}));
            return .{ index, .any };
        },
        else => try parser.parsePrimaryExpr(ctx),
    };
}

/// Returns true if the given node is a cell literal or a reference to a cell literal.
fn isDynamicReference(parser: *const Parser, index: Index) bool {
    return @import("ast.zig").isDynamicReference(parser.nodes.slice(), index);
}

/// Returns true if the given node is a cell literal or a reference to a cell literal.
fn isDynamicRange(parser: *const Parser, index: Index) bool {
    const tags = parser.nodes.items(.tag);
    return switch (tags[index.n]) {
        .dynamic_range => true,
        else => false,
    };
}

/// Marks the expression as volatile if the given node could be a cell reference and is not a cell
/// literal or a reference to a cell literal, or if the expression could be a cell range.
fn volatileAccess(parser: *Parser, index: Index, result_type: Type) void {
    parser.is_volatile =
        parser.is_volatile or
        result_type.range_ref and parser.isDynamicRange(index) or
        result_type.cell_ref and parser.isDynamicReference(index);
}

/// Marks the expression as volatile if the given node could be a cell reference and is not a cell
/// literal or a reference to a cell literal.
fn volatileAccessSingle(parser: *Parser, index: Index, result_type: Type) void {
    parser.is_volatile =
        parser.is_volatile or
        result_type.cell_ref and parser.isDynamicReference(index);
}

/// PrimaryExpr <- Number / Range / StringLiteral / Builtin / '(' Expression ')'
fn parsePrimaryExpr(parser: *Parser, ctx: ExpressionContext) !Result {
    return switch (parser.token_tags[parser.tok_i]) {
        .number => try parser.parseNumber(),
        .rel_rel, .rel_abs, .abs_rel, .abs_abs => try parser.parseCellName(ctx),
        .lparen => {
            try parser.expectToken(.lparen);
            const ret = try parser.parseExpression(ctx);
            try parser.expectToken(.rparen);
            return ret;
        },
        .builtin => try parser.parseBuiltin(),
        inline .single_string_literal_start,
        .double_string_literal_start,
        => |tag| try parser.parseStringLiteral(tag),
        else => parser.setError(error.UnexpectedToken, .{ .expected_string = "expression" }),
    };
}

/// Builtin <- builtin ('(' ArgList? ')')?
fn parseBuiltin(parser: *Parser) !Result {
    const start = try parser.expectTokenGet(.builtin);
    const end = parser.token_starts[parser.tok_i];

    const identifier = std.mem.trimRight(u8, parser.src[start + 1 .. end], &std.ascii.whitespace);
    const builtin = builtins.get(identifier) orelse return parser.setError(
        error.InvalidBuiltin,
        .{ .invalid_builtin = identifier },
    );

    const args_start, const result_type: Type = sw: switch (builtin) {
        // These builtins aren't even functions!
        .pi, .e => {
            const index = try parser.addNode(
                .init(.builtin, .{
                    .tag = builtin,
                    .first_arg = @enumFromInt(0),
                }),
            );
            return .{ index, .number };
        },
        // These builtins take only one argument
        .width,
        .height,
        => {
            try parser.expectToken(.lparen);
            const expr, _ = try parser.parseExpression(.value);
            break :sw .{ expr, .number };
        },
        .sqrt,
        .round,
        .floor,
        .ceil,
        .len,
        => {
            try parser.expectToken(.lparen);
            const expr, const result_type = try parser.parseExpression(.reference);
            parser.volatileAccessSingle(expr, result_type);

            break :sw .{ expr, .number };
        },
        .upper,
        .lower,
        => {
            try parser.expectToken(.lparen);
            const expr, const result_type = try parser.parseExpression(.reference);
            parser.volatileAccessSingle(expr, result_type);

            break :sw .{ expr, .string };
        },
        // These builtins require at least one argument
        .sum,
        .max,
        .prod,
        .avg,
        .min,
        .count,
        .count_all,
        => {
            try parser.expectToken(.lparen);
            const index = try parser.parseVarArgsAccess(.reference);
            break :sw .{ index, .number };
        },
        .log => {
            try parser.expectToken(.lparen);
            const index = try parser.parseArgsAccess(2, .reference);
            break :sw .{ index, .number };
        },
    };
    try parser.expectToken(.rparen);

    const len: u32 = @intCast(parser.nodes.len);
    const index = try parser.addNode(.init(.builtin, .{
        .tag = builtin,
        .first_arg = @enumFromInt(len - args_start.n),
    }));
    return .{ index, result_type };
}

/// ArgList <- Expression (',' Expression)*
fn parseVarArgsAccess(parser: *Parser, ctx: ExpressionContext) !Index {
    const start, var result_type = try parser.parseExpression(ctx);
    parser.volatileAccess(start, result_type);

    while (parser.eatToken(.comma)) |_| {
        const index, result_type = try parser.parseExpression(ctx);
        parser.volatileAccess(index, result_type);
    }

    return start;
}

/// Parses an argument list with exactly `n` arguments.
fn parseArgsAccess(parser: *Parser, n: usize, ctx: ExpressionContext) !Index {
    const start, var result_type = try parser.parseExpression(ctx);
    parser.volatileAccess(start, result_type);

    for (0..n - 1) |_| {
        try parser.expectToken(.comma);
        const index, result_type = try parser.parseExpression(ctx);
        parser.volatileAccess(index, result_type);
    }

    return start;
}

/// Number <- ('+' / '-')? ('0'-'9')+
fn parseNumber(parser: *Parser) !Result {
    const is_positive = parser.eatToken(.minus) == null;
    if (is_positive) _ = parser.eatToken(.plus);

    const start = try parser.expectTokenGet(.number);
    const raw = parser.src[start..parser.token_starts[parser.tok_i]];
    const text = std.mem.trimRight(u8, raw, " \t\r\n");

    // Correctness of the number is guaranteed because the tokenizer wouldn't have generated a
    // number token on invalid format.
    const num = std.fmt.parseFloat(f64, text) catch {
        std.debug.print("'{s}' ({x})\n", .{ text, text });
        std.debug.print("Next token: {any}\n", .{parser.token_tags[parser.tok_i]});
        unreachable;
    };

    const index = try parser.addNode(.init(.number, if (is_positive) num else -num));
    return .{ index, .number };
}

fn parseStringLiteral(parser: *Parser, comptime expected_tag: Token.Tag) ParseError!Result {
    const start = try parser.expectTokenGet(expected_tag);
    const end_tag = switch (expected_tag) {
        .single_string_literal_start => .single_string_literal_end,
        .double_string_literal_start => .double_string_literal_end,
        else => comptime unreachable,
    };
    const end = try parser.expectTokenGet(end_tag);

    const len = end - start;
    parser.strings_len += len;

    // TODO: Handle escapes of quotes
    const index = try parser.addNode(
        .init(.string_literal, .{
            .start = start + 1,
            .end = end,
        }),
    );
    return .{ index, .string };
}

// TODO: Inidicate from caller if we're in a reference or value context and adjust result type
/// CellReference <- ('a'-'z' / 'A'-'Z')+ ('0'-'9')+
fn parseCellName(parser: *Parser, ctx: ExpressionContext) !Result {
    switch (parser.token_tags[parser.tok_i]) {
        .rel_rel, .rel_abs, .abs_rel, .abs_abs => {},
        else => return parser.setError(
            error.UnexpectedToken,
            .{ .expected_token = .rel_rel },
        ),
    }
    const start = parser.token_starts[parser.tok_i];
    parser.tok_i += 1;
    const raw = parser.src[start..parser.token_starts[parser.tok_i]];
    const text = std.mem.trimRight(u8, raw, " \t\r\n");

    const res = Position.fromAddress2(text) catch return parser.setError(
        error.InvalidCellAddress,
        .{ .invalid_cell_address = text },
    );

    switch (res.tag) {
        inline else => |t| {
            const tag: Node.Tag = switch (t) {
                .abs_abs => .abs_abs,
                .abs_rel => .abs_rel,
                .rel_abs => .rel_abs,
                .rel_rel => .rel_rel,
            };

            const index = try parser.addNode(.init(tag, res.pos));
            const result_type: Type = switch (ctx) {
                .value => .any,
                .reference => .cell,
            };
            return .{ index, result_type };
        },
    }
}

fn addNode(noalias parser: *Parser, node: Node) Allocator.Error!Index {
    const ret: Index = .from(@intCast(parser.nodes.len));
    try parser.nodes.append(parser.allocator, node);
    return ret;
}

pub fn expectTokenGet(parser: *Parser, expected_tag: Token.Tag) !u32 {
    if (parser.token_tags[parser.tok_i] != expected_tag) {
        @branchHint(.unlikely);
        return parser.setError(error.UnexpectedToken, .{
            .expected_token = expected_tag,
        });
    }
    const ret = parser.token_starts[parser.tok_i];
    parser.tok_i += 1;
    return ret;
}

pub fn expectToken(parser: *Parser, expected_tag: Token.Tag) !void {
    if (parser.token_tags[parser.tok_i] != expected_tag) {
        @branchHint(.unlikely);
        return parser.setError(error.UnexpectedToken, .{
            .expected_token = expected_tag,
        });
    }
    parser.tok_i += 1;
}

fn setError(parser: *Parser, err: ParseError, info: Diagnostics.Payload) ParseError {
    if (parser.diagnostics) |p| p.* = .{
        .payload = info,
        .actual = parser.token_tags[parser.tok_i],
        .prev = if (parser.tok_i > 0) parser.token_tags[parser.tok_i - 1] else .eof,
    };
    return err;
}

fn fmtTags(tags: []const Token.Tag) std.fmt.Formatter([]const Token.Tag, formatTags) {
    return .{ .data = tags };
}

fn formatTags(tags: []const Token.Tag, writer: *std.io.Writer) !void {
    if (tags.len == 1) {
        try writer.print("{f}", .{tags[0]});
        return;
    }

    // try writer.writeByte('[');
    for (tags[0 .. tags.len - 1]) |tag| {
        try writer.print("{f}, ", .{tag});
    }
    try writer.print("or {f}", .{tags[tags.len - 1]});
}

fn eatToken(parser: *Parser, expected_tag: Token.Tag) ?Token {
    if (parser.token_tags[parser.tok_i] == expected_tag) {
        @branchHint(.likely);
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
        fn func(bytes: []const u8, node_tags: []const Node.Tag) !void {
            var reader: std.io.Reader = .fixed(bytes);
            var tokens = try Tokenizer.collectTokens(t.allocator, &reader, 0);
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
        fn func(bytes: []const u8, err: ?anyerror) !void {
            var reader: std.io.Reader = .fixed(bytes);
            var tokens = try Tokenizer.collectTokens(
                t.allocator,
                &reader,
                @intCast(bytes.len / 2),
            );
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

    try testParser("let a0 = 5", &.{ .number, .assignment });
    try testParser("let a0 = 5.0 + +5.0", &.{ .number, .number, .plus, .add, .assignment });
    try testParser("let a0 = 5.0 + -5.0", &.{ .number, .number, .minus, .add, .assignment });
    try testParser("let a0 = 5.0 - +5.0", &.{ .number, .number, .plus, .sub, .assignment });
    try testParser("let a0 = 5.0 - -5.0", &.{ .number, .number, .minus, .sub, .assignment });
    try testParser("let b0 = 0.0 + 1.123", &.{ .number, .number, .add, .assignment });
    try testParser("let xxx50000 = 000000 - 11111122222223333333444444", &.{ .number, .number, .sub, .assignment });
    try testParser("let c30 = 123_123.231 * 2", &.{ .number, .number, .mul, .assignment });
    try testParser("let crxp65535 = 123_123.321 / 123_123.321", &.{ .number, .number, .div, .assignment });

    try testParser("let a0 = 3 - 1 * 2", &.{ .number, .number, .number, .mul, .sub, .assignment });
    try testParser("let a0 = 1 / 2 + 3", &.{ .number, .number, .div, .number, .add, .assignment });
    try testParser("let a0 = 1 - (3 + 5)", &.{ .number, .number, .number, .add, .sub, .assignment });
    try testParser("let a0 = (1 + 2) - (2 + 1)", &.{ .number, .number, .add, .number, .number, .add, .sub, .assignment });
    try testParser("let a0 = 2 / (1 - (1 + 3))", &.{ .number, .number, .number, .number, .add, .sub, .div, .assignment });

    try testParser("let a0 = 'this is epic' # ' and nice'", &.{ .string_literal, .string_literal, .concat, .assignment });

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
    try testParseError("let a0 = 5 - ", error.UnexpectedToken);

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
            var reader: std.io.Reader = .fixed(bytes);
            var tokens = try Tokenizer.collectTokens(
                t.allocator,
                &reader,
                @intCast(bytes.len / 2),
            );
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
                    std.debug.print("bytes: {s}, expected {}, got {}\n", .{
                        bytes,
                        expected.get(),
                        actual.get(),
                    });
                    return err;
                };
            }
        }
    }.func;

    try testNodes(
        "let b30 = 5 * (3 - 2) / (2 + 1)",
        &.{
            .init(.number, 5.0),
            .init(.number, 3.0),
            .init(.number, 2.0),
            .init(.sub, .{ .lhs = .from(2), .rhs = .from(1) }),
            .init(.mul, .{ .lhs = .from(4), .rhs = .from(1) }),
            .init(.number, 2.0),
            .init(.number, 1.0),
            .init(.add, .{ .lhs = .from(2), .rhs = .from(1) }),
            .init(.div, .{ .lhs = .from(4), .rhs = .from(1) }),
            .init(.assignment, .fromValidAddress("b30")),
        },
    );
    try testNodes(
        "let crxp65535 = 'this is epic' # 'nice'",
        &.{
            .init(.string_literal, .{
                .start = "let crxp65535 = '".len,
                .end = "let crxp65535 = 'this is epic".len,
            }),
            .init(.string_literal, .{
                .start = "let crxp65535 = 'this is epic' # '".len,
                .end = "let crxp65535 = 'this is epic' # 'nice".len,
            }),
            .init(.concat, .{ .lhs = .from(2), .rhs = .from(1) }),
            .init(.assignment, .fromValidAddress("crxp65535")),
        },
    );

    try testNodes(
        "let a0 = 1 and 2",
        &.{
            .init(.number, 1.0),
            .init(.number, 2.0),
            .init(.logical_and, .{
                .lhs = .from(2),
                .rhs = .from(1),
            }),
            .init(.assignment, .fromValidAddress("a0")),
        },
    );
}

fn testVolatile(expr: []const u8, volatility: bool) !void {
    var r: std.io.Reader = .fixed(expr);
    var tokens = try Tokenizer.collectTokens(std.testing.allocator, &r, @intCast(expr.len));
    defer tokens.deinit(std.testing.allocator);
    var p: Parser = .init(std.testing.allocator, expr, tokens.items(.tag), tokens.items(.start), .{});
    defer p.nodes.deinit(std.testing.allocator);
    try p.parse();
    try std.testing.expectEqual(volatility, p.is_volatile);
}

test "Volatile expressions" {
    try testVolatile("10", false);
    try testVolatile("b0", false);
    try testVolatile("&b0", false);
    try testVolatile("b0:c0", false);
    try testVolatile("b0:*c0", false);
    try testVolatile("*b0:c0", false);
    try testVolatile("*b0:*c0", false);
    try testVolatile("**b0:c0", true);
    try testVolatile("**b0", true);

    // These builtins accept references and make accesses through them.
    try testVolatile("@sqrt(a0)", false);
    try testVolatile("@sqrt(*a0)", true);
    try testVolatile("@sum(a0)", false);
    try testVolatile("@sum(a0:d30, 1, 3 + 2 * 300 + @prod(a0:d3), zzz10)", false);
    try testVolatile("@sum(a0:d1)", false);
    try testVolatile("@sum(*a0:d1)", true);
    try testVolatile("@sum(a0:*d1)", true);
    try testVolatile("@sum(*a0:*d1)", true);

    // These builtins accept references but don't make any accesses through them, and as such never
    // need to be marked as volatile.
    try testVolatile("@width(*a0)", false);
    try testVolatile("@width(*a0:b0)", false);
    try testVolatile("@width(a0:*b0)", false);
    try testVolatile("@width(*a0:*b0)", false);

    try testVolatile("@height(*a0)", false);
    try testVolatile("@height(*a0:b0)", false);
    try testVolatile("@height(a0:*b0)", false);
    try testVolatile("@height(*a0:*b0)", false);
}
