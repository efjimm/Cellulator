const std = @import("std");
const Sheet = @import("Sheet.zig");
const Position = @import("Position.zig").Position;
const Tokenizer = @import("Tokenizer.zig");
const Token = Tokenizer.Token;

const Ast = @import("Ast.zig");
const Node = Ast.Node;
const Index = Node.Index;
const Builtin = Node.Builtin;

const MultiList = @import("multi_list.zig").MultiList;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Parser = @This();

/// The same allocator used for `ast`.
gpa: Allocator,
ast: *Ast,
token_tags: []const Token.Tag,
token_starts: []const u32,
src: []const u8,
tok_i: u32,

// TODO: When custom Lua functions are implemented, they could have volatile behaviour.
//       It should be possible to explicitly mark a function as volatile. It should also be
//       allowed for the volatility of a function to depend on it's arguments, e.g. a function
//       that is passed a dynamic range only needs to be volatile if there is cell accesses through
//       that range.
//
/// A volatile expression is always re-evaluated whenever anything in the sheet changes.
/// Any expression that accesses cells dynamically is volatile.
is_volatile: bool = false,

diagnostics: ?*Diagnostics = null,

pub const StringSlice = extern struct {
    offset: u64,
    len: u64,
};

pub const Result = struct {
    root: Node.Index,
    is_volatile: bool,
    destination: ?Position,

    pub const invalid: Result = .{
        .root = .invalid,
        .is_volatile = false,
        .destination = null,
    };
};

const Intermediate = struct { Index, Type };

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

pub const Options = struct {
    diagnostics: ?*Diagnostics = null,
};

pub fn init(
    gpa: std.mem.Allocator,
    source: []const u8,
    token_tags: []const Token.Tag,
    token_starts: []const u32,
    ast: *Ast,
    options: Options,
) ParseError!Parser {
    return .{
        .ast = ast,
        .gpa = gpa,
        .token_tags = token_tags,
        .token_starts = token_starts,
        .tok_i = 0,
        .src = source,
        .diagnostics = options.diagnostics,
    };
}

pub fn parseFromExpression(
    ast: *Ast,
    gpa: Allocator,
    source: []const u8,
    options: Options,
) ParseError!Result {
    var reader: std.io.Reader = .fixed(source);
    var tokens = Tokenizer.collectTokens(
        gpa,
        &reader,
        @intCast(source.len / 2),
    ) catch |err| switch (err) {
        error.ReadFailed => unreachable,
        error.OutOfMemory => |e| return e,
    };

    defer tokens.deinit(gpa);

    const start_state = ast.save();
    errdefer ast.restore(start_state);

    var parser: Parser = try .init(
        gpa,
        source,
        tokens.items(.tag),
        tokens.items(.start),
        ast,
        options,
    );

    return try parser.parseEof();
}

pub fn root(p: *const Parser) Index {
    const last = p.ast.lastIndex();
    assert(p.ast.tag(last.subi(1)) == .end);
    return last.subi(2);
}

/// Parse one statement, returning `null` on EOF.
pub fn nextStatement(p: *Parser) ParseError!?Result {
    if (p.tok_i >= p.token_tags.len or p.token_tags[p.tok_i] == .eof)
        return null;

    const start_state = p.ast.save();
    errdefer p.ast.restore(start_state);
    return try p.parse();
}

fn parseEof(p: *Parser) ParseError!Result {
    const ret = try p.parse();
    try p.expectToken(.eof);
    return ret;
}

/// <- (Statement / Expression) eof
fn parse(p: *Parser) ParseError!Result {
    p.is_volatile = false;
    const nodes_start = p.ast.nodes.len();
    const index = try p.parseStatement();
    _ = try p.addNode(.init(.end, @intFromEnum(index) - nodes_start + 1));

    const root_index = p.root();
    return .{
        .root = root_index,
        .is_volatile = p.is_volatile,
        .destination = if (p.ast.tag(root_index) == .assignment)
            p.ast.payload(root_index).assignment
        else
            null,
    };
}

/// Statement <- 'let' Assignment
fn parseStatement(p: *Parser) ParseError!Index {
    switch (p.token_tags[p.tok_i]) {
        .keyword_let => {
            p.tok_i += 1;
            return try p.parseAssignment();
        },
        else => {
            const index, _ = try p.parseExpression(.value);
            return index;
        },
    }
}

