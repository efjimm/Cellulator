//! Basic expression parser. Does not attempt error recovery and returns immediately on fatal
//! errors. Contains a `MultiArrayList` of `Node`s that is sorted in reverse topological order.
// TODO: Pretty much all of this file can be moved to Sheet.zig

const std = @import("std");
const Position = @import("Position.zig").Position;
const Sheet = @import("Sheet.zig");
const Reference = Sheet.Reference;
const PosInt = Position.Int;
const MultiArrayList = @import("multi_array_list.zig").MultiArrayList;

const Tokenizer = @import("Tokenizer.zig");
const Parser = @import("Parser.zig");
const BinaryOperator = Parser.BinaryOperator;
const Builtin = Parser.Builtin;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const ParseError = Parser.ParseError;

pub const String = struct {
    start: u32,
    end: u32,
};

pub const Node = union(enum) {
    number: f64,
    column: PosInt,
    pos: Position,
    assignment: BinaryOperator,
    concat: BinaryOperator,
    add: BinaryOperator,
    sub: BinaryOperator,
    mul: BinaryOperator,
    div: BinaryOperator,
    mod: BinaryOperator,
    builtin: Builtin,
    range: BinaryOperator,
    string_literal: String,

    ref_abs_abs: Reference,
    ref_rel_abs: Reference,
    ref_abs_rel: Reference,
    ref_rel_rel: Reference,

    pub const Tag = std.meta.Tag(Node);
    pub const Payload = MultiArrayList(Node).Elem.Bare;

    pub fn isRef(n: Node) bool {
        return isRefTag(n);
    }

    pub fn isRefTag(tag: std.meta.Tag(Node)) bool {
        return switch (tag) {
            .ref_abs_abs, .ref_rel_abs, .ref_abs_rel, .ref_rel_rel => true,
            else => false,
        };
    }
};

pub const NodeList = MultiArrayList(Node);
pub const NodeSlice = NodeList.Slice;
pub const Index = packed struct {
    n: u32,

    pub fn from(n: u32) Index {
        return .{ .n = n };
    }

    pub fn isValid(n: Index) bool {
        return n == .invalid;
    }

    pub const invalid: Index = .{ .n = std.math.maxInt(u32) };
};

comptime {
    const u = @typeInfo(Node).@"union";
    for (u.fields) |field| {
        if (@sizeOf(field.type) > 8) {
            @compileError("Ast.Node field greater than 8 bytes");
        }
    }
}

pub fn dupeStrings(
    allocator: Allocator,
    source: []const u8,
    nodes: NodeSlice,
    root_node: Index,
) Allocator.Error![]const u8 {
    assert(root_node.n < nodes.len);
    const start = leftMostChild(nodes, root_node);
    assert(start.n <= root_node.n);

    const tags = nodes.items(.tags)[start.n .. root_node.n + 1];
    const data = nodes.items(.data)[start.n .. root_node.n + 1];

    var nstrings: u32 = 0;
    const len = blk: {
        var len: u32 = 0;
        for (tags, 0..) |tag, i| {
            if (tag == .string_literal) {
                const str = data[i].string_literal;
                len += str.end - str.start;
                nstrings += 1;
            }
        }
        break :blk len;
    };

    if (len == 0) {
        if (nstrings != 0) {
            for (tags, 0..) |tag, i| {
                if (tag == .string_literal) {
                    data[i].string_literal = .{
                        .start = 0,
                        .end = 0,
                    };
                }
            }
        }

        return "";
    }

    var list = try std.ArrayListUnmanaged(u8).initCapacity(allocator, len);

    // Append contents of all string literals to the list, and update their `start` and `end`
    // indices to be into this list.
    for (tags, 0..) |tag, i| {
        if (tag == .string_literal) {
            const str = &data[i].string_literal;
            const bytes = source[str.start..str.end];
            str.start = @intCast(list.items.len);
            str.end = @intCast(str.start + bytes.len);
            list.appendSliceAssumeCapacity(bytes);
        }
    }
    return list.toOwnedSlice(allocator);
}

