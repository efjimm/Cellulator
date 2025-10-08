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

locals: std.ArrayList(LocalVariable) = .empty,
captures: std.ArrayList(CapturedVariable) = .empty,
scope: Node.OptionalIndex = .none,
capture_count: u8 = 0,

diagnostics: ?*Diagnostics = null,

const CapturedVariable = struct {
    scope: Index,
    slot: u8,
    capture_slot: u8,
};

const LocalVariable = struct {
    name: Ast.String,
    /// Index of the function whose scope this local variable is in
    scope: Index,
    slot: u8,
};

pub const StringSlice = extern struct {
    offset: u64,
    len: u64,
};

pub const OptionalResult = struct {
    root: Node.OptionalIndex,
    is_volatile: bool,
    destination: ?Position,

    pub const none: OptionalResult = .{
        .root = .none,
        .is_volatile = false,
        .destination = null,
    };
};

pub const Result = struct {
    root: Node.Index,
    is_volatile: bool,
    destination: ?Position,

    pub fn toOptional(res: Result) OptionalResult {
        return .{
            .root = res.root.toOptional(),
            .is_volatile = res.is_volatile,
            .destination = res.destination,
        };
    }
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

pub fn deinit(p: *Parser) void {
    p.captures.deinit(p.gpa);
    p.locals.deinit(p.gpa);
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
    defer parser.deinit();

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

/// <- Statement / Expression
fn parse(p: *Parser) ParseError!Result {
    p.is_volatile = false;
    p.locals.clearRetainingCapacity();

    const nodes_start = p.ast.nodes.len();
    const index = try p.parseStatement();
    _ = try p.addNode(.init(.end, .{ .length = @intCast(@intFromEnum(index) - nodes_start + 1) }));

    const root_index = p.root();
    return .{
        .root = root_index,
        .is_volatile = false,
        .destination = if (p.ast.tag(root_index) == .assignment)
            p.ast.payload(root_index).assignment
        else
            null,
    };
}

/// FunctionDef <- ('||' / ('|' (IDENTIFIER ',')* IDENTIFIER ','? '|')) Expression
///
/// Functions are laid out in the AST like so:
///
/// - function_body_start
///   - function_parameter nodes
///   - function body nodes
///   - function_capture nodes
/// - function_body_end
fn parseFunctionDefinition(p: *Parser) ParseError!Intermediate {
    try p.expectToken(.pipe);

    const start_node = try p.addNode(.init(.function_body_start, .{
        .arg_count = 0,
        .body_length = 0,
        .capture_count = 0,
    }));

    const old_cap_count = p.capture_count;
    p.capture_count = 0;

    const previous_scope = p.scope;
    p.scope = start_node.toOptional();

    var arg_count: u8 = 0;
    while (true) {
        if (p.eatToken(.pipe)) |_| break;
        const start = try p.expectTokenGet(.identifier);
        const end = p.token_starts[p.tok_i];
        const bytes = std.mem.trimRight(u8, p.src[start..end], &std.ascii.whitespace);
        const string = try p.addString(bytes);
        try p.locals.append(p.gpa, .{
            .name = string,
            .scope = start_node,
            .slot = arg_count,
        });
        _ = try p.addNode(.init(.function_parameter, string));
        arg_count += 1;

        _ = p.eatToken(.comma) orelse {
            try p.expectToken(.pipe);
            break;
        };
    }

    const body_start = p.ast.nodes.len();
    _ = try p.parseExpression(.value);
    const body_len: u32 = @intCast(p.ast.nodes.len() - body_start);

    const func: Ast.Node.FunctionDefStart = .{
        .arg_count = arg_count,
        .body_length = body_len,
        .capture_count = p.capture_count,
    };

    for (0..p.capture_count) |_| {
        const capture = p.captures.pop().?;
        _ = try p.addNode(.init(.function_capture, .{
            .offset = capture.slot,
            .scope = capture.scope,
        }));
    }

    const end_node = try p.addNode(.init(.function_body_end, .{
        .arg_count = func.arg_count,
        .capture_count = func.capture_count,
        .body_length = func.body_length,
    }));
    p.ast.payloadPtr(start_node).* = .{ .function_body_start = func };

    p.scope = previous_scope;
    p.capture_count = old_cap_count;
    p.locals.items.len -= arg_count;

    // TODO: Add function result type
    return .{ end_node, .any };
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

/// Expression <- PipeExpr
fn parseExpression(p: *Parser, ctx: ExpressionContext) ParseError!Intermediate {
    return try p.parsePipeExpr(ctx);
}

/// PipeExpr <- OrExpr ('|>' OrExpr)*
fn parsePipeExpr(p: *Parser, ctx: ExpressionContext) ParseError!Intermediate {
    const start = p.ast.nodes.len();
    var index, var result_type = try p.parseOrExpr(ctx);

    while (p.eatToken(.pipe_to)) |_| {
        const temp_tags = try p.gpa.dupe(Node.Tag, p.ast.tags()[start..]);
        defer p.gpa.free(temp_tags);
        const temp_data = try p.gpa.dupe(Node.Payload, p.ast.payloads()[start..]);
        defer p.gpa.free(temp_data);

        p.ast.nodes.shrinkRetainingCapacity(start);

        index, result_type = try p.parseOrExpr(ctx);
        var function_index: u48 = undefined;
        if (p.ast.tag(index) != .function_call) {
            index = try p.addNode(.init(.function_call, .{
                .function_index = @intCast(1 + temp_tags.len),
                .arg_count = 1,
                .is_pipe = true,
            }));
            function_index = 1;
        } else {
            const call = p.ast.payload(index).function_call;
            p.ast.payloadPtr(index).function_call.arg_count += 1;
            p.ast.payloadPtr(index).function_call.function_index += @intCast(temp_tags.len);
            p.ast.payloadPtr(index).function_call.is_pipe = true;
            function_index = call.function_index;
        }

        const dest = try p.ast.nodes.insertMany(
            p.gpa,
            @intFromEnum(index) - (function_index - 1),
            temp_tags.len,
        );

        for (temp_tags, temp_data, 0..) |tag, data, i| {
            dest.seti(i, .{
                .tag = tag,
                .data = data,
            });
        }

        index = index.addi(@intCast(temp_tags.len));
    }

    return .{ index, result_type };
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
            _ = try p.parseSuffixExpr(ctx);
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
        else => try p.parseSuffixExpr(ctx),
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

/// SuffixExpr <- PrimaryExpr '(' (FnCallArguments)? ')'
fn parseSuffixExpr(p: *Parser, ctx: ExpressionContext) !Intermediate {
    var index, var result_type = try p.parsePrimaryExpr(ctx);

    while (true) {
        var arg_count: u8 = 0;
        _ = p.eatToken(.lparen) orelse return .{ index, result_type };
        while (true) {
            if (p.eatToken(.rparen)) |_| break;
            // TODO: Volatility depends on the function, which is not known until evaluation time.
            //       Volatility would need to be checked later.
            _ = try p.parseExpression(.reference);
            _ = p.eatToken(.comma);
            arg_count += 1;
        }

        index = try p.addNode(.init(.function_call, .{
            .is_pipe = false,
            .arg_count = arg_count,
            .function_index = @intCast(@intFromEnum(p.ast.lastIndex().sub(index))),
        }));
        result_type = .any;
    }

    return .{ index, result_type };
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
        .pipe => try p.parseFunctionDefinition(),
        .identifier => try p.parseVariable(),
        else => p.setError(error.UnexpectedToken, .{ .expected_string = "expression" }),
    };
}

fn parseVariable(p: *Parser) !Intermediate {
    const start = try p.expectTokenGet(.identifier);
    const end = p.token_starts[p.tok_i];
    const bytes = std.mem.trimRight(u8, p.src[start..end], &std.ascii.whitespace);
    var i = p.locals.items.len;
    while (i > 0) {
        i -= 1;
        const local = p.locals.items[i];
        const local_name = p.ast.string(local.name);
        if (std.mem.eql(u8, bytes, local_name)) {
            if (p.scope != local.scope.toOptional()) {
                // Variable exists but not in the current scope. It's a capture.
                // Check if the variable has already been captured.
                var j = p.captures.items.len;
                while (j > 0) {
                    j -= 1;
                    const cap = p.captures.items[j];
                    if (cap.scope == local.scope and cap.slot == local.slot) {
                        // Already captured
                        const index = try p.addNode(.init(.captured_variable, .{
                            .slot = cap.slot,
                            .offset = cap.capture_slot,
                            .scope = cap.scope,
                        }));
                        return .{ index, .any };
                    }
                }

                // Create capture
                const index = try p.addNode(.init(.captured_variable, .{
                    .slot = local.slot,
                    .offset = p.capture_count,
                    .scope = local.scope,
                }));
                try p.captures.append(p.gpa, .{
                    .capture_slot = p.capture_count,
                    .slot = local.slot,
                    .scope = local.scope,
                });
                p.capture_count += 1;
                return .{ index, .any };
            }

            const index = try p.addNode(.init(.local_variable, .{ .offset = local.slot }));
            return .{ index, .any };
        }

        // if (std.mem.eql(u8, a: []const T, b: []const T))
    }

    return error.UnexpectedToken; // TODO: Global variables
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

    const index = try p.addNode(.init(.builtin, .{ .tag = builtin }));
    return .{ index, .any };
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

fn addString(p: *Parser, bytes: []const u8) !Ast.String {
    const start: u32 = @intCast(p.ast.strings.items.len);
    try p.ast.strings.appendSlice(p.gpa, bytes);
    return .{ .start = start, .end = @intCast(start + bytes.len) };
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

    try testParseError("let a0 = @upper()", null);
    try testParseError("let a0 = @lower()", null);
    try testParseError("let a0 = @upper(a0:b0)", null);
    try testParseError("let a0 = @lower(a0:b0)", null);
    try testParseError("let a0 = @upper(a0, b0)", null);
    try testParseError("let a0 = @lower(a0, b0)", null);

    try testParseError("let a0 = @sum('string1')", null);
    try testParseError("let a0 = @prod('string1')", null);
    try testParseError("let a0 = @avg('string1')", null);
    try testParseError("let a0 = @min('string1')", null);
    try testParseError("let a0 = @max('string1')", null);
    try testParseError("let a0 = 'string' # 'string'", null);
    try testParseError("let a0 = 'string' 5", error.UnexpectedToken);
    try testParseError("let a0 = 'string' 'string'", error.UnexpectedToken);

    try testParseError("let crxp0 = 5", null);
    try testParseError("let crxp0 = 'string'", null);

    try testParseError("let a0 = n", error.UnexpectedToken);
    try testParseError("let a0 = global", error.UnexpectedToken);
    try testParseError("let a0 = |x| y", error.UnexpectedToken);
}

test "Node contents" {
    const t = std.testing;
    const testNodes = struct {
        fn func(bytes: []const u8, nodes: []const Node) !void {
            var ast: Ast = .empty;
            defer ast.deinit(std.testing.allocator);

            _ = try ast.parseFromExpression(t.allocator, bytes, .{});
            errdefer {
                std.debug.print("Expected {{\n", .{});
                for (nodes) |node| {
                    std.debug.print("    {any},\n", .{node.get()});
                }
                std.debug.print("}}\n\n", .{});
                std.debug.print("Got {{\n", .{});
                for (0..ast.nodes.len()) |i| {
                    std.debug.print("    {any},\n", .{ast.nodes.geti(i).get()});
                }
                std.debug.print("}}\n", .{});
            }

            if (ast.nodes.len() != nodes.len) {
                return error.Failed;
            }
            for (nodes, ast.nodes.items(.tag), ast.nodes.items(.data)) |expected, tag, data| {
                const actual: Node = .{
                    .tag = tag,
                    .data = data,
                };
                try t.expectEqual(expected.get(), actual.get());
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
            .init(.end, .{ .length = 10 }),
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
            .init(.end, .{ .length = 4 }),
        },
    );

    try testNodes(
        "let a0 = 1 and 2",
        &.{
            .init(.number, 1.0),
            .init(.number, 2.0),
            .init(.logical_and, {}),
            .init(.assignment, .fromValidAddress("a0")),
            .init(.end, .{ .length = 4 }),
        },
    );

    try testNodes(
        "**a0:b0",
        &.{
            .init(.rel_rel, .fromValidAddress("a0")),
            .init(.dereference, {}),
            .init(.dereference, {}),
            .init(.rel_rel, .fromValidAddress("b0")),
            .init(.dynamic_range, {}),
            .init(.end, .{ .length = 5 }),
        },
    );

    try testNodes(
        "let a0 = || 2",
        &.{
            .init(.function_body_start, .{ .arg_count = 0, .body_length = 1, .capture_count = 0 }),
            .init(.number, 2.0),
            .init(.function_body_end, .{ .arg_count = 0, .body_length = 1, .capture_count = 0 }),
            .init(.assignment, .fromValidAddress("a0")),
            .init(.end, .{ .length = 4 }),
        },
    );

    try testNodes(
        "let a0 = (|| 2)()",
        &.{
            .init(.function_body_start, .{ .arg_count = 0, .body_length = 1, .capture_count = 0 }),
            .init(.number, 2.0),
            .init(.function_body_end, .{ .arg_count = 0, .body_length = 1, .capture_count = 0 }),
            .init(.function_call, .{ .is_pipe = false, .arg_count = 0, .function_index = 1 }),
            .init(.assignment, .fromValidAddress("a0")),
            .init(.end, .{ .length = 5 }),
        },
    );

    try testNodes(
        "let a0 = |x| 1",
        &.{
            .init(.function_body_start, .{ .arg_count = 1, .body_length = 1, .capture_count = 0 }),
            .init(.function_parameter, .{ .start = 0, .end = 1 }),
            .init(.number, 1.0),
            .init(.function_body_end, .{ .arg_count = 1, .body_length = 1, .capture_count = 0 }),
            .init(.assignment, .fromValidAddress("a0")),
            .init(.end, .{ .length = 5 }),
        },
    );

    try testNodes(
        "let a0 = |x| x",
        &.{
            .init(.function_body_start, .{ .arg_count = 1, .body_length = 1, .capture_count = 0 }),
            .init(.function_parameter, .{ .start = 0, .end = 1 }),
            .init(.local_variable, .{ .offset = 0 }),
            .init(.function_body_end, .{ .arg_count = 1, .body_length = 1, .capture_count = 0 }),
            .init(.assignment, .fromValidAddress("a0")),
            .init(.end, .{ .length = 5 }),
        },
    );

    try testNodes(
        "let a0 = |x, y, z| x * y + z",
        &.{
            .init(.function_body_start, .{ .arg_count = 3, .body_length = 5, .capture_count = 0 }),
            .init(.function_parameter, .{ .start = 0, .end = 1 }),
            .init(.function_parameter, .{ .start = 1, .end = 2 }),
            .init(.function_parameter, .{ .start = 2, .end = 3 }),
            .init(.local_variable, .{ .offset = 0 }),
            .init(.local_variable, .{ .offset = 1 }),
            .init(.mul, {}),
            .init(.local_variable, .{ .offset = 2 }),
            .init(.add, {}),
            .init(.function_body_end, .{ .arg_count = 3, .body_length = 5, .capture_count = 0 }),
            .init(.assignment, .fromValidAddress("a0")),
            .init(.end, .{ .length = 11 }),
        },
    );

    try testNodes(
        "let a0 = |x| |y| x + y",
        &.{
            .init(.function_body_start, .{ .arg_count = 1, .body_length = 7, .capture_count = 0 }),
            .init(.function_parameter, .{ .start = 0, .end = 1 }),
            .init(.function_body_start, .{ .arg_count = 1, .body_length = 3, .capture_count = 1 }),
            .init(.function_parameter, .{ .start = 1, .end = 2 }),
            .init(.captured_variable, .{ .slot = 0, .offset = 0, .scope = @enumFromInt(0) }),
            .init(.local_variable, .{ .offset = 0 }),
            .init(.add, {}),
            .init(.function_capture, .{ .offset = 0, .scope = @enumFromInt(0) }),
            .init(.function_body_end, .{ .arg_count = 1, .body_length = 3, .capture_count = 1 }),
            .init(.function_body_end, .{ .arg_count = 1, .body_length = 7, .capture_count = 0 }),
            .init(.assignment, .fromValidAddress("a0")),
            .init(.end, .{ .length = 11 }),
        },
    );

    try testNodes(
        "5 |> a0()",
        &.{
            .init(.rel_rel, .fromValidAddress("a0")),
            .init(.number, 5),
            .init(.function_call, .{ .is_pipe = true, .arg_count = 1, .function_index = 2 }),
            .init(.end, .{ .length = 3 }),
        },
    );

    try testNodes(
        "3 |> a0(5, 10)",
        &.{
            .init(.rel_rel, .fromValidAddress("a0")),
            .init(.number, 3),
            .init(.number, 5),
            .init(.number, 10),
            .init(.function_call, .{ .is_pipe = true, .arg_count = 3, .function_index = 4 }),
            .init(.end, .{ .length = 5 }),
        },
    );

    try testNodes(
        "@upper(A0) # @lower(B0)",
        &.{
            .init(.builtin, .{ .tag = .upper }),
            .init(.rel_rel, .fromValidAddress("A0")),
            .init(.function_call, .{ .is_pipe = false, .arg_count = 1, .function_index = 2 }),
            .init(.builtin, .{ .tag = .lower }),
            .init(.rel_rel, .fromValidAddress("B0")),
            .init(.function_call, .{ .is_pipe = false, .arg_count = 1, .function_index = 2 }),
            .init(.concat, {}),
            .init(.end, .{ .length = 7 }),
        },
    );
}

fn testVolatile(expr: []const u8, volatility: bool) !void {
    var ast: Ast = .empty;
    defer ast.deinit(std.testing.allocator);

    const res = try ast.parseFromExpression(std.testing.allocator, expr, .{});
    try std.testing.expectEqual(volatility, res.is_volatile);
}
