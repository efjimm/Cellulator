//! Basic expression parser. Does not attempt error recovery and returns immediately on fatal
//! errors. Contains a `MultiArrayList` of `Node`s that is sorted in reverse topological order.

const std = @import("std");
const Position = @import("Position.zig").Position;
const Sheet = @import("Sheet.zig");
const PosInt = Position.Int;
const Rect = Position.Rect;

const Tokenizer = @import("Tokenizer.zig");
const Parser = @import("Parser.zig");
const BinaryOperator = Parser.BinaryOperator;
const Builtin = Parser.Builtin;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const ParseError = Parser.ParseError;

pub const String = extern struct {
    start: u32,
    end: u32,
};

pub const Node = extern struct {
    tag: Tag,
    data: Payload,

    pub const Tag = blk: {
        const t = @typeInfo(std.meta.FieldEnum(Payload));
        break :blk @Type(.{ .@"enum" = .{
            .tag_type = u8,
            .fields = t.@"enum".fields,
            .decls = &.{},
            .is_exhaustive = true,
        } });
    };

    pub const Payload = extern union {
        number: f64,
        column: PosInt,
        pos: Position,
        assignment: Position,
        concat: BinaryOperator,
        add: BinaryOperator,
        sub: BinaryOperator,
        mul: BinaryOperator,
        div: BinaryOperator,
        mod: BinaryOperator,
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
        const t = @typeInfo(Payload).@"union";
        break :blk @Type(.{ .@"union" = .{
            .layout = t.layout,
            .fields = t.fields,
            .decls = t.decls,
            .tag_type = Tag,
        } });
    };

    pub inline fn get(n: Node) Tagged {
        switch (n.tag) {
            inline else => |tag| {
                const field = @tagName(tag);
                return @unionInit(Tagged, field, @field(n.data, field));
            },
        }
    }
};

pub const NodeList = std.MultiArrayList(Node);
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

pub fn fromSource(sheet: *Sheet, source: [:0]const u8) ParseError!Index {
    var tokens = try Tokenizer.collectTokens(sheet.allocator, source, @intCast(source.len / 2));
    defer tokens.deinit(sheet.allocator);

    var parser: Parser = .init(
        sheet.allocator,
        source,
        tokens.items(.tag),
        tokens.items(.start),
        .{ .nodes = sheet.ast_nodes.toMultiArrayList() },
    );

    const old_len = sheet.ast_nodes.len;

    // The parser could re-allocate the underlying nodes
    defer sheet.ast_nodes = parser.nodes.slice();
    errdefer sheet.ast_nodes.len = old_len;

    try parser.parse();

    return .from(@intCast(parser.nodes.len - 1));
}

