//! Basic expression parser. Does not attempt error recovery and returns immediately on fatal
//! errors. Contains a `MultiArrayList` of `Node`s that is sorted in reverse topological order.

// TODO: Proper error messages

const std = @import("std");
const Position = @import("Position.zig").Position;
const Sheet = @import("Sheet.zig");
const PosInt = Position.Int;
const Rect = Position.Rect;

const Tokenizer = @import("Tokenizer.zig");
const Parser = @import("Parser.zig");
pub const BinaryOperator = Parser.BinaryOperator;
pub const Builtin = Parser.Builtin;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const ParseError = Parser.ParseError;

// TODO: Make these usize
pub const String = extern struct {
    start: u32,
    end: u32,
};

pub fn isSingle(tag: Node.Tag) bool {
    return switch (tag) {
        .identifier,
        .number,
        .rel_rel,
        .abs_abs,
        .abs_rel,
        .rel_abs,
        .string_literal,
        .range,
        .dynamic_range,
        .builtin,
        .invalidated_pos,
        .invalidated_range,
        .minus,
        .plus,
        .not,
        .reference,
        .dereference,
        => true,
        .assignment,
        .end,
        .concat,
        .add,
        .sub,
        .mul,
        .div,
        .mod,
        .pow,
        .logical_and,
        .logical_or,
        .greater_than,
        .less_than,
        .greater_equals,
        .less_equals,
        .equals,
        .not_equals,
        => false,
    };
}

comptime {
    assert(@sizeOf(Node.Payload) <= 8);
}

pub const Node = extern struct {
    tag: Tag,
    data: Payload,

    pub const Tag = enum(u8) {
        end,
        number,
        abs_abs,
        abs_rel,
        rel_abs,
        rel_rel,
        string_literal,
        identifier,
        invalidated_pos,
        invalidated_range,
        assignment,
        builtin,
        minus,
        plus,
        not,
        concat,
        add,
        sub,
        mul,
        div,
        mod,
        pow,
        greater_than,
        less_than,
        greater_equals,
        less_equals,
        equals,
        not_equals,
        logical_and,
        logical_or,
        range,
        dynamic_range,
        reference,
        dereference,
    };

    pub const Tagged = union(Tag) {
        /// Stores the number of nodes in the AST.
        end: usize,
        number: f64,
        abs_abs: Position,
        abs_rel: Position,
        rel_abs: Position,
        rel_rel: Position,
        string_literal: String,
        identifier: String,
        invalidated_pos: Position,
        invalidated_range,

        assignment: Position,
        builtin: Builtin,
        minus,
        plus,
        not,
        concat,
        add,
        sub,
        mul,
        div,
        mod,
        pow,
        greater_than,
        less_than,
        greater_equals,
        less_equals,
        equals,
        not_equals,
        logical_and,
        logical_or,

        /// The colon operator with two static arguments.
        /// Cell value accesses through this range are non-volatile.
        range,
        /// The colon operator with one or more dynamic arguments.
        /// Cell value accesses through this range are volatile.
        dynamic_range,

        reference,
        dereference,
    };

    pub const Payload = blk: {
        var t = @typeInfo(Tagged).@"union";
        t.layout = .@"extern";
        t.tag_type = null;
        break :blk @Type(.{ .@"union" = t });
    };

    pub fn init(comptime tag: Tag, data: @FieldType(Payload, @tagName(tag))) Node {
        return .{
            .tag = tag,
            .data = @unionInit(Payload, @tagName(tag), data),
        };
    }

    pub inline fn get(n: Node) Tagged {
        switch (n.tag) {
            inline else => |tag| {
                const field = @tagName(tag);
                return @unionInit(Tagged, field, @field(n.data, field));
            },
        }
    }

    pub fn isCommutative(tag: Tag) bool {
        return switch (tag) {
            .end,
            .number,
            .abs_abs,
            .abs_rel,
            .rel_abs,
            .rel_rel,
            .builtin,
            .range,
            .dynamic_range,
            .invalidated_pos,
            .invalidated_range,
            .string_literal,
            .assignment,
            .not,
            .plus,
            .minus,
            .reference,
            .dereference,
            .identifier,
            => true,
            .add => true,
            .sub => false,
            .mul => true,
            .div => false,
            .mod => false,
            .pow => false,
            .concat => false,
            .less_than => false,
            .greater_than => false,
            .equals => false,
            .greater_equals => false,
            .less_equals => false,
            .not_equals => false,
            .logical_and => false,
            .logical_or => false,
        };
    }

    pub fn precedence(tag: Tag) i8 {
        return switch (tag) {
            // These aren't operators
            .end,
            .number,
            .abs_abs,
            .abs_rel,
            .rel_abs,
            .rel_rel,
            .builtin,
            .range,
            .dynamic_range,
            .invalidated_pos,
            .invalidated_range,
            .string_literal,
            .assignment,
            .identifier,
            => 127,

            // Actual operators
            .reference => 3,
            .dereference => 3,
            .minus => 2,
            .plus => 2,
            .not => 2,
            .mul => 1,
            .div => 1,
            .mod => 1,
            .pow => 1,
            .concat => 0,
            .add => 0,
            .sub => 0,
            .less_than => -1,
            .greater_than => -1,
            .equals => -1,
            .greater_equals => -1,
            .less_equals => -1,
            .not_equals => -1,
            .logical_and => -2,
            .logical_or => -3,
        };
    }
};

pub const NodeList = std.MultiArrayList(Node);
pub const NodeSlice = NodeList.Slice;
pub const Index = packed struct {
    n: usize,

    pub fn from(n: usize) Index {
        return .{ .n = n };
    }

    pub fn sub(index: Index, offset: usize) Index {
        return .from(index.n - offset);
    }

    pub fn addN(index: Index, offset: usize) Index {
        return .from(index.n + offset);
    }

    pub fn isValid(i: Index) bool {
        return i != invalid;
    }

    pub const invalid: Index = .{ .n = std.math.maxInt(usize) };
};

pub fn parseFromSource(
    gpa: std.mem.Allocator,
    nodes: *NodeSlice,
    source: []const u8,
) ParseError!Index {
    var reader: std.io.Reader = .fixed(source);
    var tokens = Tokenizer.collectTokens(
        gpa,
        &reader,
        @intCast(source.len / 2),
    ) catch |err| switch (err) {
        error.ReadFailed => unreachable,
        else => |e| return e,
    };
    defer tokens.deinit(gpa);

    if (tokens.items(.tag)[0] == .eof)
        return .invalid;

    var parser: Parser = .init(
        gpa,
        source,
        tokens.items(.tag),
        tokens.items(.start),
        .{ .nodes = nodes.toMultiArrayList() },
    );

    const old_len = nodes.len;

    // The parser could re-allocate the underlying nodes
    defer nodes.* = parser.nodes.slice();
    errdefer nodes.len = old_len;

    try parser.parse();

    return parser.root();
}

