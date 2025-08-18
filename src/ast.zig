//! Basic expression parser. Does not attempt error recovery and returns immediately on fatal
//! errors. Contains a `MultiArrayList` of `Node`s that is sorted in reverse topological order.

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
        .number,
        .column,
        .rel_rel,
        .abs_abs,
        .abs_rel,
        .rel_abs,
        .string_literal,
        .range,
        .builtin,
        .invalidated_pos,
        .invalidated_range,
        .minus,
        .plus,
        .not,
        => true,
        .assignment,
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

pub const Node = extern struct {
    tag: Tag,
    data: Payload,

    pub const Tag = blk: {
        var t = @typeInfo(std.meta.FieldEnum(Payload));
        t.@"enum".tag_type = u8;
        break :blk @Type(t);
    };

    pub const Payload = extern union {
        number: f64,
        column: PosInt,
        abs_abs: Position,
        abs_rel: Position,
        rel_abs: Position,
        rel_rel: Position,
        minus: void,
        plus: void,
        not: void,
        assignment: Position,
        concat: BinaryOperator,
        add: BinaryOperator,
        sub: BinaryOperator,
        mul: BinaryOperator,
        div: BinaryOperator,
        mod: BinaryOperator,
        pow: BinaryOperator,
        greater_than: BinaryOperator,
        less_than: BinaryOperator,
        greater_equals: BinaryOperator,
        less_equals: BinaryOperator,
        equals: BinaryOperator,
        not_equals: BinaryOperator,
        logical_and: BinaryOperator,
        logical_or: BinaryOperator,
        builtin: Builtin,
        range: BinaryOperator,
        invalidated_pos: Position,
        invalidated_range: BinaryOperator,
        string_literal: String,
    };

    pub fn init(comptime tag: Tag, data: @FieldType(Payload, @tagName(tag))) Node {
        return .{
            .tag = tag,
            .data = @unionInit(Payload, @tagName(tag), data),
        };
    }

    pub const Tagged = blk: {
        var t = @typeInfo(Payload);
        t.@"union".layout = .auto;
        t.@"union".tag_type = Tag;
        break :blk @Type(t);
    };

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
            .number,
            .column,
            .abs_abs,
            .abs_rel,
            .rel_abs,
            .rel_rel,
            .builtin,
            .range,
            .invalidated_pos,
            .invalidated_range,
            .string_literal,
            .assignment,
            .not,
            .plus,
            .minus,
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
            .number,
            .column,
            .abs_abs,
            .abs_rel,
            .rel_abs,
            .rel_rel,
            .builtin,
            .range,
            .invalidated_pos,
            .invalidated_range,
            .string_literal,
            .assignment,
            => 127,

            // Actual operators
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

    pub fn sub(index: Index, offset: NegativeOffset) Index {
        return index.subN(offset.int());
    }

    pub fn subN(index: Index, offset: u32) Index {
        return .from(index.n - offset);
    }

    pub fn isValid(i: Index) bool {
        return i != invalid;
    }

    pub const invalid: Index = .{ .n = std.math.maxInt(usize) };
};