pub fn fromSource(sheet: *Sheet, source: []const u8) ParseError!Index {
    var parser = Parser.init(
        sheet.allocator,
        .init(source),
        .{ .nodes = sheet.ast_nodes.toMultiArrayList() },
    );

    const old_len = sheet.ast_nodes.len;

    // The parser could re-allocate the underlying nodes
    defer sheet.ast_nodes = parser.nodes.slice();
    errdefer sheet.ast_nodes.len = old_len;

    try parser.parse();

    return .from(parser.nodes.len - 1);
}

pub fn fromExpression(sheet: *Sheet, source: []const u8) ParseError!Index {
    const tokenizer = Tokenizer.init(source);

    var parser = Parser.init(
        sheet.allocator,
        tokenizer,
        .{ .nodes = sheet.ast_nodes.toMultiArrayList() },
    );

    const old_len = sheet.ast_nodes.len;

    // The parser could re-allocate the underlying nodes
    defer sheet.ast_nodes = parser.nodes.slice();
    errdefer sheet.ast_nodes.len = old_len;

    _ = try parser.parseExpression();
    _ = try parser.expectToken(.eof);

    return .from(parser.nodes.len - 1);
}

pub inline fn printFromIndex(
    nodes: NodeSlice,
    sheet: *Sheet,
    index: Index,
    writer: anytype,
    strings: []const u8,
) @TypeOf(writer).Error!void {
    const node = nodes.get(index.n);
    return printFromNode(nodes, sheet, index, node, writer, strings);
}