const Token = Tokenizer.Token;
pub fn initTokens(
    sheet: *Sheet,
    source: []const u8,
    token_tags: []const Token.Tag,
    token_starts: []const u32,
) ParseError!Parser {
    var parser: Parser = .init(
        sheet.gpa,
        source,
        token_tags,
        token_starts,
        .{ .nodes = sheet.ast_nodes.toMultiArrayList() },
    );

    const old_len = sheet.ast_nodes.len;

    // The parser could re-allocate the underlying nodes
    defer sheet.ast_nodes = parser.nodes.slice();
    errdefer sheet.ast_nodes.len = old_len;

    _ = try parser.parseStatement();

    return parser;
}

pub fn parseFromExpression(sheet: *Sheet, source: []const u8) ParseError!Sheet.Expression {
    return parseFromExpressionDiag(sheet, source, null);
}

pub fn parseFromExpressionDiag(
    sheet: *Sheet,
    source: []const u8,
    diag: ?*Parser.Diagnostics,
) ParseError!Sheet.Expression {
    var reader: std.io.Reader = .fixed(source);
    var tokens = Tokenizer.collectTokens(
        sheet.gpa,
        &reader,
        @intCast(source.len / 2),
    ) catch |err| switch (err) {
        error.ReadFailed => unreachable,
        error.OutOfMemory => |e| return e,
    };

    defer tokens.deinit(sheet.gpa);

    var parser: Parser = .init(
        sheet.gpa,
        source,
        tokens.items(.tag),
        tokens.items(.start),
        .{ .nodes = sheet.ast_nodes.toMultiArrayList(), .diagnostics = diag },
    );

    const old_len = sheet.ast_nodes.len;

    // The parser could re-allocate the underlying nodes
    defer sheet.ast_nodes = parser.nodes.slice();
    errdefer sheet.ast_nodes.len = old_len;

    try parser.parse();

    return .{
        .root = .from(@intCast(parser.nodes.len - 2)),
        .source = source,
        .is_volatile = parser.is_volatile,
    };
}

pub inline fn printFromIndex(
    nodes: NodeSlice,
    index: Index,
    writer: *std.io.Writer,
    strings: []const u8,
) std.io.Writer.Error!void {
    const node = nodes.get(index.n);
    return printFromNode(nodes, index, node, writer, strings);
}

pub fn printFromNode(
    nodes: NodeSlice,
    index: Index,
    node: Node,
    writer: *std.io.Writer,
    strings: []const u8,
) std.io.Writer.Error!void {
    // On the left-hand side, expressions involving operators with lower precedence need
    // parentheses.

    // On the right-hand side, expressions involving operators with lower precedence, or
    // non-commutative operators with the same precedence need to be surrounded by parentheses.
    switch (node.get()) {
        .number => |n| try writer.print("{d}", .{n}),
        .rel_rel => |pos| try writer.print("{f}", .{pos}),
        .rel_abs => |pos| try writer.print("{f}${d}", .{
            Position.fmtColumnAddress(pos.x), pos.y,
        }),
        .abs_rel => |pos| try writer.print("${f}{d}", .{
            Position.fmtColumnAddress(pos.x), pos.y,
        }),
        .abs_abs => |pos| try writer.print("${f}${d}", .{
            Position.fmtColumnAddress(pos.x), pos.y,
        }),
        .invalidated_pos => |pos| try writer.print("{f}", .{pos}),
        .identifier => |str| try writer.writeAll(strings[str.start..str.end]),
        .string_literal => |str| {
            try writer.print("\"{s}\"", .{strings[str.start..str.end]});
        },
        .concat => {
            const rhs = index.sub(1);
            const lhs = leftMostChild(nodes, rhs).sub(1);
            try printFromIndex(nodes, lhs, writer, strings);
            try writer.writeAll(" # ");
            try printFromIndex(nodes, rhs, writer, strings);
        },
        .end => {
            try printFromIndex(nodes, index.sub(1), writer, strings);
        },
        .assignment => |pos| {
            try writer.print("let {f} = ", .{pos});
            try printFromIndex(nodes, index.sub(1), writer, strings);
        },
        inline .plus, .minus, .not, .reference, .dereference => |_, t| {
            const n = index.sub(1);
            const rhs = nodes.get(n.n);

            const byte = switch (t) {
                .plus => '+',
                .minus => '-',
                .not => '!',
                .reference => '&',
                .dereference => '*',
                else => comptime unreachable,
            };

            try writer.writeByte(byte);
            if (isSingle(rhs.tag)) {
                try printFromNode(nodes, n, rhs, writer, strings);
            } else {
                try writer.writeByte('(');
                try printFromNode(nodes, n, rhs, writer, strings);
                try writer.writeByte(')');
            }
        },
        inline .greater_than,
        .less_than,
        .greater_equals,
        .less_equals,
        .equals,
        .not_equals,
        .logical_or,
        .logical_and,
        .sub,
        .mul,
        .pow,
        .div,
        .mod,
        .add,
        => |_, t| {
            const str = switch (t) {
                .greater_than => ">",
                .less_than => "<",
                .greater_equals => ">=",
                .less_equals => "<=",
                .equals => "==",
                .not_equals => "!=",
                .logical_or => "or",
                .logical_and => "and",
                .add => "+",
                .sub => "-",
                .mul => "*",
                .pow => "^",
                .div => "/",
                .mod => "%",
                else => comptime unreachable,
            };

            const rhs = index.sub(1);
            const lhs = leftMostChild(nodes, rhs).sub(1);
            try printFromIndex(nodes, lhs, writer, strings);
            try writer.writeAll(" " ++ str ++ " ");
            const rhs_node = nodes.get(rhs.n);
            const prec = comptime Node.precedence(t);
            const rprec = Node.precedence(rhs_node.tag);
            if (rprec < prec or rprec == prec and (!Node.isCommutative(t) or !Node.isCommutative(rhs_node.tag))) {
                try writer.writeByte('(');
                try printFromNode(nodes, rhs, rhs_node, writer, strings);
                try writer.writeByte(')');
            } else {
                try printFromNode(nodes, rhs, rhs_node, writer, strings);
            }
        },
        .range, .invalidated_range, .dynamic_range => {
            const rhs = index.sub(1);
            const lhs = leftMostChild(nodes, rhs).sub(1);
            try printFromIndex(nodes, lhs, writer, strings);
            try writer.writeByte(':');
            try printFromIndex(nodes, rhs, writer, strings);
        },

        .builtin => |b| {
            switch (b.tag) {
                .pi, .e => {
                    try writer.print("@{f}", .{b.tag});
                    return;
                },
                inline else => |tag| try writer.print("@{f}(", .{tag}),
            }
            var iter = argIteratorForwards(nodes, index.sub(b.first_arg), index);
            if (iter.next()) |arg_index| {
                try printFromIndex(nodes, arg_index, writer, strings);
            }
            while (iter.next()) |arg_index| {
                try writer.writeAll(", ");
                try printFromIndex(nodes, arg_index, writer, strings);
            }
            try writer.writeByte(')');
        },
    }
}

