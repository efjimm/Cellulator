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

const MultiList = @import("multi_list.zig").MultiList;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Ast = @This();

nodes: NodeList,
extra: std.ArrayListAligned(u8, .@"16"),
strings: std.ArrayList(u8),

pub const NodeList = MultiList(Node, usize);

/// Can be passed to `restore` to free any data added after the checkpoint was created.
/// Useful for temporary ASTs.
pub const Checkpoint = struct {
    nodes_len: usize,
    extra_len: usize,
    strings_len: usize,

    pub const reset: Checkpoint = .{
        .nodes_len = 0,
        .extra_len = 0,
        .strings_len = 0,
    };
};

pub const empty: Ast = .{
    .nodes = .empty,
    .strings = .empty,
    .extra = .empty,
};

pub fn deinit(ast: *Ast, gpa: std.mem.Allocator) void {
    ast.nodes.deinit(gpa);
    ast.strings.deinit(gpa);
    ast.extra.deinit(gpa);
}

pub fn save(ast: *const Ast) Checkpoint {
    return .{
        .nodes_len = ast.nodes.len(),
        .extra_len = ast.extra.items.len,
        .strings_len = ast.strings.items.len,
    };
}

pub fn restore(ast: *Ast, checkpoint: Checkpoint) void {
    ast.nodes.shrinkRetainingCapacity(checkpoint.nodes_len);
    ast.extra.shrinkRetainingCapacity(checkpoint.extra_len);
    ast.strings.shrinkRetainingCapacity(checkpoint.strings_len);
}

// TODO: Rename
pub fn lastIndex(ast: *const Ast) Node.Index {
    return ast.nodes.nextIndex();
}

pub fn clearRetainingCapacity(ast: *Ast) void {
    ast.nodes.clearRetainingCapacity();
    ast.strings.clearRetainingCapacity();
}

pub fn tag(ast: *const Ast, index: Node.Index) Node.Tag {
    return ast.nodes.item(index, .tag);
}

pub fn payload(ast: *const Ast, index: Node.Index) Node.Payload {
    return ast.nodes.item(index, .data);
}

pub fn node(ast: *const Ast, index: Node.Index) Node.Tagged {
    return ast.nodes.get(index).get();
}

/// Removes the root node from the last expression appended to `ast.nodes`.
pub fn spliceLast(ast: *Ast) struct { Node.Index, Position } {
    const len = ast.nodes.len();
    const t = ast.tags();
    const data = ast.payloads();

    assert(t[len - 1] == .end);
    assert(t[len - 2] == .assignment);

    const pos = data[len - 2].assignment;
    t[len - 2] = .end;
    data[len - 2] = .{ .end = data[len - 1].end - 1 };

    ast.nodes.shrinkRetainingCapacity(ast.nodes.len() - 1);

    return .{ @enumFromInt(len - 3), pos };
}

pub fn tags(ast: *const Ast) []Node.Tag {
    return ast.nodes.items(.tag);
}

pub fn payloads(ast: *const Ast) []Node.Payload {
    return ast.nodes.items(.data);
}

pub const ParseError = Parser.ParseError;

// TODO: Make these u64
pub const String = extern struct {
    start: u32,
    end: u32,
};

comptime {
    assert(@sizeOf(Node.Payload) <= 8);
}

