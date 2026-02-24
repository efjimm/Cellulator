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
            range,
            filter,
            map,

            pub fn format(t: Builtin.Tag, w: *std.Io.Writer) !void {
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
        function_offset: u48,
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

    pub const End = packed struct(u64) {
        unused: u16 = 0,
        /// Stores the number of nodes in the AST.
        length: u48,
    };

    pub const Tuple = packed struct(u64) {
        unused: u8 = 0,
        arg_count: u8,
        length: u48,
    };

    pub const Payload = extern union {
        end: End,
        nil: void,
        number: f64,
        abs_abs_value: Position,
        abs_rel_value: Position,
        rel_abs_value: Position,
        rel_rel_value: Position,
        abs_abs_reference: Position,
        abs_rel_reference: Position,
        rel_abs_reference: Position,
        rel_rel_reference: Position,
        string_literal: String,
        invalidated_pos: Position,
        invalidated_range: void,

        function_body_start: FunctionDefStart,
        function_body_end: FunctionDefEnd,
        function_parameter: String,
        function_capture: CaptureDeclaration,
        function_call: FunctionCall,
        pipe_call: FunctionCall,
        local_variable: LocalVariable,
        captured_variable: CapturedVariable,

        assignment: Position,
        builtin: Builtin,
        minus: void,
        plus: void,
        not: void,
        concat: void,
        add: void,
        sub: void,
        mul: void,
        div: void,
        mod: void,
        pow: void,
        greater_than: void,
        less_than: void,
        greater_equals: void,
        less_equals: void,
        equals: void,
        not_equals: void,
        logical_and: void,
        logical_or: void,

        /// The colon operator with two static arguments.
        /// Cell value accesses through this range are non-volatile.
        range: void,
        /// The colon operator with one or more dynamic arguments.
        /// Cell value accesses through this range are volatile.
        dynamic_range: void,

        reference: void,
        dereference: void,
        tuple: Tuple,
    };

    pub const Tagged = union(Tag) {
        end: End,
        nil,
        number: f64,
        abs_abs_value: Position,
        abs_rel_value: Position,
        rel_abs_value: Position,
        rel_rel_value: Position,
        abs_abs_reference: Position,
        abs_rel_reference: Position,
        rel_abs_reference: Position,
        rel_rel_reference: Position,
        string_literal: String,
        invalidated_pos: Position,
        invalidated_range,

        function_body_start: FunctionDefStart,
        function_body_end: FunctionDefEnd,
        function_parameter: String,
        function_capture: CaptureDeclaration,
        function_call: FunctionCall,
        pipe_call: FunctionCall,
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
        tuple: Tuple,
    };

    pub const Tag = enum(u8) {
        end,
        nil,
        number,
        abs_abs_value,
        abs_rel_value,
        rel_abs_value,
        rel_rel_value,
        abs_abs_reference,
        abs_rel_reference,
        rel_abs_reference,
        rel_rel_reference,
        string_literal,
        invalidated_pos,
        invalidated_range,

        function_body_start,
        function_body_end,
        function_parameter,
        function_capture,
        function_call,
        pipe_call,
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
        tuple,

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
                .nil,
                .number,
                .abs_abs_value,
                .abs_rel_value,
                .rel_abs_value,
                .rel_rel_value,
                .abs_abs_reference,
                .abs_rel_reference,
                .rel_abs_reference,
                .rel_rel_reference,
                .builtin,
                .invalidated_pos,
                .string_literal,
                .assignment, // Not a real operator
                .function_body_start,
                .function_body_end,
                .function_parameter,
                .function_capture,
                .local_variable,
                .captured_variable,
                .tuple,
                => 127,

                // Actual operators
                .function_call => 6,
                .reference => 5,
                .dereference => 5,
                .range, .dynamic_range, .invalidated_range => 4,
                .minus => 3,
                .plus => 3,
                .not => 3,
                .pow => 2,
                .mul => 1,
                .div => 1,
                .mod => 1,
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
                .pipe_call => -4,
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

/// Prints an AST as an expression.
///
/// This function is non-recursive and does many small allocations. The arena is first pre-heated
/// by allocating and immediately freeing 1024 bytes. If this allocation fails the function continues
/// as normal and returns any other allocation errors as usual.
pub fn print(
    ast: *const Ast,
    arena: Allocator,
    first_node: Node.Index,
    w: *std.Io.Writer,
) (Allocator.Error || std.Io.Writer.Error)!void {
    if (arena.alloc(u8, 1024)) |bytes| {
        arena.free(bytes);
    } else |_| {}

    const Item = struct { str: []const u8, tag: Node.Tag };
    var function_stack_allocator = std.heap.stackFallback(512, arena);
    const fsa = function_stack_allocator.get();
    var function_stack: std.ArrayList(Node.Index) = .empty;
    var stack: std.ArrayList(Item) = .empty;
    try stack.ensureTotalCapacity(arena, 128);

    var i = first_node;
    while (true) : (i = i.addi(1)) {
        var str: std.ArrayList(u8) = .empty;
        try str.ensureTotalCapacity(arena, 32);
        sw: switch (ast.node(i)) {
            .function_body_start => |f| {
                try function_stack.ensureUnusedCapacity(fsa, 1);
                try str.ensureTotalCapacity(arena, 2 + f.arg_count * 5);
                str.appendAssumeCapacity('|');
                const parameters = ast.payloads()[@intFromEnum(i.addi(1))..][0..f.arg_count];
                if (parameters.len > 0) {
                    for (parameters[0 .. parameters.len - 1]) |arg| {
                        const parameter_name = ast.string(arg.function_parameter);
                        try str.print(arena, "{s}, ", .{parameter_name});
                    }
                    const last_parameter = parameters[parameters.len - 1].function_parameter;
                    try str.appendSlice(arena, ast.string(last_parameter));
                }
                try str.append(arena, '|');
                function_stack.appendAssumeCapacity(i);
            },
            .function_parameter => continue,
            .function_capture => continue,
            .function_body_end => {
                // Combine function body and function parameter list
                const body = stack.pop().?;
                const parameter_list = stack.pop().?;
                try str.ensureUnusedCapacity(arena, body.str.len + 1 + parameter_list.str.len);
                str.appendSliceAssumeCapacity(parameter_list.str);
                str.appendAssumeCapacity(' ');
                str.appendSliceAssumeCapacity(body.str);
            },
            .local_variable => |v| {
                const current_function = function_stack.items[function_stack.items.len - 1];
                const identifier = current_function.addi(1 + v.offset);
                assert(ast.tag(identifier) == .function_parameter);
                const name = ast.payload(identifier).function_parameter;
                const bytes = ast.string(name);
                try str.appendSlice(arena, bytes);
            },
            .captured_variable => |v| {
                const parameter_index = v.scope.addi(1 + v.slot);
                assert(ast.tag(parameter_index) == .function_parameter);
                const name = ast.payload(parameter_index).function_parameter;
                try str.appendSlice(arena, ast.string(name));
            },
            .function_call, .pipe_call => |call| {
                const function_string = stack.items[stack.items.len - call.arg_count - 1];
                const func = i.subi(call.function_offset);
                const needs_parentheses = switch (ast.tag(func)) {
                    // leaf nodes
                    .nil,
                    .string_literal,
                    .number,
                    .invalidated_pos,
                    .rel_rel_value,
                    .rel_abs_value,
                    .abs_rel_value,
                    .abs_abs_value,
                    .rel_rel_reference,
                    .rel_abs_reference,
                    .abs_rel_reference,
                    .abs_abs_reference,
                    .function_body_start,
                    .local_variable,
                    .captured_variable,
                    .builtin,
                    => false,
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
                    .minus,
                    .plus,
                    .not,
                    .reference,
                    .dereference,
                    .assignment,
                    .end,
                    .function_parameter,
                    .function_capture,
                    .function_body_end,
                    .function_call,
                    .pipe_call,
                    .tuple,
                    => true,
                };

                if (call.is_pipe) {
                    const args = stack.items[stack.items.len - call.arg_count ..];
                    try str.print(arena, "{s} |> {s}(", .{ args[0].str, function_string.str });
                    if (args.len > 1) {
                        for (args[1 .. args.len - 1]) |arg| {
                            try str.print(arena, "{s}, ", .{arg.str});
                        }
                        try str.appendSlice(arena, stack.items[stack.items.len - 1].str);
                    }
                    try str.appendSlice(arena, ")");
                } else {
                    if (needs_parentheses) {
                        try str.print(arena, "({s})", .{function_string.str});
                    } else {
                        try str.appendSlice(arena, function_string.str);
                    }
                    try str.append(arena, '(');
                    if (call.arg_count > 0) {
                        for (stack.items[stack.items.len - call.arg_count .. stack.items.len - 1]) |arg| {
                            try str.print(arena, "{s}, ", .{arg.str});
                        }
                        try str.appendSlice(arena, stack.items[stack.items.len - 1].str);
                    }
                    try str.append(arena, ')');
                }
                stack.items.len = stack.items.len - call.arg_count - 1;
            },
            .end => break,
            .nil => try str.appendSlice(arena, "nil"),
            .number => |n| try str.print(arena, "{d}", .{n}),
            .invalidated_pos,
            .rel_rel_value,
            .rel_rel_reference,
            => |pos| try str.print(arena, "{f}", .{pos}),
            .rel_abs_value,
            .rel_abs_reference,
            => |pos| try str.print(arena, "{f}${d}", .{
                Position.fmtColumnAddress(pos.x),
                pos.y,
            }),
            .abs_rel_value,
            .abs_rel_reference,
            => |pos| try str.print(arena, "${f}{d}", .{
                Position.fmtColumnAddress(pos.x),
                pos.y,
            }),
            .abs_abs_value,
            .abs_abs_reference,
            => |pos| try str.print(arena, "${f}${d}", .{
                Position.fmtColumnAddress(pos.x),
                pos.y,
            }),
            .string_literal => |s| try str.print(arena, "'{s}'", .{ast.string(s)}),
            .tuple => |tuple| {
                if (tuple.arg_count == 0) {
                    try str.appendSlice(arena, "[]");
                    break :sw;
                }

                try str.ensureUnusedCapacity(arena, 2 + tuple.arg_count * 4);
                str.appendAssumeCapacity('[');
                for (stack.items[stack.items.len - tuple.arg_count ..][0 .. tuple.arg_count - 1]) |arg| {
                    try str.print(arena, "{s}, ", .{arg.str});
                }
                try str.print(arena, "{s}]", .{stack.items[stack.items.len - 1].str});
                stack.items.len -= tuple.arg_count;
            },
            .assignment => |pos| {
                const arg = stack.pop().?;
                try str.print(arena, "let {f} = {s}", .{ pos, arg.str });
            },
            .builtin => |b| {
                try str.print(arena, "@{f}", .{b.tag});
            },
            inline .plus, .minus, .not, .reference, .dereference => |_, t| {
                const byte = switch (t) {
                    .plus => '+',
                    .minus => '-',
                    .not => '!',
                    .reference => '&',
                    .dereference => '*',
                    else => comptime unreachable,
                };
                const rhs = stack.pop().?;
                try str.append(arena, byte);
                const prec = comptime t.precedence();
                if (rhs.tag.precedence() >= prec) {
                    try str.appendSlice(arena, rhs.str);
                } else {
                    try str.print(arena, "({s})", .{rhs.str});
                }
            },
            inline .equals,
            .not_equals,
            .mul,
            .add,
            => |_, t| {
                const s = switch (t) {
                    .equals => "==",
                    .not_equals => "!=",
                    .add => "+",
                    .mul => "*",
                    else => comptime unreachable,
                };

                const rhs = stack.pop() orelse {
                    std.debug.print("Tag: {t}\n", .{t});
                    unreachable;
                };
                const lhs = stack.pop().?;
                const prec = comptime t.precedence();

                if (lhs.tag.precedence() < prec) {
                    try str.print(arena, "({s})", .{lhs.str});
                } else {
                    try str.appendSlice(arena, lhs.str);
                }

                try str.appendSlice(arena, " " ++ s ++ " ");

                const rhs_prec = rhs.tag.precedence();
                if (rhs_prec < prec or rhs_prec == prec and !rhs.tag.isCommutative()) {
                    try str.print(arena, "({s})", .{rhs.str});
                } else {
                    try str.appendSlice(arena, rhs.str);
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
            .range,
            .dynamic_range,
            .invalidated_range,
            => |_, t| {
                const s = switch (t) {
                    .greater_than => " > ",
                    .less_than => " < ",
                    .greater_equals => " >= ",
                    .less_equals => " <= ",
                    .sub => " - ",
                    .div => " / ",
                    .mod => " % ",
                    .pow => "^",
                    .concat => " # ",
                    .logical_or => " or ",
                    .logical_and => " and ",
                    .range, .dynamic_range, .invalidated_range => ":",
                    else => comptime unreachable,
                };

                const rhs = stack.pop().?;
                const lhs = stack.pop().?;
                const prec = comptime t.precedence();

                if (lhs.tag.precedence() < prec) {
                    try str.print(arena, "({s})", .{lhs.str});
                } else {
                    try str.appendSlice(arena, lhs.str);
                }

                try str.appendSlice(arena, s);

                if (rhs.tag.precedence() <= prec) {
                    try str.print(arena, "({s})", .{rhs.str});
                } else {
                    try str.appendSlice(arena, rhs.str);
                }
            },
        }
        try stack.append(arena, .{
            .str = try str.toOwnedSlice(arena),
            .tag = ast.tag(i),
        });
    }
    // assert(stack.items.len == 1);
    try w.writeAll(stack.items[0].str);
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
    arena: Allocator,
    root: Node.Index,
};

pub fn fmtExpression(
    ast: *const Ast,
    arena: Allocator,
    root: Node.Index,
) std.fmt.Alt(FormatData, format) {
    return .{ .data = .{ .ast = ast, .arena = arena, .root = root } };
}

pub fn format(f: FormatData, w: *std.Io.Writer) std.Io.Writer.Error!void {
    f.ast.print(f.arena, f.root, w) catch return error.WriteFailed;
}

pub fn leftMostChild(
    ast: *const Ast,
    index: Node.Index,
) Node.Index {
    return switch (ast.node(index)) {
        // leaf nodes
        .nil,
        .string_literal,
        .number,
        .invalidated_pos,
        .rel_rel_value,
        .rel_abs_value,
        .abs_rel_value,
        .abs_abs_value,
        .rel_rel_reference,
        .rel_abs_reference,
        .abs_rel_reference,
        .abs_abs_reference,
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
        .function_parameter,
        .function_capture,
        => ast.leftMostChild(index.subi(1)),
        .end => |end| index.subi(end.length),
        .function_body_end => |def| index.subi(def.length() + 1),
        .function_call,
        .pipe_call,
        => |call| ast.leftMostChild(index.subi(call.function_offset)),
        .tuple => |tuple| index.subi(tuple.length),
    };
}

pub const EvalError = error{
    InvalidCoercion,
    DivideByZero,
    CyclicalReference,
    NotEvaluable,
} || Allocator.Error;

pub const Interpreter = struct {};

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
    traverse.traverse(unwrapped, .no_deref);
}

const CellLiteralContext = enum { value, reference };

// TODO: Make this function a stack machine instead of using recursion
fn TraverseDependencies(Context: type, func: fn (Context, Rect) void) type {
    return struct {
        ast: Ast,
        user_ctx: Context,

        fn traverse(
            self: *const @This(),
            index: Node.Index,
            /// Whether the context will automatically dereference a reference. If a reference to a cell
            /// literal is automatically dereferenced, it will be added to the dependency graph.
            deref: enum { deref, no_deref },
        ) void {
            const ast = self.ast;

            switch (self.ast.node(index)) {
                .function_capture => unreachable,
                .function_call, .pipe_call => |call| {
                    const start = index.subi(call.function_offset);
                    var iter = ast.argIterator(start, index);
                    while (iter.next()) |i| {
                        self.traverse(i, .deref);
                    }
                    const func_node = index.subi(call.function_offset);
                    self.traverse(func_node, .no_deref);
                },
                .tuple => |tuple| {
                    var iter = ast.argIterator(index, index.subi(tuple.arg_count));
                    _ = iter.next();
                    while (iter.next()) |i| {
                        self.traverse(i, .deref);
                    }
                },
                .local_variable, .captured_variable => {},
                .function_body_start => unreachable,
                .function_body_end => |def| {
                    self.traverse(index.subi(def.capture_count + 1), .no_deref);
                },
                .function_parameter => unreachable,
                .assignment, .end => {
                    self.traverse(index.subi(1), .no_deref);
                },
                .nil,
                .number,
                .string_literal,
                .invalidated_pos,
                .invalidated_range,
                .builtin,
                => {},
                .rel_rel_value,
                .rel_abs_value,
                .abs_rel_value,
                .abs_abs_value,
                => |pos| {
                    func(self.user_ctx, .initSinglePos(pos));
                },
                .rel_rel_reference,
                .rel_abs_reference,
                .abs_rel_reference,
                .abs_abs_reference,
                => |pos| switch (deref) {
                    .deref => func(self.user_ctx, .initSinglePos(pos)),
                    .no_deref => {},
                },
                .range => {
                    std.log.debug("Got here", .{});
                    const rhs = index.subi(1);
                    const lhs = ast.leftMostChild(rhs).subi(1);
                    const tl = switch (ast.tag(lhs)) {
                        .reference => switch (ast.tag(lhs.subi(1))) {
                            .rel_rel_reference,
                            .rel_abs_reference,
                            .abs_rel_reference,
                            .abs_abs_reference,
                            => ast.payload(lhs.subi(1)).rel_rel_value,
                            else => unreachable,
                        },
                        .rel_rel_reference,
                        .rel_abs_reference,
                        .abs_rel_reference,
                        .abs_abs_reference,
                        => ast.payload(lhs).rel_rel_value,
                        else => unreachable,
                    };
                    std.log.debug("RHS: {t}", .{ast.tag(rhs)});
                    const br = switch (ast.tag(rhs)) {
                        .reference => switch (ast.tag(rhs.subi(1))) {
                            .rel_rel_reference,
                            .rel_abs_reference,
                            .abs_rel_reference,
                            .abs_abs_reference,
                            => ast.payload(rhs.subi(1)).rel_rel_value,
                            else => unreachable,
                        },
                        .rel_rel_reference,
                        .rel_abs_reference,
                        .abs_rel_reference,
                        .abs_abs_reference,
                        => ast.payload(rhs).rel_rel_value,
                        else => unreachable,
                    };
                    func(self.user_ctx, .initNormalizePos(tl, br));
                },
                .dynamic_range => {
                    const rhs = index.subi(1);
                    const lhs = ast.leftMostChild(rhs).subi(1);
                    self.traverse(lhs, .no_deref);
                    self.traverse(rhs, .no_deref);
                },
                .reference => switch (deref) {
                    .deref => self.traverse(index.subi(1), .no_deref),
                    .no_deref => {},
                },
                .dereference => {
                    self.traverse(index.subi(1), .deref);
                },
                .minus, .plus, .not => {
                    self.traverse(index.subi(1), .no_deref);
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
                    self.traverse(lhs, .no_deref);
                    self.traverse(rhs, .no_deref);
                },
            }
        }
    };
}

/// Returns true if the given node is a cell literal or a reference to a cell literal.
pub fn isDynamicReference(nodes: NodeList, index: Node.Index) bool {
    return switch (nodes.item(index, .tag)) {
        .reference => switch (nodes.item(index.subi(1), .tag)) {
            .rel_rel_value,
            .rel_abs_value,
            .abs_rel_value,
            .abs_abs_value,
            .rel_rel_reference,
            .rel_abs_reference,
            .abs_rel_reference,
            .abs_abs_reference,
            => false,
            else => true,
        },
        .rel_rel_value,
        .rel_abs_value,
        .abs_rel_value,
        .abs_abs_value,
        .rel_rel_reference,
        .rel_abs_reference,
        .abs_rel_reference,
        .abs_abs_reference,
        => false,
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

    const normalized = .{
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
        .{ "(1 and 2) or (3 and 4)", "1 and 2 or 3 and 4" },

        .{ "A0:B0", "A0:B0" },
        .{ "@sum(A0:B0, 1, 1 + 2, 1 + 2 * 3, 1 + 2 * 3 / 4)", "@sum(A0:B0, 1, 1 + 2, 1 + 2 * 3, 1 + 2 * 3 / 4)" },
        .{ "@prod(A0:B0, 1, 1 + 2, 1 + 2 * 3, 1 + 2 * 3 / 4)", "@prod(A0:B0, 1, 1 + 2, 1 + 2 * 3, 1 + 2 * 3 / 4)" },
        .{ "@avg(A0:B0, 1, 1 + 2, 1 + 2 * 3, 1 + 2 * 3 / 4)", "@avg(A0:B0, 1, 1 + 2, 1 + 2 * 3, 1 + 2 * 3 / 4)" },
        .{ "@min(A0:B0, 1, 1 + 2, 1 + 2 * 3, 1 + 2 * 3 / 4)", "@min(A0:B0, 1, 1 + 2, 1 + 2 * 3, 1 + 2 * 3 / 4)" },
        .{ "@max(A0:B0, 1, 1 + 2, 1 + 2 * 3, 1 + 2 * 3 / 4)", "@max(A0:B0, 1, 1 + 2, 1 + 2 * 3, 1 + 2 * 3 / 4)" },
    };

    const identical = .{
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
        "-(1 * 2)",
        "-(1 / 2)",
        "-(1 % 2)",
        "-*A0",
        "**A0",
        "***A0",
        "A0:D10",
        "*A0:D10",
        "**A0:D0",
        "A0:*D10",
        "A0:**D10",
        "**A0:**D10",

        "0 or 0",
        "0 or 1",
        "1 or 1",
        "1 or 1",

        "1 and 2 or 3 and 4",
        "1 and (2 or 3) and 4",
        "A0:D10 |> @map(|x| *x) |> @sum()",
        "1 + (A0:D10 |> @sum())",
        "(A0:D10 |> @map(|x| *x) |> @filter(|x| x > 2) |> @sum()) / 2",
        "1 + @sum(A0:D10)",
        "@sum(A0:D10) + 1",
    };

    var sheet = try Sheet.init(t.allocator);
    defer sheet.deinit();

    inline for (normalized) |d| {
        const src, const expected = d;
        const expr = try sheet.parseFromExpression(src);

        var buf: [4096]u8 = undefined;
        var fixed: std.Io.Writer = .fixed(&buf);
        try sheet.ast.print(sheet.arena.allocator(), sheet.ast.leftMostChild(expr.root), &fixed);
        try t.expectEqualStrings(expected, fixed.buffered());
    }

    inline for (identical) |src| {
        const expr = try sheet.parseFromExpression(src);

        var buf: [4096]u8 = undefined;
        var fixed: std.Io.Writer = .fixed(&buf);
        try sheet.ast.print(sheet.arena.allocator(), sheet.ast.leftMostChild(expr.root), &fixed);
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