/// Returns the root index of each argument of a function, backwards.
pub const ArgIterator = struct {
    nodes: NodeSlice,
    first_arg: Index,
    index: Index,

    pub fn next(iter: *ArgIterator) ?Index {
        if (iter.index.n <= iter.first_arg.n) return null;
        const ret: Index = .from(iter.index.n - 1);
        iter.index = leftMostChild(iter.nodes, ret);
        return ret;
    }
};

pub fn argIterator(nodes: NodeSlice, start: Index, end: Index) ArgIterator {
    return ArgIterator{
        .nodes = nodes,
        .first_arg = start,
        .index = end,
    };
}

/// Returns the root index of each argument of a function, forwards. Prefer to use `ArgIterator`
/// for performance reasons.
pub const ArgIteratorForwards = struct {
    nodes: NodeSlice,
    end: Index,
    index: Index,
    backwards_iter: ArgIterator,
    buffer: [32]Index = undefined,
    i: usize = 0,

    pub fn next(iter: *ArgIteratorForwards) ?Index {
        if (iter.index.n >= iter.end.n) return null;
        const ret = iter.index;

        if (iter.i == 0) {
            const first_item = iter.backwards_iter.next() orelse {
                iter.index = iter.end;
                return ret;
            };

            iter.buffer[0] = first_item;
            iter.i = 1;

            for (iter.buffer[1..]) |*d| {
                const item = iter.backwards_iter.next() orelse break;
                d.* = item;
                iter.i += 1;
            }
        }
        iter.index = iter.buffer[iter.i - 1];
        iter.i -= 1;

        return ret;
    }
};

pub fn argIteratorForwards(nodes: NodeSlice, start: Index, end: Index) ArgIteratorForwards {
    return ArgIteratorForwards{
        .nodes = nodes,
        .end = end,
        .index = start,
        .backwards_iter = argIterator(nodes, .from(start.n + 1), end),
    };
}

pub const FormatData = struct {
    nodes: NodeSlice,
    root: Index,
    strings: []const u8,
};

pub fn fmtAst(
    nodes: NodeSlice,
    root: Index,
    strings: []const u8,
) std.fmt.Formatter(FormatData, formatAst) {
    return .{
        .data = .{
            .nodes = nodes,
            .root = root,
            .strings = strings,
        },
    };
}

pub fn formatAst(data: FormatData, w: *std.io.Writer) !void {
    return print(data.nodes, data.root, data.strings, w);
}

pub fn exprLen(nodes: NodeSlice, root: Index) usize {
    assert(nodes.items(.tag)[root.n + 1] == .end);
    return nodes.items(.data)[root.n + 1].end;
}

pub fn exprStart(nodes: NodeSlice, root: Index) Index {
    const len = exprLen(nodes, root);
    return root.sub(len - 1);
}

pub fn exprNodes(nodes: NodeSlice, root: Index) NodeSlice {
    const start = exprStart(nodes, root);
    const len = exprLen(nodes, root);
    return nodes.subslice(start.n, len);
}

pub fn print(
    nodes: NodeSlice,
    root: Index,
    strings: []const u8,
    writer: *std.io.Writer,
) std.io.Writer.Error!void {
    if (!root.isValid()) return;
    return printFromIndex(nodes, root, writer, strings);
}

pub fn leftMostChild(
    nodes: NodeSlice,
    index: Index,
) Index {
    assert(index.n < nodes.len);

    const node = nodes.get(index.n);

    return switch (node.get()) {
        // leaf nodes
        .string_literal,
        .number,
        .invalidated_pos,
        .rel_rel,
        .rel_abs,
        .abs_rel,
        .abs_abs,
        .identifier,
        => index,
        // branch nodes
        .concat,
        .add,
        .sub,
        .mul,
        .div,
        .mod,
        .range,
        .dynamic_range,
        .invalidated_range,
        .pow,
        .logical_and,
        .logical_or,
        .greater_than,
        .less_than,
        .greater_equals,
        .less_equals,
        .equals,
        .not_equals,
        => {
            const rhs = index.sub(1);
            const lhs = leftMostChild(nodes, rhs).sub(1);
            return leftMostChild(nodes, lhs);
        },
        .builtin => |b| if (b.first_arg != 0)
            leftMostChild(nodes, index.sub(b.first_arg))
        else
            index,
        .minus,
        .plus,
        .not,
        .reference,
        .dereference,
        .assignment,
        => leftMostChild(nodes, index.sub(1)),
        .end => |n| index.sub(n),
    };
}

/// Specifies the requested result type of an expression.
///
/// This is used to avoid intermediate 'magic' types that don't get used except for casting
/// purposes. For example, a cell literal (`A0`, `D10`) evaluates to the value of the cell it
/// references. However, it can also automatically coerce to a cell reference if the context in
/// which it is used requires a cell reference. Passing the requested result type to eval allows
/// cell literals to return a different type based on the context, either a number/string/none value
/// or a reference.
///
/// Without result types, it wouldn't be possible to have the same semantics for cell literals
/// without an intermediate type. If it evaluates to a value, we lose the information required
/// to cast it to a reference. If it evaluates to a reference, we can't tell the difference
/// between an explicit reference and an implicit one, which is an issue for contexts where values
/// and references are both valid. An intermediate type could be used to solve this, but the
/// calling code would immediately cast it to a value or reference based on the context, and the
/// intermediate type would be a dead branch in every part of the code handling results.
///
/// TODO: Investigate more possible uses of result types.
pub const ResultType = enum {
    any,
    reference,
};

pub const EvalResult = union(enum) {
    none,
    number: f64,
    string: StringResult,
    cell: Position,
    range: Range,

    pub const Range = struct {
        rect: Rect,
        map: Index = .invalid,

        pub fn format(r: Range, w: *std.io.Writer) !void {
            try r.rect.format(w);
        }

        pub fn eql(a: Range, b: Range) bool {
            return a.rect.eql(b.rect);
        }
    };

    pub fn boolean(res: EvalResult, _: *const Sheet) bool {
        return switch (res) {
            .none => false,
            .number => |n| n != 0,
            .string => true,
            .cell => true,
            .range => true,
        };
    }
};

pub const Reference = union(enum) {
    cell: Position,
    range: Rect,

    pub fn format(ref: @This(), w: *std.io.Writer) !void {
        switch (ref) {
            inline else => |f| try f.format(w),
        }
    }

    pub fn toRange(ref: @This()) Rect {
        return switch (ref) {
            .cell => |p| .initSinglePos(p),
            .range => |r| r,
        };
    }
};

pub const EvalResult2 = union(enum) {
    none,
    number: f64,
    string: StringResult,
    cell: Position,
    range: EvalResult.Range,
    cell_literal: Position,

    pub fn from(res: EvalResult) EvalResult2 {
        return switch (res) {
            .none => .none,
            .number => |n| .{ .number = n },
            .string => |str| .{ .string = str },
            .cell => |pos| .{ .cell = pos },
            .range => |r| .{ .range = r },
        };
    }
};

pub const StringResult = union(enum) {
    slice: []const u8,
    cell: struct {
        sheet: *Sheet,
        list_index: @FieldType(Sheet, "string_values").List.Index,
    },

    pub fn bytes(self: @This()) []const u8 {
        return switch (self) {
            .slice => |s| s,
            .cell => |s| s.sheet.string_values.items(s.list_index),
        };
    }
};