/// Assignment <- CellReference '=' Expression
fn parseAssignment(p: *Parser) ParseError!Index {
    switch (p.token_tags[p.tok_i]) {
        .rel_rel, .rel_abs, .abs_rel, .abs_abs => {},
        else => return error.UnexpectedToken,
    }
    const start = p.token_starts[p.tok_i];
    p.tok_i += 1;
    const raw = p.src[start..p.token_starts[p.tok_i]];
    const text = std.mem.trimRight(u8, raw, " \t\r\n");

    const pos = Position.fromAddress(text) catch return p.setError(
        error.InvalidCellAddress,
        .{ .invalid_cell_address = text },
    );

    try p.expectToken(.equals_sign);
    _ = try p.parseExpression(.value);

    return p.addNode(.init(.assignment, pos));
}

/// Expression <- OrExpr
fn parseExpression(p: *Parser, ctx: ExpressionContext) ParseError!Intermediate {
    return try p.parseOrExpr(ctx);
}

/// OrExpr <- AndExpr ('or' AndExpr)*
fn parseOrExpr(p: *Parser, ctx: ExpressionContext) !Intermediate {
    var index, var result_type = try p.parseAndExpr(ctx);

    while (p.eatToken(.keyword_or)) |_| {
        _ = try p.parseAndExpr(ctx);

        index = try p.addNode(.init(.logical_or, {}));
        result_type = .number;
    }

    return .{ index, result_type };
}

/// AndExpr <- EqualityExpr ('and' EqualityExpr)*
fn parseAndExpr(p: *Parser, ctx: ExpressionContext) !Intermediate {
    var index, var result_type = try p.parseEqualityExpr(ctx);

    while (p.eatToken(.keyword_and)) |_| {
        _ = try p.parseEqualityExpr(ctx);

        index = try p.addNode(.init(.logical_and, {}));
        result_type = .number;
    }

    return .{ index, result_type };
}

/// EqualityExpr <- AddExpr (('==' / '!=' / '<' / '>') AddExpr)*
fn parseEqualityExpr(p: *Parser, ctx: ExpressionContext) !Intermediate {
    var index, var result_type = try p.parseAddExpr(ctx);

    while (true) switch (p.token_tags[p.tok_i]) {
        inline .double_equals,
        .exclamation_equals,
        .greater_than,
        .less_than,
        .greater_equals,
        .less_equals,
        => |tag| {
            p.tok_i += 1;
            _ = try p.parseAddExpr(ctx);

            const node_tag: Node.Tag = switch (tag) {
                .double_equals => .equals,
                .exclamation_equals => .not_equals,
                .greater_than => .greater_than,
                .less_than => .less_than,
                .greater_equals => .greater_equals,
                .less_equals => .less_equals,
                else => comptime unreachable,
            };

            index = try p.addNode(.init(node_tag, {}));
            result_type = .number;
        },
        else => break,
    };

    return .{ index, result_type };
}

