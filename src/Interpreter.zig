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
stack: List(StackEntry, u32) = .empty,

/// Index of the current function header in the stack
header: StackEntry.OptionalIndex = .none,
is_volatile: bool = false,
pc: Node.Index = undefined,

pub const Value = union(enum) {
    none,
    nil,
    err,
    number: f64,
    string: String,
    cell: Position,
    range: Range,
    function: Function,
    builtin_function: BuiltinFunction,
    indirect_range: Range,
    indirect_cell: Position,
    pipeline: Pipeline,
    tuple: Tuple,

    /// Returns a deep copy of the given value. Avoid when possible. Currently only used for
    /// storing tuples and pipelines in cells, which is a relatively rare use case.
    pub fn clone(v: Value, gpa: anytype) Allocator.Error!Value {
        switch (v) {
            .none,
            .nil,
            .err,
            .number,
            .cell,
            .range,
            .builtin_function,
            .indirect_range,
            .indirect_cell,
            => return v,
            .string => |s| switch (s) {
                .cell => return v,
                .slice => |slice| return .{ .string = .{ .slice = try gpa.dupe(u8, slice) } },
            },
            .function => |f| {
                const caps = try gpa.dupe(Value, f.captures);
                errdefer gpa.free(caps);

                for (caps, 0..) |*cap, i| {
                    errdefer for (caps[0..i -| 1]) |cap2| cap2.deinit(gpa);
                    cap.* = try cap.clone(gpa);
                }
                return .{ .function = .{ .root = f.root, .captures = caps } };
            },
            .pipeline => |p| {
                const stages = try gpa.dupe(Pipeline.Stage, p.stages.items);
                return .{ .pipeline = .{ .stages = .fromOwnedSlice(stages) } };
            },
            .tuple => |t| {
                const values = try gpa.dupe(Value, t.values);
                errdefer gpa.free(values);

                for (values, 0..) |*value, i| {
                    errdefer for (values[0..i -| 1]) |duped_value|
                        duped_value.deinit(gpa);
                    value.* = try value.clone(gpa);
                }
                return .{ .tuple = .{ .values = values } };
            },
        }
    }

    /// Free a cloned value.
    pub fn deinit(v: Value, gpa: Allocator) void {
        switch (v) {
            .none,
            .nil,
            .err,
            .number,
            .cell,
            .range,
            .builtin_function,
            .indirect_range,
            .indirect_cell,
            => {},
            .string => |s| switch (s) {
                .cell => {},
                .slice => |slice| {
                    gpa.free(slice);
                },
            },
            .function => |f| {
                for (f.captures) |cap|
                    cap.deinit(gpa);
                gpa.free(f.captures);
            },
            .pipeline => |p| {
                var temp = p.stages;
                temp.deinit(gpa);
            },
            .tuple => |t| {
                for (t.values) |value|
                    value.deinit(gpa);
                gpa.free(t.values);
            },
        }
    }

    pub const Tuple = struct {
        values: []Value,
    };

    // Range/map/filter functions return a new pipeline
    pub const Pipeline = struct {
        stages: std.ArrayList(Stage) = .empty,

        pub const Stage = union(enum) {
            number_range: struct {
                current: f64,
                start: f64,
                end: f64,
            },
            range: CellRange,
            indirect_range: CellRange,
            tuple: struct {
                values: []Value,
                index: usize,
            },
            filter: struct {
                predicate: Function,
            },
            map: struct {
                apply: Function,
            },
        };

        // TODO: AWFUL
        pub const CellRange = struct {
            min: Sheet.CellTree.Point,
            max: Sheet.CellTree.Point,
            iter: ?Sheet.CellTree.QueryIterator,
        };
    };

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
        /// Index of the `function_body_start` node.
        root: Node.Index,
        captures: []Value = &.{},
    };

    pub const BuiltinFunction = struct {
        tag: Node.Builtin.Tag,
    };

    pub const Range = struct {
        rect: Rect,

        pub fn format(r: Range, w: *std.Io.Writer) !void {
            try r.rect.format(w);
        }

        pub fn eql(a: Range, b: Range) bool {
            return a.rect.eql(b.rect);
        }
    };

    pub fn boolean(res: Value) bool {
        return switch (res) {
            .none => false,
            .nil => false,
            .err => false,
            .number => |n| n != 0,
            .string => true,
            .cell, .indirect_cell => true,
            .range, .indirect_range => true,
            .function, .builtin_function => true,
            .pipeline => true,
            .tuple => true,
        };
    }

    /// Casts the value to a number. Returns `null` if value is an empty cell. Returns
    /// `error.InvalidCoercion` if the value cannot be casted to a number.
    fn toNumber(res: Value) !?f64 {
        return switch (res) {
            .none => null,
            .number => |n| n,
            .string => |str| std.fmt.parseFloat(f64, str.bytes()) catch error.InvalidCoercion,
            .nil,
            .err,
            .cell,
            .indirect_cell,
            .range,
            .indirect_range,
            .function,
            .builtin_function,
            .pipeline,
            .tuple,
            => error.InvalidCoercion,
        };
    }
};