pub const EvalError = error{
    InvalidCoercion,
    DivideByZero,
    CyclicalReference,
    NotEvaluable,
} || Allocator.Error;

pub fn EvalContext(comptime Context: type) type {
    return struct {
        nodes: NodeSlice,
        tags: []const Node.Tag,
        data: []const Node.Payload,

        arena: Allocator,
        strings: []const u8,
        sheet: *Sheet,
        context: Context,
        stack: std.ArrayList(EvalResult2) = .empty,

        pub const Error = blk: {
            const E = error{
                InvalidCoercion,
                DivideByZero,
                CyclicalReference,
                NotEvaluable,
            } || Allocator.Error;

            if (Context == void) break :blk E;

            const C = if (@typeInfo(Context) == .pointer)
                std.meta.Child(Context)
            else
                Context;

            const func = @field(C, "evalCellByHandle");
            const info = @typeInfo(@TypeOf(func));
            const ret_info = @typeInfo(info.@"fn".return_type.?);
            break :blk E || ret_info.error_union.error_set;
        };

        fn toNumber(eval: *const @This(), res: EvalResult, none_value: f64) !f64 {
            return try eval.toNumberOrNull(res) orelse none_value;
        }

        fn toNumberOrNull(_: *const @This(), res: EvalResult) !?f64 {
            return switch (res) {
                .none => null,
                .number => |n| n,
                .string => |str| std.fmt.parseFloat(f64, str.bytes()) catch error.InvalidCoercion,
                .cell, .range => error.InvalidCoercion,
            };
        }

        /// Coerces `res` to a number, dereferencing one level of reference if required.
        fn toNumberDeref(eval: *const @This(), res: EvalResult) !?f64 {
            return switch (res) {
                .none => null,
                .number => |n| n,
                .string => |str| std.fmt.parseFloat(f64, str.bytes()) catch error.InvalidCoercion,
                .cell => |pos| {
                    const r2 = try eval.context.evalCellByPos(pos);
                    return eval.toNumberOrNull(r2);
                },
                .range => error.InvalidCoercion,
            };
        }

        fn push(eval: *@This(), res: EvalResult2) !void {
            try eval.stack.append(eval.arena, res);
        }

        fn pop(eval: *@This(), result_type: ResultType) !EvalResult {
            const ret = eval.stack.pop().?;
            return switch (ret) {
                .cell_literal => |pos| switch (result_type) {
                    .reference => .{ .cell = pos },
                    .any => try eval.context.evalCellByPos(pos),
                },
                .none => .none,
                .number => |n| .{ .number = n },
                .cell => |c| .{ .cell = c },
                .range => |r| .{ .range = r },
                .string => |str| .{ .string = str },
            };
        }

        fn evaluate(eval: *@This(), root: Index) Error!void {
            const start = leftMostChild(eval.nodes, root);
            for (start.n..root.n + 1) |i| switch (eval.nodes.get(i).get()) {
                .end => break,
                .identifier => {
                    @panic("TODO");
                },
                .number => |n| try eval.push(.{ .number = n }),
                .rel_rel, .rel_abs, .abs_rel, .abs_abs => |pos| {
                    try eval.push(.{ .cell_literal = pos });
                },
                .minus => {
                    const rhs = try eval.pop(.any);
                    try eval.push(.{ .number = -(try eval.toNumber(rhs, 0)) });
                },
                .plus => {
                    const rhs = try eval.pop(.any);
                    try eval.push(.{ .number = @abs(try eval.toNumber(rhs, 0)) });
                },
                .not => {
                    const rhs = try eval.pop(.any);
                    try eval.push(.{
                        .number = @floatFromInt(@intFromBool(!rhs.boolean(eval.sheet))),
                    });
                },
                .reference => {
                    const arg = try eval.pop(.reference);
                    try eval.push(.{ .cell = arg.cell });
                },
                .dereference => {
                    const arg = try eval.pop(.reference);
                    if (arg != .cell)
                        return error.NotEvaluable;

                    const pos = arg.cell;
                    const res = try eval.context.evalCellByPos(pos);
                    try eval.push(.from(res));
                },
                inline .add, .sub, .mul, .div, .mod, .pow => |_, t| {
                    const rhs = try eval.pop(.any);
                    const lhs = try eval.pop(.any);
                    const l = try eval.toNumber(lhs, 0);
                    const r = try eval.toNumber(rhs, 0);
                    const res: EvalResult2 = .{ .number = switch (t) {
                        .add => l + r,
                        .sub => l - r,
                        .mul => l * r,
                        .div => {
                            if (r == 0) return error.DivideByZero;
                            try eval.push(.{ .number = l / r });
                            continue;
                        },
                        .mod => {
                            if (r <= 0) return error.DivideByZero;
                            try eval.push(.{ .number = @rem(l, r) });
                            continue;
                        },
                        .pow => std.math.pow(f64, l, r),
                        else => comptime unreachable,
                    } };
                    try eval.push(res);
                },
                // and/or have the same semantics as Lua's and/or operators.
                .logical_and => {
                    const rhs = try eval.pop(.any);
                    const lhs = try eval.pop(.any);
                    const res: EvalResult2 =
                        if (lhs.boolean(eval.sheet))
                            .from(rhs)
                        else
                            .{ .number = 0 };

                    try eval.push(res);
                },
                .logical_or => {
                    const rhs = try eval.pop(.any);
                    const lhs = try eval.pop(.any);
                    const res: EvalResult2 =
                        if (lhs.boolean(eval.sheet))
                            .from(lhs)
                        else
                            .from(rhs);

                    try eval.push(res);
                },
                inline .equals, .not_equals => |_, tag| {
                    const rhs = try eval.pop(.any);
                    const lhs = try eval.pop(.any);
                    const false_value = @intFromBool(tag != .equals);
                    if (@as(std.meta.Tag(EvalResult), lhs) != rhs) {
                        try eval.push(.{ .number = false_value });
                        continue;
                    }

                    const n = switch (lhs) {
                        .none => true,
                        .number => |n| n == rhs.number,
                        .string => std.mem.eql(u8, lhs.string.bytes(), rhs.string.bytes()),
                        .cell => |pos| pos.eql(rhs.cell),
                        .range => |r| r.eql(rhs.range),
                    };

                    const b = switch (tag) {
                        .equals => n,
                        .not_equals => !n,
                        else => comptime unreachable,
                    };

                    try eval.push(.{ .number = @floatFromInt(@intFromBool(b)) });
                },
                inline .greater_than,
                .less_than,
                .greater_equals,
                .less_equals,
                => |_, t| {
                    const rhs = try eval.pop(.any);
                    const lhs = try eval.pop(.any);
                    const l = try eval.toNumber(lhs, 0);
                    const r = try eval.toNumber(rhs, 0);
                    const n = switch (t) {
                        .greater_equals => l >= r,
                        .less_equals => l <= r,
                        .greater_than => l > r,
                        .less_than => l < r,
                        .equals => l == r,
                        .not_equals => l != r,
                        else => comptime unreachable,
                    };

                    try eval.push(.{ .number = @floatFromInt(@intFromBool(n)) });
                },

                .builtin => |b| try eval.push(switch (b.tag) {
                    .sum => .{ .number = try eval.evalSum(b.arg_count) },
                    .prod => .{ .number = try eval.evalProd(b.arg_count) },
                    .avg => .{ .number = try eval.evalAvg(b.arg_count) },
                    .max => .{ .number = try eval.evalMax(b.arg_count) },
                    .min => .{ .number = try eval.evalMin(b.arg_count) },
                    .upper => .{ .string = .{ .slice = try eval.evalUpper() } },
                    .lower => .{ .string = .{ .slice = try eval.evalLower() } },
                    .sqrt => .{ .number = try eval.evalSqrt() },
                    .round => .{ .number = try eval.evalRound() },
                    .floor => .{ .number = try eval.evalFloor() },
                    .ceil => .{ .number = try eval.evalCeil() },
                    .len => .{ .number = try eval.evalStringLen() },
                    .count => .{ .number = try eval.evalCount(.numbers, b.arg_count) },
                    .count_all => .{ .number = try eval.evalCount(.all, b.arg_count) },
                    .log => .{ .number = try eval.evalLog() },
                    .pi => .{ .number = std.math.pi },
                    .e => .{ .number = std.math.e },
                    .width => .{ .number = try eval.evalWidth() },
                    .height => .{ .number = try eval.evalHeight() },
                }),

                .concat => {
                    const rhs = try eval.pop(.any);
                    const lhs = try eval.pop(.any);
                    var aw: std.io.Writer.Allocating = .init(eval.arena);
                    eval.formatString(lhs, &aw.writer) catch |err| switch (err) {
                        error.WriteFailed => return error.OutOfMemory,
                        else => |e| return e,
                    };
                    eval.formatString(rhs, &aw.writer) catch |err| switch (err) {
                        error.WriteFailed => return error.OutOfMemory,
                        else => |e| return e,
                    };
                    try eval.push(.{ .string = .{ .slice = try aw.toOwnedSlice() } });
                },
                .range, .dynamic_range => {
                    const rhs = try eval.pop(.reference);
                    const lhs = try eval.pop(.reference);
                    const invalid_args = lhs != .cell or rhs != .cell;

                    if (invalid_args)
                        return error.NotEvaluable;

                    try eval.push(.{
                        .range = .{ .rect = .initNormalizePos(lhs.cell, rhs.cell) },
                    });
                },
                .string_literal => |str| try eval.push(.{ .string = .{
                    .slice = eval.strings[str.start..str.end],
                } }),
                .invalidated_pos,
                .invalidated_range,
                .assignment,
                => return error.NotEvaluable,
            };
        }

        fn formatStringAlloc(eval: *const @This(), res: EvalResult) ![]u8 {
            var aw: std.io.Writer.Allocating = .init(eval.arena);
            eval.formatString(res, &aw.writer) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                else => |e| return e,
            };
            return aw.toOwnedSlice();
        }

        fn formatString(_: *const @This(), res: EvalResult, w: *std.io.Writer) !void {
            switch (res) {
                .none => {},
                .number => |n| try w.print("{d}", .{n}),
                .string => |str| try w.writeAll(str.bytes()),
                .cell => |c| try c.format(w),
                .range => |r| try r.format(w),
            }
        }

        fn mapArgsNumber(eval: *@This(), arg_count: u32, ctx: anytype) !void {
            const MapContext = struct {
                eval: *const EvalContext(Context),
                outer_ctx: @TypeOf(ctx),

                pub fn func(inner_ctx: @This(), cell: Sheet.Cell.Handle) !void {
                    const res = try inner_ctx.eval.context.evalCellByHandle(cell);
                    const number = try inner_ctx.eval.toNumberOrNull(res);
                    try inner_ctx.outer_ctx.func(number);
                }
            };

            for (0..arg_count) |_| {
                const res = try eval.pop(.reference);
                switch (res) {
                    .cell => |pos| {
                        const res2 = try eval.context.evalCellByPos(pos);
                        const number = try eval.toNumberOrNull(res2);
                        try ctx.func(number);
                    },
                    .range => |range| {
                        const rect = range.rect;
                        var map_ctx: MapContext = .{ .eval = eval, .outer_ctx = ctx };
                        try eval.sheet.cell_tree.traverse(
                            &.{ rect.tl.x, rect.tl.y },
                            &.{ rect.br.x, rect.br.y },
                            &map_ctx,
                        );
                    },
                    else => {
                        const n = try eval.toNumberOrNull(res);
                        try ctx.func(n);
                    },
                }
            }
        }

        /// Converts an ast range to a position range.
        fn toPosRange(eval: *const @This(), lhs: Index, rhs: Index) Position.Rect {
            switch (eval.tags[lhs.n]) {
                .rel_rel, .abs_abs, .rel_abs, .abs_rel => {},
                else => {
                    std.debug.print("{}\n", .{eval.tags[lhs.n]});
                    unreachable;
                },
            }

            switch (eval.tags[rhs.n]) {
                .rel_rel, .abs_abs, .rel_abs, .abs_rel => {},
                else => {
                    std.debug.print("{}\n", .{eval.tags[rhs.n]});
                    unreachable;
                },
            }

            return .initPos(eval.data[lhs.n].rel_rel, eval.data[rhs.n].rel_rel);
        }

        fn evalUpper(eval: *@This()) ![]const u8 {
            const arg = try eval.pop(.any);
            const str = try eval.formatStringAlloc(arg);
            for (str) |*c| c.* = std.ascii.toUpper(c.*);
            return str;
        }

        fn evalLower(eval: *@This()) ![]const u8 {
            const arg = try eval.pop(.any);
            const str = try eval.formatStringAlloc(arg);
            for (str) |*c| c.* = std.ascii.toLower(c.*);
            return str;
        }

        const ProdContext = struct {
            total: f64 = 1,

            fn func(ctx: *@This(), n: ?f64) !void {
                ctx.total *= n orelse 1;
            }
        };

        const SumContext = struct {
            total: f64 = 0,

            fn func(ctx: *@This(), n: ?f64) !void {
                ctx.total += n orelse 0;
            }
        };

        const AvgContext = struct {
            total: f64 = 0,
            total_items: u65 = 0,

            fn func(ctx: *@This(), n: ?f64) !void {
                ctx.total += n orelse return;
                ctx.total_items += 1;
            }
        };

        const MaxContext = struct {
            max: ?f64 = null,

            fn func(ctx: *@This(), n: ?f64) !void {
                if (ctx.max == null or ctx.max.? < n orelse 0)
                    ctx.max = n orelse 0;
            }
        };

        const MinContext = struct {
            min: ?f64 = null,

            fn func(ctx: *@This(), n: ?f64) !void {
                if (ctx.min == null or ctx.min.? > n orelse 0)
                    ctx.min = n orelse 0;
            }
        };

        fn evalSum(eval: *@This(), arg_count: u32) !f64 {
            var ctx: SumContext = .{};
            try eval.mapArgsNumber(arg_count, &ctx);
            return ctx.total;
        }

        fn evalProd(eval: *@This(), arg_count: u32) !f64 {
            var ctx: ProdContext = .{};
            try eval.mapArgsNumber(arg_count, &ctx);
            return ctx.total;
        }

        // TODO: This function assumes that ranges do not overlap?
        fn evalAvg(eval: *@This(), arg_count: u32) !f64 {
            var ctx: AvgContext = .{};
            try eval.mapArgsNumber(arg_count, &ctx);
            if (ctx.total_items == 0) return 0;
            return ctx.total / @as(f64, @floatFromInt(ctx.total_items));
        }

        fn evalMax(eval: *@This(), arg_count: u32) !f64 {
            var ctx: MaxContext = .{};
            try eval.mapArgsNumber(arg_count, &ctx);
            return ctx.max orelse 0;
        }

        fn evalMin(eval: *@This(), arg_count: u32) !f64 {
            var ctx: MinContext = .{};
            try eval.mapArgsNumber(arg_count, &ctx);
            return ctx.min orelse 0;
        }

        fn evalSqrt(eval: *@This()) !f64 {
            const arg = try eval.pop(.reference);
            const n = try eval.toNumberDeref(arg) orelse 0;
            if (n < 0) return error.NotEvaluable;
            return std.math.sqrt(n);
        }

        fn evalRound(eval: *@This()) !f64 {
            const arg = try eval.pop(.reference);
            const n = try eval.toNumberDeref(arg) orelse 0;
            return std.math.round(n);
        }

        fn evalFloor(eval: *@This()) !f64 {
            const arg = try eval.pop(.reference);
            const n = try eval.toNumberDeref(arg) orelse 0;
            return @floor(n);
        }

        fn evalCeil(eval: *@This()) !f64 {
            const arg = try eval.pop(.reference);
            const n = try eval.toNumberDeref(arg) orelse 0;
            return @ceil(n);
        }

        fn evalStringLen(eval: *@This()) !f64 {
            const arg = try eval.pop(.any);
            switch (arg) {
                .none => return 0,
                .number => |n| {
                    // TODO: This should account for the current precision of the cell
                    return @floatFromInt(std.fmt.count("{d}", .{n}));
                },
                .string => |str| {
                    const zg = @import("zg");
                    var iter = zg.graphemes.iterator(str.bytes());
                    var count: usize = 0;
                    while (iter.next()) |_| count += 1;
                    return @floatFromInt(count);
                },
                inline .cell, .range => |value| return @floatFromInt(std.fmt.count("{f}", .{value})),
            }
        }

        fn evalCount(
            eval: *@This(),
            comptime operation: enum { all, numbers },
            arg_count: u32,
        ) !f64 {
            const CountContext = struct {
                count: u65,
                eval: *const EvalContext(Context),

                pub fn func(ctx: *@This(), cell: Sheet.Cell.Handle) !void {
                    const res = ctx.eval.context.evalCellByHandle(cell) catch |err| switch (err) {
                        error.OutOfMemory => |e| return e,
                        else => {
                            switch (operation) {
                                .all => ctx.count += 1,
                                .numbers => {},
                            }
                            return;
                        },
                    };

                    switch (operation) {
                        .all => ctx.count += 1,
                        .numbers => if (res == .number) {
                            ctx.count += 1;
                        },
                    }
                }
            };

            var total: u65 = 0;
            for (0..arg_count) |_| {
                const res = try eval.pop(.any);
                switch (res) {
                    .none => {},
                    inline .number, .string => |_, tag| {
                        switch (operation) {
                            .all => total += 1,
                            .numbers => if (tag == .number) {
                                total += 1;
                            },
                        }
                    },
                    .cell => |pos| {
                        const range: Rect = .initSinglePos(pos);
                        var ctx: CountContext = .{ .count = 0, .eval = eval };
                        try eval.sheet.cell_tree.traverse(
                            &range.tl.array(),
                            &range.br.array(),
                            &ctx,
                        );
                        total += ctx.count;
                    },
                    .range => |range| {
                        const rect = range.rect;
                        var ctx: CountContext = .{ .count = 0, .eval = eval };
                        try eval.sheet.cell_tree.traverse(
                            &rect.tl.array(),
                            &rect.br.array(),
                            &ctx,
                        );
                        total += ctx.count;
                    },
                }
            }

            return @floatFromInt(total);
        }

        fn evalLog(eval: *@This()) !f64 {
            const base_result = try eval.pop(.any);
            const n_result = try eval.pop(.any);
            const base = try eval.toNumber(base_result, 10);
            const n = try eval.toNumber(n_result, 0);
            if (base <= 0 or base == 1 or n <= 0)
                return error.NotEvaluable;
            return std.math.log(f64, base, n);
        }

        fn evalWidth(eval: *@This()) !f64 {
            const res = try eval.pop(.any);
            return switch (res) {
                .cell => 1,
                .range => |r| @floatFromInt(r.rect.width2()),
                .none, .number, .string => return error.NotEvaluable,
            };
        }

        fn evalHeight(eval: *@This()) !f64 {
            const res = try eval.pop(.any);
            return switch (res) {
                .cell => 1,
                .range => |r| @floatFromInt(r.rect.height2()),
                .none, .number, .string => return error.NotEvaluable,
            };
        }
    };
}

