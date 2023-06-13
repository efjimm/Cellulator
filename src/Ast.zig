//! Basic expression parser. Does not attempt error recovery and returns immediately on fatal
//! errors. Contains a `MultiArrayList` of `Node`s that is sorted in reverse topological order.

// TODO
// Handle division by zero (seemingly works with @rem but docs say it's ub)

const std = @import("std");
const Position = @import("Sheet.zig").Position;
const MultiArrayList = @import("multi_array_list.zig").MultiArrayList;
const HeaderList = @import("header_list.zig").HeaderList;
const SizedArrayListUnmanaged = @import("sized_array_list.zig").SizedArrayListUnmanaged;

const Tokenizer = @import("Tokenizer.zig");
const Parser = @import("Parser.zig");
const BinaryOperator = Parser.BinaryOperator;
const Builtin = Parser.Builtin;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const Node = Parser.Node;

const NodeList = MultiArrayList(Node);
pub const ParseError = Parser.ParseError;

nodes: NodeList = .{},

const Self = @This();

pub fn parse(ast: *Self, allocator: Allocator, source: []const u8) ParseError!void {
    ast.nodes.len = 0;
    const tokenizer = Tokenizer.init(source);

    var parser = Parser.init(allocator, tokenizer, .{ .nodes = ast.nodes });
    errdefer parser.deinit();
    try parser.parse();

    ast.nodes = parser.nodes;
}