pub const StackEntry = union(enum) {
    value: Value,
    function_header: FunctionHeader,

    pub const FunctionHeader = struct {
        parent: OptionalIndex,
        return_address: Node.Index,
    };

    pub const Index = List(StackEntry, u32).Index;
    pub const OptionalIndex = List(StackEntry, u32).OptionalIndex;
};

pub const EvaluateResult = struct {
    is_volatile: bool,
};

const Direction = enum {
    direct,
    indirect,
};

inline fn push(eval: *Interpreter, res: StackEntry) Allocator.Error!void {
    try eval.stack.append(eval.arena, res);
}

inline fn pushv(eval: *Interpreter, value: Value) Allocator.Error!void {
    return eval.push(.{ .value = value });
}

inline fn pushvAssumeCapacity(eval: *Interpreter, value: Value) void {
    eval.stack.appendAssumeCapacity(.{ .value = value });
}

fn reserveStack(eval: *Interpreter, n: usize) Allocator.Error!void {
    try eval.stack.ensureUnusedCapacity(eval.arena, n);
}

pub fn pop(eval: *Interpreter) Value {
    return switch (eval.stack.pop().?) {
        .value => |v| v,
        .function_header => @panic(""),
    };
}

/// Return the value at the specified index. Cell literals will be evaluated based on
/// `result_type`.
fn valueAt(eval: *Interpreter, index: StackEntry.Index) !Value {
    const ret = eval.stack.get(index);
    return switch (ret) {
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
        .range => .{ .pipeline = try eval.evalRange(arg_count) },
        .filter => .{ .pipeline = try eval.evalFilter(arg_count) },
        .map => .{ .pipeline = try eval.evalMap(arg_count) },
    };
}

/// Call a function. The top of the stack should contain the arguments to the function followed by
/// the function itself.
fn call(eval: *Interpreter, arg_count: u8) error{
    InvalidCoercion,
    DivideByZero,
    CyclicalReference,
    NotEvaluable,
    OutOfMemory,
}!void {
    // The arguments are at the top of the stack, with the function to call below.
    const index = eval.stack.lastIndex().subi(1).subi(arg_count);
    const arg = try eval.valueAt(index);
    switch (arg) {
        .function => {
            const func = arg.function.root;
            assert(eval.sheet.ast.tag(func) == .function_body_start);
            const def = eval.sheet.ast.payload(func).function_body_start;
            if (def.arg_count != arg_count)
                return error.NotEvaluable;

            const old_header = eval.header;
            eval.header = index.toOptional();
            try eval.stack.inserti(
                eval.arena,
                eval.stack.len() - 1 - arg_count,
                .{ .function_header = .{
                    .parent = old_header,
                    .return_address = eval.pc,
                } },
            );
            eval.pc = func.addi(def.bodyStart() - 1);
        },
        // We don't need to insert a frame header because we don't actually 'jump'
        // anywhere in the AST to evaluate a builtin.
        .builtin_function => |f| {
            const res = try eval.evaluateBuiltin(f.tag, arg_count);
            eval.stack.shrinkRetainingCapacity(index);
            try eval.pushv(res);
        },
        else => return error.NotEvaluable,
    }
}

pub fn evaluate(eval: *Interpreter, start: Node.Index) !void {
    return eval.evaluate2(start, false);
}