const Token = Tokenizer.Token;
pub fn fromSource2(
    sheet: *Sheet,
    source: [:0]const u8,
    token_tags: []const Token.Tag,
    token_starts: []const u32,
) ParseError!struct {
    /// Total byte length of all parsed string literals
    u32,
    u32,
} {
    var parser: Parser = .init(
        sheet.allocator,
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

    return .{ parser.strings_len, parser.tok_i };
}

pub fn fromExpression(sheet: *Sheet, source: [:0]const u8) ParseError!Index {
    var tokens = try Tokenizer.collectTokens(sheet.allocator, source, @intCast(source.len / 2));
    defer tokens.deinit(sheet.allocator);

    var parser: Parser = .init(
        sheet.allocator,
        source,
        tokens.items(.tag),
        tokens.items(.start),
        .{ .nodes = sheet.ast_nodes.toMultiArrayList() },
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
    switch (node.get()) {
        .number => |n| try writer.print("{d}", .{n}),
        .column => |col| try Position.writeColumnAddress(col, writer),
        .pos => |pos| try pos.writeCellAddress(writer),
        .invalidated_pos => |pos| {
            // TODO: Print these differently
            try pos.writeCellAddress(writer);
        },

        .string_literal => |str| {
            try writer.print("\"{s}\"", .{strings[str.start..str.end]});
        },
        .concat => |b| {
            try printFromIndex(nodes, sheet, b.lhs, writer, strings);
            try writer.writeAll(" # ");
            try printFromIndex(nodes, sheet, b.rhs, writer, strings);
        },
        .assignment => |pos| {
            try writer.print("let {} = ", .{pos});
            try printFromIndex(nodes, sheet, .from(index.n - 1), writer, strings);
        },
        .add => |b| {
            try printFromIndex(nodes, sheet, b.lhs, writer, strings);
            try writer.writeAll(" + ");
            const rhs = nodes.get(b.rhs.n);
            switch (rhs.tag) {
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
            switch (rhs.tag) {
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
            switch (lhs.tag) {
                .add, .sub => {
                    try writer.writeByte('(');
                    try printFromNode(nodes, sheet, b.lhs, lhs, writer, strings);
                    try writer.writeByte(')');
                },
                else => try printFromNode(nodes, sheet, b.lhs, lhs, writer, strings),
            }
            try writer.writeAll(" * ");
            const rhs = nodes.get(b.rhs.n);
            switch (rhs.tag) {
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
            switch (lhs.tag) {
                .add, .sub => {
                    try writer.writeByte('(');
                    try printFromNode(nodes, sheet, b.lhs, lhs, writer, strings);
                    try writer.writeByte(')');
                },
                else => try printFromNode(nodes, sheet, b.lhs, lhs, writer, strings),
            }
            try writer.writeAll(" / ");
            const rhs = nodes.get(b.rhs.n);
            switch (rhs.tag) {
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
            switch (lhs.tag) {
                .add, .sub => {
                    try writer.writeByte('(');
                    try printFromNode(nodes, sheet, b.lhs, lhs, writer, strings);
                    try writer.writeByte(')');
                },
                else => try printFromNode(nodes, sheet, b.lhs, lhs, writer, strings),
            }
            try writer.writeAll(" % ");
            const rhs = nodes.get(b.rhs.n);
            switch (rhs.tag) {
                .add, .sub, .mul, .div, .mod => {
                    try writer.writeByte('(');
                    try printFromNode(nodes, sheet, b.rhs, rhs, writer, strings);
                    try writer.writeByte(')');
                },
                else => try printFromNode(nodes, sheet, b.rhs, rhs, writer, strings),
            }
        },
        .range, .invalidated_range => |b| {
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
        iter.index = iter.buffer.pop().?;

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

pub fn print(
    nodes: NodeSlice,
    root: Index,
    sheet: *Sheet,
    strings: []const u8,
    writer: anytype,
) @TypeOf(writer).Error!void {
    return printFromIndex(nodes, sheet, root, writer, strings);
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
        .pos,
        .invalidated_pos,
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
        => |b| leftMostChild(nodes, b.lhs),
        .builtin => |b| leftMostChild(nodes, b.first_arg),
    };
}

pub const EvalResult = union(enum) {
    none,
    number: f64,
    string: []const u8,
    cell_string: struct {
        sheet: *Sheet,
        list_index: @FieldType(Sheet, "string_values").List.Index,
    },

    /// Attempts to coerce `res` to an integer.
    fn toNumber(res: EvalResult, none_value: f64) !f64 {
        return switch (res) {
            .none => none_value,
            .number => |n| n,
            .string => |str| std.fmt.parseFloat(f64, str) catch error.InvalidCoercion,
            .cell_string => |i| {
                const str = i.sheet.string_values.items(i.list_index);
                return std.fmt.parseFloat(f64, str) catch error.InvalidCoercion;
            },
        };
    }

    fn toNumberOrNull(res: EvalResult) !?f64 {
        return switch (res) {
            .none => null,
            .number => |n| n,
            .string => |str| std.fmt.parseFloat(f64, str) catch error.InvalidCoercion,
            .cell_string => |i| {
                const str = i.sheet.string_values.items(i.list_index);
                return std.fmt.parseFloat(f64, str) catch error.InvalidCoercion;
            },
        };
    }

    fn toStringAlloc(res: EvalResult, allocator: Allocator) ![]u8 {
        return switch (res) {
            .none => "",
            .number => |n| std.fmt.allocPrint(allocator, "{d}", .{n}),
            .string => |str| allocator.dupe(u8, str),
            .cell_string => |i| {
                const str = i.sheet.string_values.items(i.list_index);
                return allocator.dupe(u8, str);
            },
        };
    }

    fn toString(res: EvalResult, writer: anytype) !void {
        switch (res) {
            .none => {},
            .number => |n| try writer.print("{d}", .{n}),
            .string => |str| try writer.writeAll(str),
            .cell_string => |i| {
                const str = i.sheet.string_values.items(i.list_index);
                try writer.writeAll(str);
            },
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
            .cell_string => |i| i.sheet.string_values.len(i.list_index),
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
        pos: Position,

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

        // TODO: Pass references to `context.evalCell` instead of positions
        fn eval(
            self: @This(),
            index: Index,
        ) Error!EvalResult {
            const node = self.nodes.get(index.n);

            return switch (node.get()) {
                .number => |n| .{ .number = n },
                .pos => |pos| {
                    return self.context.evalCellByPos(pos);
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

                    const rhs_number = try rhs.toNumberOrNull() orelse return error.DivideByZero;
                    if (rhs_number == 0) return error.DivideByZero;

                    return .{ .number = try lhs.toNumber(0) / rhs_number };
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
                .column,
                .invalidated_pos,
                .range,
                .invalidated_range,
                .assignment,
                => error.NotEvaluable,
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
            const tags = self.nodes.items(.tag);
            const data = self.nodes.items(.data);

            var iter = argIterator(self.nodes, start, end);
            var total: f64 = 0;

            while (iter.next()) |i| switch (tags[i.n]) {
                .range => total += try self.sumRange(data[i.n].range),
                .invalidated_range => return error.NotEvaluable,
                else => {
                    const res = try self.eval(i);
                    total += try res.toNumber(0);
                },
            };

            return total;
        }

        /// Converts an ast range to a position range.
        fn toPosRange(self: @This(), r: BinaryOperator) Position.Rect {
            const data = self.nodes.items(.data);

            if (self.nodes.items(.tag)[r.lhs.n] != .pos) {
                std.debug.print("{}\n", .{self.nodes.items(.tag)[r.lhs.n]});
                unreachable;
            }
            if (self.nodes.items(.tag)[r.rhs.n] != .pos) {
                std.debug.print("{}\n", .{self.nodes.items(.tag)[r.rhs.n]});
                unreachable;
            }

            return .initPos(
                data[r.lhs.n].pos,
                data[r.rhs.n].pos,
            );
        }

        fn sumRange(self: @This(), r: BinaryOperator) !f64 {
            const range = self.toPosRange(r);

            var total: f64 = 0;
            var results: std.ArrayList(Sheet.CellHandle) = .init(self.allocator);
            defer results.deinit();
            try self.sheet.cell_tree.queryWindow(
                &.{ range.tl.x, range.tl.y },
                &.{ range.br.x, range.br.y },
                &results,
            );
            for (results.items) |handle| {
                const res = try self.context.evalCellByHandle(handle);
                total += try res.toNumber(0);
            }

            return total;
        }

        fn evalProd(self: @This(), start: Index, end: Index) !f64 {
            const tags = self.nodes.items(.tag);
            const data = self.nodes.items(.data);

            var iter = argIterator(self.nodes, start, end);
            var total: f64 = 1;

            while (iter.next()) |i| switch (tags[i.n]) {
                .range => total *= try self.prodRange(data[i.n].range),
                .invalidated_range => return error.NotEvaluable,
                else => {
                    const res = try self.eval(i);
                    total *= try res.toNumber(0);
                },
            };

            return total;
        }

        fn prodRange(self: @This(), r: BinaryOperator) !f64 {
            const range = self.toPosRange(r);

            var total: f64 = 1;
            var results: std.ArrayList(Sheet.CellHandle) = .init(self.allocator);
            defer results.deinit();
            try self.sheet.cell_tree.queryWindow(
                &.{ range.tl.x, range.tl.y },
                &.{ range.br.x, range.br.y },
                &results,
            );

            for (results.items) |handle| {
                const res = try self.context.evalCellByHandle(handle);
                total *= try res.toNumber(1);
            }

            return total;
        }

        // TODO: This function assumes that ranges do not overlap?
        fn evalAvg(self: @This(), start: Index, end: Index) !f64 {
            const tags = self.nodes.items(.tag);
            const data = self.nodes.items(.data);

            var iter = argIterator(self.nodes, start, end);
            var total: f64 = 0;
            var total_items: Position.HashInt = 0;

            while (iter.next()) |i| switch (tags[i.n]) {
                .range => {
                    const r = data[i.n].range;
                    total += try self.sumRange(r);

                    const rect: Rect = .initPos(
                        data[r.lhs.n].pos,
                        data[r.rhs.n].pos,
                    );

                    total_items += rect.area();
                },
                .invalidated_range => return error.NotEvaluable,
                else => {
                    const res = try self.eval(i);
                    total += try res.toNumber(0);
                    total_items += 1;
                },
            };

            return total / @as(f64, @floatFromInt(total_items));
        }

        fn evalMax(self: @This(), start: Index, end: Index) !f64 {
            const tags = self.nodes.items(.tag);
            const data = self.nodes.items(.data);

            var iter = argIterator(self.nodes, start, end);
            var max: ?f64 = null;

            while (iter.next()) |i| {
                const m = switch (tags[i.n]) {
                    .range => try self.maxRange(data[i.n].range),
                    .invalidated_range => return error.NotEvaluable,
                    else => blk: {
                        const res = try self.eval(i);
                        break :blk try res.toNumberOrNull();
                    },
                } orelse continue;

                if (max == null or m > max.?) max = m;
            }

            return max orelse 0;
        }

        fn maxRange(self: @This(), r: BinaryOperator) !?f64 {
            const range = self.toPosRange(r);

            var max: ?f64 = null;
            var results: std.ArrayList(Sheet.CellHandle) = .init(self.allocator);
            defer results.deinit();
            try self.sheet.cell_tree.queryWindow(
                &.{ range.tl.x, range.tl.y },
                &.{ range.br.x, range.br.y },
                &results,
            );
            for (results.items) |handle| {
                const res = try self.context.evalCellByHandle(handle);
                const n = try res.toNumberOrNull() orelse continue;
                if (max == null or n > max.?) max = n;
            }

            return max;
        }

        fn evalMin(self: @This(), start: Index, end: Index) !f64 {
            const tags = self.nodes.items(.tag);
            const data = self.nodes.items(.data);

            var iter = argIterator(self.nodes, start, end);
            var min: ?f64 = null;

            while (iter.next()) |i| {
                const m = switch (tags[i.n]) {
                    .range => try self.minRange(data[i.n].range),
                    .invalidated_range => return error.NotEvaluable,
                    else => blk: {
                        const res = try self.eval(i);
                        break :blk try res.toNumberOrNull();
                    },
                } orelse continue;

                if (min == null or m < min.?) min = m;
            }

            return min orelse 0;
        }

        fn minRange(self: @This(), r: BinaryOperator) !?f64 {
            const range = self.toPosRange(r);

            var min: ?f64 = null;
            var results: std.ArrayList(Sheet.CellHandle) = .init(self.allocator);
            defer results.deinit();
            try self.sheet.cell_tree.queryWindow(
                &.{ range.tl.x, range.tl.y },
                &.{ range.br.x, range.br.y },
                &results,
            );
            for (results.items) |handle| {
                const res = try self.context.evalCellByHandle(handle);
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
    pos: Position,
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
        .pos = pos,
    };

    const res = try ctx.eval(root_node);

    return switch (res) {
        .none => .none,
        .number => |n| .{ .number = n },
        .string => |str| .{ .string = try sheet.allocator.dupeZ(u8, str) },
        .cell_string => |i| .{
            .string = try sheet.allocator.dupeZ(u8, i.sheet.string_values.items(i.list_index)),
        },
    };
}

test "Parse and Eval Expression" {
    const t = std.testing;
    const Context = struct {
        pub fn evalCellByHandle(_: @This(), _: Sheet.CellHandle) !EvalResult {
            unreachable;
        }

        pub fn evalCellByPos(_: @This(), _: Position) !EvalResult {
            unreachable;
        }
    };

    const Error = EvalContext(void).Error || Parser.ParseError;

    const testExpr = struct {
        fn func(expected: Error!f64, expr: [:0]const u8) !void {
            const sheet = try Sheet.create(t.allocator);
            defer sheet.destroy();

            const expr_root = fromExpression(sheet, expr) catch |err| {
                return if (err != expected) err else {};
            };

            const res = eval(
                sheet.ast_nodes,
                expr_root,
                .init(0, 0),
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
        fn testSheetExpr(expected: f64, expr: [:0]const u8) !void {
            const sheet = try Sheet.create(t.allocator);
            defer sheet.destroy();

            try sheet.setCell(try Position.fromAddress("A0"), "0", try fromExpression(sheet, "0"), .{});
            try sheet.setCell(try Position.fromAddress("B0"), "100", try fromExpression(sheet, "100"), .{});
            try sheet.setCell(try Position.fromAddress("A1"), "500", try fromExpression(sheet, "500"), .{});
            try sheet.setCell(try Position.fromAddress("B1"), "333.33", try fromExpression(sheet, "333.33"), .{});

            const expr_root = try fromExpression(sheet, expr);

            try sheet.update();
            const res = try eval(
                sheet.ast_nodes,
                expr_root,
                .init(0, 0),
                sheet,
                "",
                sheet,
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

//         pub fn evalCellByHandle(_: @This(), _: Sheet.CellHandle) !EvalResult {
//             return .none;
//         }
//     };

//     const sheet = try Sheet.create(t.allocator);
//     defer sheet.destroy();

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