/// Dynamically typed evaluation of expressions.
pub fn evaluate(
    nodes: NodeSlice,
    root_node: Index,
    sheet: *Sheet,
    /// Strings required by the expression. String literal nodes contain offsets
    /// into this buffer. If the expression has no string literals then this
    /// argument can be left as "".
    strings: []const u8,
    /// Instance of a type which has the method uevalCell`,
    /// which evaluates the cell at the given position.
    context: anytype,
) !EvalResult {
    var arena: std.heap.ArenaAllocator = .init(sheet.gpa);
    defer arena.deinit();

    var ctx: EvalContext(@TypeOf(context)) = .{
        .nodes = nodes,
        .tags = nodes.items(.tag),
        .data = nodes.items(.data),

        .arena = arena.allocator(),
        .sheet = sheet,
        .strings = strings,
        .context = context,
    };

    try ctx.evaluate(root_node);
    const res = try ctx.pop(.any);

    return switch (res) {
        .string => |str| .{ .string = .{ .slice = try sheet.gpa.dupe(u8, str.bytes()) } },
        .none, .number, .cell, .range => res,
    };
}

const CountDependenciesContext = struct {
    total: usize = 0,

    pub fn func(ctx: *CountDependenciesContext, _: Rect) void {
        ctx.total += 1;
    }
};