pub fn evaluate2(eval: *Interpreter, start: Node.Index, comptime one_func: bool) !void {
    const ast = &eval.sheet.ast;
    const old_pc = eval.pc;
    eval.pc = start;
    // Required because cell evaluation calls this function recursively on the same Interpreter
    // instance :/
    // This will change in the future!
    defer eval.pc = old_pc;
    while (true) : (eval.pc = eval.pc.addi(1)) {
        switch (ast.node(eval.pc)) {
            .end => break,
            .nil => try eval.pushv(.nil),
            .number => |n| try eval.pushv(.{ .number = n }),
            .rel_rel_value,
            .rel_abs_value,
            .abs_rel_value,
            .abs_abs_value,
            => |pos| {
                try eval.evaluateCellPush(pos, .direct);
            },
            .rel_rel_reference,
            .rel_abs_reference,
            .abs_rel_reference,
            .abs_abs_reference,
            => |pos| {
                try eval.pushv(.{ .cell = pos });
            },
            .string_literal => |str| {
                try eval.pushv(.{ .string = .{ .slice = ast.string(str) } });
            },
            .tuple => |tuple| {
                assert(eval.stack.len() >= tuple.arg_count);
                if (tuple.arg_count == 0)
                    try eval.reserveStack(1);

                const values = try eval.arena.alloc(Value, tuple.arg_count);
                for (values, eval.stack.items()[eval.stack.len() - tuple.arg_count ..]) |*dest, src| {
                    dest.* = src.value;
                }
                eval.stack.shrinkRetainingCapacity(@enumFromInt(eval.stack.len() - tuple.arg_count));

                eval.pushvAssumeCapacity(.{ .tuple = .{ .values = values } });
            },
            .invalidated_pos, .invalidated_range => return error.NotEvaluable,
            .function_body_start => |def| {
                // Capture any necessary values
                const captures = ast.nodes.subsliceIndex(eval.pc.addi(def.captures()), def.capture_count);
                const cap_slice = try eval.arena.alloc(Value, def.capture_count);
                for (cap_slice, captures.items(.data)) |*dest, data| {
                    const cap = data.function_capture;
                    var frame = eval.header;
                    while (frame.unwrap()) |f| : (frame = eval.stack.get(f).function_header.parent) {
                        const func = try eval.valueAt(f.addi(1));
                        if (func.function.root == cap.scope) {
                            // Found the value
                            const value = eval.stack.get(f.addi(2).addi(cap.offset)).value;
                            dest.* = value;
                            break;
                        }
                    } else unreachable;
                }

                try eval.pushv(.{ .function = .{ .root = eval.pc, .captures = cap_slice } });
                eval.pc = eval.pc.addi(1 + def.length());
            },
            .function_body_end => {
                // Return from the function
                const header_index = eval.header.unwrap().?;
                const header = eval.stack.get(header_index).function_header;

                const return_value = eval.stack.pop().?;
                eval.stack.shrinkRetainingCapacity(header_index);
                eval.stack.appendAssumeCapacity(return_value);

                eval.header = header.parent;
                eval.pc = header.return_address;
                if (one_func) break;
            },
            .function_parameter => unreachable,
            .function_capture => {},
            .function_call, .pipe_call => |f| {
                try eval.call(f.arg_count);
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
                const func = (try eval.valueAt(frame.addi(1))).function;
                const value = func.captures[v.offset];
                try eval.pushv(value);
            },

            .assignment => return error.NotEvaluable,
            .builtin => |b| {
                try eval.pushv(.{ .builtin_function = .{ .tag = b.tag } });
            },
            .minus => {
                const rhs = eval.pop();
                try eval.pushv(.{ .number = -(try rhs.toNumber() orelse 0) });
            },
            .plus => {
                const rhs = eval.pop();
                try eval.pushv(.{ .number = @abs(try rhs.toNumber() orelse 0) });
            },
            .not => {
                const rhs = eval.pop();
                try eval.pushv(.{
                    .number = @floatFromInt(@intFromBool(!rhs.boolean())),
                });
            },
            .concat => {
                const rhs = eval.pop();
                const lhs = eval.pop();
                var aw: std.Io.Writer.Allocating = .init(eval.arena);
                eval.sheet.formatInterpreterValue(lhs, &aw.writer) catch |err| switch (err) {
                    error.WriteFailed => return error.OutOfMemory,
                    else => |e| return e,
                };
                eval.sheet.formatInterpreterValue(rhs, &aw.writer) catch |err| switch (err) {
                    error.WriteFailed => return error.OutOfMemory,
                    else => |e| return e,
                };
                try eval.pushv(.{ .string = .{ .slice = try aw.toOwnedSlice() } });
            },
            inline .add, .sub, .mul, .pow => |_, t| {
                const rhs = eval.pop();
                const lhs = eval.pop();
                const l = try lhs.toNumber() orelse 0;
                const r = try rhs.toNumber() orelse 0;
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
                const rhs = eval.pop();
                const lhs = eval.pop();
                const l = try lhs.toNumber() orelse 0;
                const r = try rhs.toNumber() orelse 0;
                if (r == 0) return error.DivideByZero;
                try eval.pushv(.{ .number = l / r });
            },
            .mod => {
                const rhs = eval.pop();
                const lhs = eval.pop();
                const l = try lhs.toNumber() orelse 0;
                const r = try rhs.toNumber() orelse 0;
                if (r <= 0) return error.DivideByZero;
                try eval.pushv(.{ .number = @rem(l, r) });
            },
            .reference => {
                const arg = eval.pop();
                try eval.pushv(.{ .cell = arg.cell });
            },
            .dereference => {
                const arg = eval.pop();
                switch (arg) {
                    .cell => |pos| try eval.evaluateCellPush(pos, .direct),
                    .indirect_cell => |pos| try eval.evaluateCellPush(pos, .indirect),
                    else => return error.NotEvaluable,
                }
            },
            // and/or have the same semantics as Lua's and/or operators.
            .logical_and => |rhs_length| {
                // const rhs = eval.pop();
                const lhs = eval.pop();

                if (lhs.boolean()) {
                    // Do nothing. This will evaluate the right hand side and push it to the stack.
                } else {
                    // Push the LHS to the stack and skip the RHS
                    eval.push(.{ .value = lhs }) catch unreachable;
                    eval.pc = eval.pc.addi(@intCast(rhs_length));
                }
            },
            .logical_or => |rhs_length| {
                const lhs = eval.pop();

                if (lhs.boolean()) {
                    // Push the LHS to the stack and skip the RHS
                    eval.push(.{ .value = lhs }) catch unreachable;
                    eval.pc = eval.pc.addi(@intCast(rhs_length));
                } else {
                    // Do nothing. This will evaluate the right hand side and push it to the stack.
                }
            },
            inline .greater_than,
            .less_than,
            .greater_equals,
            .less_equals,
            => |_, t| {
                const rhs = eval.pop();
                const lhs = eval.pop();
                const l = try lhs.toNumber() orelse 0;
                const r = try rhs.toNumber() orelse 0;
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
                const rhs = eval.pop();
                const lhs = eval.pop();

                // TODO: Vet equality semantics
                const n = switch (lhs) {
                    .none => true,
                    .nil => switch (rhs) {
                        .nil => true,
                        else => false,
                    },
                    .err => switch (rhs) {
                        .err => true,
                        else => false,
                    },
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
                    .pipeline => false,
                    .tuple => false, // TODO
                };

                const b = switch (t) {
                    .equals => n,
                    .not_equals => !n,
                    else => comptime unreachable,
                };
                try eval.pushv(.{ .number = @floatFromInt(@intFromBool(b)) });
            },
            .range, .dynamic_range => {
                const rhs = eval.pop();
                const lhs = eval.pop();
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
        }
    }
}

/// Coerces `res` to a number, dereferencing one level of reference if required.
fn toNumberDeref(eval: *Interpreter, res: Value) !?f64 {
    return switch (res) {
        .none => null,
        .number => |n| n,
        .string => |str| std.fmt.parseFloat(f64, str.bytes()) catch error.InvalidCoercion,
        .cell => |pos| Value.toNumber(
            try eval.evaluateCell(pos, .direct),
        ),
        .indirect_cell => |pos| Value.toNumber(
            try eval.evaluateCell(pos, .indirect),
        ),
        .nil,
        .err,
        .range,
        .indirect_range,
        .function,
        .builtin_function,
        .pipeline,
        .tuple,
        => error.InvalidCoercion,
    };
}

fn toPipeline(eval: *Interpreter, v: Value) !Value.Pipeline {
    switch (v) {
        .pipeline => |p| return p,
        .indirect_range => |r| {
            var p: Value.Pipeline = .{};
            try p.stages.append(eval.arena, .{ .indirect_range = .{
                .min = r.rect.tl.array(),
                .max = r.rect.br.array(),
                .iter = null,
            } });
            return p;
        },
        .range => |r| {
            var p: Value.Pipeline = .{};
            try p.stages.append(eval.arena, .{ .range = .{
                .min = r.rect.tl.array(),
                .max = r.rect.br.array(),
                .iter = null,
            } });
            return p;
        },
        .tuple => |t| {
            var p: Value.Pipeline = .{};
            try p.stages.append(eval.arena, .{ .tuple = .{
                .values = t.values,
                .index = 0,
            } });
            return p;
        },
        else => return error.NotEvaluable,
    }
}

fn mapArgsNumber(eval: *Interpreter, arg_count: u8, ctx: anytype) !void {
    const MapContext = struct {
        eval: *Interpreter,
        outer_ctx: @TypeOf(ctx),

        pub fn func(inner_ctx: @This(), cell: Sheet.Cell.Handle) !void {
            const res = try inner_ctx.eval.sheet.evalCellByHandle(inner_ctx.eval, cell);
            const number = try res.toNumber();
            try inner_ctx.outer_ctx.func(number);
        }
    };

    for (0..arg_count) |_| {
        const res = eval.pop();
        switch (res) {
            .cell => |pos| {
                const res2 = try eval.evaluateCell(pos, .direct);
                const number = try res2.toNumber();
                try ctx.func(number);
            },
            .indirect_cell => |pos| {
                const res2 = try eval.evaluateCell(pos, .indirect);
                const number = try res2.toNumber();
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
            .pipeline => |p| {
                const pc_start = eval.pc;
                defer eval.pc = pc_start;
                var iter: PipelineIterator = .{
                    .eval = eval,
                    .p = p,
                    .i = 0,
                    .value = undefined,
                };

                while (iter.next()) |value| {
                    const n = try eval.toNumberDeref(value);
                    try ctx.func(n);
                } else |err| switch (err) {
                    error.EndOfStream => {},
                    else => |e| return e,
                }
            },
            .tuple => |t| {
                for (t.values) |v| {
                    const number = try v.toNumber();
                    try ctx.func(number);
                }
            },
            else => {
                const n = try res.toNumber();
                try ctx.func(n);
            },
        }
    }
}

/// Iteratively pulls values from a pipeline.
const PipelineIterator = struct {
    eval: *Interpreter,
    p: Value.Pipeline,
    i: usize,
    value: Value,

    pub fn next(iter: *PipelineIterator) !Value {
        const p = &iter.p;
        const eval = iter.eval;
        switch (p.stages.items[0]) {
            .range, .indirect_range => |*r| {
                if (r.iter == null) {
                    r.iter = eval.sheet.cell_tree.iterator2(&r.min, &r.max);
                }
            },
            else => {},
        }

        while (iter.i < p.stages.items.len) {
            switch (p.stages.items[iter.i]) {
                .number_range => |*r| {
                    if (r.current >= r.end) return error.EndOfStream;
                    const ret = r.current;
                    r.current += 1;
                    iter.value = .{ .number = ret };
                },
                .range => |*r| {
                    const h = try r.iter.?.next() orelse return error.EndOfStream;
                    const point = eval.sheet.cell_tree.entryItem(h, .point);
                    iter.value = .{ .cell = .fromArray(point.*) };
                },
                .indirect_range => |*r| {
                    // TODO: This is imprecise.
                    eval.is_volatile = true;
                    const h = try r.iter.?.next() orelse return error.EndOfStream;
                    const point = eval.sheet.cell_tree.entryItem(h, .point);
                    iter.value = .{ .indirect_cell = .fromArray(point.*) };
                },
                .tuple => |*t| {
                    if (t.index >= t.values.len) return error.EndOfStream;
                    iter.value = t.values[t.index];
                    t.index += 1;
                },
                .filter => |f| {
                    // Push function
                    try eval.pushv(.{ .function = f.predicate });
                    // Push arguments
                    try eval.pushv(iter.value);
                    // Set up call stack and jump to function
                    try eval.call(1);
                    eval.pc = eval.pc.addi(1);
                    // Evaluate function
                    try eval.evaluate2(eval.pc, true);
                    // Pop return value
                    const return_value = eval.pop();
                    if (!return_value.boolean()) {
                        iter.i = 0;
                        continue;
                    }
                },
                .map => |f| {
                    try eval.pushv(.{ .function = f.apply });
                    try eval.pushv(iter.value);
                    try eval.call(1);
                    eval.pc = eval.pc.addi(1);
                    try eval.evaluate2(eval.pc, true);
                    iter.value = eval.pop();
                },
            }
            iter.i += 1;
        }

        iter.i = 0;
        return iter.value;
    }
};

fn evalUpper(eval: *Interpreter, arg_count: u8) ![]const u8 {
    if (arg_count != 1) return error.NotEvaluable;
    const arg = blk: {
        const arg = eval.pop();
        break :blk switch (arg) {
            .cell => |cell| try eval.evaluateCell(cell, .direct),
            .indirect_cell => |cell| try eval.evaluateCell(cell, .indirect),
            else => arg,
        };
    };
    const str = try std.fmt.allocPrint(eval.arena, "{f}", .{eval.sheet.fmtInterpreterValue(arg)});
    for (str) |*c| c.* = std.ascii.toUpper(c.*);
    return str;
}

fn evalLower(eval: *Interpreter, arg_count: u8) ![]const u8 {
    if (arg_count != 1) return error.NotEvaluable;
    const arg = blk: {
        const arg = eval.pop();
        break :blk switch (arg) {
            .cell => |cell| try eval.evaluateCell(cell, .direct),
            .indirect_cell => |cell| try eval.evaluateCell(cell, .indirect),
            else => arg,
        };
    };
    const str = try std.fmt.allocPrint(eval.arena, "{f}", .{eval.sheet.fmtInterpreterValue(arg)});
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
    std.log.debug("CALLED SUM", .{});
    var ctx: SumContext = .{};
    try eval.mapArgsNumber(arg_count, &ctx);
    return ctx.total;
}

fn evalProd(eval: *Interpreter, arg_count: u8) !f64 {
    std.log.debug("CALLED PROD", .{});
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
    const arg = eval.pop();
    const n = try eval.toNumberDeref(arg) orelse 0;
    if (n < 0) return error.NotEvaluable;
    return std.math.sqrt(n);
}

fn evalRound(eval: *Interpreter, arg_count: u8) !f64 {
    if (arg_count != 1) return error.NotEvaluable;
    const arg = eval.pop();
    const n = try eval.toNumberDeref(arg) orelse 0;
    return std.math.round(n);
}

fn evalFloor(eval: *Interpreter, arg_count: u8) !f64 {
    if (arg_count != 1) return error.NotEvaluable;
    const arg = eval.pop();
    const n = try eval.toNumberDeref(arg) orelse 0;
    return @floor(n);
}

fn evalCeil(eval: *Interpreter, arg_count: u8) !f64 {
    if (arg_count != 1) return error.NotEvaluable;
    const arg = eval.pop();
    const n = try eval.toNumberDeref(arg) orelse 0;
    return @ceil(n);
}

fn evalStringLen(eval: *Interpreter, arg_count: u8) !f64 {
    if (arg_count != 1) return error.NotEvaluable;
    const arg = eval.pop();
    return switch (arg) {
        .none => 0,
        .nil => 3,
        .err => 5,
        .number => |n|
        // TODO: This should account for the current precision of the cell
        @floatFromInt(std.fmt.count("{d}", .{n})),
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
        => |value| @floatFromInt(std.fmt.count("{f}", .{value})),
        .function,
        .builtin_function,
        .pipeline,
        .tuple,
        => error.NotEvaluable,
    };
}

const CountOperation = enum { all, numbers };

fn evalCount(
    eval: *Interpreter,
    comptime operation: CountOperation,
    arg_count: u8,
) !f64 {
    var total: u65 = 0;
    for (0..arg_count) |_| {
        // TODO: Vet reference semantics
        const res = eval.pop();
        total += try eval.countValue(res, operation);
    }

    return @floatFromInt(total);
}

fn countValue(
    eval: *Interpreter,
    v: Value,
    comptime operation: CountOperation,
) !u65 {
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
    switch (v) {
        .none, .nil, .err => {},
        inline .number,
        .string,
        .function,
        .builtin_function,
        => |_, t| {
            switch (operation) {
                .all => total += 1,
                .numbers => if (t == .number) {
                    total += 1;
                },
            }
        },
        .pipeline => |p| {
            const pc_start = eval.pc;
            defer eval.pc = pc_start;
            var iter: PipelineIterator = .{
                .eval = eval,
                .p = p,
                .i = 0,
                .value = undefined,
            };
            while (iter.next()) |value| {
                total += try eval.countValue(value, operation);
            } else |err| switch (err) {
                error.EndOfStream => {},
                else => |e| return e,
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
        .tuple => |t| {
            for (t.values) |value|
                total += try eval.countValue(value, operation);
        },
    }
    return total;
}

fn evalFilter(eval: *Interpreter, arg_count: u8) !Value.Pipeline {
    if (arg_count != 2) return error.NotEvaluable;
    const arg2 = eval.pop();
    const arg1 = eval.pop();
    if (arg2 != .function) return error.NotEvaluable;
    var pipeline = try eval.toPipeline(arg1);
    const predicate = arg2.function;

    try pipeline.stages.append(eval.arena, .{
        .filter = .{ .predicate = predicate },
    });

    return pipeline;
}

fn evalMap(eval: *Interpreter, arg_count: u8) !Value.Pipeline {
    if (arg_count != 2) return error.NotEvaluable;
    const arg2 = eval.pop();
    const arg1 = eval.pop();
    if (arg2 != .function) return error.NotEvaluable;
    var pipeline = try eval.toPipeline(arg1);
    const apply = arg2.function;

    try pipeline.stages.append(eval.arena, .{
        .map = .{ .apply = apply },
    });

    return pipeline;
}

fn evalRange(eval: *Interpreter, arg_count: u8) !Value.Pipeline {
    if (arg_count != 2) return error.NotEvaluable;
    const end_result = eval.pop();
    const start_result = eval.pop();
    const end = try end_result.toNumber() orelse return error.NotEvaluable;
    const start = try start_result.toNumber() orelse return error.NotEvaluable;
    if (start > end)
        return error.NotEvaluable;
    var ret: Value.Pipeline = .{};
    try ret.stages.ensureUnusedCapacity(eval.arena, 8);
    ret.stages.appendAssumeCapacity(.{ .number_range = .{
        .current = start,
        .start = start,
        .end = end,
    } });
    return ret;
}

fn evalLog(eval: *Interpreter, arg_count: u8) !f64 {
    if (arg_count != 2) return error.NotEvaluable;
    const base_result = eval.pop();
    const n_result = eval.pop();
    const base = try base_result.toNumber() orelse 10;
    const n = try n_result.toNumber() orelse 0;
    if (base <= 0 or base == 1 or n <= 0)
        return error.NotEvaluable;
    return std.math.log(f64, base, n);
}

fn evalWidth(eval: *Interpreter, arg_count: u8) !f64 {
    if (arg_count != 1) return error.NotEvaluable;
    const res = blk: {
        const arg = eval.pop();
        break :blk switch (arg) {
            .cell => |cell| try eval.evaluateCell(cell, .direct),
            .indirect_cell => |cell| try eval.evaluateCell(cell, .indirect),
            else => arg,
        };
    };
    return switch (res) {
        .cell, .indirect_cell => 1,
        .range, .indirect_range => |r| @floatFromInt(r.rect.width2()),
        .none,
        .nil,
        .err,
        .number,
        .string,
        .function,
        .builtin_function,
        .pipeline,
        .tuple,
        => return error.NotEvaluable,
    };
}

fn evalHeight(eval: *Interpreter, arg_count: u8) !f64 {
    if (arg_count != 1) return error.NotEvaluable;
    const res = blk: {
        const arg = eval.pop();
        break :blk switch (arg) {
            .cell => |cell| try eval.evaluateCell(cell, .direct),
            .indirect_cell => |cell| try eval.evaluateCell(cell, .indirect),
            else => arg,
        };
    };
    return switch (res) {
        .cell, .indirect_cell => 1,
        .range, .indirect_range => |r| @floatFromInt(r.rect.height2()),
        .none,
        .nil,
        .err,
        .number,
        .string,
        .function,
        .builtin_function,
        .pipeline,
        .tuple,
        => return error.NotEvaluable,
    };
}