/// AddExpr <- MulExpr (('+' / '-' / '#') MulExpr)*
fn parseAddExpr(p: *Parser, ctx: ExpressionContext) !Intermediate {
    var index, var result_type = try p.parseMulExpr(ctx);

    while (true) switch (p.token_tags[p.tok_i]) {
        inline .plus, .minus, .hash => |tag| {
            p.tok_i += 1;
            _ = try p.parseMulExpr(ctx);

            const node_tag: Node.Tag = switch (tag) {
                .plus => .add,
                .minus => .sub,
                .hash => .concat,
                else => comptime unreachable,
            };

            index = try p.addNode(.init(node_tag, {}));
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
fn parseMulExpr(p: *Parser, ctx: ExpressionContext) !Intermediate {
    var index, var result_type = try p.parsePowExpr(ctx);

    while (true) switch (p.token_tags[p.tok_i]) {
        inline .asterisk, .forward_slash, .percent => |tag| {
            p.tok_i += 1;
            _ = try p.parsePowExpr(ctx);

            index = try p.addNode(.init(switch (tag) {
                .asterisk => .mul,
                .forward_slash => .div,
                .percent => .mod,
                else => comptime unreachable,
            }, {}));
            result_type = .number;
        },
        else => break,
    };

    return .{ index, result_type };
}

/// PowExpr <- UnaryExpr ('^' UnaryExpr)*
fn parsePowExpr(p: *Parser, ctx: ExpressionContext) !Intermediate {
    var index, var result_type = try p.parseUnaryExpr(ctx);

    while (p.eatToken(.caret)) |_| {
        _ = try p.parseUnaryExpr(ctx);
        index = try p.addNode(.init(.pow, {}));
        result_type = .number;
    }

    return .{ index, result_type };
}

/// UnaryExpr <- ('+' / '-' / '!')* RangeExpr
fn parseUnaryExpr(p: *Parser, ctx: ExpressionContext) !Intermediate {
    return switch (p.token_tags[p.tok_i]) {
        inline .minus, .plus, .exclamation => |t| {
            const tag: Node.Tag = switch (t) {
                .minus => .minus,
                .plus => .plus,
                .exclamation => .not,
                else => comptime unreachable,
            };
            p.tok_i += 1;
            _ = try p.parseUnaryExpr(ctx);
            const index = try p.addNode(.init(tag, {}));
            return .{ index, .number };
        },
        else => try p.parseRangeExpr(ctx),
    };
}

/// RangeExpr <- ReferenceExpr (':' ReferenceExpr)?
fn parseRangeExpr(p: *Parser, ctx: ExpressionContext) !Intermediate {
    const lhs, const lhs_type = try p.parseReferenceExpr(ctx);

    _ = p.eatToken(.colon) orelse return .{ lhs, lhs_type };
    const rhs, _ = try p.parseReferenceExpr(ctx);

    var node: Node = .init(.range, {});

    // If either of the operands are anything other than a cell literal or a reference to a cell
    // literal, then this expression must be marked volatile.
    if (p.isDynamicReference(lhs) or p.isDynamicReference(rhs)) {
        // TODO: remove dynamic range tag
        node.tag = .dynamic_range;
    }

    const index = try p.addNode(node);
    return .{ index, .range };
}

fn parseReferenceExpr(p: *Parser, ctx: ExpressionContext) !Intermediate {
    return switch (p.token_tags[p.tok_i]) {
        .ampersand => {
            p.tok_i += 1;
            _ = try p.parsePrimaryExpr(ctx);
            const index = try p.addNode(.init(.reference, {}));
            return .{ index, .cell };
        },
        .asterisk => {
            p.tok_i += 1;
            const operand, _ = try p.parseReferenceExpr(ctx);

            // Accessing the value of a cell dynamically requires volatile
            if (p.isDynamicReference(operand))
                p.is_volatile = true;

            const index = try p.addNode(.init(.dereference, {}));
            return .{ index, .any };
        },
        else => try p.parsePrimaryExpr(ctx),
    };
}

/// Returns true if the given node is a cell literal or a reference to a cell literal.
fn isDynamicReference(p: *const Parser, index: Index) bool {
    return Ast.isDynamicReference(p.ast.nodes, index);
}

/// Returns true if the given node is a cell literal or a reference to a cell literal.
fn isDynamicRange(p: *const Parser, index: Index) bool {
    return switch (p.ast.nodes.item(index, .tag)) {
        .dynamic_range => true,
        else => false,
    };
}

/// Marks the expression as volatile if the given node could be a cell reference and is not a cell
/// literal or a reference to a cell literal, or if the expression could be a cell range.
fn volatileAccess(p: *Parser, index: Index, result_type: Type) void {
    p.is_volatile =
        p.is_volatile or
        result_type.range_ref and p.isDynamicRange(index) or
        result_type.cell_ref and p.isDynamicReference(index);
}

/// Marks the expression as volatile if the given node could be a cell reference and is not a cell
/// literal or a reference to a cell literal.
fn volatileAccessSingle(p: *Parser, index: Index, result_type: Type) void {
    p.is_volatile =
        p.is_volatile or
        result_type.cell_ref and p.isDynamicReference(index);
}

/// PrimaryExpr <- Number / Range / StringLiteral / Identifier / Builtin / '(' Expression ')'
fn parsePrimaryExpr(p: *Parser, ctx: ExpressionContext) !Intermediate {
    return switch (p.token_tags[p.tok_i]) {
        .number => try p.parseNumber(),
        .rel_rel, .rel_abs, .abs_rel, .abs_abs => try p.parseCellName(ctx),
        .lparen => {
            try p.expectToken(.lparen);
            const ret = try p.parseExpression(ctx);
            try p.expectToken(.rparen);
            return ret;
        },
        .builtin => try p.parseBuiltin(),
        // .identifier => try parser.parseIdentifier(),
        inline .single_string_literal_start,
        .double_string_literal_start,
        => |tag| try p.parseStringLiteral(tag),
        else => p.setError(error.UnexpectedToken, .{ .expected_string = "expression" }),
    };
}

fn parseIdentifier(p: *Parser) !Intermediate {
    const start = try p.expectTokenGet(.identifier);
    const end = p.token_starts[p.tok_i];
    const index = try p.addNode(.init(.identifier, .{
        .start = start,
        .end = end,
    }));
    return .{ index, .any };
}

/// Builtin <- builtin ('(' ArgList? ')')?
fn parseBuiltin(p: *Parser) !Intermediate {
    const start = try p.expectTokenGet(.builtin);
    const end = p.token_starts[p.tok_i];

    const identifier = std.mem.trimRight(u8, p.src[start + 1 .. end], &std.ascii.whitespace);
    const builtin = builtins.get(identifier) orelse return p.setError(
        error.InvalidBuiltin,
        .{ .invalid_builtin = identifier },
    );

    var arg_count: u32 = 0;
    const args_start, const result_type: Type = sw: switch (builtin) {
        // These builtins aren't even functions!
        .pi, .e => {
            const index = try p.addNode(
                .init(.builtin, .{
                    .tag = builtin,
                    .arg_count = 0,
                    .first_arg = 0,
                }),
            );
            return .{ index, .number };
        },
        // These builtins take only one argument
        .width,
        .height,
        => {
            try p.expectToken(.lparen);
            const expr, _ = try p.parseExpression(.value);
            arg_count = 1;
            break :sw .{ expr, .number };
        },
        .sqrt,
        .round,
        .floor,
        .ceil,
        .len,
        => {
            try p.expectToken(.lparen);
            const expr, const result_type = try p.parseExpression(.reference);
            p.volatileAccessSingle(expr, result_type);
            arg_count = 1;

            break :sw .{ expr, .number };
        },
        .upper,
        .lower,
        => {
            try p.expectToken(.lparen);
            const expr, const result_type = try p.parseExpression(.reference);
            p.volatileAccessSingle(expr, result_type);
            arg_count = 1;

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
            try p.expectToken(.lparen);
            const index, arg_count = try p.parseVarArgsAccess(.reference);
            break :sw .{ index, .number };
        },
        .log => {
            try p.expectToken(.lparen);
            const index = try p.parseArgsAccess(2, .reference);
            arg_count = 2;
            break :sw .{ index, .number };
        },
    };
    try p.expectToken(.rparen);

    const index = try p.addNode(.init(.builtin, .{
        .tag = builtin,
        .arg_count = @intCast(arg_count),
        .first_arg = @intCast(p.ast.nodes.len() - @intFromEnum(args_start)),
    }));
    return .{ index, result_type };
}

/// ArgList <- Expression (',' Expression)*
fn parseVarArgsAccess(p: *Parser, ctx: ExpressionContext) !struct { Index, u32 } {
    var count: u32 = 1;
    const start, var result_type = try p.parseExpression(ctx);
    p.volatileAccess(start, result_type);

    while (p.eatToken(.comma)) |_| : (count += 1) {
        const index, result_type = try p.parseExpression(ctx);
        p.volatileAccess(index, result_type);
    }

    return .{ start, count };
}

/// Parses an argument list with exactly `n` arguments.
fn parseArgsAccess(p: *Parser, n: usize, ctx: ExpressionContext) !Index {
    const start, var result_type = try p.parseExpression(ctx);
    p.volatileAccess(start, result_type);

    for (0..n - 1) |_| {
        try p.expectToken(.comma);
        const index, result_type = try p.parseExpression(ctx);
        p.volatileAccess(index, result_type);
    }

    return start;
}

/// Number <- ('+' / '-')? ('0'-'9')+
fn parseNumber(p: *Parser) !Intermediate {
    const is_positive = p.eatToken(.minus) == null;
    if (is_positive) _ = p.eatToken(.plus);

    const start = try p.expectTokenGet(.number);
    const raw = p.src[start..p.token_starts[p.tok_i]];
    const text = std.mem.trimRight(u8, raw, " \t\r\n");

    // Correctness of the number is guaranteed because the tokenizer wouldn't have generated a
    // number token on invalid format.
    const num = std.fmt.parseFloat(f64, text) catch {
        std.debug.print("'{s}' ({x})\n", .{ text, text });
        std.debug.print("Next token: {any}\n", .{p.token_tags[p.tok_i]});
        unreachable;
    };

    const index = try p.addNode(.init(.number, if (is_positive) num else -num));
    return .{ index, .number };
}

fn parseStringLiteral(p: *Parser, comptime expected_tag: Token.Tag) ParseError!Intermediate {
    const start = try p.expectTokenGet(expected_tag);
    const end_tag = switch (expected_tag) {
        .single_string_literal_start => .single_string_literal_end,
        .double_string_literal_start => .double_string_literal_end,
        else => comptime unreachable,
    };
    const end = try p.expectTokenGet(end_tag);

    const bytes = p.src[start + 1 .. end];
    const string_start = p.ast.strings.items.len;
    try p.ast.strings.appendSlice(p.gpa, bytes);

    // TODO: Handle escapes of quotes
    const index = try p.addNode(
        .init(.string_literal, .{
            .start = @intCast(string_start),
            .end = @intCast(string_start + bytes.len),
        }),
    );
    return .{ index, .string };
}

// TODO: Inidicate from caller if we're in a reference or value context and adjust result type
/// CellReference <- ('a'-'z' / 'A'-'Z')+ ('0'-'9')+
fn parseCellName(p: *Parser, ctx: ExpressionContext) !Intermediate {
    switch (p.token_tags[p.tok_i]) {
        .rel_rel, .rel_abs, .abs_rel, .abs_abs => {},
        else => return p.setError(
            error.UnexpectedToken,
            .{ .expected_token = .rel_rel },
        ),
    }
    const start = p.token_starts[p.tok_i];
    p.tok_i += 1;
    const raw = p.src[start..p.token_starts[p.tok_i]];
    const text = std.mem.trimRight(u8, raw, " \t\r\n");

    const res = Position.fromAddress2(text) catch return p.setError(
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

            const index = try p.addNode(.init(tag, res.pos));
            const result_type: Type = switch (ctx) {
                .value => .any,
                .reference => .cell,
            };
            return .{ index, result_type };
        },
    }
}

fn addNode(p: *Parser, node: Node) Allocator.Error!Index {
    return try p.ast.nodes.append(p.gpa, node);
}

fn expectTokenGet(p: *Parser, expected_tag: Token.Tag) !u32 {
    if (p.token_tags[p.tok_i] != expected_tag) {
        @branchHint(.unlikely);
        return p.setError(error.UnexpectedToken, .{
            .expected_token = expected_tag,
        });
    }
    const ret = p.token_starts[p.tok_i];
    p.tok_i += 1;
    return ret;
}

fn expectToken(p: *Parser, expected_tag: Token.Tag) !void {
    if (p.token_tags[p.tok_i] != expected_tag) {
        @branchHint(.unlikely);
        return p.setError(error.UnexpectedToken, .{
            .expected_token = expected_tag,
        });
    }
    p.tok_i += 1;
}

fn setError(p: *Parser, err: ParseError, info: Diagnostics.Payload) ParseError {
    if (p.diagnostics) |diag| diag.* = .{
        .payload = info,
        .actual = p.token_tags[p.tok_i],
        .prev = if (p.tok_i > 0) p.token_tags[p.tok_i - 1] else .eof,
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

fn eatToken(p: *Parser, expected_tag: Token.Tag) ?Token {
    if (p.token_tags[p.tok_i] == expected_tag) {
        @branchHint(.likely);
        const ret: Token = .{
            .tag = p.token_tags[p.tok_i],
            .start = p.token_starts[p.tok_i],
        };
        p.tok_i += 1;
        return ret;
    }

    return null;
}

test "parser" {
    const t = std.testing;
    const testParser = struct {
        fn func(bytes: []const u8, node_tags: []const Node.Tag) !void {
            var ast: Ast = .empty;
            defer ast.deinit(std.testing.allocator);

            _ = try ast.parseFromExpression(t.allocator, bytes, .{});
            for (node_tags, ast.nodes.items(.tag)) |expected, actual| {
                try t.expectEqual(expected, actual);
            }
        }
    }.func;
    const testParseError = struct {
        fn func(bytes: []const u8, err: ?anyerror) !void {
            var ast: Ast = .empty;
            defer ast.deinit(std.testing.allocator);

            if (err) |e| {
                try t.expectError(e, ast.parseFromExpression(t.allocator, bytes, .{}));
            } else {
                _ = try ast.parseFromExpression(t.allocator, bytes, .{});
            }
        }
    }.func;

    try testParser("let a0 = 5", &.{ .number, .assignment, .end });
    try testParser("let a0 = 5.0 + +5.0", &.{ .number, .number, .plus, .add, .assignment, .end });
    try testParser("let a0 = 5.0 + -5.0", &.{ .number, .number, .minus, .add, .assignment, .end });
    try testParser("let a0 = 5.0 - +5.0", &.{ .number, .number, .plus, .sub, .assignment, .end });
    try testParser("let a0 = 5.0 - -5.0", &.{ .number, .number, .minus, .sub, .assignment, .end });
    try testParser("let b0 = 0.0 + 1.123", &.{ .number, .number, .add, .assignment, .end });
    try testParser("let xxx50000 = 000000 - 11111122222223333333444444", &.{ .number, .number, .sub, .assignment, .end });
    try testParser("let c30 = 123_123.231 * 2", &.{ .number, .number, .mul, .assignment, .end });
    try testParser("let crxp65535 = 123_123.321 / 123_123.321", &.{ .number, .number, .div, .assignment, .end });

    try testParser("let a0 = 3 - 1 * 2", &.{ .number, .number, .number, .mul, .sub, .assignment, .end });
    try testParser("let a0 = 1 / 2 + 3", &.{ .number, .number, .div, .number, .add, .assignment, .end });
    try testParser("let a0 = 1 - (3 + 5)", &.{ .number, .number, .number, .add, .sub, .assignment, .end });
    try testParser("let a0 = (1 + 2) - (2 + 1)", &.{ .number, .number, .add, .number, .number, .add, .sub, .assignment, .end });
    try testParser("let a0 = 2 / (1 - (1 + 3))", &.{ .number, .number, .number, .number, .add, .sub, .div, .assignment, .end });

    try testParser("let a0 = 'this is epic' # ' and nice'", &.{ .string_literal, .string_literal, .concat, .assignment, .end });

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
            var ast: Ast = .empty;
            defer ast.deinit(std.testing.allocator);

            _ = try ast.parseFromExpression(t.allocator, bytes, .{});
            for (nodes, ast.nodes.items(.tag), ast.nodes.items(.data)) |expected, tag, data| {
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
            .init(.sub, {}),
            .init(.mul, {}),
            .init(.number, 2.0),
            .init(.number, 1.0),
            .init(.add, {}),
            .init(.div, {}),
            .init(.assignment, .fromValidAddress("b30")),
            .init(.end, 10),
        },
    );
    try testNodes(
        "let crxp65535 = 'this is epic' # 'nice'",
        &.{
            .init(.string_literal, .{
                .start = 0,
                .end = "this is epic".len,
            }),
            .init(.string_literal, .{
                .start = "this is epic".len,
                .end = "this is epic".len + "nice".len,
            }),
            .init(.concat, {}),
            .init(.assignment, .fromValidAddress("crxp65535")),
            .init(.end, 4),
        },
    );

    try testNodes(
        "let a0 = 1 and 2",
        &.{
            .init(.number, 1.0),
            .init(.number, 2.0),
            .init(.logical_and, {}),
            .init(.assignment, .fromValidAddress("a0")),
            .init(.end, 4),
        },
    );
}

fn testVolatile(expr: []const u8, volatility: bool) !void {
    var ast: Ast = .empty;
    defer ast.deinit(std.testing.allocator);

    const res = try ast.parseFromExpression(std.testing.allocator, expr, .{});
    try std.testing.expectEqual(volatility, res.is_volatile);
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
