//! Basic expression parser. Does not attempt error recovery and returns immediately on fatal
//! errors. Contains a `MultiArrayList` of `Node`s that is sorted in reverse topological order.

const std = @import("std");
const Position = @import("Position.zig");
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
    cell: Position,
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
};

nodes: MultiArrayList(Node) = .{},

const Self = @This();

pub fn parse(ast: *Self, allocator: Allocator, source: []const u8) ParseError!void {
    ast.nodes.len = 0;
    const tokenizer = Tokenizer.init(source);

    var parser = Parser.init(allocator, tokenizer, .{ .nodes = ast.nodes });
    errdefer parser.deinit();
    try parser.parse();

    ast.nodes = parser.nodes;
}

pub fn parseExpr(ast: *Self, allocator: Allocator, source: []const u8) ParseError!void {
    ast.nodes.len = 0;
    const tokenizer = Tokenizer.init(source);

    var parser = Parser.init(allocator, tokenizer, .{ .nodes = ast.nodes });
    errdefer parser.deinit();
    _ = try parser.parseExpression();

    ast.nodes = parser.nodes;
}

pub fn dupeStrings(
    ast: Self,
    allocator: Allocator,
    source: []const u8,
) Allocator.Error![]const u8 {
    const slice = ast.nodes.slice();
    var nstrings: u32 = 0;
    const len = blk: {
        var len: u32 = 0;
        for (slice.items(.tags), 0..) |tag, i| {
            switch (tag) {
                .string_literal => {
                    const str = slice.items(.data)[i].string_literal;
                    len += str.end - str.start;
                    nstrings += 1;
                },
                else => {},
            }
        }
        break :blk len;
    };

    if (len == 0) {
        if (nstrings != 0) {
            for (slice.items(.tags), 0..) |tag, i| switch (tag) {
                .string_literal => {
                    slice.items(.data)[i].string_literal = .{
                        .start = 0,
                        .end = 0,
                    };
                },
                else => {},
            };
        }
        return "";
    }

    var list = try std.ArrayListUnmanaged(u8).initCapacity(allocator, len);

    // Append contents of all string literals to the list, and update their `start` and `end`
    // indices to be into this list.
    for (slice.items(.tags), 0..) |tag, i| switch (tag) {
        .string_literal => {
            const str = &slice.items(.data)[i].string_literal;
            const bytes = source[str.start..str.end];
            str.start = @intCast(list.items.len);
            list.appendSliceAssumeCapacity(bytes);
            str.end = @intCast(list.items.len);
        },
        else => {},
    };
    return list.toOwnedSlice(allocator);
}

pub fn fromSource(allocator: Allocator, source: []const u8) ParseError!Self {
    var ast = Self{};
    errdefer ast.deinit(allocator);
    try ast.parse(allocator, source);
    return ast;
}

pub fn fromExpression(allocator: Allocator, source: []const u8) ParseError!Self {
    const tokenizer = Tokenizer.init(source);

    var parser = Parser.init(allocator, tokenizer, .{});
    errdefer parser.deinit();

    _ = try parser.parseExpression();
    _ = try parser.expectToken(.eof);

    return Self{
        .nodes = parser.nodes,
    };
}

pub fn fromStringExpression(allocator: Allocator, source: []const u8) ParseError!Self {
    const tokenizer = Tokenizer.init(source);

    var parser = Parser.init(allocator, tokenizer, .{});
    errdefer parser.deinit();

    _ = try parser.parseExpression();
    _ = try parser.expectToken(.eof);

    return Self{
        .nodes = parser.nodes,
    };
}

pub fn deinit(ast: *Self, allocator: Allocator) void {
    ast.nodes.deinit(allocator);
    // if (ast.strings) |strings| {
    //     strings.destroy(allocator);
    // }
    ast.* = .{};
}