pub fn printFromNode(
    nodes: NodeSlice,
    sheet: *Sheet,
    index: Index,
    node: Node,
    writer: anytype,
    strings: []const u8,
) @TypeOf(writer).Error!void {
    // On the left-hand side, expressions involving operators with lower precedence need
    // parentheses.

    // On the right-hand side, expressions involving operators with lower precedence, or
    // non-commutative operators with the same precedence need to be surrounded by parentheses.
    switch (node) {
        .number => |n| try writer.print("{d}", .{n}),
        .column => |col| try Position.writeColumnAddress(col, writer),
        .pos => |pos| try pos.writeCellAddress(writer),
        .ref_abs_abs, .ref_rel_abs, .ref_abs_rel, .ref_rel_rel => |ref| {
            try ref.resolve(sheet).writeCellAddress(writer);
        },

        .string_literal => |str| {
            try writer.print("\"{s}\"", .{strings[str.start..str.end]});
        },
        .concat => |b| {
            try printFromIndex(nodes, sheet, b.lhs, writer, strings);
            try writer.writeAll(" # ");
            try printFromIndex(nodes, sheet, b.rhs, writer, strings);
        },
        .assignment => |b| {
            try writer.writeAll("let ");
            try printFromIndex(nodes, sheet, b.lhs, writer, strings);
            try writer.writeAll(" = ");
            try printFromIndex(nodes, sheet, b.rhs, writer, strings);
        },
        .add => |b| {
            try printFromIndex(nodes, sheet, b.lhs, writer, strings);
            try writer.writeAll(" + ");
            const rhs = nodes.get(b.rhs.n);
            switch (rhs) {
                .sub => {
                    try writer.writeByte('(');
                    try printFromNode(nodes, sheet, b.rhs, rhs, writer, strings);
                    try writer.writeByte(')');
                },
                else => {
                    try printFromNode(nodes, sheet, b.rhs, rhs, writer, strings);
                },
            }
        },
        .sub => |b| {
            try printFromIndex(nodes, sheet, b.lhs, writer, strings);
            try writer.writeAll(" - ");

            const rhs = nodes.get(b.rhs.n);
            switch (rhs) {
                .add, .sub => {
                    try writer.writeByte('(');
                    try printFromNode(nodes, sheet, b.rhs, rhs, writer, strings);
                    try writer.writeByte(')');
                },
                else => {
                    try printFromNode(nodes, sheet, b.rhs, rhs, writer, strings);
                },
            }
        },
        .mul => |b| {
            const lhs = nodes.get(b.lhs.n);
            switch (lhs) {
                .add, .sub => {
                    try writer.writeByte('(');
                    try printFromNode(nodes, sheet, b.lhs, lhs, writer, strings);
                    try writer.writeByte(')');
                },
                else => try printFromNode(nodes, sheet, b.lhs, lhs, writer, strings),
            }
            try writer.writeAll(" * ");
            const rhs = nodes.get(b.rhs.n);
            switch (rhs) {
                .add, .sub, .div, .mod => {
                    try writer.writeByte('(');
                    try printFromNode(nodes, sheet, b.rhs, rhs, writer, strings);
                    try writer.writeByte(')');
                },
                else => try printFromNode(nodes, sheet, b.rhs, rhs, writer, strings),
            }
        },
        .div => |b| {
            const lhs = nodes.get(b.lhs.n);
            switch (lhs) {
                .add, .sub => {
                    try writer.writeByte('(');
                    try printFromNode(nodes, sheet, b.lhs, lhs, writer, strings);
                    try writer.writeByte(')');
                },
                else => try printFromNode(nodes, sheet, b.lhs, lhs, writer, strings),
            }
            try writer.writeAll(" / ");
            const rhs = nodes.get(b.rhs.n);
            switch (rhs) {
                .add, .sub, .mul, .div, .mod => {
                    try writer.writeByte('(');
                    try printFromNode(nodes, sheet, b.rhs, rhs, writer, strings);
                    try writer.writeByte(')');
                },
                else => try printFromNode(nodes, sheet, b.rhs, rhs, writer, strings),
            }
        },
        .mod => |b| {
            const lhs = nodes.get(b.lhs.n);
            switch (lhs) {
                .add, .sub => {
                    try writer.writeByte('(');
                    try printFromNode(nodes, sheet, b.lhs, lhs, writer, strings);
                    try writer.writeByte(')');
                },
                else => try printFromNode(nodes, sheet, b.lhs, lhs, writer, strings),
            }
            try writer.writeAll(" % ");
            const rhs = nodes.get(b.rhs.n);
            switch (rhs) {
                .add, .sub, .mul, .div, .mod => {
                    try writer.writeByte('(');
                    try printFromNode(nodes, sheet, b.rhs, rhs, writer, strings);
                    try writer.writeByte(')');
                },
                else => try printFromNode(nodes, sheet, b.rhs, rhs, writer, strings),
            }
        },
        .range => |b| {
            try printFromIndex(nodes, sheet, b.lhs, writer, strings);
            try writer.writeByte(':');
            try printFromIndex(nodes, sheet, b.rhs, writer, strings);
        },

        .builtin => |b| {
            switch (b.tag) {
                inline else => |tag| try writer.print("@{s}(", .{@tagName(tag)}),
            }
            var iter = argIteratorForwards(nodes, b.first_arg, index);
            if (iter.next()) |arg_index| {
                try printFromIndex(nodes, sheet, arg_index, writer, strings);
            }
            while (iter.next()) |arg_index| {
                try writer.writeAll(", ");
                try printFromIndex(nodes, sheet, arg_index, writer, strings);
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
    buffer: std.BoundedArray(Index, 32) = .{},

    pub fn next(iter: *ArgIteratorForwards) ?Index {
        if (iter.index.n >= iter.end.n) return null;
        const ret = iter.index;

        if (iter.buffer.len == 0) {
            const first_item = iter.backwards_iter.next() orelse {
                iter.index = iter.end;
                return ret;
            };

            iter.buffer.appendAssumeCapacity(first_item);

            for (1..iter.buffer.capacity()) |_| {
                const item = iter.backwards_iter.next() orelse break;
                iter.buffer.appendAssumeCapacity(item);
            }
        }
        iter.index = iter.buffer.pop();

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

/// Removes all nodes except for the given index and its children
/// Nodes in the list are already sorted in reverse topological order which allows us to overwrite
/// nodes sequentially without loss. This function preserves reverse topological order.
pub fn splice(nodes: *NodeSlice, new_root: Index) Index {
    const old_root: Index = .from(nodes.len - 1);
    const old_first = leftMostChild(nodes.*, old_root);

    const new_first = leftMostChild(nodes.*, new_root);
    const new_len = nodes.len - (new_first.n - old_first.n) - (old_root.n - new_root.n);

    assert(old_first.n <= new_first.n);

    for (
        old_first.n..,
        new_first.n..new_root.n + 1,
    ) |i, j| {
        var n = nodes.get(@intCast(j));
        switch (n) {
            .assignment,
            .concat,
            .add,
            .sub,
            .mul,
            .div,
            .mod,
            .range,
            => |*b| {
                b.lhs.n -= new_first.n - old_first.n;
                b.rhs.n -= new_first.n - old_first.n;
            },
            .builtin => |*b| {
                b.first_arg.n -= new_first.n - old_first.n;
            },
            .string_literal,
            .number,
            .column,
            .pos,
            .ref_abs_abs,
            .ref_rel_abs,
            .ref_abs_rel,
            .ref_rel_rel,
            => {},
        }
        nodes.set(@intCast(i), n);
    }

    nodes.len = new_len;
    return .from(nodes.len - 1);
}

pub fn print(
    nodes: NodeSlice,
    root: Index,
    sheet: *Sheet,
    strings: []const u8,
    writer: anytype,
) @TypeOf(writer).Error!void {
    return printFromIndex(nodes, sheet, root, writer, strings);
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

pub fn leftMostChild(
    nodes: NodeSlice,
    index: Index,
) Index {
    assert(index.n < nodes.len);

    const node = nodes.get(index.n);

    return switch (node) {
        // leaf nodes
        .ref_abs_abs,
        .ref_rel_abs,
        .ref_abs_rel,
        .ref_rel_rel,
        .string_literal,
        .number,
        .column,
        .pos,
        => index,
        // branch nodes
        .assignment,
        .concat,
        .add,
        .sub,
        .mul,
        .div,
        .mod,
        .range,
        => |b| leftMostChild(nodes, b.lhs),
        .builtin => |b| leftMostChild(nodes, b.first_arg),
    };
}

pub const EvalResult = union(enum) {
    none,
    number: f64,
    string: []const u8,

    /// Attempts to coerce `res` to an integer.
    fn toNumber(res: EvalResult, none_value: f64) !f64 {
        return switch (res) {
            .none => none_value,
            .number => |n| n,
            .string => |str| std.fmt.parseFloat(f64, str) catch error.InvalidCoercion,
        };
    }

    fn toNumberOrNull(res: EvalResult) !?f64 {
        return switch (res) {
            .none => null,
            .number => |n| n,
            .string => |str| std.fmt.parseFloat(f64, str) catch error.InvalidCoercion,
        };
    }

    fn toStringAlloc(res: EvalResult, allocator: Allocator) ![]u8 {
        return switch (res) {
            .none => "",
            .number => |n| std.fmt.allocPrint(allocator, "{d}", .{n}),
            .string => |str| allocator.dupe(u8, str),
        };
    }

    fn toString(res: EvalResult, writer: anytype) !void {
        switch (res) {
            .none => {},
            .number => |n| try writer.print("{d}", .{n}),
            .string => |str| try writer.writeAll(str),
        }
    }

    /// Returns the number of bytes required to represent `res` as a string, without
    fn lengthAsString(res: EvalResult) usize {
        return switch (res) {
            .none => 0,
            .number => |n| {
                var counting_writer = std.io.countingWriter(std.io.null_writer);
                const writer = counting_writer.writer();
                writer.print("{d}", .{n}) catch unreachable;
                return @intCast(counting_writer.bytes_written);
            },
            .string => |str| str.len,
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
        allocator: Allocator,
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

            const func = @field(C, "evalCell");
            const info = @typeInfo(@TypeOf(func));
            const ret_info = @typeInfo(info.@"fn".return_type.?);
            break :blk E || ret_info.error_union.error_set;
        };

        // TODO: Pass references to `context.evalCell` instead of positions
        fn eval(
            self: @This(),
            index: Index,
        ) Error!EvalResult {
            const node = self.nodes.get(index.n);

            return switch (node) {
                .number => |n| .{ .number = n },
                .pos => unreachable,
                .ref_abs_abs, .ref_rel_abs, .ref_abs_rel, .ref_rel_rel => |ref| {
                    return try self.context.evalCell(ref);
                },
                .add => |op| {
                    const lhs = try self.eval(op.lhs);
                    const rhs = try self.eval(op.rhs);

                    return .{ .number = try lhs.toNumber(0) + try rhs.toNumber(0) };
                },
                .sub => |op| {
                    const rhs = try self.eval(op.rhs);
                    const lhs = try self.eval(op.lhs);

                    return .{ .number = try lhs.toNumber(0) - try rhs.toNumber(0) };
                },
                .mul => |op| {
                    const rhs = try self.eval(op.lhs);
                    const lhs = try self.eval(op.rhs);
                    return .{ .number = try lhs.toNumber(0) * try rhs.toNumber(0) };
                },
                .div => |op| {
                    const lhs = try self.eval(op.lhs);
                    const rhs = try self.eval(op.rhs);

                    return .{ .number = try lhs.toNumber(0) / try rhs.toNumber(0) };
                },
                .mod => |op| {
                    const lhs = try self.eval(op.lhs);
                    const rhs = try self.eval(op.rhs);

                    return .{ .number = @rem(try lhs.toNumber(0), try rhs.toNumber(0)) };
                },

                .builtin => |b| switch (b.tag) {
                    .sum => .{ .number = try self.evalSum(b.first_arg, index) },
                    .prod => .{ .number = try self.evalProd(b.first_arg, index) },
                    .avg => .{ .number = try self.evalAvg(b.first_arg, index) },
                    .max => .{ .number = try self.evalMax(b.first_arg, index) },
                    .min => .{ .number = try self.evalMin(b.first_arg, index) },
                    .upper => .{ .string = try self.evalUpper(b.first_arg) },
                    .lower => .{ .string = try self.evalLower(b.first_arg) },
                },

                .concat => |op| {
                    const lhs = try self.eval(op.lhs);
                    const rhs = try self.eval(op.rhs);

                    const len = lhs.lengthAsString() + rhs.lengthAsString();
                    const buf = try self.allocator.alloc(u8, len);
                    var fbs = std.io.fixedBufferStream(buf);
                    const writer = fbs.writer();
                    lhs.toString(writer) catch unreachable;
                    rhs.toString(writer) catch unreachable;

                    return .{ .string = buf };
                },
                .string_literal => |str| .{ .string = self.strings[str.start..str.end] },
                .column, .range, .assignment => error.NotEvaluable,
            };
        }

        fn evalUpper(self: @This(), arg: Index) ![]const u8 {
            const str = try (try self.eval(arg)).toStringAlloc(self.allocator);
            for (str) |*c| c.* = std.ascii.toUpper(c.*);
            return str;
        }

        fn evalLower(self: @This(), arg: Index) ![]const u8 {
            const str = try (try self.eval(arg)).toStringAlloc(self.allocator);
            for (str) |*c| c.* = std.ascii.toLower(c.*);
            return str;
        }

        fn evalSum(self: @This(), start: Index, end: Index) !f64 {
            const tags = self.nodes.items(.tags);
            const data = self.nodes.items(.data);

            var iter = argIterator(self.nodes, start, end);
            var total: f64 = 0;

            while (iter.next()) |i| {
                const tag = tags[i.n];
                if (tag == .range) {
                    total += try self.sumRange(data[i.n].range);
                } else {
                    const res = try self.eval(i);
                    total += try res.toNumber(0);
                }
            }

            return total;
        }

        /// Converts an ast range to a position range.
        fn toPosRange(self: @This(), r: BinaryOperator) Position.Rect {
            const data = self.nodes.items(.data);

            assert(self.nodes.get(r.lhs.n).isRef());
            assert(self.nodes.get(r.rhs.n).isRef());

            // We just want the reference data and we don't care about the relative/absolute tag.
            const ref1: *const Reference = @ptrCast(&data[r.lhs.n]);
            const ref2: *const Reference = @ptrCast(&data[r.rhs.n]);

            const p1 = ref1.resolve(self.sheet);
            const p2 = ref2.resolve(self.sheet);
            return Position.Rect.initPos(p1, p2);
        }

        fn sumRange(self: @This(), r: BinaryOperator) !f64 {
            const range = self.toPosRange(r);

            var total: f64 = 0;
            var iter = try self.sheet.cell_tree.searchIterator(self.allocator, range);
            while (try iter.next()) |kv| {
                const res = try self.context.evalCellByPtr(kv.key);
                total += try res.toNumber(0);
            }

            return total;
        }

        fn evalProd(self: @This(), start: Index, end: Index) !f64 {
            const tags = self.nodes.items(.tags);
            const data = self.nodes.items(.data);

            var iter = argIterator(self.nodes, start, end);
            var total: f64 = 1;

            while (iter.next()) |i| {
                const tag = tags[i.n];
                if (tag == .range) {
                    total *= try self.prodRange(data[i.n].range);
                } else {
                    const res = try self.eval(i);
                    total *= try res.toNumber(0);
                }
            }

            return total;
        }

        fn prodRange(self: @This(), r: BinaryOperator) !f64 {
            const range = self.toPosRange(r);

            var total: f64 = 1;
            var iter = try self.sheet.cell_tree.searchIterator(self.allocator, range);

            while (try iter.next()) |kv| {
                const res = try self.context.evalCellByPtr(kv.key);
                total *= try res.toNumber(1);
            }

            return total;
        }

        fn evalAvg(self: @This(), start: Index, end: Index) !f64 {
            const tags = self.nodes.items(.tags);
            const data = self.nodes.items(.data);

            var iter = argIterator(self.nodes, start, end);
            var total: f64 = 0;
            var total_items: Position.HashInt = 0;

            while (iter.next()) |i| {
                if (tags[i.n] == .range) {
                    const r = data[i.n].range;
                    total += try self.sumRange(r);

                    const p1, const p2 = blk: {
                        const r1: *const Reference = @ptrCast(&data[r.lhs.n]);
                        const r2: *const Reference = @ptrCast(&data[r.rhs.n]);
                        break :blk .{
                            r1.resolve(self.sheet),
                            r2.resolve(self.sheet),
                        };
                    };
                    total_items += Position.area(p1, p2);
                } else {
                    const res = try self.eval(i);
                    total += try res.toNumber(0);
                    total_items += 1;
                }
            }

            return total / @as(f64, @floatFromInt(total_items));
        }

        fn evalMax(self: @This(), start: Index, end: Index) !f64 {
            const tags = self.nodes.items(.tags);
            const data = self.nodes.items(.data);

            var iter = argIterator(self.nodes, start, end);
            var max: ?f64 = null;

            while (iter.next()) |i| {
                const m = blk: {
                    if (tags[i.n] == .range) {
                        const r = data[i.n].range;
                        break :blk try self.maxRange(r) orelse continue;
                    } else {
                        const res = try self.eval(i);
                        break :blk try res.toNumberOrNull() orelse continue;
                    }
                };

                if (max == null or m > max.?) max = m;
            }

            return max orelse 0;
        }

        fn maxRange(self: @This(), r: BinaryOperator) !?f64 {
            const range = self.toPosRange(r);

            var max: ?f64 = null;
            var iter = try self.sheet.cell_tree.searchIterator(self.allocator, range);
            while (try iter.next()) |kv| {
                const res = try self.context.evalCellByPtr(kv.key);
                const n = try res.toNumberOrNull() orelse continue;
                if (max == null or n > max.?) max = n;
            }

            return max;
        }

        fn evalMin(self: @This(), start: Index, end: Index) !f64 {
            const tags = self.nodes.items(.tags);
            const data = self.nodes.items(.data);

            var iter = argIterator(self.nodes, start, end);
            var min: ?f64 = null;

            while (iter.next()) |i| {
                const m = blk: {
                    if (tags[i.n] == .range) {
                        const r = data[i.n].range;
                        break :blk try self.minRange(r) orelse continue;
                    } else {
                        const res = try self.eval(i);
                        break :blk try res.toNumberOrNull() orelse continue;
                    }
                };

                if (min == null or m < min.?) min = m;
            }

            return min orelse 0;
        }

        fn minRange(self: @This(), r: BinaryOperator) !?f64 {
            const range = self.toPosRange(r);

            var min: ?f64 = null;
            var iter = try self.sheet.cell_tree.searchIterator(self.allocator, range);
            while (try iter.next()) |kv| {
                const res = try self.context.evalCellByPtr(kv.key);
                const n = try res.toNumberOrNull() orelse continue;
                if (min == null or n < min.?) min = n;
            }

            return min;
        }
    };
}

pub const DynamicEvalResult = union(enum) {
    none,
    number: f64,
    string: [:0]const u8,
};

/// Dynamically typed evaluation of expressions.
pub fn eval(
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
) !DynamicEvalResult {
    var arena = std.heap.ArenaAllocator.init(sheet.allocator);
    defer arena.deinit();

    const ctx = EvalContext(@TypeOf(context)){
        .sheet = sheet,
        .nodes = nodes,
        .allocator = arena.allocator(),
        .strings = strings,
        .context = context,
    };

    const res = try ctx.eval(root_node);

    // TODO: Remove string allocation from arena list and shrink, rather than copying.
    return switch (res) {
        .none => .none,
        .number => |n| .{ .number = n },
        .string => |str| .{ .string = try sheet.allocator.dupeZ(u8, str) },
    };
}

const EvalDynamicError = error{
    InvalidCoercion, // Tried to coerce invalid string to integer
};

test "Parse and Eval Expression" {
    const t = std.testing;
    const Context = struct {
        pub fn evalCell(_: @This(), _: Reference) !EvalResult {
            unreachable;
        }

        pub fn evalCellByPtr(_: @This(), _: *Sheet.Cell) !EvalResult {
            unreachable;
        }
    };

    const Error = EvalContext(void).Error || Parser.ParseError;

    const testExpr = struct {
        fn func(expected: Error!f64, expr: []const u8) !void {
            const sheet = try Sheet.create(t.allocator);
            defer sheet.destroy();

            const expr_root = fromExpression(sheet, expr) catch |err| {
                return if (err != expected) err else {};
            };

            const res = eval(
                sheet.ast_nodes,
                expr_root,
                sheet,
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
            const sheet = try Sheet.create(t.allocator);
            defer sheet.destroy();

            try sheet.setCell(try Position.fromAddress("A0"), "0", try fromExpression(sheet, "0"), .{});
            try sheet.setCell(try Position.fromAddress("B0"), "100", try fromExpression(sheet, "100"), .{});
            try sheet.setCell(try Position.fromAddress("A1"), "500", try fromExpression(sheet, "500"), .{});
            try sheet.setCell(try Position.fromAddress("B1"), "333.33", try fromExpression(sheet, "333.33"), .{});

            const expr_root = try fromExpression(sheet, expr);

            try sheet.anchorAst(expr_root);

            try sheet.update();
            const res = try eval(
                sheet.ast_nodes,
                expr_root,
                sheet,
                "",
                Sheet.EvalContext{ .sheet = sheet },
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

test "Splice" {
    const t = std.testing;

    const Context = struct {
        pub fn evalCell(_: @This(), _: Reference) !EvalResult {
            return .none;
        }

        pub fn evalCellByPtr(_: @This(), _: *Sheet.Cell) !EvalResult {
            return .none;
        }
    };

    const sheet = try Sheet.create(t.allocator);
    defer sheet.destroy();

    const expr_root = try fromSource(sheet, "let a0 = 100 * 3 + 5 / 2 + @avg(1, 10)");
    const root_node = sheet.ast_nodes.get(expr_root.n);

    var spliced_root = splice(&sheet.ast_nodes, root_node.assignment.rhs);

    try t.expectApproxEqRel(
        308,
        (try eval(sheet.ast_nodes, spliced_root, sheet, "", Context{})).number,
        0.0001,
    );
    try t.expectEqual(11, sheet.ast_nodes.len);

    spliced_root = splice(&sheet.ast_nodes, sheet.ast_nodes.get(spliced_root.n).add.rhs);

    try t.expectApproxEqRel(
        5.5,
        (try eval(sheet.ast_nodes, spliced_root, sheet, "", Context{})).number,
        0.0001,
    );
    try t.expectEqual(3, sheet.ast_nodes.len);
}

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

test "DupeStrings" {
    const t = std.testing;
    const sheet = try Sheet.create(t.allocator);
    defer sheet.destroy();

    {
        const source = "let a0 = 'this is epic' # 'nice' # 'string!'";
        const expr_root = try fromSource(sheet, source);

        const strings = try dupeStrings(
            t.allocator,
            source,
            sheet.ast_nodes,
            expr_root,
        );
        defer t.allocator.free(strings);

        try t.expectEqualStrings("this is epicnicestring!", strings);
    }

    {
        const source = "let a0 = b0";
        const expr_root = try fromSource(sheet, source);

        try t.expectEqualStrings("", try dupeStrings(
            t.allocator,
            source,
            sheet.ast_nodes,
            expr_root,
        ));
    }
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

    const sheet = try Sheet.create(t.allocator);
    defer sheet.destroy();

    inline for (data) |d| {
        const expr, const expected = d;
        const expr_root = try fromExpression(sheet, expr);

        var buf = std.BoundedArray(u8, 4096){};
        try print(sheet.ast_nodes, expr_root, sheet, expr, buf.writer());
        try t.expectEqualStrings(expected, buf.constSlice());
    }
}