pub const Node = extern struct {
    tag: Tag,
    data: Payload,

    pub const Index = NodeList.Index;

    pub const Payload = blk: {
        var t = @typeInfo(Tagged).@"union";
        t.layout = .@"extern";
        t.tag_type = null;
        break :blk @Type(.{ .@"union" = t });
    };

    pub const Builtin = packed struct(u64) {
        tag: Builtin.Tag,
        arg_count: u27,
        first_arg: u32,

        pub const Tag = enum(u5) {
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

            pub fn format(t: Builtin.Tag, w: *std.io.Writer) !void {
                switch (t) {
                    .count_all => try w.writeAll("countAll"),
                    else => try w.writeAll(@tagName(t)),
                }
            }
        };
    };

    pub fn init(comptime t: Tag, data: @FieldType(Payload, @tagName(t))) Node {
        return .{
            .tag = t,
            .data = @unionInit(Payload, @tagName(t), data),
        };
    }

    pub inline fn get(n: Node) Tagged {
        switch (n.tag) {
            inline else => |t| {
                const field = @tagName(t);
                return @unionInit(Tagged, field, @field(n.data, field));
            },
        }
    }

    pub const Tagged = union(Tag) {
        /// Stores the number of nodes in the AST.
        end: u64,
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

        pub fn isSingle(t: Tag) bool {
            return switch (t) {
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

        pub fn isCommutative(t: Tag) bool {
            return switch (t) {
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

        pub fn precedence(t: Tag) i8 {
            return switch (t) {
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
};

pub fn parseFromExpression(
    ast: *Ast,
    gpa: std.mem.Allocator,
    src: []const u8,
    options: Parser.Options,
) !Parser.Result {
    return Parser.parseFromExpression(ast, gpa, src, options);
}

pub inline fn printFromIndex(
    ast: *const Ast,
    index: Node.Index,
    writer: *std.io.Writer,
    strings: []const u8,
) std.io.Writer.Error!void {
    const n = ast.nodes.get(index);
    return ast.printFromNode(index, n, writer, strings);
}

pub fn printFromNode(
    ast: *const Ast,
    index: Node.Index,
    data: Node,
    writer: *std.io.Writer,
    strings: []const u8,
) std.io.Writer.Error!void {
    // On the left-hand side, expressions involving operators with lower precedence need
    // parentheses.

    // On the right-hand side, expressions involving operators with lower precedence, or
    // non-commutative operators with the same precedence need to be surrounded by parentheses.
    switch (data.get()) {
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
            const rhs = index.subi(1);
            const lhs = ast.leftMostChild(rhs).subi(1);
            try ast.printFromIndex(lhs, writer, strings);
            try writer.writeAll(" # ");
            try ast.printFromIndex(rhs, writer, strings);
        },
        .end => {
            try ast.printFromIndex(index.subi(1), writer, strings);
        },
        .assignment => |pos| {
            try writer.print("let {f} = ", .{pos});
            try ast.printFromIndex(index.subi(1), writer, strings);
        },
        inline .plus, .minus, .not, .reference, .dereference => |_, t| {
            const n = index.subi(1);
            const rhs = ast.nodes.get(n);

            const byte = switch (t) {
                .plus => '+',
                .minus => '-',
                .not => '!',
                .reference => '&',
                .dereference => '*',
                else => comptime unreachable,
            };

            try writer.writeByte(byte);
            if (rhs.tag.isSingle()) {
                try ast.printFromNode(n, rhs, writer, strings);
            } else {
                try writer.writeByte('(');
                try ast.printFromNode(n, rhs, writer, strings);
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

            const rhs = index.subi(1);
            const lhs = ast.leftMostChild(rhs).subi(1);
            try ast.printFromIndex(lhs, writer, strings);
            try writer.writeAll(" " ++ str ++ " ");
            const rhs_node = ast.nodes.get(rhs);
            const prec = comptime t.precedence();
            const rprec = rhs_node.tag.precedence();
            if (rprec < prec or rprec == prec and (!t.isCommutative() or !rhs_node.tag.isCommutative())) {
                try writer.writeByte('(');
                try ast.printFromNode(rhs, rhs_node, writer, strings);
                try writer.writeByte(')');
            } else {
                try ast.printFromNode(rhs, rhs_node, writer, strings);
            }
        },
        .range, .invalidated_range, .dynamic_range => {
            const rhs = index.subi(1);
            const lhs = ast.leftMostChild(rhs).subi(1);
            try ast.printFromIndex(lhs, writer, strings);
            try writer.writeByte(':');
            try ast.printFromIndex(rhs, writer, strings);
        },

        .builtin => |b| {
            switch (b.tag) {
                .pi, .e => {
                    try writer.print("@{f}", .{b.tag});
                    return;
                },
                inline else => |t| try writer.print("@{f}(", .{t}),
            }
            var iter = ast.argIteratorForwards(index.subi(b.first_arg), index);
            if (iter.next()) |arg_index| {
                try ast.printFromIndex(arg_index, writer, strings);
            }
            while (iter.next()) |arg_index| {
                try writer.writeAll(", ");
                try ast.printFromIndex(arg_index, writer, strings);
            }
            try writer.writeByte(')');
        },
    }
}

/// Returns the root index of each argument of a function, backwards.
pub const ArgIterator = struct {
    ast: Ast,
    first_arg: Node.Index,
    index: Node.Index,

    pub fn next(iter: *ArgIterator) ?Node.Index {
        if (iter.index.le(iter.first_arg)) return null;
        const ret = iter.index.subi(1);
        iter.index = iter.ast.leftMostChild(ret);
        return ret;
    }
};

pub fn argIterator(ast: Ast, start: Node.Index, end: Node.Index) ArgIterator {
    return .{
        .ast = ast,
        .first_arg = start,
        .index = end,
    };
}

/// Returns the root index of each argument of a function, forwards. Prefer to use `ArgIterator`
/// for performance reasons.
pub const ArgIteratorForwards = struct {
    ast: Ast,
    end: Node.Index,
    index: Node.Index,
    backwards_iter: ArgIterator,
    buffer: [32]Node.Index = undefined,
    i: usize = 0,

    pub fn next(iter: *ArgIteratorForwards) ?Node.Index {
        if (@intFromEnum(iter.index) >= @intFromEnum(iter.end)) return null;
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

pub fn argIteratorForwards(ast: *const Ast, start: Node.Index, end: Node.Index) ArgIteratorForwards {
    return .{
        .ast = ast.*,
        .end = end,
        .index = start,
        .backwards_iter = ast.argIterator(start.addi(1), end),
    };
}

pub const FormatData = struct {
    ast: *const Ast,
    root: Node.Index,
};

pub fn exprLen(ast: *const Ast, root: Node.Index) usize {
    assert(ast.tag(root.addi(1)) == .end);
    return ast.payload(root.addi(1)).end;
}

pub fn exprStart(ast: *const Ast, root: Node.Index) Node.Index {
    const len = ast.exprLen(root);
    return root.subi(len - 1);
}

pub fn exprSlice(ast: *const Ast, root: Node.Index) NodeList {
    const start = ast.exprStart(root);
    const len = ast.exprLen(root);
    return ast.nodes.subslice(@intFromEnum(start), len);
}

/// Slice of the expression's AST nodes including the sentinel node.
pub fn exprSliceEnd(ast: *const Ast, root: Node.Index) NodeList {
    var ret = ast.exprSlice(root);
    ret.slice.len += 1;
    assert(ret.len() <= ast.nodes.capacity());
    return ret;
}

pub fn print(
    ast: *const Ast,
    root: Node.Index,
    writer: *std.io.Writer,
) std.io.Writer.Error!void {
    if (root == .invalid) return;
    return ast.printFromIndex(root, writer, ast.strings.items);
}

pub fn leftMostChild(
    ast: *const Ast,
    index: Node.Index,
) Node.Index {
    return switch (ast.node(index)) {
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
            const rhs = index.subi(1);
            const lhs = ast.leftMostChild(rhs).subi(1);
            return ast.leftMostChild(lhs);
        },
        .builtin => |b| if (b.first_arg != 0)
            ast.leftMostChild(index.subi(b.first_arg))
        else
            index,
        .minus,
        .plus,
        .not,
        .reference,
        .dereference,
        .assignment,
        .end,
        => ast.leftMostChild(index.subi(1)),
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

pub const Value = union(enum) {
    none,
    number: f64,
    string: StringResult,
    cell: Position,
    range: Range,

    pub const Range = struct {
        rect: Rect,
        map: Node.Index = .invalid,

        pub fn format(r: Range, w: *std.io.Writer) !void {
            try r.rect.format(w);
        }

        pub fn eql(a: Range, b: Range) bool {
            return a.rect.eql(b.rect);
        }
    };

    pub fn boolean(res: Value, _: *const Sheet) bool {
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

pub const StackFrame = union(enum) {
    value: Value,
    cell_literal: Position,
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
        ast: Ast,
        tags: []const Node.Tag,
        data: []const Node.Payload,

        arena: Allocator,
        sheet: *Sheet,
        context: Context,
        stack: std.ArrayList(StackFrame) = .empty,
        strings: []const u8,

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

        fn toNumber(eval: *const @This(), res: Value, none_value: f64) !f64 {
            return try eval.toNumberOrNull(res) orelse none_value;
        }

        fn toNumberOrNull(_: *const @This(), res: Value) !?f64 {
            return switch (res) {
                .none => null,
                .number => |n| n,
                .string => |str| std.fmt.parseFloat(f64, str.bytes()) catch error.InvalidCoercion,
                .cell, .range => error.InvalidCoercion,
            };
        }

        /// Coerces `res` to a number, dereferencing one level of reference if required.
        fn toNumberDeref(eval: *const @This(), res: Value) !?f64 {
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

        fn push(eval: *@This(), res: StackFrame) !void {
            try eval.stack.append(eval.arena, res);
        }

        fn pop(eval: *@This(), result_type: ResultType) !Value {
            const ret = eval.stack.pop().?;
            return switch (ret) {
                .cell_literal => |pos| switch (result_type) {
                    .reference => .{ .cell = pos },
                    .any => try eval.context.evalCellByPos(pos),
                },
                .value => |v| v,
            };
        }

        fn evaluate(eval: *@This(), root: Node.Index) Error!void {
            const nodes = eval.ast.exprSlice(root);
            for (0..nodes.len()) |i| switch (nodes.geti(i).get()) {
                .end => break,
                .identifier => {
                    @panic("TODO");
                },
                .number => |n| try eval.push(.{ .value = .{ .number = n } }),
                .rel_rel, .rel_abs, .abs_rel, .abs_abs => |pos| {
                    try eval.push(.{ .cell_literal = pos });
                },
                .minus => {
                    const rhs = try eval.pop(.any);
                    try eval.push(.{ .value = .{ .number = -(try eval.toNumber(rhs, 0)) } });
                },
                .plus => {
                    const rhs = try eval.pop(.any);
                    try eval.push(.{ .value = .{ .number = @abs(try eval.toNumber(rhs, 0)) } });
                },
                .not => {
                    const rhs = try eval.pop(.any);
                    try eval.push(.{ .value = .{
                        .number = @floatFromInt(@intFromBool(!rhs.boolean(eval.sheet))),
                    } });
                },
                .reference => {
                    const arg = try eval.pop(.reference);
                    try eval.push(.{ .value = .{ .cell = arg.cell } });
                },
                .dereference => {
                    const arg = try eval.pop(.reference);
                    if (arg != .cell)
                        return error.NotEvaluable;

                    const pos = arg.cell;
                    const res = try eval.context.evalCellByPos(pos);
                    try eval.push(.{ .value = res });
                },
                inline .add, .sub, .mul, .div, .mod, .pow => |_, t| {
                    const rhs = try eval.pop(.any);
                    const lhs = try eval.pop(.any);
                    const l = try eval.toNumber(lhs, 0);
                    const r = try eval.toNumber(rhs, 0);
                    const res: Value = .{ .number = switch (t) {
                        .add => l + r,
                        .sub => l - r,
                        .mul => l * r,
                        .div => {
                            if (r == 0) return error.DivideByZero;
                            try eval.push(.{ .value = .{ .number = l / r } });
                            continue;
                        },
                        .mod => {
                            if (r <= 0) return error.DivideByZero;
                            try eval.push(.{ .value = .{ .number = @rem(l, r) } });
                            continue;
                        },
                        .pow => std.math.pow(f64, l, r),
                        else => comptime unreachable,
                    } };
                    try eval.push(.{ .value = res });
                },
                // and/or have the same semantics as Lua's and/or operators.
                .logical_and => {
                    const rhs = try eval.pop(.any);
                    const lhs = try eval.pop(.any);
                    const res: StackFrame =
                        if (lhs.boolean(eval.sheet))
                            .{ .value = rhs }
                        else
                            .{ .value = .{ .number = 0 } };

                    try eval.push(res);
                },
                .logical_or => {
                    const rhs = try eval.pop(.any);
                    const lhs = try eval.pop(.any);
                    const res = if (lhs.boolean(eval.sheet)) lhs else rhs;

                    try eval.push(.{ .value = res });
                },
                inline .equals, .not_equals => |_, t| {
                    const rhs = try eval.pop(.any);
                    const lhs = try eval.pop(.any);
                    const false_value = @intFromBool(t != .equals);
                    if (@as(std.meta.Tag(Value), lhs) != rhs) {
                        try eval.push(.{ .value = .{ .number = false_value } });
                        continue;
                    }

                    const n = switch (lhs) {
                        .none => true,
                        .number => |n| n == rhs.number,
                        .string => std.mem.eql(u8, lhs.string.bytes(), rhs.string.bytes()),
                        .cell => |pos| pos.eql(rhs.cell),
                        .range => |r| r.eql(rhs.range),
                    };

                    const b = switch (t) {
                        .equals => n,
                        .not_equals => !n,
                        else => comptime unreachable,
                    };

                    try eval.push(.{ .value = .{ .number = @floatFromInt(@intFromBool(b)) } });
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

                    try eval.push(.{ .value = .{ .number = @floatFromInt(@intFromBool(n)) } });
                },

                .builtin => |b| try eval.push(.{ .value = switch (b.tag) {
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
                } }),

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
                    try eval.push(.{ .value = .{ .string = .{ .slice = try aw.toOwnedSlice() } } });
                },
                .range, .dynamic_range => {
                    const rhs = try eval.pop(.reference);
                    const lhs = try eval.pop(.reference);
                    const invalid_args = lhs != .cell or rhs != .cell;

                    if (invalid_args)
                        return error.NotEvaluable;

                    try eval.push(.{ .value = .{
                        .range = .{ .rect = .initNormalizePos(lhs.cell, rhs.cell) },
                    } });
                },
                .string_literal => |str| try eval.push(.{ .value = .{ .string = .{
                    .slice = eval.strings[str.start..str.end],
                } } }),
                .invalidated_pos,
                .invalidated_range,
                .assignment,
                => return error.NotEvaluable,
            };
        }

        fn formatStringAlloc(eval: *const @This(), res: Value) ![]u8 {
            var aw: std.io.Writer.Allocating = .init(eval.arena);
            eval.formatString(res, &aw.writer) catch |err| switch (err) {
                error.WriteFailed => return error.OutOfMemory,
                else => |e| return e,
            };
            return aw.toOwnedSlice();
        }

        fn formatString(_: *const @This(), res: Value, w: *std.io.Writer) !void {
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
        fn toPosRange(eval: *const @This(), lhs: Node.Index, rhs: Node.Index) Position.Rect {
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
                    inline .number, .string => |_, t| {
                        switch (operation) {
                            .all => total += 1,
                            .numbers => if (t == .number) {
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
    ast: *const Ast,
    root_node: Node.Index,
    sheet: *Sheet,
    /// Strings required by the expression. String literal nodes contain offsets
    /// into this buffer. If the expression has no string literals then this
    /// argument can be left as "".
    /// Instance of a type which has the method uevalCell`,
    /// which evaluates the cell at the given position.
    context: anytype,
) !Value {
    var arena: std.heap.ArenaAllocator = .init(sheet.gpa);
    defer arena.deinit();

    var ctx: EvalContext(@TypeOf(context)) = .{
        .ast = ast.*,
        .tags = ast.nodes.items(.tag),
        .data = ast.nodes.items(.data),

        .arena = arena.allocator(),
        .sheet = sheet,
        .context = context,
        .strings = ast.strings.items,
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

pub fn countDependencies(ast: *const Ast, root: Node.Index) usize {
    var ctx: CountDependenciesContext = .{};
    ast.traverseDependencies(root, &ctx, CountDependenciesContext.func);
    return ctx.total;
}

pub fn traverseDependencies(
    ast: *const Ast,
    root: Node.Index,
    ctx: anytype,
    func: fn (@TypeOf(ctx), Rect) void,
) void {
    if (root == .invalid) return;

    var traverse: TraverseDependencies(@TypeOf(ctx), func) = .{
        .ast = ast.*,
        .user_ctx = ctx,
    };
    traverse.traverse(root, .value, .no_deref);
}

fn TraverseDependencies(Context: type, func: fn (Context, Rect) void) type {
    return struct {
        ast: Ast,
        user_ctx: Context,

        fn traverse(
            self: *const @This(),
            index: Node.Index,
            /// Whether the context treats a cell literal as a value or a reference. If treated as a value,
            /// the cell literal will be added to the dependency graph.
            ctx: Parser.ExpressionContext,
            /// Whether the context will automatically dereference a reference. If a reference to a cell
            /// literal is automatically dereferenced, it will be added to the dependency graph.
            deref: enum { deref, no_deref },
        ) void {
            const ast = self.ast;

            switch (self.ast.node(index)) {
                .assignment, .end => {
                    self.traverse(index.subi(1), ctx, .no_deref);
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
                        const rhs = index.subi(1);
                        const lhs = ast.leftMostChild(rhs).subi(1);
                        const tl = switch (ast.tag(lhs)) {
                            .reference => switch (ast.tag(lhs.subi(1))) {
                                .rel_rel,
                                .rel_abs,
                                .abs_rel,
                                .abs_abs,
                                => ast.payload(lhs.subi(1)).rel_rel,
                                else => unreachable,
                            },
                            .rel_rel, .rel_abs, .abs_rel, .abs_abs => ast.payload(lhs).rel_rel,
                            else => unreachable,
                        };
                        const br = switch (ast.tag(rhs)) {
                            .reference => switch (ast.tag(rhs.subi(1))) {
                                .rel_rel,
                                .rel_abs,
                                .abs_rel,
                                .abs_abs,
                                => ast.payload(rhs.subi(1)).rel_rel,
                                else => unreachable,
                            },
                            .rel_rel, .rel_abs, .abs_rel, .abs_abs => ast.payload(rhs).rel_rel,
                            else => unreachable,
                        };
                        func(self.user_ctx, .initNormalizePos(tl, br));
                    }
                },
                .dynamic_range => {
                    const rhs = index.subi(1);
                    const lhs = ast.leftMostChild(rhs).subi(1);
                    self.traverse(lhs, .reference, .no_deref);
                    self.traverse(rhs, .reference, .no_deref);
                },
                .reference => switch (deref) {
                    .deref => self.traverse(index.subi(1), .value, .no_deref),
                    .no_deref => {},
                },
                .dereference => {
                    self.traverse(index.subi(1), .reference, .deref);
                },
                .minus, .plus, .not => {
                    self.traverse(index.subi(1), .value, .no_deref);
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
                    const rhs = index.subi(1);
                    const lhs = ast.leftMostChild(rhs).subi(1);
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
                        var iter = self.ast.argIterator(index.subi(b.first_arg), index);
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
                        self.traverse(index.subi(b.first_arg), .reference, .deref);
                    },
                    .width,
                    .height,
                    => {
                        self.traverse(index.subi(b.first_arg), .value, .no_deref);
                    },
                },
            }
        }
    };
}

/// Returns true if the given node is a cell literal or a reference to a cell literal.
pub fn isDynamicReference(nodes: NodeList, index: Node.Index) bool {
    return switch (nodes.item(index, .tag)) {
        .reference => switch (nodes.item(index.subi(1), .tag)) {
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
    start: Node.Index,
    i: usize,

    pub fn init(nodes: NodeList, start: Node.Index) ExpressionIterator {
        return .{
            .tags = nodes.items(.tag),
            .data = nodes.items(.data),
            .start = start,
            .i = nodes.len(),
        };
    }

    pub fn prev(iter: *ExpressionIterator) ?Node.Index {
        if (iter.i <= @intFromEnum(iter.start)) return null;
        iter.i -= 1;
        assert(iter.tags[iter.i] == .end);
        const len = iter.data[iter.i].end;
        const ret = iter.i - 1;
        iter.i -= len;
        return @enumFromInt(ret);
    }
};

test "Parse and Eval Expression" {
    const t = std.testing;
    const Context = struct {
        pub fn evalCellByHandle(_: @This(), _: Sheet.Cell.Handle) !Value {
            unreachable;
        }

        pub fn evalCellByPos(_: @This(), _: Position) !Value {
            unreachable;
        }
    };

    const Error = EvalContext(void).Error || Parser.ParseError;

    const testExpr = struct {
        fn func(expected: Error!f64, src: []const u8) !void {
            var sheet = try Sheet.init(t.allocator);
            defer sheet.deinit();

            const expr = sheet.parseFromExpression(src) catch |err| {
                return if (err != expected) err else {};
            };

            const res = sheet.ast.evaluate(expr.root, &sheet, Context{}) catch |err| {
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
    const testSheetExpr = struct {
        fn testSheetExpr(expected: f64, src: []const u8) !void {
            var sheet = try Sheet.init(t.allocator);
            defer sheet.deinit();

            try sheet.setCell(try Position.fromAddress("A0"), try sheet.parseFromExpression("0"), .{});
            try sheet.setCell(try Position.fromAddress("B0"), try sheet.parseFromExpression("100"), .{});
            try sheet.setCell(try Position.fromAddress("A1"), try sheet.parseFromExpression("500"), .{});
            try sheet.setCell(try Position.fromAddress("B1"), try sheet.parseFromExpression("333.33"), .{});

            const expr = try sheet.parseFromExpression(src);

            try sheet.update();
            const res = try sheet.ast.evaluate(expr.root, &sheet, &sheet);
            try std.testing.expectApproxEqRel(expected, res.number, 0.0001);
        }
    }.testSheetExpr;

    try testSheetExpr(0, "@sum(a0:a0)");
    try testSheetExpr(100, "@sum(a0:b0)");
    try testSheetExpr(500, "@sum(a0:a1)");
    try testSheetExpr(933.33, "@sum(a0:b1)");
    try testSheetExpr(933.33, "@sum(a0:z10)");
    try testSheetExpr(833.33, "@sum(a1:z10)");
    try testSheetExpr(0, "@sum(c3:z10)");
    try testSheetExpr(953.33, "@sum(5, a0:z10, 5, 10)");
    try testSheetExpr(35, "@sum(5, 30 / 2, c3:z10, 5, 10)");
    try t.expectError(error.UnexpectedToken, testSheetExpr(0, "@sum()"));

    try testSheetExpr(0, "@prod(a0:a0)");
    try testSheetExpr(0, "@prod(a0:b0)");
    try testSheetExpr(0, "@prod(a0:a1)");
    try testSheetExpr(0, "@prod(a0:b1)");
    try testSheetExpr(166665, "@prod(a1:b1)");
    try testSheetExpr(166665, "@prod(a1:z10)");
    try testSheetExpr(333.33, "@prod(b1:z10)");
    try testSheetExpr(0, "@prod(100, -1, a0:z10, 50)");
    try testSheetExpr(-166665000, "@prod(100, -1, b0:b1, 50)");
    try t.expectError(error.UnexpectedToken, testSheetExpr(0, "@prod()"));

    try testSheetExpr(0, "@avg(a0:a0)");
    try testSheetExpr(50, "@avg(a0:b0)");
    try testSheetExpr(250, "@avg(a0:a1)");
    try testSheetExpr(233.3325, "@avg(a0:b1)");
    try testSheetExpr(135.47571428571428571428, "@avg(5, 5, a0:b1, 5)");
    try t.expectError(error.UnexpectedToken, testSheetExpr(0, "@avg()"));

    try testSheetExpr(0, "@max(a0:a0)");
    try testSheetExpr(100, "@max(a0:b0)");
    try testSheetExpr(500, "@max(a0:a1)");
    try testSheetExpr(500, "@max(a0:b1)");
    try testSheetExpr(100, "@max(a0:z0)");
    try testSheetExpr(500, "@max(a0:z10)");
    try testSheetExpr(0, "@max(c3:z10)");
    try testSheetExpr(3, "@max(3, c3:z10, 1, 2)");
    try testSheetExpr(500, "@max(3, a0:b1, 1, 2)");
    try t.expectError(error.UnexpectedToken, testSheetExpr(0, "@max()"));

    try testSheetExpr(0, "@min(a0:a0)");
    try testSheetExpr(0, "@min(a0:b0)");
    try testSheetExpr(0, "@min(a0:a1)");
    try testSheetExpr(0, "@min(a0:b1)");
    try testSheetExpr(333.33, "@min(a1:z10)");
    try testSheetExpr(0, "@min(c3:z10)");
    try testSheetExpr(1, "@min(3, c3:z10, 1, 2)");
    try testSheetExpr(0, "@min(3, a0:b1, 1, 2)");
    try t.expectError(error.UnexpectedToken, testSheetExpr(0, "@min()"));
}

test "Print" {
    const t = std.testing;

    const cases = .{
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

    inline for (cases) |d| {
        const src, const expected = d;
        const expr = try sheet.parseFromExpression(src);

        var buf: [4096]u8 = undefined;
        var fixed: std.io.Writer = .fixed(&buf);
        try sheet.ast.print(expr.root, &fixed);
        try t.expectEqualStrings(expected, fixed.buffered());
    }

    inline for (data2) |src| {
        const expr = try sheet.parseFromExpression(src);

        var buf: [4096]u8 = undefined;
        var fixed: std.io.Writer = .fixed(&buf);
        try sheet.ast.print(expr.root, &fixed);
        try t.expectEqualStrings(src, fixed.buffered());
    }
}
