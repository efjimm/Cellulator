const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const Ast = @import("Ast.zig");
const Node = Ast.Node;
const List = @import("list.zig").List;
const Position = @import("Position.zig").Position;
const Rect = Position.Rect;
const Sheet = @import("Sheet.zig");

const Interpreter = @This();

arena: Allocator,
sheet: *Sheet,
stack: List(StackFrame, u32) = .empty,

/// Index of the current function header in the stack
header: StackFrame.OptionalIndex = .none,
is_volatile: bool = false,

pub const ResultType = enum { any, reference };

pub const Value = union(enum) {
    none,
    number: f64,
    string: String,
    cell: Position,
    range: Range,
    function: Function,
    builtin_function: BuiltinFunction,
    indirect_range: Range,
    indirect_cell: Position,

    pub const String = union(enum) {
        slice: []const u8,
        cell: struct {
            sheet: *Sheet,
            list_index: @FieldType(Sheet, "string_values").List.Index,
        },

        pub fn bytes(self: *const String) []const u8 {
            return switch (self.*) {
                .slice => |s| s,
                .cell => |s| s.sheet.string_values.items(s.list_index),
            };
        }
    };

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

fn toNumberOrNull(_: *const Interpreter, res: Value) !?f64 {
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

fn formatString(_: *const Interpreter, res: Value, w: *std.io.Writer) !void {
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

    fn func(ctx: *ProdContext, n: ?f64) !void {
        ctx.total *= n orelse 1;
    }
};

const SumContext = struct {
    total: f64 = 0,

    fn func(ctx: *SumContext, n: ?f64) !void {
        ctx.total += n orelse 0;
    }
};

const AvgContext = struct {
    total: f64 = 0,
    total_items: u65 = 0,

    fn func(ctx: *AvgContext, n: ?f64) !void {
        ctx.total += n orelse return;
        ctx.total_items += 1;
    }
};

const MaxContext = struct {
    max: ?f64 = null,

    fn func(ctx: *MaxContext, n: ?f64) !void {
        if (ctx.max == null or ctx.max.? < n orelse 0)
            ctx.max = n orelse 0;
    }
};

const MinContext = struct {
    min: ?f64 = null,

    fn func(ctx: *MinContext, n: ?f64) !void {
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