pub fn countDependencies(nodes: NodeSlice, root: Index) usize {
    var ctx: CountDependenciesContext = .{};
    traverseDependencies(nodes, root, &ctx, CountDependenciesContext.func);
    return ctx.total;
}

pub fn traverseDependencies(
    nodes: NodeSlice,
    root: Index,
    ctx: anytype,
    func: fn (@TypeOf(ctx), Rect) void,
) void {
    if (!root.isValid()) return;

    var traverse: TraverseDependencies(@TypeOf(ctx), func) = .{
        .nodes = nodes,
        .user_ctx = ctx,
    };
    traverse.traverse(root, .value, .no_deref);
}

fn TraverseDependencies(Context: type, func: fn (Context, Rect) void) type {
    return struct {
        nodes: NodeSlice,
        user_ctx: Context,

        fn traverse(
            self: *const @This(),
            index: Index,
            /// Whether the context treats a cell literal as a value or a reference. If treated as a value,
            /// the cell literal will be added to the dependency graph.
            ctx: Parser.ExpressionContext,
            /// Whether the context will automatically dereference a reference. If a reference to a cell
            /// literal is automatically dereferenced, it will be added to the dependency graph.
            deref: enum { deref, no_deref },
        ) void {
            const nodes = self.nodes;
            const node = nodes.get(index.n);

            switch (node.get()) {
                .assignment, .end => {
                    self.traverse(index.sub(1), ctx, .no_deref);
                },
                .identifier => {},
                .number, .string_literal, .invalidated_pos, .invalidated_range => {},
                .rel_rel, .rel_abs, .abs_rel, .abs_abs => |pos| switch (ctx) {
                    .reference => switch (deref) {
                        .deref => func(self.user_ctx, .initSinglePos(pos)),
                        .no_deref => {},
                    },
                    .value => {
                        func(self.user_ctx, .initSinglePos(pos));
                    },
                },
                .range => {
                    const add_dependency = switch (ctx) {
                        .reference => switch (deref) {
                            .deref => true,
                            .no_deref => false,
                        },
                        .value => false,
                    };
                    if (add_dependency) {
                        const rhs = index.sub(1);
                        const lhs = leftMostChild(nodes, rhs).sub(1);
                        const tags = nodes.items(.tag);
                        const data = nodes.items(.data);
                        const lhs_tag = tags[lhs.n];
                        const rhs_tag = tags[rhs.n];
                        const tl = switch (lhs_tag) {
                            .reference => switch (tags[lhs.n - 1]) {
                                .rel_rel, .rel_abs, .abs_rel, .abs_abs => data[lhs.n - 1].rel_rel,
                                else => unreachable,
                            },
                            .rel_rel, .rel_abs, .abs_rel, .abs_abs => data[lhs.n].rel_rel,
                            else => unreachable,
                        };
                        const br = switch (rhs_tag) {
                            .reference => switch (tags[rhs.n - 1]) {
                                .rel_rel, .rel_abs, .abs_rel, .abs_abs => data[rhs.n - 1].rel_rel,
                                else => unreachable,
                            },
                            .rel_rel, .rel_abs, .abs_rel, .abs_abs => data[rhs.n].rel_rel,
                            else => unreachable,
                        };
                        func(self.user_ctx, .initNormalizePos(tl, br));
                    }
                },
                .dynamic_range => {
                    const rhs = index.sub(1);
                    const lhs = leftMostChild(nodes, rhs).sub(1);
                    self.traverse(lhs, .reference, .no_deref);
                    self.traverse(rhs, .reference, .no_deref);
                },
                .reference => switch (deref) {
                    .deref => self.traverse(index.sub(1), .value, .no_deref),
                    .no_deref => {},
                },
                .dereference => {
                    self.traverse(index.sub(1), .reference, .deref);
                },
                .minus, .plus, .not => {
                    self.traverse(index.sub(1), .value, .no_deref);
                },
                .add,
                .sub,
                .mul,
                .div,
                .mod,
                .pow,
                .logical_and,
                .logical_or,
                .equals,
                .not_equals,
                .greater_than,
                .less_than,
                .greater_equals,
                .less_equals,
                .concat,
                => {
                    const rhs = index.sub(1);
                    const lhs = leftMostChild(nodes, rhs).sub(1);
                    self.traverse(lhs, .value, .no_deref);
                    self.traverse(rhs, .value, .no_deref);
                },
                .builtin => |b| switch (b.tag) {
                    .pi,
                    .e,
                    => {},
                    .sum,
                    .prod,
                    .avg,
                    .max,
                    .min,
                    .count,
                    .count_all,
                    .log,
                    => {
                        var iter = argIterator(nodes, index.sub(b.first_arg), index);
                        while (iter.next()) |i| {
                            self.traverse(i, .reference, .deref);
                        }
                    },
                    .upper,
                    .lower,
                    .sqrt,
                    .round,
                    .floor,
                    .ceil,
                    .len,
                    => {
                        self.traverse(index.sub(b.first_arg), .reference, .deref);
                    },
                    .width,
                    .height,
                    => {
                        self.traverse(index.sub(b.first_arg), .value, .no_deref);
                    },
                },
            }
        }
    };
}