pub const Slice = struct {
    nodes: MultiArrayList(Node).Slice,

    pub fn toAst(ast: *Slice) Self {
        return .{
            .nodes = ast.nodes.toMultiArrayList(),
        };
    }

    pub fn rootNodeIndex(ast: Slice) u32 {
        return @as(u32, @intCast(ast.nodes.len)) - 1;
    }

    pub fn rootTag(ast: Slice) u32 {
        return ast.nodes.items(.tags)[ast.nodes.len - 1];
    }

    pub fn rootNode(ast: Slice) Node {
        return ast.nodes.get(ast.rootNodeIndex());
    }

    pub fn leftMostChild(ast: Slice, index: u32) u32 {
        assert(index < ast.nodes.len);

        const node = ast.nodes.get(index);

        return switch (node) {
            .string_literal, .number, .column, .cell => index,
            .assignment,
            .concat,
            .add,
            .sub,
            .mul,
            .div,
            .mod,
            .range,
            => |b| ast.leftMostChild(b.lhs),
            .builtin => |b| ast.leftMostChild(b.first_arg),
        };
    }

    /// Removes all nodes except for the given index and its children
    /// Nodes in the list are already sorted in reverse topological order which allows us to overwrite
    /// nodes sequentially without loss. This function preserves reverse topological order.
    pub fn splice(ast: *Slice, new_root: u32) void {
        const first_node = ast.leftMostChild(new_root);
        const new_len = new_root + 1 - first_node;

        for (0..new_len, first_node..new_root + 1) |i, j| {
            var n = ast.nodes.get(@intCast(j));
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
                    b.lhs -= first_node;
                    b.rhs -= first_node;
                },
                .builtin => |*b| {
                    b.first_arg -= first_node;
                },
                .string_literal, .number, .column, .cell => {},
            }
            ast.nodes.set(@intCast(i), n);
        }

        ast.nodes.len = new_len;
    }

    pub inline fn printFromIndex(
        ast: Slice,
        index: u32,
        writer: anytype,
        strings: []const u8,
    ) @TypeOf(writer).Error!void {
        const node = ast.nodes.get(index);
        return ast.printFromNode(index, node, writer, strings);
    }

    pub fn printFromNode(
        ast: Slice,
        index: u32,
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
            .cell => |pos| try pos.writeCellAddress(writer),

            .string_literal => |str| {
                try writer.print("\"{s}\"", .{strings[str.start..str.end]});
            },
            .concat => |b| {
                try ast.printFromIndex(b.lhs, writer, strings);
                try writer.writeAll(" # ");
                try ast.printFromIndex(b.rhs, writer, strings);
            },
            .assignment => |b| {
                try writer.writeAll("let ");
                try ast.printFromIndex(b.lhs, writer, strings);
                try writer.writeAll(" = ");
                try ast.printFromIndex(b.rhs, writer, strings);
            },
            .add => |b| {
                try ast.printFromIndex(b.lhs, writer, strings);
                try writer.writeAll(" + ");
                const rhs = ast.nodes.get(b.rhs);
                switch (rhs) {
                    .sub => {
                        try writer.writeByte('(');
                        try ast.printFromNode(b.rhs, rhs, writer, strings);
                        try writer.writeByte(')');
                    },
                    else => {
                        try ast.printFromNode(b.rhs, rhs, writer, strings);
                    },
                }
            },
            .sub => |b| {
                try ast.printFromIndex(b.lhs, writer, strings);
                try writer.writeAll(" - ");

                const rhs = ast.nodes.get(b.rhs);
                switch (rhs) {
                    .add, .sub => {
                        try writer.writeByte('(');
                        try ast.printFromNode(b.rhs, rhs, writer, strings);
                        try writer.writeByte(')');
                    },
                    else => {
                        try ast.printFromNode(b.rhs, rhs, writer, strings);
                    },
                }
            },
            .mul => |b| {
                const lhs = ast.nodes.get(b.lhs);
                switch (lhs) {
                    .add, .sub => {
                        try writer.writeByte('(');
                        try ast.printFromNode(b.lhs, lhs, writer, strings);
                        try writer.writeByte(')');
                    },
                    else => try ast.printFromNode(b.lhs, lhs, writer, strings),
                }
                try writer.writeAll(" * ");
                const rhs = ast.nodes.get(b.rhs);
                switch (rhs) {
                    .add, .sub, .div, .mod => {
                        try writer.writeByte('(');
                        try ast.printFromNode(b.rhs, rhs, writer, strings);
                        try writer.writeByte(')');
                    },
                    else => try ast.printFromNode(b.rhs, rhs, writer, strings),
                }
            },
            .div => |b| {
                const lhs = ast.nodes.get(b.lhs);
                switch (lhs) {
                    .add, .sub => {
                        try writer.writeByte('(');
                        try ast.printFromNode(b.lhs, lhs, writer, strings);
                        try writer.writeByte(')');
                    },
                    else => try ast.printFromNode(b.lhs, lhs, writer, strings),
                }
                try writer.writeAll(" / ");
                const rhs = ast.nodes.get(b.rhs);
                switch (rhs) {
                    .add, .sub, .mul, .div, .mod => {
                        try writer.writeByte('(');
                        try ast.printFromNode(b.rhs, rhs, writer, strings);
                        try writer.writeByte(')');
                    },
                    else => try ast.printFromNode(b.rhs, rhs, writer, strings),
                }
            },
            .mod => |b| {
                const lhs = ast.nodes.get(b.lhs);
                switch (lhs) {
                    .add, .sub => {
                        try writer.writeByte('(');
                        try ast.printFromNode(b.lhs, lhs, writer, strings);
                        try writer.writeByte(')');
                    },
                    else => try ast.printFromNode(b.lhs, lhs, writer, strings),
                }
                try writer.writeAll(" % ");
                const rhs = ast.nodes.get(b.rhs);
                switch (rhs) {
                    .add, .sub, .mul, .div, .mod => {
                        try writer.writeByte('(');
                        try ast.printFromNode(b.rhs, rhs, writer, strings);
                        try writer.writeByte(')');
                    },
                    else => try ast.printFromNode(b.rhs, rhs, writer, strings),
                }
            },
            .range => |b| {
                try ast.printFromIndex(b.lhs, writer, strings);
                try writer.writeByte(':');
                try ast.printFromIndex(b.rhs, writer, strings);
            },

            .builtin => |b| {
                switch (b.tag) {
                    inline else => |tag| try writer.print("@{s}(", .{@tagName(tag)}),
                }
                var iter = ast.argIteratorForwards(b.first_arg, index);
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

    /// Same as `traverse`, but starting from the node at the given index.
    fn traverseFrom(ast: Slice, index: u32, order: TraverseOrder, context: anytype) !bool {
        const node = ast.nodes.get(index);

        switch (node) {
            .assignment, .concat, .add, .sub, .mul, .div, .mod, .range => |b| {
                switch (order) {
                    .first => {
                        if (!try context.evalCell(index)) return false;
                        if (!try ast.traverseFrom(b.lhs, order, context)) return false;
                        if (!try ast.traverseFrom(b.rhs, order, context)) return false;
                    },
                    .middle => {
                        if (!try ast.traverseFrom(b.lhs, order, context)) return false;
                        if (!try context.evalCell(index)) return false;
                        if (!try ast.traverseFrom(b.rhs, order, context)) return false;
                    },
                    .last => {
                        if (!try ast.traverseFrom(b.lhs, order, context)) return false;
                        if (!try ast.traverseFrom(b.rhs, order, context)) return false;
                        if (!try context.evalCell(index)) return false;
                    },
                }
            },
            .string_literal, .number, .cell, .column => {
                if (!try context.evalCell(index)) return false;
            },
            .builtin => |b| {
                var iter = ast.argIterator(b.first_arg, index);
                if (order != .last and !try context.evalCell(index)) return false;
                while (iter.next()) |arg| {
                    if (!try ast.traverseFrom(arg, order, context)) return false;
                }
                if (order == .last and !try context.evalCell(index)) return false;
            },
        }

        return true;
    }

    /// Iterates over expressions backwards
    pub const ArgIterator = struct {
        ast: *const Slice,
        first_arg: u32,
        index: u32,

        pub fn next(iter: *ArgIterator) ?u32 {
            if (iter.index <= iter.first_arg) return null;
            const ret = iter.index - 1;
            iter.index = iter.ast.leftMostChild(ret);
            return ret;
        }
    };

    pub fn argIterator(ast: *const Slice, start: u32, end: u32) ArgIterator {
        return ArgIterator{
            .ast = ast,
            .first_arg = start,
            .index = end,
        };
    }

    /// Iterates over expressions forwards. Only use when the ordering is required.
    pub const ArgIteratorForwards = struct {
        ast: *const Slice,
        end: u32,
        index: u32,
        backwards_iter: ArgIterator,
        buffer: std.BoundedArray(u32, 32) = .{},

        pub fn next(iter: *ArgIteratorForwards) ?u32 {
            if (iter.index >= iter.end) return null;
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

    pub fn argIteratorForwards(ast: *const Slice, start: u32, end: u32) ArgIteratorForwards {
        return ArgIteratorForwards{
            .ast = ast,
            .end = end,
            .index = start,
            .backwards_iter = ast.argIterator(start + 1, end),
        };
    }
};

pub fn rootNode(ast: Self) Node {
    return ast.nodes.get(ast.rootNodeIndex());
}

pub fn rootNodeIndex(ast: Self) u32 {
    return @as(u32, @intCast(ast.nodes.len)) - 1;
}

pub fn rootTag(ast: Self) std.meta.Tag(Node) {
    return ast.nodes.items(.tags)[ast.nodes.len - 1];
}

/// Removes all nodes except for the given index and its children
/// Nodes in the list are already sorted in reverse topological order which allows us to overwrite
/// nodes sequentially without loss. This function preserves reverse topological order.
pub fn splice(ast: *Self, new_root: u32) void {
    var slice = ast.toSlice();
    slice.splice(new_root);
    ast.* = slice.toAst();
}

pub fn toSlice(ast: Self) Slice {
    return .{
        .nodes = ast.nodes.slice(),
    };
}

pub fn print(ast: Self, strings: []const u8, writer: anytype) @TypeOf(writer).Error!void {
    const slice = ast.toSlice();
    return slice.printFromIndex(slice.rootNodeIndex(), writer, strings);
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

/// Recursively visits every node in the tree. `context` is an instance of a type which must have
/// the function `fn evalCell(@TypeOf(context), u32) !bool`. This function is run on every leaf
/// node in the tree, with `index` being the index of the node in the `nodes` array. If the
/// function returns false, traversal stops immediately.
pub fn traverse(ast: Self, order: TraverseOrder, context: anytype) !bool {
    const slice = ast.toSlice();
    return slice.traverseFrom(slice.rootNodeIndex(), order, context);
}

pub fn leftMostChild(ast: Self, index: u32) u32 {
    const slice = ast.toSlice();
    return slice.leftMostChild(index);
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

const Sheet = @import("Sheet.zig");

pub fn EvalContext(comptime Context: type) type {
    return struct {
        slice: Slice,
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

            const C = if (@typeInfo(Context) == .Pointer)
                std.meta.Child(Context)
            else
                Context;

            const func = @field(C, "evalCell");
            const info = @typeInfo(@TypeOf(func));
            const ret_info = @typeInfo(info.Fn.return_type.?);
            break :blk E || ret_info.ErrorUnion.error_set;
        };

        fn eval(
            self: @This(),
            index: u32,
        ) Error!EvalResult {
            const node = self.slice.nodes.get(index);

            return switch (node) {
                .number => |n| .{ .number = n },
                .cell => |pos| try self.context.evalCell(pos),
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

        fn evalUpper(self: @This(), arg: u32) ![]const u8 {
            const str = try (try self.eval(arg)).toStringAlloc(self.allocator);
            for (str) |*c| c.* = std.ascii.toUpper(c.*);
            return str;
        }

        fn evalLower(self: @This(), arg: u32) ![]const u8 {
            const str = try (try self.eval(arg)).toStringAlloc(self.allocator);
            for (str) |*c| c.* = std.ascii.toLower(c.*);
            return str;
        }

        fn evalSum(self: @This(), start: u32, end: u32) !f64 {
            const tags = self.slice.nodes.items(.tags);
            const data = self.slice.nodes.items(.data);

            var iter = self.slice.argIterator(start, end);
            var total: f64 = 0;

            while (iter.next()) |i| {
                const tag = tags[i];
                if (tag == .range) {
                    total += try self.sumRange(data[i].range);
                } else {
                    const res = try self.eval(i);
                    total += try res.toNumber(0);
                }
            }

            return total;
        }

        /// Converts an ast range to a position range.
        fn toPosRange(self: @This(), r: BinaryOperator) Position.Range {
            const data = self.slice.nodes.items(.data);
            return Position.Range.initPos(data[r.lhs].cell, data[r.rhs].cell);
        }

        fn sumRange(self: @This(), r: BinaryOperator) !f64 {
            const range = self.toPosRange(r);

            var total: f64 = 0;
            const kvs = try self.sheet.cell_tree.search(self.allocator, range);
            for (kvs) |kv| {
                var iter = kv.key.iterator();
                while (iter.next()) |p| {
                    const res = try self.context.evalCell(p);
                    total += try res.toNumber(0);
                }
            }

            return total;
        }

        fn evalProd(self: @This(), start: u32, end: u32) !f64 {
            const tags = self.slice.nodes.items(.tags);
            const data = self.slice.nodes.items(.data);

            var iter = self.slice.argIterator(start, end);
            var total: f64 = 1;

            while (iter.next()) |i| {
                const tag = tags[i];
                if (tag == .range) {
                    total *= try self.prodRange(data[i].range);
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
            var iter = range.iterator();
            while (iter.next()) |pos| {
                const res = try self.context.evalCell(pos);
                total *= try res.toNumber(1);
            }

            return total;
        }

        fn evalAvg(self: @This(), start: u32, end: u32) !f64 {
            const tags = self.slice.nodes.items(.tags);
            const data = self.slice.nodes.items(.data);

            var iter = self.slice.argIterator(start, end);
            var total: f64 = 0;
            var total_items: Position.HashInt = 0;

            while (iter.next()) |i| {
                if (tags[i] == .range) {
                    const r = data[i].range;
                    total += try self.sumRange(r);

                    const p1 = data[r.lhs].cell;
                    const p2 = data[r.rhs].cell;
                    total_items += Position.area(p1, p2);
                } else {
                    const res = try self.eval(i);
                    total += try res.toNumber(0);
                    total_items += 1;
                }
            }

            return total / @as(f64, @floatFromInt(total_items));
        }

        fn evalMax(self: @This(), start: u32, end: u32) !f64 {
            const tags = self.slice.nodes.items(.tags);
            const data = self.slice.nodes.items(.data);

            var iter = self.slice.argIterator(start, end);
            var max: ?f64 = null;

            while (iter.next()) |i| {
                const m = blk: {
                    if (tags[i] == .range) {
                        const r = data[i].range;
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
            var iter = range.iterator();
            while (iter.next()) |pos| {
                const res = try self.context.evalCell(pos);
                const n = try res.toNumberOrNull() orelse continue;
                if (max == null or n > max.?) max = n;
            }

            return max;
        }

        fn evalMin(self: @This(), start: u32, end: u32) !f64 {
            const tags = self.slice.nodes.items(.tags);
            const data = self.slice.nodes.items(.data);

            var iter = self.slice.argIterator(start, end);
            var min: ?f64 = null;

            while (iter.next()) |i| {
                const m = blk: {
                    if (tags[i] == .range) {
                        const r = data[i].range;
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
            var iter = range.iterator();
            while (iter.next()) |pos| {
                const res = try self.context.evalCell(pos);
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
    ast: Self,
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
        .slice = ast.toSlice(),
        .allocator = arena.allocator(),
        .strings = strings,
        .context = context,
    };

    const res = try ctx.eval(ast.rootNodeIndex());

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
        pub fn evalCell(_: @This(), _: Position) !EvalResult {
            unreachable;
        }
    };

    const Error = EvalContext(void).Error || Parser.ParseError;

    const testExpr = struct {
        fn func(expected: Error!f64, expr: []const u8) !void {
            var ast = fromExpression(t.allocator, expr) catch |err| {
                return if (err != expected) err else {};
            };
            defer ast.deinit(t.allocator);

            var sheet = Sheet.init(t.allocator);
            defer sheet.deinit();
            const res = ast.eval(&sheet, expr, Context{}) catch |err| {
                return if (err != expected) err else {};
            };
            const n = res.number;

            const val = try expected;
            std.testing.expectApproxEqRel(val, n, 0.0001) catch |err| {
                for (0..ast.nodes.len) |i| {
                    const u = ast.nodes.get(@intCast(i));
                    std.debug.print("{}\n", .{u});
                }
                return err;
            };
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
        sheet: *Sheet,

        fn evalCell(context: *const @This(), pos: Position) !EvalResult {
            const ptr: *const Sheet.EvalContext = @ptrCast(context);
            return Sheet.EvalContext.evalCell(ptr.*, pos);
        }

        fn testSheetExpr(expected: f64, expr: []const u8) !void {
            var sheet = Sheet.init(t.allocator);
            defer sheet.deinit();

            try sheet.setCell(.{ .x = 0, .y = 0 }, "0", try Self.fromExpression(t.allocator, "0"), .{});
            try sheet.setCell(.{ .x = 1, .y = 0 }, "100", try Self.fromExpression(t.allocator, "100"), .{});
            try sheet.setCell(.{ .x = 0, .y = 1 }, "500", try Self.fromExpression(t.allocator, "500"), .{});
            try sheet.setCell(.{ .x = 1, .y = 1 }, "333.33", try Self.fromExpression(t.allocator, "333.33"), .{});

            var ast = try fromExpression(t.allocator, expr);
            defer ast.deinit(t.allocator);

            try sheet.update();
            const res = try ast.eval(&sheet, "", @This(){ .sheet = &sheet });
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
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const Context = struct {
        pub fn evalCell(_: @This(), _: Position) !EvalResult {
            return .none;
        }
    };

    var ast = try fromSource(allocator, "let a0 = 100 * 3 + 5 / 2 + @avg(1, 10)");

    ast.splice(ast.rootNode().assignment.rhs);
    var sheet = Sheet.init(t.allocator);
    defer sheet.deinit();
    try t.expectApproxEqRel(@as(f64, 308), (try ast.eval(&sheet, "", Context{})).number, 0.0001);
    try t.expectEqual(@as(usize, 11), ast.nodes.len);

    ast.splice(ast.rootNode().add.rhs);
    try t.expectApproxEqRel(@as(f64, 5.5), (try ast.eval(&sheet, "", Context{})).number, 0.0001);
    try t.expectEqual(@as(usize, 3), ast.nodes.len);
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
    {
        const source = "let a0 = 'this is epic' # 'nice' # 'string!'";
        var ast = try fromSource(t.allocator, source);
        defer ast.deinit(t.allocator);

        const strings = try ast.dupeStrings(t.allocator, source);
        defer t.allocator.free(strings);

        try t.expectEqualStrings("this is epicnicestring!", strings);
    }

    {
        const source = "let a0 = b0";
        var ast = try fromSource(t.allocator, source);
        defer ast.deinit(t.allocator);

        try t.expectEqualStrings("", try ast.dupeStrings(t.allocator, source));
    }
}

test "Print" {
    const t = std.testing;

    const testPrint = struct {
        fn func(expr: []const u8, expected: []const u8) !void {
            var ast = try fromExpression(t.allocator, expr);
            defer ast.deinit(t.allocator);

            var buf = std.BoundedArray(u8, 4096){};
            try ast.print(expr, buf.writer());
            try t.expectEqualStrings(expected, buf.constSlice());
        }
    }.func;

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

    inline for (data) |d| try testPrint(d[0], d[1]);
}