pub const NegativeOffset = enum(u32) {
    _,

    pub fn from(n: u32) NegativeOffset {
        assert(n != 0);
        return @enumFromInt(n);
    }

    pub fn int(o: NegativeOffset) u32 {
        return @intFromEnum(o);
    }
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

    return .from(@intCast(parser.nodes.len - 1));
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

pub fn parseFromExpression(sheet: *Sheet, source: []const u8) ParseError!Index {
    return parseFromExpressionDiag(sheet, source, null);
}

pub fn parseFromExpressionDiag(
    sheet: *Sheet,
    source: []const u8,
    diag: ?*Parser.Diagnostics,
) ParseError!Index {
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

    _ = try parser.parseExpression();
    _ = try parser.expectToken(.eof);

    return .from(@intCast(parser.nodes.len - 1));
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
        .column => |col| try writer.print("{f}", .{Position.fmtColumnAddress(col)}),
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

        .string_literal => |str| {
            try writer.print("\"{s}\"", .{strings[str.start..str.end]});
        },
        .concat => |b| {
            try printFromIndex(nodes, index.sub(b.lhs), writer, strings);
            try writer.writeAll(" # ");
            try printFromIndex(nodes, index.sub(b.rhs), writer, strings);
        },
        .assignment => |pos| {
            try writer.print("let {f} = ", .{pos});
            try printFromIndex(nodes, .from(index.n - 1), writer, strings);
        },
        inline .plus, .minus, .not => |_, t| {
            const n = index.subN(1);
            const rhs = nodes.get(n.n);

            const byte = switch (t) {
                .plus => '+',
                .minus => '-',
                .not => '!',
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
        => |b, t| {
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

            try printFromIndex(nodes, index.sub(b.lhs), writer, strings);
            try writer.writeAll(" " ++ str ++ " ");
            const rhs = nodes.get(index.sub(b.rhs).n);
            const prec = comptime Node.precedence(t);
            const rprec = Node.precedence(rhs.tag);
            if (rprec < prec or rprec == prec and (!Node.isCommutative(t) or !Node.isCommutative(rhs.tag))) {
                try writer.writeByte('(');
                try printFromNode(nodes, index.sub(b.rhs), rhs, writer, strings);
                try writer.writeByte(')');
            } else {
                try printFromNode(nodes, index.sub(b.rhs), rhs, writer, strings);
            }
        },
        .range, .invalidated_range => |b| {
            try printFromIndex(nodes, index.sub(b.lhs), writer, strings);
            try writer.writeByte(':');
            try printFromIndex(nodes, index.sub(b.rhs), writer, strings);
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
        .column,
        .invalidated_pos,
        .rel_rel,
        .rel_abs,
        .abs_rel,
        .abs_abs,
        => index,
        .assignment => leftMostChild(nodes, .from(index.n - 1)),
        // branch nodes
        .concat,
        .add,
        .sub,
        .mul,
        .div,
        .mod,
        .range,
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
        => |b| leftMostChild(nodes, index.sub(b.lhs)),
        .builtin => |b| if (b.first_arg.int() != 0)
            leftMostChild(nodes, index.sub(b.first_arg))
        else
            index,
        .minus, .plus, .not => leftMostChild(nodes, index.subN(1)),
    };
}

pub const EvalResult = union(enum) {
    none,
    number: f64,
    string: union(enum) {
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
    },

    /// Attempts to coerce `res` to an integer.
    fn toNumber(res: EvalResult, none_value: f64) !f64 {
        return switch (res) {
            .none => none_value,
            .number => |n| n,
            .string => |str| std.fmt.parseFloat(f64, str.bytes()) catch error.InvalidCoercion,
        };
    }

    fn toNumberOrNull(res: EvalResult) !?f64 {
        return switch (res) {
            .none => null,
            .number => |n| n,
            .string => |str| std.fmt.parseFloat(f64, str.bytes()) catch error.InvalidCoercion,
        };
    }

    pub fn format(res: EvalResult, w: *std.io.Writer) !void {
        switch (res) {
            .none => {},
            .number => |n| try w.print("{d}", .{n}),
            .string => |str| try w.writeAll(str.bytes()),
        }
    }

    pub fn boolean(res: EvalResult) bool {
        return switch (res) {
            .none => false,
            .number => |n| n != 0,
            .string => true,
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

        fn evaluate(eval: *const @This(), index: Index) Error!EvalResult {
            const node = eval.nodes.get(index.n);

            return switch (node.get()) {
                .number => |n| .{ .number = n },
                .rel_rel, .abs_abs, .abs_rel, .rel_abs => |pos| {
                    return eval.context.evalCellByPos(pos);
                },
                .minus => {
                    const rhs = try eval.evaluate(index.subN(1));
                    return .{ .number = -(try rhs.toNumber(0)) };
                },
                .plus => {
                    const rhs = try eval.evaluate(index.subN(1));
                    return .{ .number = @abs(try rhs.toNumber(0)) };
                },
                .not => {
                    const rhs = try eval.evaluate(index.subN(1));
                    return .{ .number = @floatFromInt(@intFromBool(!rhs.boolean())) };
                },
                inline .add, .sub, .mul, .div, .mod, .pow => |op, t| {
                    const lhs = try eval.evaluate(index.sub(op.lhs));
                    const rhs = try eval.evaluate(index.sub(op.rhs));
                    const l = try lhs.toNumber(0);
                    const r = try rhs.toNumber(0);
                    return .{ .number = switch (t) {
                        .add => l + r,
                        .sub => l - r,
                        .mul => l * r,
                        .div => {
                            if (r == 0) return error.DivideByZero;
                            return .{ .number = l / r };
                        },
                        .mod => {
                            if (r <= 0) return error.DivideByZero;
                            return .{ .number = @rem(l, r) };
                        },
                        .pow => std.math.pow(f64, l, r),
                        else => comptime unreachable,
                    } };
                },
                // and/or have the same semantics as Lua's and/or operators.
                .logical_and => |op| {
                    const lhs = try eval.evaluate(index.sub(op.lhs));
                    const rhs = try eval.evaluate(index.sub(op.rhs));
                    if (lhs.boolean()) return rhs;
                    return .{ .number = 0 };
                },
                .logical_or => |op| {
                    const lhs = try eval.evaluate(index.sub(op.lhs));
                    const rhs = try eval.evaluate(index.sub(op.rhs));
                    if (lhs.boolean()) return lhs;
                    return rhs;
                },
                // Boolean operators
                inline .greater_than,
                .less_than,
                .equals,
                .not_equals,
                .greater_equals,
                .less_equals,
                => |op, t| {
                    const lhs = try eval.evaluate(index.sub(op.lhs));
                    const rhs = try eval.evaluate(index.sub(op.rhs));
                    const l = try lhs.toNumber(0);
                    const r = try rhs.toNumber(0);
                    const n = switch (t) {
                        .greater_equals => l >= r,
                        .less_equals => l <= r,
                        .greater_than => l > r,
                        .less_than => l < r,
                        .equals => l == r,
                        .not_equals => l != r,
                        else => comptime unreachable,
                    };

                    return .{ .number = @floatFromInt(@intFromBool(n)) };
                },

                .builtin => |b| switch (b.tag) {
                    .sum => .{ .number = try eval.evalSum(index.sub(b.first_arg), index) },
                    .prod => .{ .number = try eval.evalProd(index.sub(b.first_arg), index) },
                    .avg => .{ .number = try eval.evalAvg(index.sub(b.first_arg), index) },
                    .max => .{ .number = try eval.evalMax(index.sub(b.first_arg), index) },
                    .min => .{ .number = try eval.evalMin(index.sub(b.first_arg), index) },
                    .upper => .{ .string = .{ .slice = try eval.evalUpper(index.sub(b.first_arg)) } },
                    .lower => .{ .string = .{ .slice = try eval.evalLower(index.sub(b.first_arg)) } },
                    .sqrt => .{ .number = try eval.evalSqrt(index.subN(1)) },
                    .round => .{ .number = try eval.evalRound(index.subN(1)) },
                    .floor => .{ .number = try eval.evalFloor(index.subN(1)) },
                    .ceil => .{ .number = try eval.evalCeil(index.subN(1)) },
                    .len => .{ .number = try eval.evalStringLen(index.subN(1)) },
                    .count => .{ .number = try eval.evalCount(index.sub(b.first_arg), index) },
                    .count_all => .{ .number = try eval.evalCount(index.sub(b.first_arg), index) },
                    .log => .{ .number = try eval.evalLog(index.sub(b.first_arg), index.subN(1)) },
                    .pi => .{ .number = std.math.pi },
                    .e => .{ .number = std.math.e },
                    .width => .{ .number = try eval.evalWidth(index.subN(1)) },
                    .height => .{ .number = try eval.evalHeight(index.subN(1)) },
                },

                .concat => |op| {
                    const lhs = try eval.evaluate(index.sub(op.lhs));
                    const rhs = try eval.evaluate(index.sub(op.rhs));
                    const slice = try std.fmt.allocPrint(eval.arena, "{f}{f}", .{ lhs, rhs });
                    return .{ .string = .{ .slice = slice } };
                },
                .string_literal => |str| .{ .string = .{ .slice = eval.strings[str.start..str.end] } },
                .column,
                .invalidated_pos,
                .range,
                .invalidated_range,
                .assignment,
                => error.NotEvaluable,
            };
        }

        fn evalUpper(eval: *const @This(), arg: Index) ![]const u8 {
            const evaled_arg = try eval.evaluate(arg);
            const str = try std.fmt.allocPrint(eval.arena, "{f}", .{evaled_arg});
            for (str) |*c| c.* = std.ascii.toUpper(c.*);
            return str;
        }

        fn evalLower(eval: *const @This(), arg: Index) ![]const u8 {
            const evaled_arg = try eval.evaluate(arg);
            const str = try std.fmt.allocPrint(eval.arena, "{f}", .{evaled_arg});
            for (str) |*c| c.* = std.ascii.toLower(c.*);
            return str;
        }

        fn evalSum(eval: *const @This(), start: Index, end: Index) !f64 {
            var iter = argIterator(eval.nodes, start, end);
            var total: f64 = 0;

            while (iter.next()) |i| switch (eval.tags[i.n]) {
                .range => {
                    const lhs, const rhs = eval.data[i.n].range.resolve(i);
                    total += try eval.sumRange(lhs, rhs);
                },
                .invalidated_range => return error.NotEvaluable,
                else => {
                    const res = try eval.evaluate(i);
                    total += try res.toNumber(0);
                },
            };

            return total;
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

        const SumContext = struct {
            total: f64 = 0,
            eval: *const EvalContext(Context),

            pub fn func(ctx: *SumContext, handle: Sheet.Cell.Handle) !void {
                const res = try ctx.eval.context.evalCellByHandle(handle);
                ctx.total += try res.toNumber(0);
            }
        };

        fn sumRange(eval: *const @This(), lhs: Index, rhs: Index) !f64 {
            const range = eval.toPosRange(lhs, rhs);

            var ctx: SumContext = .{ .eval = eval };
            try eval.sheet.cell_tree.traverse(
                &.{ range.tl.x, range.tl.y },
                &.{ range.br.x, range.br.y },
                &ctx,
            );

            return ctx.total;
        }

        fn evalProd(eval: *const @This(), start: Index, end: Index) !f64 {
            var iter = argIterator(eval.nodes, start, end);
            var total: f64 = 1;

            while (iter.next()) |i| switch (eval.tags[i.n]) {
                .range => {
                    const r = eval.data[i.n].range;
                    total *= try eval.prodRange(i.sub(r.lhs), i.sub(r.rhs));
                },
                .invalidated_range => return error.NotEvaluable,
                else => {
                    const res = try eval.evaluate(i);
                    total *= try res.toNumber(0);
                },
            };

            return total;
        }

        const ProdContext = struct {
            total: f64,
            eval: *const EvalContext(Context),

            pub fn func(ctx: *ProdContext, h: Sheet.Cell.Handle) !void {
                const res = try ctx.eval.context.evalCellByHandle(h);
                ctx.total *= try res.toNumber(1);
            }
        };

        fn prodRange(eval: *const @This(), lhs: Index, rhs: Index) !f64 {
            const range = eval.toPosRange(lhs, rhs);

            var ctx: ProdContext = .{ .eval = eval, .total = 1 };
            try eval.sheet.cell_tree.traverse(
                &.{ range.tl.x, range.tl.y },
                &.{ range.br.x, range.br.y },
                &ctx,
            );
            return ctx.total;
        }

        // TODO: This function assumes that ranges do not overlap?
        fn evalAvg(eval: *const @This(), start: Index, end: Index) !f64 {
            var iter = argIterator(eval.nodes, start, end);
            var total: f64 = 0;
            var total_items: Position.HashInt = 0;

            while (iter.next()) |i| switch (eval.tags[i.n]) {
                .range => {
                    const r = eval.data[i.n].range;
                    const lhs = i.sub(r.lhs);
                    const rhs = i.sub(r.rhs);
                    total += try eval.sumRange(lhs, rhs);

                    const rect: Rect = .initPos(
                        eval.data[lhs.n].rel_rel,
                        eval.data[rhs.n].rel_rel,
                    );

                    total_items += rect.area();
                },
                .invalidated_range => return error.NotEvaluable,
                else => {
                    const res = try eval.evaluate(i);
                    total += try res.toNumber(0);
                    total_items += 1;
                },
            };

            return total / @as(f64, @floatFromInt(total_items));
        }

        fn evalMax(eval: *const @This(), start: Index, end: Index) !f64 {
            var iter = argIterator(eval.nodes, start, end);
            var max: ?f64 = null;

            while (iter.next()) |i| {
                const m = switch (eval.tags[i.n]) {
                    .range => blk: {
                        const lhs, const rhs = eval.data[i.n].range.resolve(i);
                        break :blk try eval.maxRange(lhs, rhs);
                    },
                    .invalidated_range => return error.NotEvaluable,
                    else => blk: {
                        const res = try eval.evaluate(i);
                        break :blk try res.toNumberOrNull();
                    },
                } orelse continue;

                if (max == null or m > max.?) max = m;
            }

            return max orelse 0;
        }

        const MaxContext = struct {
            max: ?f64 = null,
            eval: *const EvalContext(Context),

            pub fn func(ctx: *MaxContext, h: Sheet.Cell.Handle) !void {
                const res = try ctx.eval.context.evalCellByHandle(h);
                if (try res.toNumberOrNull()) |n| {
                    if (ctx.max == null or n > ctx.max.?) ctx.max = n;
                }
            }
        };

        fn maxRange(eval: *const @This(), lhs: Index, rhs: Index) !?f64 {
            const range = eval.toPosRange(lhs, rhs);

            var ctx: MaxContext = .{ .eval = eval };
            try eval.sheet.cell_tree.traverse(
                &.{ range.tl.x, range.tl.y },
                &.{ range.br.x, range.br.y },
                &ctx,
            );

            return ctx.max;
        }

        fn evalMin(eval: *const @This(), start: Index, end: Index) !f64 {
            var iter = argIterator(eval.nodes, start, end);
            var min: ?f64 = null;

            while (iter.next()) |i| {
                const m = switch (eval.tags[i.n]) {
                    .range => blk: {
                        const lhs, const rhs = eval.data[i.n].range.resolve(i);
                        break :blk try eval.minRange(lhs, rhs);
                    },
                    .invalidated_range => return error.NotEvaluable,
                    else => blk: {
                        const res = try eval.evaluate(i);
                        break :blk try res.toNumberOrNull();
                    },
                } orelse continue;

                if (min == null or m < min.?) min = m;
            }

            return min orelse 0;
        }

        const MinContext = struct {
            min: ?f64 = null,
            eval: *const EvalContext(Context),

            pub fn func(ctx: *MinContext, h: Sheet.Cell.Handle) !void {
                const res = try ctx.eval.context.evalCellByHandle(h);
                if (try res.toNumberOrNull()) |n| {
                    if (ctx.min == null or n < ctx.min.?) ctx.min = n;
                }
            }
        };

        fn minRange(eval: *const @This(), lhs: Index, rhs: Index) !?f64 {
            const range = eval.toPosRange(lhs, rhs);

            var ctx: MinContext = .{ .eval = eval };
            try eval.sheet.cell_tree.traverse(
                &.{ range.tl.x, range.tl.y },
                &.{ range.br.x, range.br.y },
                &ctx,
            );

            return ctx.min;
        }

        fn evalSqrt(eval: *const @This(), arg: Index) !f64 {
            const res = try eval.evaluate(arg);
            const n = try res.toNumberOrNull() orelse 0;
            if (n < 0) return error.NotEvaluable;
            return std.math.sqrt(n);
        }

        fn evalRound(eval: *const @This(), arg: Index) !f64 {
            const res = try eval.evaluate(arg);
            const n = try res.toNumberOrNull() orelse 0;
            return std.math.round(n);
        }

        fn evalFloor(eval: *const @This(), arg: Index) !f64 {
            const res = try eval.evaluate(arg);
            const n = try res.toNumberOrNull() orelse 0;
            return @floor(n);
        }

        fn evalCeil(eval: *const @This(), arg: Index) !f64 {
            const res = try eval.evaluate(arg);
            const n = try res.toNumberOrNull() orelse 0;
            return @ceil(n);
        }

        fn evalStringLen(eval: *const @This(), arg: Index) !f64 {
            const res = try eval.evaluate(arg);
            switch (res) {
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
            }
        }

        fn evalCount(eval: *const @This(), start: Index, end: Index) !f64 {
            var iter = argIterator(eval.nodes, start, end);
            var total: f64 = 0;
            while (iter.next()) |i| switch (eval.tags[i.n]) {
                .range => total += eval.countRange(i, .numbers),
                else => {
                    const res = eval.evaluate(i) catch continue;
                    if (res != .none) {
                        _ = res.toNumberOrNull() catch continue;
                        total += 1;
                    }
                },
            };

            return total;
        }

        fn evalCountAll(eval: *const @This(), start: Index, end: Index) !f64 {
            var iter = argIterator(eval.nodes, start, end);
            var total: f64 = 0;
            while (iter.next()) |i| switch (eval.tags[i.n]) {
                .range => total += eval.countRange(i, .all),
                else => {
                    const res = eval.evaluate(i) catch continue;
                    if (res != .none) total += 1;
                },
            };

            return total;
        }

        fn countRange(
            eval: *const @This(),
            range_arg: Index,
            comptime count_type: enum { all, numbers },
        ) f64 {
            assert(eval.tags[range_arg.n] == .range);
            const lhs, const rhs = eval.data[range_arg.n].range.resolve(range_arg);
            const r = eval.toPosRange(lhs, rhs);
            const CountContext = struct {
                count: u64,
                eval: *const EvalContext(Context),

                pub fn func(ctx: *@This(), cell: Sheet.Cell.Handle) !void {
                    _ = try ctx.eval.context.evalCellByHandle(cell);

                    switch (count_type) {
                        .all => ctx.count += 1,
                        .numbers => {
                            if (ctx.eval.sheet.getCellFromHandle(cell).value_tag == .number) {
                                ctx.count += 1;
                            }
                        },
                    }
                }
            };

            var ctx: CountContext = .{ .count = 0, .eval = eval };
            eval.sheet.cell_tree.traverse(&r.tl.array(), &r.br.array(), &ctx) catch unreachable;
            return @floatFromInt(ctx.count);
        }

        fn evalLog(eval: *const @This(), arg: Index, base_arg: Index) !f64 {
            const base_result = try eval.evaluate(base_arg);
            const n_result = try eval.evaluate(arg);
            const base = try base_result.toNumber(10);
            const n = try n_result.toNumber(0);
            if (base <= 0 or base == 1 or n <= 0)
                return error.NotEvaluable;
            return std.math.log(f64, base, n);
        }

        fn evalWidth(eval: *const @This(), arg: Index) !f64 {
            if (eval.tags[arg.n] != .range)
                return error.NotEvaluable;
            const lhs, const rhs = eval.data[arg.n].range.resolve(arg);
            const p = eval.toPosRange(lhs, rhs);
            return @floatFromInt(p.width2());
        }

        fn evalHeight(eval: *const @This(), arg: Index) !f64 {
            if (eval.tags[arg.n] != .range)
                return error.NotEvaluable;
            const lhs, const rhs = eval.data[arg.n].range.resolve(arg);
            const p = eval.toPosRange(lhs, rhs);
            return @floatFromInt(p.height2());
        }
    };
}

pub const DynamicEvalResult = union(enum) {
    none,
    number: f64,
    string: [:0]const u8,

    pub fn boolean(res: DynamicEvalResult) bool {
        return switch (res) {
            .none => false,
            .number => |n| n != 0,
            .string => true,
        };
    }
};

/// Dynamically typed evaluation of expressions.
pub fn evaluate(
    nodes: NodeSlice,
    root_node: Index,
    sheet: *Sheet,
    /// Strings required by the expression. String literal nodes contain offsets
    /// into this buffer. If the expression has no string literals then this
    /// argument can be left as "".
    strings: []const u8,
    /// Instance of a type which has the method `evalCell`,
    /// which evaluates the cell at the given position.
    context: anytype,
) !EvalResult {
    var arena: std.heap.ArenaAllocator = .init(sheet.gpa);
    defer arena.deinit();

    const ctx: EvalContext(@TypeOf(context)) = .{
        .nodes = nodes,
        .tags = nodes.items(.tag),
        .data = nodes.items(.data),

        .arena = arena.allocator(),
        .sheet = sheet,
        .strings = strings,
        .context = context,
    };

    const res = try ctx.evaluate(root_node);

    return switch (res) {
        .none => .none,
        .number => |n| .{ .number = n },
        .string => |str| .{ .string = .{ .slice = try sheet.gpa.dupe(u8, str.bytes()) } },
    };
}

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
        fn func(expected: Error!f64, expr: []const u8) !void {
            var sheet = try Sheet.init(t.allocator);
            defer sheet.deinit();

            const expr_root = parseFromExpression(&sheet, expr) catch |err| {
                return if (err != expected) err else {};
            };

            const res = evaluate(
                sheet.ast_nodes,
                expr_root,
                &sheet,
                expr,
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

    // Cannot evaluate a range on its own
    try testExpr(error.NotEvaluable, "a0:a0");
    try testExpr(error.NotEvaluable, "a0:crxo65535");
    try testExpr(error.NotEvaluable, "z10:xxx500");

    // Test NaN TODO: test for error.DivideByZero
    // var ast = try fromExpression(t.allocator, "0 / 0");
    // defer ast.deinit(t.allocator);
    // const res = try ast.eval(t.allocator, "", Context{});
    // try std.testing.expect(res == .err);
}

test "Functions on Ranges" {
    const t = std.testing;
    const Test = struct {
        fn testSheetExpr(expected: f64, expr: []const u8) !void {
            var sheet = try Sheet.init(t.allocator);
            defer sheet.deinit();

            try sheet.setCell(try Position.fromAddress("A0"), "0", try parseFromExpression(&sheet, "0"), .{});
            try sheet.setCell(try Position.fromAddress("B0"), "100", try parseFromExpression(&sheet, "100"), .{});
            try sheet.setCell(try Position.fromAddress("A1"), "500", try parseFromExpression(&sheet, "500"), .{});
            try sheet.setCell(try Position.fromAddress("B1"), "333.33", try parseFromExpression(&sheet, "333.33"), .{});

            const expr_root = try parseFromExpression(&sheet, expr);

            try sheet.update();
            const res = try evaluate(
                sheet.ast_nodes,
                expr_root,
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

// test "Splice" {
//     const t = std.testing;

//     const Context = struct {
//         pub fn evalCell(_: @This(), _: Reference) !EvalResult {
//             return .none;
//         }

//         pub fn evalCellByHandle(_: @This(), _: Sheet.Cell.Handle) !EvalResult {
//             return .none;
//         }
//     };

//     const sheet = try Sheet.init(t.allocator);
//     defer sheet.deinit();

//     const expr_root = try fromSource(sheet, "let a0 = 100 * 3 + 5 / 2 + @avg(1, 10)");
//     const root_node = sheet.ast_nodes.get(expr_root.n);

//     var spliced_root = splice(&sheet.ast_nodes, root_node.data.assignment.rhs);

//     try t.expectApproxEqRel(
//         308,
//         (try eval(sheet.ast_nodes, spliced_root, sheet, "", Context{})).number,
//         0.0001,
//     );
//     try t.expectEqual(11, sheet.ast_nodes.len);

//     spliced_root = splice(&sheet.ast_nodes, sheet.ast_nodes.get(spliced_root.n).data.add.rhs);

//     try t.expectApproxEqRel(
//         5.5,
//         (try eval(sheet.ast_nodes, spliced_root, sheet, "", Context{})).number,
//         0.0001,
//     );
//     try t.expectEqual(3, sheet.ast_nodes.len);
// }

// test "StringEval" {
//     const data = .{
//         .{ "'string'", "string" },
//         .{ "'string1' # 'string2'", "string1string2" },
//         .{ "'string1' # 'string2' # 'string3'", "string1string2string3" },

//         .{ "@upper('String1')", "STRING1" },
//         .{ "@lower('String1')", "string1" },
//         .{ "@upper('STRING1')", "STRING1" },
//         .{ "@lower('string1')", "string1" },
//         .{ "@upper('StrINg1' # ' ' # 'StRinG2')", "STRING1 STRING2" },
//         .{ "@lower('StrINg1' # ' ' # 'StRinG2')", "string1 string2" },
//         .{ "@upper(@lower('String1'))", "STRING1" },
//         .{ "@lower(@upper('String1'))", "string1" },

//         .{ "@upper()", ParseError.UnexpectedToken },
//         .{ "@lower()", ParseError.UnexpectedToken },
//         .{ "@lower('string1', 'string2')", ParseError.UnexpectedToken },
//         .{ "@lower('string1', 'string2')", ParseError.UnexpectedToken },
//         .{ "@upper(a0:b0)", ParseError.UnexpectedToken },
//         .{ "@lower(a0:b0)", ParseError.UnexpectedToken },
//     };
//     var buf = SizedArrayListUnmanaged(u8, u32){};
//     defer buf.deinit(std.testing.allocator);

//     inline for (data) |d| {
//         switch (@TypeOf(d[1])) {
//             ParseError => {
//                 try std.testing.expectError(d[1], fromStringExpression(std.testing.allocator, d[0]));
//             },
//             EvalError => {
//                 var ast = try fromStringExpression(std.testing.allocator, d[0]);
//                 defer ast.deinit(std.testing.allocator);

//                 buf.clearRetainingCapacity();
//                 try std.testing.expectError(d[1], ast.stringEval(std.testing.allocator, {}, d[0], &buf));
//             },
//             else => {
//                 var ast = try fromStringExpression(std.testing.allocator, d[0]);
//                 defer ast.deinit(std.testing.allocator);

//                 buf.clearRetainingCapacity();
//                 try ast.stringEval(std.testing.allocator, {}, d[0], &buf);

//                 try std.testing.expectEqualStrings(d[1], buf.items());
//             },
//         }
//     }
// }

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
        const expr, const expected = d;
        const expr_root = try parseFromExpression(&sheet, expr);

        var buf: [4096]u8 = undefined;
        var fixed: std.io.Writer = .fixed(&buf);
        try print(sheet.ast_nodes, expr_root, expr, &fixed);
        try t.expectEqualStrings(expected, fixed.buffered());
    }

    inline for (data2) |expr| {
        const expr_root = try parseFromExpression(&sheet, expr);

        var buf: [4096]u8 = undefined;
        var fixed: std.io.Writer = .fixed(&buf);
        try print(sheet.ast_nodes, expr_root, expr, &fixed);
        try t.expectEqualStrings(expr, fixed.buffered());
    }
}