/// Returns true if the given node is a cell literal or a reference to a cell literal.
pub fn isDynamicReference(nodes: NodeSlice, index: Index) bool {
    const tags = nodes.items(.tag);
    return switch (tags[index.n]) {
        .reference => switch (tags[index.n - 1]) {
            .rel_rel, .rel_abs, .abs_rel, .abs_abs => false,
            else => true,
        },
        .rel_rel, .rel_abs, .abs_rel, .abs_abs => false,
        else => true,
    };
}

/// Iterates backwards over a flat list of AST nodes that contains multiple expressions in sequence.
pub const ExpressionIterator = struct {
    tags: []const Node.Tag,
    data: []const Node.Payload,
    start: Index,
    i: usize,

    pub fn init(nodes: NodeSlice, start: Index) ExpressionIterator {
        return .{
            .tags = nodes.items(.tag),
            .data = nodes.items(.data),
            .start = start,
            .i = nodes.len,
        };
    }

    pub fn prev(iter: *ExpressionIterator) ?Index {
        if (iter.i <= iter.start.n) return null;
        iter.i -= 1;
        assert(iter.tags[iter.i] == .end);
        const len = iter.data[iter.i].end;
        const ret = iter.i - 1;
        iter.i -= len;
        return .from(ret);
    }
};

