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
const List = @import("list.zig").List;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Ast = @This();

nodes: NodeList,
extra: std.ArrayListAligned(u8, .@"16"),
strings: std.ArrayList(u8),

pub const NodeList = MultiList(Node, u48);

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

pub fn tagPtr(ast: *const Ast, index: Node.Index) *Node.Tag {
    return ast.nodes.ptr(index, .tag);
}

pub fn payloadPtr(ast: *const Ast, index: Node.Index) *Node.Payload {
    return ast.nodes.ptr(index, .data);
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
    data[len - 2] = .{ .end = .{ .length = data[len - 1].end.length - 1 } };

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

    pub const OptionalIndex = NodeList.OptionalIndex;
    pub const Index = NodeList.Index;

    pub const Payload = blk: {
        var t = @typeInfo(Tagged).@"union";
        t.layout = .@"extern";
        t.tag_type = null;
        break :blk @Type(.{ .@"union" = t });
    };

    pub const Builtin = extern struct {
        tag: Builtin.Tag,

        pub const Tag = enum(u8) {
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

    pub const CaptureDeclaration = packed struct(u64) {
        unused: u8 = 0,
        offset: u8,
        scope: Index,
    };

    pub const LocalVariable = extern struct {
        offset: u8,
    };

    pub const CapturedVariable = packed struct(u64) {
        slot: u8,
        offset: u8,
        scope: Index,
    };

    pub const FunctionDefStart = packed struct(u64) {
        arg_count: u8,
        capture_count: u8,
        body_length: u48,

        pub fn length(def: FunctionDefStart) u48 {
            return def.arg_count + def.body_length + def.capture_count;
        }

        pub fn args(_: FunctionDefStart) u48 {
            return 1;
        }

        pub fn bodyStart(def: FunctionDefStart) u48 {
            return 1 + @as(u48, def.arg_count);
        }

        pub fn body(def: FunctionDefStart) u48 {
            return def.arg_count + def.body_length;
        }

        pub fn captures(def: FunctionDefStart) u48 {
            return @as(u48, 1) + def.arg_count + def.body_length;
        }
    };

    pub const FunctionDefEnd = packed struct(u64) {
        arg_count: u8,
        capture_count: u8,
        body_length: u48,

        pub fn length(def: FunctionDefEnd) u48 {
            return def.arg_count + def.body_length + def.capture_count;
        }

        pub fn body(def: FunctionDefEnd) u48 {
            return 1 + @as(u48, def.capture_count);
        }

        pub fn start(def: FunctionDefEnd) u48 {
            return 1 + def.capture_count + def.body_length + def.arg_count;
        }

        pub fn args(def: FunctionDefEnd) u48 {
            return def.capture_count + def.body_length + def.arg_count;
        }
    };

    pub const FunctionCall = packed struct(u64) {
        unused: u7 = 0,
        is_pipe: bool,
        arg_count: u8,
        function_index: u48,
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
        end: packed struct(u64) {
            unused: u16 = 0,
            /// Stores the number of nodes in the AST.
            length: u48,
        },
        number: f64,
        abs_abs: Position,
        abs_rel: Position,
        rel_abs: Position,
        rel_rel: Position,
        string_literal: String,
        invalidated_pos: Position,
        invalidated_range,

        function_body_start: FunctionDefStart,
        function_body_end: FunctionDefEnd,
        function_parameter: String,
        function_capture: CaptureDeclaration,
        function_call: FunctionCall,
        local_variable: LocalVariable,
        captured_variable: CapturedVariable,

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
        invalidated_pos,
        invalidated_range,

        function_body_start,
        function_body_end,
        function_parameter,
        function_capture,
        function_call,
        local_variable,
        captured_variable,

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
                .function_body_end,
                .function_body_start,
                .function_parameter,
                .function_capture,
                .local_variable,
                .captured_variable,
                .function_call,
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
                .add, .mul, .equals, .not_equals => true,
                else => false,
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
                .function_body_start,
                .function_body_end,
                .function_parameter,
                .function_capture,
                .local_variable,
                .captured_variable,
                => 127,

                // Actual operators
                .function_call => 4,
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

pub fn string(ast: *const Ast, str: String) []u8 {
    return ast.strings.items[str.start..str.end];
}

pub fn printFromIndex(
    ast: *const Ast,
    index: Node.Index,
    writer: *std.io.Writer,
    current_function: Node.OptionalIndex,
) std.io.Writer.Error!void {
    const n = ast.nodes.get(index);
    return ast.printFromNode(index, n, writer, current_function);
}

pub fn printFromNode(
    ast: *const Ast,
    index: Node.Index,
    data: Node,
    w: *std.io.Writer,
    /// Index of the `function_body_start` node of the current function's defintion.
    current_function: Node.OptionalIndex,
) std.io.Writer.Error!void {
    // On the left-hand side, expressions involving operators with lower precedence need
    // parentheses.

    // On the right-hand side, expressions involving operators with lower precedence, or
    // non-commutative operators with the same precedence need to be surrounded by parentheses.
    switch (data.get()) {
        .function_capture => {
            try ast.printFromIndex(index.subi(1), w, current_function);
        },
        .function_call => |call| {
            const func = index.subi(call.function_index);
            if (call.is_pipe) {
                var iter = ast.argIteratorForwards(index.subi(call.function_index), index);
                // Skip function
                _ = iter.next().?;
                // Print first argument
                try ast.printFromIndex(iter.next().?, w, current_function);
                try w.writeAll(" |> ");
                iter = ast.argIteratorForwards(index.subi(call.function_index), index);

                const needs_parentheses = ast.tag(func) != .function_call and
                    func != ast.leftMostChild(func);
                if (needs_parentheses) try w.writeByte('(');
                try ast.printFromIndex(iter.next().?, w, current_function);
                if (needs_parentheses) try w.writeByte(')');
                // Skip first argument
                _ = iter.next().?;

                try w.writeByte('(');
                if (iter.next()) |arg_index| {
                    try ast.printFromIndex(arg_index, w, current_function);
                }

                while (iter.next()) |arg_index| {
                    try w.writeAll(", ");
                    try ast.printFromIndex(arg_index, w, current_function);
                }
                try w.writeByte(')');
            } else {
                const needs_parentheses = ast.tag(func) != .function_call and
                    func != ast.leftMostChild(func);

                if (needs_parentheses) try w.writeByte('(');
                var iter = ast.argIteratorForwards(index.subi(call.function_index), index);
                if (iter.next()) |arg_index| {
                    try ast.printFromIndex(arg_index, w, current_function);
                }
                if (needs_parentheses) try w.writeByte(')');
                try w.writeByte('(');
                if (iter.next()) |arg_index| {
                    try ast.printFromIndex(arg_index, w, current_function);
                }

                while (iter.next()) |arg_index| {
                    try w.writeAll(", ");
                    try ast.printFromIndex(arg_index, w, current_function);
                }

                try w.writeByte(')');
            }
        },
        .local_variable => |v| {
            const identifier = current_function.unwrap().?.addi(1 + v.offset);
            assert(ast.tag(identifier) == .function_parameter);
            const str = ast.payload(identifier).function_parameter;
            const bytes = ast.string(str);
            try w.writeAll(bytes);
        },
        .captured_variable => |v| {
            const parameter_index = v.scope.addi(1 + v.slot);
            assert(ast.tag(parameter_index) == .function_parameter);
            const str = ast.payload(parameter_index).function_parameter;
            const bytes = ast.string(str);
            try w.writeAll(bytes);
        },
        .function_body_start => |def| {
            try w.writeByte('|');
            const arg_index = index.addi(def.args());
            const args = ast.nodes.subslice(@intFromEnum(arg_index), def.arg_count);
            for (0..args.len()) |i| {
                assert(args.item(args.index(i), .tag) == .function_parameter);
                const str = args.item(args.index(i), .data).function_parameter;
                const bytes = ast.string(str);
                try w.writeAll(bytes);
                if (i + 1 < args.len())
                    try w.writeAll(", ");
            }
            try w.writeAll("| ");
            try ast.printFromIndex(
                index.addi(def.body()),
                w,
                index.toOptional(),
            );
        },
        .function_body_end => |def| {
            try w.writeByte('|');
            const arg_index = index.subi(def.args());
            const args = ast.nodes.subslice(@intFromEnum(arg_index), def.arg_count);
            for (0..args.len()) |i| {
                assert(args.item(args.index(i), .tag) == .function_parameter);
                const str = args.item(args.index(i), .data).function_parameter;
                const bytes = ast.string(str);
                try w.writeAll(bytes);
                if (i + 1 < args.len())
                    try w.writeAll(", ");
            }
            try w.writeAll("| ");
            try ast.printFromIndex(
                index.subi(def.body()),
                w,
                index.subi(def.start()).toOptional(),
            );
        },
        .function_parameter => unreachable,

        .number => |n| try w.print("{d}", .{n}),
        .rel_rel => |pos| try w.print("{f}", .{pos}),
        .rel_abs => |pos| try w.print("{f}${d}", .{
            Position.fmtColumnAddress(pos.x), pos.y,
        }),
        .abs_rel => |pos| try w.print("${f}{d}", .{
            Position.fmtColumnAddress(pos.x), pos.y,
        }),
        .abs_abs => |pos| try w.print("${f}${d}", .{
            Position.fmtColumnAddress(pos.x), pos.y,
        }),
        .invalidated_pos => |pos| try w.print("{f}", .{pos}),
        .string_literal => |str| {
            try w.print("\"{s}\"", .{ast.strings.items[str.start..str.end]});
        },
        .end => {
            try ast.printFromIndex(index.subi(1), w, current_function);
        },
        .assignment => |pos| {
            try w.print("let {f} = ", .{pos});
            try ast.printFromIndex(index.subi(1), w, current_function);
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

            try w.writeByte(byte);
            // TODO: Remove this
            if (rhs.tag.isSingle()) {
                try ast.printFromNode(n, rhs, w, current_function);
            } else {
                try w.writeByte('(');
                try ast.printFromNode(n, rhs, w, current_function);
                try w.writeByte(')');
            }
        },
        inline .equals,
        .not_equals,
        .mul,
        .add,
        => |_, t| {
            const str = switch (t) {
                .equals => "==",
                .not_equals => "!=",
                .add => "+",
                .mul => "*",
                else => comptime unreachable,
            };

            const rhs = index.subi(1);
            const lhs = ast.leftMostChild(rhs).subi(1);

            const rhs_prec = ast.tag(rhs).precedence();
            const lhs_prec = ast.tag(lhs).precedence();
            const prec = comptime t.precedence();

            if (lhs_prec < prec) {
                try w.writeByte('(');
                try ast.printFromIndex(lhs, w, current_function);
                try w.writeByte(')');
            } else {
                try ast.printFromIndex(lhs, w, current_function);
            }

            try w.writeAll(" " ++ str ++ " ");

            if (rhs_prec < prec or rhs_prec == prec and !ast.tag(rhs).isCommutative()) {
                try w.writeByte('(');
                try ast.printFromIndex(rhs, w, current_function);
                try w.writeByte(')');
            } else {
                try ast.printFromIndex(rhs, w, current_function);
            }
        },
        // Non-commutative operators
        inline .sub,
        .div,
        .mod,
        .pow,
        .concat,
        .greater_than,
        .less_than,
        .greater_equals,
        .less_equals,
        .logical_or,
        .logical_and,
        => |_, t| {
            const str = switch (t) {
                .greater_than => ">",
                .less_than => "<",
                .greater_equals => ">=",
                .less_equals => "<=",
                .sub => "-",
                .div => "/",
                .mod => "%",
                .pow => "^",
                .concat => "#",
                .logical_or => "or",
                .logical_and => "and",
                else => comptime unreachable,
            };

            const rhs = index.subi(1);
            const lhs = ast.leftMostChild(rhs).subi(1);

            const rhs_prec = ast.tag(rhs).precedence();
            const lhs_prec = ast.tag(lhs).precedence();
            const prec = comptime t.precedence();

            if (lhs_prec < prec) {
                try w.writeByte('(');
                try ast.printFromIndex(lhs, w, current_function);
                try w.writeByte(')');
            } else {
                try ast.printFromIndex(lhs, w, current_function);
            }

            try w.writeAll(" " ++ str ++ " ");

            if (rhs_prec <= prec) {
                try w.writeByte('(');
                try ast.printFromIndex(rhs, w, current_function);
                try w.writeByte(')');
            } else {
                try ast.printFromIndex(rhs, w, current_function);
            }
        },
        .range, .invalidated_range, .dynamic_range => {
            const rhs = index.subi(1);
            const lhs = ast.leftMostChild(rhs).subi(1);
            try ast.printFromIndex(lhs, w, current_function);
            try w.writeByte(':');
            try ast.printFromIndex(rhs, w, current_function);
        },

        .builtin => |b| {
            try w.print("@{f}", .{b.tag});
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
    buffer: [256]Node.Index = undefined,
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

pub fn exprLen(ast: *const Ast, root: Node.Index) u48 {
    assert(ast.tag(root.addi(1)) == .end);
    return ast.payload(root.addi(1)).end.length;
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

pub const FormatData = struct {
    ast: *const Ast,
    root: Node.Index,
};

pub fn fmtExpression(ast: *const Ast, root: Node.Index) std.fmt.Alt(FormatData, format) {
    return .{ .data = .{ .ast = ast, .root = root } };
}

pub fn format(f: FormatData, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try f.ast.print(f.root, w);
}

pub fn print(
    ast: *const Ast,
    root: Node.Index,
    writer: *std.io.Writer,
) std.Io.Writer.Error!void {
    return ast.printFromIndex(root, writer, .none);
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
        .function_body_start,
        .local_variable,
        .captured_variable,
        .builtin,
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
        .minus,
        .plus,
        .not,
        .reference,
        .dereference,
        .assignment,
        .end,
        .function_parameter,
        .function_capture,
        => ast.leftMostChild(index.subi(1)),
        .function_body_end => |def| index.subi(def.length() + 1),
        .function_call => |call| ast.leftMostChild(index.subi(call.function_index)),
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
    function: Function,
    builtin_function: BuiltinFunction,
    indirect_range: Range,
    indirect_cell: Position,

    pub const Function = struct {
        root: Node.Index,
        captures: []Value = &.{},
    };

    pub const BuiltinFunction = struct {
        tag: Node.Builtin.Tag,
    };

    pub const Range = struct {
        rect: Rect,
        map: Node.OptionalIndex = .none,

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
            .cell, .indirect_cell => true,
            .range, .indirect_range => true,
            .function, .builtin_function => true,
        };
    }
};

pub const StackFrame = union(enum) {
    value: Value,
    cell_literal: Position,
    function_header: FunctionHeader,

    pub const FunctionHeader = struct {
        parent: OptionalIndex,
        return_address: Node.Index,
    };

    pub const Index = List(StackFrame, u32).Index;
    pub const OptionalIndex = List(StackFrame, u32).OptionalIndex;
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

pub const Interpreter = struct {
    arena: Allocator,
    sheet: *Sheet,
    stack: List(StackFrame, u32) = .empty,

    /// Index of the current function header in the stack
    header: StackFrame.OptionalIndex = .none,
    is_volatile: bool = false,

    pub const EvaluateResult = struct {
        is_volatile: bool,
    };

    const Direction = enum {
        direct,
        indirect,
    };

    fn push(eval: *Interpreter, res: StackFrame) !void {
        try eval.stack.append(eval.arena, res);
    }

    fn pushv(eval: *Interpreter, value: Value) !void {
        return eval.push(.{ .value = value });
    }

    pub fn pop(eval: *Interpreter, result_type: ResultType) !Value {
        return switch (eval.stack.pop().?) {
            .cell_literal => |pos| switch (result_type) {
                .reference => .{ .cell = pos },
                .any => eval.evaluateCell(pos, .direct),
            },
            .value => |v| v,
            .function_header => return error.NotEvaluable,
        };
    }

    /// Return the value at the specified index. Cell literals will be evaluated based on
    /// `result_type`.
    fn valueAt(eval: *Interpreter, index: StackFrame.Index, result_type: ResultType) !Value {
        const ret = eval.stack.get(index);
        return switch (ret) {
            .cell_literal => |pos| switch (result_type) {
                .reference => .{ .cell = pos },
                .any => eval.evaluateCell(pos, .direct),
            },
            .value => |v| v,
            .function_header => return error.NotEvaluable,
        };
    }

    fn evaluateCellPush(
        eval: *Interpreter,
        pos: Position,
        comptime direct: Direction,
    ) !void {
        const res = try eval.evaluateCell(pos, direct);
        try eval.push(.{ .value = res });
    }

    /// Returns the value of a cell. If the access is indirect, sets the volatile flag.
    fn evaluateCell(
        eval: *Interpreter,
        pos: Position,
        comptime direct: Direction,
    ) !Value {
        if (direct == .indirect) eval.is_volatile = true;
        return try eval.sheet.evalCellByPos(eval, pos);
    }

    fn evaluateBuiltin(eval: *Interpreter, builtin_tag: Node.Builtin.Tag, arg_count: u8) !Value {
        return switch (builtin_tag) {
            .sum => .{ .number = try eval.evalSum(arg_count) },
            .prod => .{ .number = try eval.evalProd(arg_count) },
            .avg => .{ .number = try eval.evalAvg(arg_count) },
            .max => .{ .number = try eval.evalMax(arg_count) },
            .min => .{ .number = try eval.evalMin(arg_count) },
            .upper => .{ .string = .{ .slice = try eval.evalUpper(arg_count) } },
            .lower => .{ .string = .{ .slice = try eval.evalLower(arg_count) } },
            .sqrt => .{ .number = try eval.evalSqrt(arg_count) },
            .round => .{ .number = try eval.evalRound(arg_count) },
            .floor => .{ .number = try eval.evalFloor(arg_count) },
            .ceil => .{ .number = try eval.evalCeil(arg_count) },
            .len => .{ .number = try eval.evalStringLen(arg_count) },
            .count => .{ .number = try eval.evalCount(.numbers, arg_count) },
            .count_all => .{ .number = try eval.evalCount(.all, arg_count) },
            .log => .{ .number = try eval.evalLog(arg_count) },
            .pi => {
                if (arg_count != 0) return error.NotEvaluable;
                return .{ .number = std.math.pi };
            },
            .e => {
                if (arg_count != 0) return error.NotEvaluable;
                return .{ .number = std.math.e };
            },
            .width => .{ .number = try eval.evalWidth(arg_count) },
            .height => .{ .number = try eval.evalHeight(arg_count) },
        };
    }

    pub fn evaluate(eval: *Interpreter, start: Node.Index) !EvaluateResult {
        const ast = &eval.sheet.ast;
        var i = start;
        while (true) : (i = i.addi(1)) switch (ast.node(i)) {
            .end => break,
            .number => |n| try eval.pushv(.{ .number = n }),
            .rel_rel, .rel_abs, .abs_rel, .abs_abs => |pos| {
                try eval.push(.{ .cell_literal = pos });
            },
            .string_literal => |str| {
                try eval.pushv(.{ .string = .{ .slice = ast.string(str) } });
            },
            .invalidated_pos, .invalidated_range => return error.NotEvaluable,
            .function_body_start => |def| {
                // Capture any necessary values
                const captures = ast.nodes.subsliceIndex(i.addi(def.captures()), def.capture_count);
                const cap_slice = try eval.arena.alloc(Value, def.capture_count);
                for (cap_slice, captures.items(.data)) |*dest, data| {
                    const cap = data.function_capture;
                    var frame = eval.header;
                    while (frame.unwrap()) |f| : (frame = eval.stack.get(f).function_header.parent) {
                        const func = try eval.valueAt(f.addi(1), .any);
                        if (func.function.root == cap.scope) {
                            // Found the value
                            const value = eval.stack.get(f.addi(2).addi(cap.offset)).value;
                            dest.* = value;
                            break;
                        }
                    } else unreachable;
                }

                try eval.pushv(.{ .function = .{ .root = i, .captures = cap_slice } });
                i = i.addi(1 + def.length());
            },
            .function_body_end => {
                // Return from the function
                const header_index = eval.header.unwrap().?;
                const header = eval.stack.get(header_index).function_header;

                const return_value = eval.stack.pop().?;
                eval.stack.shrinkRetainingCapacity(header_index);
                eval.stack.appendAssumeCapacity(return_value);

                eval.header = header.parent;
                i = header.return_address;
            },
            .function_parameter => unreachable,
            .function_capture => {},
            .function_call => |call| {
                // The arguments are at the top of the stack, with the function to call below.
                const index = eval.stack.lastIndex().subi(1).subi(call.arg_count);
                const arg = try eval.valueAt(index, .any);
                switch (arg) {
                    .function => {
                        const func = arg.function.root;
                        assert(eval.sheet.ast.tag(func) == .function_body_start);
                        const def = eval.sheet.ast.payload(func).function_body_start;
                        if (def.arg_count != call.arg_count)
                            return error.NotEvaluable;

                        const old_header = eval.header;
                        eval.header = index.toOptional();
                        try eval.stack.inserti(
                            eval.arena,
                            eval.stack.len() - 1 - call.arg_count,
                            .{ .function_header = .{
                                .parent = old_header,
                                .return_address = i,
                            } },
                        );
                        i = func.addi(def.bodyStart() - 1);
                    },
                    // We don't need to insert a frame header because we don't actually 'jump'
                    // anywhere in the AST to evaluate a builtin.
                    .builtin_function => |f| {
                        const res = try eval.evaluateBuiltin(f.tag, call.arg_count);
                        eval.stack.shrinkRetainingCapacity(index);
                        try eval.pushv(res);
                    },
                    else => return error.NotEvaluable,
                }
            },
            .local_variable => |v| {
                // TODO: Should this resolve cell literals?
                const frame = eval.header.unwrap().?;
                const value = eval.stack.get(frame.addi(2).addi(v.offset));
                assert(value != .function_header);
                try eval.push(value);
            },
            .captured_variable => |v| {
                const frame = eval.header.unwrap().?;
                const func = (try eval.valueAt(frame.addi(1), .any)).function;
                const value = func.captures[v.offset];
                try eval.pushv(value);
            },

            .assignment => return error.NotEvaluable,
            .builtin => |b| {
                try eval.pushv(.{ .builtin_function = .{ .tag = b.tag } });
            },
            .minus => {
                const rhs = try eval.pop(.any);
                try eval.pushv(.{ .number = -(try eval.toNumber(rhs, 0)) });
            },
            .plus => {
                const rhs = try eval.pop(.any);
                try eval.pushv(.{ .number = @abs(try eval.toNumber(rhs, 0)) });
            },
            .not => {
                const rhs = try eval.pop(.any);
                try eval.pushv(.{
                    .number = @floatFromInt(@intFromBool(!rhs.boolean(eval.sheet))),
                });
            },
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
                try eval.pushv(.{ .string = .{ .slice = try aw.toOwnedSlice() } });
            },
            inline .add, .sub, .mul, .pow => |_, t| {
                const rhs = try eval.pop(.any);
                const lhs = try eval.pop(.any);
                const l = try eval.toNumber(lhs, 0);
                const r = try eval.toNumber(rhs, 0);
                const res: f64 = switch (t) {
                    .add => l + r,
                    .sub => l - r,
                    .mul => l * r,
                    .pow => std.math.pow(f64, l, r),
                    else => comptime unreachable,
                };
                try eval.pushv(.{ .number = res });
            },
            .div => {
                const rhs = try eval.pop(.any);
                const lhs = try eval.pop(.any);
                const l = try eval.toNumber(lhs, 0);
                const r = try eval.toNumber(rhs, 0);
                if (r == 0) return error.DivideByZero;
                try eval.pushv(.{ .number = l / r });
            },
            .mod => {
                const rhs = try eval.pop(.any);
                const lhs = try eval.pop(.any);
                const l = try eval.toNumber(lhs, 0);
                const r = try eval.toNumber(rhs, 0);
                if (r <= 0) return error.DivideByZero;
                try eval.pushv(.{ .number = @rem(l, r) });
            },
            .reference => {
                const arg = try eval.pop(.reference);
                try eval.pushv(.{ .cell = arg.cell });
            },
            .dereference => {
                const arg = try eval.pop(.reference);
                switch (arg) {
                    .cell => |pos| try eval.evaluateCellPush(pos, .direct),
                    .indirect_cell => |pos| try eval.evaluateCellPush(pos, .indirect),
                    else => return error.NotEvaluable,
                }
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

                try eval.pushv(res);
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

                try eval.pushv(.{ .number = @floatFromInt(@intFromBool(n)) });
            },
            inline .equals, .not_equals => |_, t| {
                const rhs = try eval.pop(.any);
                const lhs = try eval.pop(.any);

                const n = switch (lhs) {
                    .none => true,
                    .number => |n1| switch (rhs) {
                        .number => |n2| n1 == n2,
                        else => false,
                    },
                    .string => |str1| switch (rhs) {
                        .string => |str2| std.mem.eql(u8, str1.bytes(), str2.bytes()),
                        else => false,
                    },
                    .cell, .indirect_cell => |p1| switch (rhs) {
                        .cell, .indirect_cell => |p2| p1.eql(p2),
                        else => false,
                    },
                    .range, .indirect_range => |p1| switch (rhs) {
                        .range, .indirect_range => |p2| p1.eql(p2),
                        else => false,
                    },
                    .function => |f1| switch (rhs) {
                        .function => |f2| f1.root == f2.root,
                        else => false,
                    },
                    .builtin_function => |f1| switch (rhs) {
                        .builtin_function => |f2| f1.tag == f2.tag,
                        else => false,
                    },
                };

                const b = switch (t) {
                    .equals => n,
                    .not_equals => !n,
                    else => comptime unreachable,
                };
                try eval.pushv(.{ .number = @floatFromInt(@intFromBool(b)) });
            },
            .range, .dynamic_range => {
                const rhs = try eval.pop(.reference);
                const lhs = try eval.pop(.reference);
                const a = switch (lhs) {
                    .cell, .indirect_cell => |pos| pos,
                    else => return error.NotEvaluable,
                };
                const b = switch (rhs) {
                    .cell, .indirect_cell => |pos| pos,
                    else => return error.NotEvaluable,
                };

                try eval.pushv(.{ .range = .{ .rect = .initNormalizePos(a, b) } });
            },
        };

        return .{
            .is_volatile = eval.is_volatile,
        };
    }

    fn toNumber(eval: *const Interpreter, res: Value, none_value: f64) !f64 {
        return try eval.toNumberOrNull(res) orelse none_value;
    }

    fn toNumberOrNull(_: *const @This(), res: Value) !?f64 {
        return switch (res) {
            .none => null,
            .number => |n| n,
            .string => |str| std.fmt.parseFloat(f64, str.bytes()) catch error.InvalidCoercion,
            .cell,
            .indirect_cell,
            .range,
            .indirect_range,
            .function,
            .builtin_function,
            => error.InvalidCoercion,
        };
    }

    /// Coerces `res` to a number, dereferencing one level of reference if required.
    fn toNumberDeref(eval: *Interpreter, res: Value) !?f64 {
        return switch (res) {
            .none => null,
            .number => |n| n,
            .string => |str| std.fmt.parseFloat(f64, str.bytes()) catch error.InvalidCoercion,
            .cell => |pos| eval.toNumberOrNull(
                try eval.evaluateCell(pos, .direct),
            ),
            .indirect_cell => |pos| eval.toNumberOrNull(
                try eval.evaluateCell(pos, .indirect),
            ),
            .range, .indirect_range, .function, .builtin_function => error.InvalidCoercion,
        };
    }

    fn formatStringAlloc(eval: *const Interpreter, res: Value) ![]u8 {
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
            .cell, .indirect_cell => |c| try c.format(w),
            .range, .indirect_range => |r| try r.format(w),
            // TODO
            .function => try w.writeAll("FUNCTION"),
            .builtin_function => try w.writeAll("BUILTIN"),
        }
    }

    fn mapArgsNumber(eval: *Interpreter, arg_count: u8, ctx: anytype) !void {
        const MapContext = struct {
            eval: *Interpreter,
            outer_ctx: @TypeOf(ctx),

            pub fn func(inner_ctx: @This(), cell: Sheet.Cell.Handle) !void {
                const res = try inner_ctx.eval.sheet.evalCellByHandle(inner_ctx.eval, cell);
                const number = try inner_ctx.eval.toNumberOrNull(res);
                try inner_ctx.outer_ctx.func(number);
            }
        };

        for (0..arg_count) |_| {
            const res = try eval.pop(.reference);
            switch (res) {
                .cell => |pos| {
                    const res2 = try eval.evaluateCell(pos, .direct);
                    const number = try eval.toNumberOrNull(res2);
                    try ctx.func(number);
                },
                .indirect_cell => |pos| {
                    const res2 = try eval.evaluateCell(pos, .indirect);
                    const number = try eval.toNumberOrNull(res2);
                    try ctx.func(number);
                },
                inline .range, .indirect_range => |range, t| {
                    if (t == .indirect_range) eval.is_volatile = true;
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

    fn evalUpper(eval: *Interpreter, arg_count: u8) ![]const u8 {
        if (arg_count != 1) return error.NotEvaluable;
        const arg = try eval.pop(.any);
        const str = try eval.formatStringAlloc(arg);
        for (str) |*c| c.* = std.ascii.toUpper(c.*);
        return str;
    }

    fn evalLower(eval: *Interpreter, arg_count: u8) ![]const u8 {
        if (arg_count != 1) return error.NotEvaluable;
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

    fn evalSum(eval: *Interpreter, arg_count: u8) !f64 {
        var ctx: SumContext = .{};
        try eval.mapArgsNumber(arg_count, &ctx);
        return ctx.total;
    }

    fn evalProd(eval: *Interpreter, arg_count: u8) !f64 {
        var ctx: ProdContext = .{};
        try eval.mapArgsNumber(arg_count, &ctx);
        return ctx.total;
    }

    // TODO: This function assumes that ranges do not overlap?
    fn evalAvg(eval: *Interpreter, arg_count: u8) !f64 {
        var ctx: AvgContext = .{};
        try eval.mapArgsNumber(arg_count, &ctx);
        if (ctx.total_items == 0) return 0;
        return ctx.total / @as(f64, @floatFromInt(ctx.total_items));
    }

    fn evalMax(eval: *Interpreter, arg_count: u8) !f64 {
        var ctx: MaxContext = .{};
        try eval.mapArgsNumber(arg_count, &ctx);
        return ctx.max orelse 0;
    }

    fn evalMin(eval: *Interpreter, arg_count: u8) !f64 {
        var ctx: MinContext = .{};
        try eval.mapArgsNumber(arg_count, &ctx);
        return ctx.min orelse 0;
    }

    fn evalSqrt(eval: *Interpreter, arg_count: u8) !f64 {
        if (arg_count != 1) return error.NotEvaluable;
        const arg = try eval.pop(.reference);
        const n = try eval.toNumberDeref(arg) orelse 0;
        if (n < 0) return error.NotEvaluable;
        return std.math.sqrt(n);
    }

    fn evalRound(eval: *Interpreter, arg_count: u8) !f64 {
        if (arg_count != 1) return error.NotEvaluable;
        const arg = try eval.pop(.reference);
        const n = try eval.toNumberDeref(arg) orelse 0;
        return std.math.round(n);
    }

    fn evalFloor(eval: *Interpreter, arg_count: u8) !f64 {
        if (arg_count != 1) return error.NotEvaluable;
        const arg = try eval.pop(.reference);
        const n = try eval.toNumberDeref(arg) orelse 0;
        return @floor(n);
    }

    fn evalCeil(eval: *Interpreter, arg_count: u8) !f64 {
        if (arg_count != 1) return error.NotEvaluable;
        const arg = try eval.pop(.reference);
        const n = try eval.toNumberDeref(arg) orelse 0;
        return @ceil(n);
    }

    fn evalStringLen(eval: *Interpreter, arg_count: u8) !f64 {
        if (arg_count != 1) return error.NotEvaluable;
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
            inline .cell,
            .indirect_cell,
            .range,
            .indirect_range,
            => |value| return @floatFromInt(std.fmt.count("{f}", .{value})),
            .function, .builtin_function => return error.NotEvaluable,
        }
    }

    fn evalCount(
        eval: *Interpreter,
        comptime operation: enum { all, numbers },
        arg_count: u8,
    ) !f64 {
        const CountContext = struct {
            count: u65,
            eval: *Interpreter,

            pub fn func(ctx: *@This(), cell: Sheet.Cell.Handle) !void {
                const res = ctx.eval.sheet.evalCellByHandle(
                    ctx.eval,
                    cell,
                ) catch |err| switch (err) {
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
                inline .number, .string, .function, .builtin_function => |_, t| {
                    switch (operation) {
                        .all => total += 1,
                        .numbers => if (t == .number) {
                            total += 1;
                        },
                    }
                },
                inline .cell, .indirect_cell => |pos, t| {
                    if (t == .indirect_cell) eval.is_volatile = true;
                    const range: Rect = .initSinglePos(pos);
                    var ctx: CountContext = .{ .count = 0, .eval = eval };
                    try eval.sheet.cell_tree.traverse(
                        &range.tl.array(),
                        &range.br.array(),
                        &ctx,
                    );
                    total += ctx.count;
                },
                inline .range, .indirect_range => |range, t| {
                    if (t == .indirect_range) eval.is_volatile = true;
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

    fn evalLog(eval: *Interpreter, arg_count: u8) !f64 {
        if (arg_count != 2) return error.NotEvaluable;
        const base_result = try eval.pop(.any);
        const n_result = try eval.pop(.any);
        const base = try eval.toNumber(base_result, 10);
        const n = try eval.toNumber(n_result, 0);
        if (base <= 0 or base == 1 or n <= 0)
            return error.NotEvaluable;
        return std.math.log(f64, base, n);
    }

    fn evalWidth(eval: *Interpreter, arg_count: u8) !f64 {
        if (arg_count != 1) return error.NotEvaluable;
        const res = try eval.pop(.any);
        return switch (res) {
            .cell, .indirect_cell => 1,
            .range, .indirect_range => |r| @floatFromInt(r.rect.width2()),
            .none,
            .number,
            .string,
            .function,
            .builtin_function,
            => return error.NotEvaluable,
        };
    }

    fn evalHeight(eval: *Interpreter, arg_count: u8) !f64 {
        if (arg_count != 1) return error.NotEvaluable;
        const res = try eval.pop(.any);
        return switch (res) {
            .cell, .indirect_cell => 1,
            .range, .indirect_range => |r| @floatFromInt(r.rect.height2()),
            .none,
            .number,
            .string,
            .function,
            .builtin_function,
            => return error.NotEvaluable,
        };
    }
};

const CountDependenciesContext = struct {
    total: usize = 0,

    pub fn func(ctx: *CountDependenciesContext, _: Rect) void {
        ctx.total += 1;
    }
};

pub fn countDependencies(ast: *const Ast, root: Node.OptionalIndex) usize {
    var ctx: CountDependenciesContext = .{};
    ast.traverseDependencies(root, &ctx, CountDependenciesContext.func);
    return ctx.total;
}

pub fn traverseDependencies(
    ast: *const Ast,
    root: Node.OptionalIndex,
    ctx: anytype,
    func: fn (@TypeOf(ctx), Rect) void,
) void {
    const unwrapped = root.unwrap() orelse return;

    var traverse: TraverseDependencies(@TypeOf(ctx), func) = .{
        .ast = ast.*,
        .user_ctx = ctx,
    };
    traverse.traverse(unwrapped, .value, .no_deref);
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
                .function_capture => {
                    std.debug.print("WHAT: {{\n", .{});
                    for (0..self.ast.nodes.len()) |i| {
                        std.debug.print("  {any}\n", .{self.ast.nodes.geti(i).get()});
                    }
                    std.debug.print("}}\n", .{});
                    unreachable;
                },
                .function_call => |call| {
                    const start = index.subi(call.function_index);
                    var iter = ast.argIteratorForwards(start, index);
                    while (iter.next()) |i| {
                        self.traverse(i, .reference, .deref);
                    }
                    const func_node = index.subi(call.function_index);
                    self.traverse(func_node, .value, .no_deref);
                },
                .local_variable, .captured_variable => {},
                // Defining a function doesn't add a dependency but calling it would
                .function_body_start => |def| {
                    self.traverse(index.addi(def.body()), .value, .no_deref);
                },
                .function_body_end => |def| {
                    self.traverse(index.subi(def.body()), .value, .no_deref);
                },
                .function_parameter => unreachable,
                .assignment, .end => {
                    self.traverse(index.subi(1), ctx, .no_deref);
                },
                .number,
                .string_literal,
                .invalidated_pos,
                .invalidated_range,
                .builtin,
                => {},
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
        const end = iter.data[iter.i].end;
        const ret = iter.i - 1;
        iter.i -= end.length;
        return @enumFromInt(ret);
    }
};

test "Parse and Eval Expression" {
    const t = std.testing;
    const testExpr = struct {
        fn func(expected: anyerror!f64, src: []const u8) !void {
            var sheet = try Sheet.init(t.allocator);
            defer sheet.deinit();

            const expr = sheet.parseFromExpression(src) catch |err| {
                return if (err != expected) err else {};
            };

            const res = sheet.evaluate(expr.root) catch |err| {
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
            const res = try sheet.evaluate(expr.root);
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
    try testSheetExpr(0, "@sum()");

    try testSheetExpr(0, "@prod(a0:a0)");
    try testSheetExpr(0, "@prod(a0:b0)");
    try testSheetExpr(0, "@prod(a0:a1)");
    try testSheetExpr(0, "@prod(a0:b1)");
    try testSheetExpr(166665, "@prod(a1:b1)");
    try testSheetExpr(166665, "@prod(a1:z10)");
    try testSheetExpr(333.33, "@prod(b1:z10)");
    try testSheetExpr(0, "@prod(100, -1, a0:z10, 50)");
    try testSheetExpr(-166665000, "@prod(100, -1, b0:b1, 50)");
    try testSheetExpr(1, "@prod()");

    try testSheetExpr(0, "@avg(a0:a0)");
    try testSheetExpr(50, "@avg(a0:b0)");
    try testSheetExpr(250, "@avg(a0:a1)");
    try testSheetExpr(233.3325, "@avg(a0:b1)");
    try testSheetExpr(135.47571428571428571428, "@avg(5, 5, a0:b1, 5)");
    try testSheetExpr(0, "@avg()");

    try testSheetExpr(0, "@max(a0:a0)");
    try testSheetExpr(100, "@max(a0:b0)");
    try testSheetExpr(500, "@max(a0:a1)");
    try testSheetExpr(500, "@max(a0:b1)");
    try testSheetExpr(100, "@max(a0:z0)");
    try testSheetExpr(500, "@max(a0:z10)");
    try testSheetExpr(0, "@max(c3:z10)");
    try testSheetExpr(3, "@max(3, c3:z10, 1, 2)");
    try testSheetExpr(500, "@max(3, a0:b1, 1, 2)");
    try testSheetExpr(0, "@max(0)");

    try testSheetExpr(0, "@min(a0:a0)");
    try testSheetExpr(0, "@min(a0:b0)");
    try testSheetExpr(0, "@min(a0:a1)");
    try testSheetExpr(0, "@min(a0:b1)");
    try testSheetExpr(333.33, "@min(a1:z10)");
    try testSheetExpr(0, "@min(c3:z10)");
    try testSheetExpr(1, "@min(3, c3:z10, 1, 2)");
    try testSheetExpr(0, "@min(3, a0:b1, 1, 2)");
    try testSheetExpr(0, "@min()");
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
        "(1 or 2) and 3",
        "(1 + 2) * 3",
        "(|x| x * 2)(5) == 10",
        "-(1 + 2)",

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

fn testVolatile(src: []const u8, is_volatile: bool) !void {
    var sheet: Sheet = try .init(std.testing.allocator);
    defer sheet.deinit();
    const res = try sheet.parseFromExpression(src);

    var arena_impl: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_impl.deinit();
    const arena = arena_impl.allocator();

    var int: Interpreter = .{
        .arena = arena,
        .ast = sheet.ast,
        .data = sheet.ast.payloads(),
        .tags = sheet.ast.tags(),
        .sheet = &sheet,
    };
    _ = try int.evaluate(sheet.ast.leftMostChild(res.root));
    try std.testing.expectEqual(is_volatile, int.is_volatile);
}