pub fn dupeStrings(
    ast: *Self,
    allocator: Allocator,
    source: []const u8,
) Allocator.Error!?*HeaderList(u8, u32) {
    const slice = ast.nodes.slice();
    var nstrings: u32 = 0;
    const len = blk: {
        var len: u32 = 0;
        for (slice.items(.tags), slice.items(.data)) |tag, data| {
            switch (tag) {
                .string_literal => {
                    const str = data.string_literal;
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
        return null;
    }

    const list = try HeaderList(u8, u32).create(allocator, len);

    // Append contents of all string literals to the list, and update their `start` and `end`
    // indices to be into this list.
    for (slice.items(.tags), 0..) |tag, i| switch (tag) {
        .string_literal => {
            const str = &slice.items(.data)[i].string_literal;
            const bytes = source[str.start..str.end];
            str.start = list.len;
            list.appendSliceAssumeCapacity(bytes);
            str.end = list.len;
        },
        else => {},
    };
    return list;
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

    _ = try parser.parseStringExpression();
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
    nodes: NodeList.Slice,

    pub fn toAst(ast: *Slice) Self {
        return .{
            .nodes = ast.nodes.toMultiArrayList(),
        };
    }

    pub fn rootNodeIndex(ast: Slice) u32 {
        return @intCast(u32, ast.nodes.len) - 1;
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
            .label,
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
            var n = ast.nodes.get(@intCast(u32, j));
            switch (n) {
                .assignment,
                .label,
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
            ast.nodes.set(@intCast(u32, i), n);
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
            .label => |b| {
                try writer.writeAll("label ");
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
            .assignment, .label, .concat, .add, .sub, .mul, .div, .mod, .range => |b| {
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

    pub fn evalNode(ast: Slice, index: u32, context: anytype) !f64 {
        const node = ast.nodes.get(index);

        return switch (node) {
            .number => |n| n,
            .cell => |pos| try context.evalCell(pos) orelse 0,
            .add => |op| {
                const rhs = try ast.evalNode(op.rhs, context);
                const lhs = try ast.evalNode(op.lhs, context);
                return lhs + rhs;
            },
            .sub => |op| {
                const rhs = try ast.evalNode(op.rhs, context);
                const lhs = try ast.evalNode(op.lhs, context);
                return lhs - rhs;
            },
            .mul => |op| {
                const rhs = try ast.evalNode(op.rhs, context);
                const lhs = try ast.evalNode(op.lhs, context);
                return lhs * rhs;
            },
            .div => |op| {
                const rhs = try ast.evalNode(op.rhs, context);
                const lhs = try ast.evalNode(op.lhs, context);
                return lhs / rhs;
            },
            .mod => |op| {
                const rhs = try ast.evalNode(op.rhs, context);
                const lhs = try ast.evalNode(op.lhs, context);
                return @rem(lhs, rhs);
            },
            .builtin => |b| ast.evalBuiltin(index, b, context),
            .concat,
            .string_literal,
            .range,
            .column,
            .assignment,
            .label,
            => EvalError.NotEvaluable,
        };
    }

    pub fn stringEvalNode(
        ast: Slice,
        allocator: Allocator,
        index: u32,
        context: anytype,
        strings: []const u8,
        buffer: *SizedArrayListUnmanaged(u8, u32),
    ) !struct {
        start: u32,
        end: u32,
    } {
        const tag = ast.nodes.items(.tags)[index];
        switch (tag) {
            .string_literal => {
                const str = ast.nodes.items(.data)[index].string_literal;
                const start = buffer.len;
                try buffer.appendSlice(allocator, strings[str.start..str.end]);
                return .{
                    .start = start,
                    .end = buffer.len,
                };
            },
            .concat => {
                const b = ast.nodes.items(.data)[index].concat;
                const start = buffer.len;
                _ = try ast.stringEvalNode(allocator, b.lhs, context, strings, buffer);
                _ = try ast.stringEvalNode(allocator, b.rhs, context, strings, buffer);
                const end = buffer.len;
                return .{
                    .start = start,
                    .end = end,
                };
            },
            .cell => {
                if (@TypeOf(context) == void) return .{
                    .start = buffer.len,
                    .end = buffer.len,
                };
                const pos = ast.nodes.items(.data)[index].cell;
                const bytes = try context.evalTextCell(pos);
                const start = buffer.len;
                try buffer.appendSlice(allocator, bytes);
                const end = buffer.len;
                return .{
                    .start = start,
                    .end = end,
                };
            },
            .number,
            .add,
            .sub,
            .mul,
            .div,
            .mod,
            .builtin,
            .range,
            .column,
            .assignment,
            .label,
            => return EvalError.NotEvaluable,
        }
    }

    fn evalBuiltin(ast: Slice, builtin_index: u32, builtin: Builtin, context: anytype) !f64 {
        return switch (builtin.tag) {
            .sum => try ast.evalSum(builtin.first_arg, builtin_index, context),
            .prod => try ast.evalProd(builtin.first_arg, builtin_index, context),
            .avg => try ast.evalAvg(builtin.first_arg, builtin_index, context),
            .max => try ast.evalMax(builtin.first_arg, builtin_index, context),
            .min => try ast.evalMin(builtin.first_arg, builtin_index, context),
        };
    }

    pub fn evalSum(ast: Slice, start: u32, end: u32, context: anytype) !f64 {
        var iter = ast.argIterator(start, end);

        var total: f64 = 0;
        while (iter.next()) |i| {
            const tag = ast.nodes.items(.tags)[i];
            total += if (tag == .range) try ast.sumRange(ast.nodes.items(.data)[i].range, context) else try ast.evalNode(i, context);
        }
        return total;
    }

    pub fn sumRange(ast: Slice, range: BinaryOperator, context: anytype) !f64 {
        const pos1 = ast.nodes.items(.data)[range.lhs].cell;
        const pos2 = ast.nodes.items(.data)[range.rhs].cell;

        const start = Position.topLeft(pos1, pos2);
        const end = Position.bottomRight(pos1, pos2);

        var total: f64 = 0;
        for (start.y..end.y + @as(u32, 1)) |y| {
            for (start.x..end.x + @as(u32, 1)) |x| {
                total += try context.evalCell(.{ .x = @intCast(u16, x), .y = @intCast(u16, y) }) orelse 0;
            }
        }
        return total;
    }

    pub fn evalProd(ast: Slice, start: u32, end: u32, context: anytype) !f64 {
        var iter = ast.argIterator(start, end);
        var total: f64 = 1;

        while (iter.next()) |i| {
            const tag = ast.nodes.items(.tags)[i];
            total *= if (tag == .range) try ast.prodRange(ast.nodes.items(.data)[i].range, context) else try ast.evalNode(i, context);
        }
        return total;
    }

    pub fn prodRange(ast: Slice, range: BinaryOperator, context: anytype) !f64 {
        const pos1 = ast.nodes.items(.data)[range.lhs].cell;
        const pos2 = ast.nodes.items(.data)[range.rhs].cell;

        const start = Position.topLeft(pos1, pos2);
        const end = Position.bottomRight(pos1, pos2);

        var total: f64 = 1;
        for (start.y..end.y + @as(u32, 1)) |y| {
            for (start.x..end.x + @as(u32, 1)) |x| {
                total *= try context.evalCell(.{ .x = @intCast(u16, x), .y = @intCast(u16, y) }) orelse continue;
            }
        }
        return total;
    }

    pub fn evalAvg(ast: Slice, start: u32, end: u32, context: anytype) !f64 {
        var iter = ast.argIterator(start, end);
        var total: f64 = 0;
        var total_items: u32 = 0;

        while (iter.next()) |i| {
            const tag = ast.nodes.items(.tags)[i];
            if (tag == .range) {
                const range = ast.nodes.items(.data)[i].range;
                total += try ast.sumRange(range, context);

                const p1 = ast.nodes.items(.data)[range.lhs].cell;
                const p2 = ast.nodes.items(.data)[range.rhs].cell;
                total_items += Position.area(p1, p2);
            } else {
                total += try ast.evalNode(i, context);
                total_items += 1;
            }
        }

        return total / @intToFloat(f64, total_items);
    }

    pub fn evalMax(ast: Slice, start: u32, end: u32, context: anytype) !f64 {
        var iter = ast.argIterator(start, end);
        var max: ?f64 = null;

        while (iter.next()) |i| {
            const tag = ast.nodes.items(.tags)[i];
            const res = if (tag == .range) try ast.maxRange(ast.nodes.items(.data)[i].range, context) orelse continue else try ast.evalNode(i, context);
            if (max == null or res > max.?)
                max = res;
        }

        return max orelse 0;
    }

    pub fn maxRange(ast: Slice, range: BinaryOperator, context: anytype) !?f64 {
        const pos1 = ast.nodes.items(.data)[range.lhs].cell;
        const pos2 = ast.nodes.items(.data)[range.rhs].cell;

        const start = Position.topLeft(pos1, pos2);
        const end = Position.bottomRight(pos1, pos2);

        var max: ?f64 = null;
        for (start.y..end.y + @as(u32, 1)) |y| {
            for (start.x..end.x + @as(u32, 1)) |x| {
                const res = try context.evalCell(.{ .x = @intCast(u16, x), .y = @intCast(u16, y) }) orelse continue;
                if (max == null or res > max.?)
                    max = res;
            }
        }
        return max;
    }

    pub fn evalMin(ast: Slice, start: u32, end: u32, context: anytype) !f64 {
        var iter = ast.argIterator(start, end);
        var min: ?f64 = null;

        while (iter.next()) |i| {
            const tag = ast.nodes.items(.tags)[i];
            const res = if (tag == .range) try ast.minRange(ast.nodes.items(.data)[i].range, context) orelse continue else try ast.evalNode(i, context);
            if (min == null or res < min.?)
                min = res;
        }

        return min orelse 0;
    }

    pub fn minRange(ast: Slice, range: BinaryOperator, context: anytype) !?f64 {
        const pos1 = ast.nodes.items(.data)[range.lhs].cell;
        const pos2 = ast.nodes.items(.data)[range.rhs].cell;

        const start = Position.topLeft(pos1, pos2);
        const end = Position.bottomRight(pos1, pos2);

        var min: ?f64 = null;
        for (start.y..end.y + @as(u32, 1)) |y| {
            for (start.x..end.x + @as(u32, 1)) |x| {
                const res = try context.evalCell(.{ .x = @intCast(u16, x), .y = @intCast(u16, y) }) orelse continue;
                if (min == null or res < min.?)
                    min = res;
            }
        }
        return min;
    }
};

pub fn rootNode(ast: Self) Node {
    return ast.nodes.get(ast.rootNodeIndex());
}

pub fn rootNodeIndex(ast: Self) u32 {
    return @intCast(u32, ast.nodes.len) - 1;
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

pub fn print(ast: Self, writer: anytype, strings: []const u8) @TypeOf(writer).Error!void {
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

pub const EvalError = error{
    NotEvaluable,
};

pub const StringEvalError = EvalError || Allocator.Error;

pub fn eval(
    ast: Self,
    /// An instance of a type which has the function `fn evalCell(@TypeOf(context), Position) ?f64`.
    /// This function should return the value of the cell at the given position. It may do this
    /// by calling this function. `null` indicates no value, which may be interpreted differently by
    /// differing eval functions - e.g. @max treats a null value as 1, @sum treats it as 0, etc...
    context: anytype,
) !f64 {
    const slice = ast.toSlice();
    return slice.evalNode(slice.rootNodeIndex(), context);
}

pub fn stringEval(
    ast: Self,
    allocator: Allocator,
    context: anytype,
    strings: []const u8,
    buffer: *SizedArrayListUnmanaged(u8, u32),
) !void {
    buffer.clearRetainingCapacity();

    std.log.debug("Have strings '{s}'", .{strings});

    const slice = ast.toSlice();
    _ = try slice.stringEvalNode(allocator, slice.rootNodeIndex(), context, strings, buffer);
}

test "Parse and Eval Expression" {
    const t = std.testing;
    const Context = struct {
        pub fn evalCell(_: @This(), _: Position) !?f64 {
            unreachable;
        }
    };

    const Error = EvalError || Parser.ParseError;

    const testExpr = struct {
        fn func(expected: Error!f64, expr: []const u8) !void {
            var ast = fromExpression(t.allocator, expr) catch |err| {
                return if (err != expected) err else {};
            };
            defer ast.deinit(t.allocator);

            const res = ast.eval(Context{}) catch |err| return if (err != expected) err else {};
            const val = try expected;
            std.testing.expectApproxEqRel(val, res, 0.0001) catch |err| {
                for (0..ast.nodes.len) |i| {
                    const u = ast.nodes.get(@intCast(u32, i));
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
}

test "Functions on Ranges" {
    const Sheet = @import("Sheet.zig");
    const t = std.testing;
    const Test = struct {
        sheet: *Sheet,

        fn evalCell(context: @This(), pos: Position) !?f64 {
            const cell = context.sheet.getCellPtr(pos) orelse return null;
            return try cell.eval(context.sheet);
        }

        fn testSheetExpr(expected: f64, expr: []const u8) !void {
            var sheet = Sheet.init(t.allocator);
            defer sheet.deinit();

            try sheet.setCell(.{ .x = 0, .y = 0 }, try Self.fromExpression(t.allocator, "0"), .{});
            try sheet.setCell(.{ .x = 1, .y = 0 }, try Self.fromExpression(t.allocator, "100"), .{});
            try sheet.setCell(.{ .x = 0, .y = 1 }, try Self.fromExpression(t.allocator, "500"), .{});
            try sheet.setCell(.{ .x = 1, .y = 1 }, try Self.fromExpression(t.allocator, "333.33"), .{});

            var ast = try fromExpression(t.allocator, expr);
            defer ast.deinit(t.allocator);

            try sheet.update(.number);
            const res = try ast.eval(@This(){ .sheet = &sheet });
            try std.testing.expectApproxEqRel(expected, res, 0.0001);
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
        pub fn evalCell(_: @This(), _: Position) !?f64 {
            return null;
        }
    };

    var ast = try fromSource(allocator, "let a0 = 100 * 3 + 5 / 2 + @avg(1, 10)");

    ast.splice(ast.rootNode().assignment.rhs);
    try t.expectApproxEqRel(@as(f64, 308), try ast.eval(Context{}), 0.0001);
    try t.expectEqual(@as(usize, 11), ast.nodes.len);

    ast.splice(ast.rootNode().add.rhs);
    try t.expectApproxEqRel(@as(f64, 5.5), try ast.eval(Context{}), 0.0001);
    try t.expectEqual(@as(usize, 3), ast.nodes.len);
}

test "StringEval" {
    const data = .{
        .{ "'string'", "string" },
        .{ "'string1' # 'string2'", "string1string2" },
        .{ "'string1' # 'string2' # 'string3'", "string1string2string3" },
    };
    var buf = SizedArrayListUnmanaged(u8, u32){};
    defer buf.deinit(std.testing.allocator);

    inline for (data) |d| {
        var ast = try fromStringExpression(std.testing.allocator, d[0]);
        defer ast.deinit(std.testing.allocator);

        buf.clearRetainingCapacity();
        switch (@typeInfo(@TypeOf(d[1]))) {
            .Null => {
                const res = ast.stringEval(std.testing.allocator, {}, d[0], &buf);
                try std.testing.expectError(error.NotEvaluable, res);
            },
            else => {
                try ast.stringEval(std.testing.allocator, {}, d[0], &buf);

                try std.testing.expectEqualStrings(d[1], buf.items());
            },
        }
    }
}

test "DupeStrings" {
    const t = std.testing;
    {
        const source = "label a0 = 'this is epic' # 'nice' # 'string!'";
        var ast = try fromSource(t.allocator, source);
        defer ast.deinit(t.allocator);

        const strings = (try ast.dupeStrings(t.allocator, source)).?;
        defer strings.destroy(t.allocator);

        try t.expectEqualStrings("this is epicnicestring!", strings.items());
    }

    {
        const source = "label a0 = b0";
        var ast = try fromSource(t.allocator, source);
        defer ast.deinit(t.allocator);

        try t.expect(try ast.dupeStrings(t.allocator, source) == null);
    }
}

test "Print" {
    const t = std.testing;

    const testPrint = struct {
        fn func(expr: []const u8, expected: []const u8) !void {
            var ast = try fromExpression(t.allocator, expr);
            defer ast.deinit(t.allocator);

            var buf = std.BoundedArray(u8, 4096){};
            try ast.print(buf.writer(), expr);
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