test "Parse and Eval Expression" {
    const t = std.testing;
    const Context = struct {
        pub fn evalCellByHandle(_: @This(), _: Sheet.Cell.Handle) !EvalResult {
            unreachable;
        }

        pub fn evalCellByPos(_: @This(), _: Position) !EvalResult {
            unreachable;
        }
    };

    const Error = EvalContext(void).Error || Parser.ParseError;

    const testExpr = struct {
        fn func(expected: Error!f64, src: []const u8) !void {
            var sheet = try Sheet.init(t.allocator);
            defer sheet.deinit();

            const expr = parseFromExpression(&sheet, src) catch |err| {
                return if (err != expected) err else {};
            };

            const res = evaluate(
                sheet.ast_nodes,
                expr.root,
                &sheet,
                src,
                Context{},
            ) catch |err| {
                return if (err != expected) err else {};
            };
            const n = res.number;

            const val = try expected;
            try std.testing.expectApproxEqRel(val, n, 0.0001);
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

    // Test NaN TODO: test for error.DivideByZero
    // var ast = try fromExpression(t.allocator, "0 / 0");
    // defer ast.deinit(t.allocator);
    // const res = try ast.eval(t.allocator, "", Context{});
    // try std.testing.expect(res == .err);
}

test "Functions on Ranges" {
    const t = std.testing;
    const Test = struct {
        fn testSheetExpr(expected: f64, src: []const u8) !void {
            var sheet = try Sheet.init(t.allocator);
            defer sheet.deinit();

            try sheet.setCell(try Position.fromAddress("A0"), try parseFromExpression(&sheet, "0"), .{});
            try sheet.setCell(try Position.fromAddress("B0"), try parseFromExpression(&sheet, "100"), .{});
            try sheet.setCell(try Position.fromAddress("A1"), try parseFromExpression(&sheet, "500"), .{});
            try sheet.setCell(try Position.fromAddress("B1"), try parseFromExpression(&sheet, "333.33"), .{});

            const expr = try parseFromExpression(&sheet, src);

            try sheet.update();
            const res = try evaluate(
                sheet.ast_nodes,
                expr.root,
                &sheet,
                "",
                &sheet,
            );
            try std.testing.expectApproxEqRel(expected, res.number, 0.0001);
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

test "Print" {
    const t = std.testing;

    const data = .{
        .{ "1 + 2 + 3", "1 + 2 + 3" },
        .{ "1 + (2 + 3)", "1 + 2 + 3" },
        .{ "1 + 2 - 3", "1 + 2 - 3" },
        .{ "1 + (2 - 3)", "1 + (2 - 3)" },
        .{ "1 + 2 * 3", "1 + 2 * 3" },
        .{ "1 + (2 * 3)", "1 + 2 * 3" },
        .{ "1 + 2 / 3", "1 + 2 / 3" },
        .{ "1 + (2 / 3)", "1 + 2 / 3" },
        .{ "1 + 2 % 3", "1 + 2 % 3" },
        .{ "1 + (2 % 3)", "1 + 2 % 3" },

        .{ "1 - 2 + 3", "1 - 2 + 3" },
        .{ "1 - (2 + 3)", "1 - (2 + 3)" },
        .{ "1 - 2 - 3", "1 - 2 - 3" },
        .{ "1 - (2 - 3)", "1 - (2 - 3)" },
        .{ "1 - 2 * 3", "1 - 2 * 3" },
        .{ "1 - (2 * 3)", "1 - 2 * 3" },
        .{ "1 - 2 / 3", "1 - 2 / 3" },
        .{ "1 - (2 / 3)", "1 - 2 / 3" },
        .{ "1 - 2 % 3", "1 - 2 % 3" },
        .{ "1 - (2 % 3)", "1 - 2 % 3" },

        .{ "1 * 2 + 3", "1 * 2 + 3" },
        .{ "1 * (2 + 3)", "1 * (2 + 3)" },
        .{ "1 * 2 - 3", "1 * 2 - 3" },
        .{ "1 * (2 - 3)", "1 * (2 - 3)" },
        .{ "1 * 2 * 3", "1 * 2 * 3" },
        .{ "1 * (2 * 3)", "1 * 2 * 3" },
        .{ "1 * 2 / 3", "1 * 2 / 3" },
        .{ "1 * (2 / 3)", "1 * (2 / 3)" },
        .{ "1 * 2 % 3", "1 * 2 % 3" },
        .{ "1 * (2 % 3)", "1 * (2 % 3)" },

        .{ "1 / 2 + 3", "1 / 2 + 3" },
        .{ "1 / (2 + 3)", "1 / (2 + 3)" },
        .{ "1 / 2 - 3", "1 / 2 - 3" },
        .{ "1 / (2 - 3)", "1 / (2 - 3)" },
        .{ "1 / 2 * 3", "1 / 2 * 3" },
        .{ "1 / (2 * 3)", "1 / (2 * 3)" },
        .{ "1 / 2 / 3", "1 / 2 / 3" },
        .{ "1 / (2 / 3)", "1 / (2 / 3)" },
        .{ "1 / 2 % 3", "1 / 2 % 3" },
        .{ "1 / (2 % 3)", "1 / (2 % 3)" },

        .{ "1 % 2 + 3", "1 % 2 + 3" },
        .{ "1 % (2 + 3)", "1 % (2 + 3)" },
        .{ "1 % 2 - 3", "1 % 2 - 3" },
        .{ "1 % (2 - 3)", "1 % (2 - 3)" },
        .{ "1 % 2 * 3", "1 % 2 * 3" },
        .{ "1 % (2 * 3)", "1 % (2 * 3)" },
        .{ "1 % 2 / 3", "1 % 2 / 3" },
        .{ "1 % (2 / 3)", "1 % (2 / 3)" },
        .{ "1 % 2 % 3", "1 % 2 % 3" },
        .{ "1 % (2 % 3)", "1 % (2 % 3)" },

        .{ "A0:B0", "A0:B0" },
        .{ "@sum(A0:B0, 1, 1 + 2, 1 + 2 * 3, 1 + 2 * 3 / 4)", "@sum(A0:B0, 1, 1 + 2, 1 + 2 * 3, 1 + 2 * 3 / 4)" },
        .{ "@prod(A0:B0, 1, 1 + 2, 1 + 2 * 3, 1 + 2 * 3 / 4)", "@prod(A0:B0, 1, 1 + 2, 1 + 2 * 3, 1 + 2 * 3 / 4)" },
        .{ "@avg(A0:B0, 1, 1 + 2, 1 + 2 * 3, 1 + 2 * 3 / 4)", "@avg(A0:B0, 1, 1 + 2, 1 + 2 * 3, 1 + 2 * 3 / 4)" },
        .{ "@min(A0:B0, 1, 1 + 2, 1 + 2 * 3, 1 + 2 * 3 / 4)", "@min(A0:B0, 1, 1 + 2, 1 + 2 * 3, 1 + 2 * 3 / 4)" },
        .{ "@max(A0:B0, 1, 1 + 2, 1 + 2 * 3, 1 + 2 * 3 / 4)", "@max(A0:B0, 1, 1 + 2, 1 + 2 * 3, 1 + 2 * 3 / 4)" },
    };

    const data2 = .{
        "0 and 0",
        "0 and 1",
        "1 and 1",
        "1 and 1",
        "1 and 3 + 1",
        "1 and (2 or 3)",

        "0 or 0",
        "0 or 1",
        "1 or 1",
        "1 or 1",
    };

    var sheet = try Sheet.init(t.allocator);
    defer sheet.deinit();

    inline for (data) |d| {
        const src, const expected = d;
        const expr = try parseFromExpression(&sheet, src);

        var buf: [4096]u8 = undefined;
        var fixed: std.io.Writer = .fixed(&buf);
        try print(sheet.ast_nodes, expr.root, expr.source, &fixed);
        try t.expectEqualStrings(expected, fixed.buffered());
    }

    inline for (data2) |src| {
        const expr = try parseFromExpression(&sheet, src);

        var buf: [4096]u8 = undefined;
        var fixed: std.io.Writer = .fixed(&buf);
        try print(sheet.ast_nodes, expr.root, expr.source, &fixed);
        try t.expectEqualStrings(src, fixed.buffered());
    }
}
