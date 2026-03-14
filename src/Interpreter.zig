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
stack: *List(StackEntry, u32),

/// Index of the current function header in the stack
header: StackEntry.OptionalIndex = .none,
is_volatile: bool = false,
pc: Node.Index = undefined,
call_depth: u32 = 0,

pub const max_depth = 1 << 14;

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
                continuing: bool,
            },
            map: struct {
                apply: Function,
                continuing: bool,
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
            => {
                std.log.debug("Cannot coerce {any} to number", .{res});
                return error.InvalidCoercion;
            },
        };
    }
};

// TODO: Don't use a tagged union here. Instead make the stack an array of bytes, where each entry
//       is variably sized. `Value` can remain a tagged union. We may store a seperate array of
//       value tags so that Values don't have unnecessary padding.
pub const StackEntry = union(enum) {
    value: Value,
    function_header: FunctionHeader,
    builtin_header: BuiltinHeader,
    cell_header: CellHeader,

    pub const FunctionHeader = struct {
        parent: OptionalIndex,
        /// Index of the next instruction to execute after returning from the function.
        return_address: Node.Index,
    };

    pub const CellHeader = struct {
        parent: OptionalIndex,
        return_address: Node.Index,
        cell_handle: Sheet.Cell.Handle,
        parent_is_volatile: bool,
    };

    pub const BuiltinHeader = struct {
        parent: OptionalIndex,
        return_address: Node.Index,
        // TODO: This can be inferred from the stack size.
        arg_count: u8,
        /// State required to resume the execution of a builtin function.
        /// When a bultin needs to execute some other code, such as a cell's expression or a
        /// function passed to it as an argument, it will save its state in this header and return
        /// `error.Suspended`. This error is bubbled up to the main evaluation loop which can
        /// proceed with evaluating the necessary code. When a builtin header is the current frame
        /// the evaluation loop will resume it and pop the frame when finished.
        resume_state: ResumeState,

        pub const ResumeState = union(enum) {
            none,
            map_args: MapArgs,
            /// Resumable without any other state.
            simple,

            pub const MapArgs = struct {
                i: u8 = 0,
                arg: Arg = .none,
                op: Op,

                pub const Arg = union(enum) {
                    pipeline: struct {
                        pipeline_i: usize = 0,
                        pipeline_value: Value = .none,
                        cell: bool = false,
                    },
                    cell,
                    range: Sheet.CellTree.QueryIterator,
                    none,
                };

                pub const Op = union(enum) {
                    sum: SumContext,
                    prod: ProdContext,
                    avg: AvgContext,
                    min: MinContext,
                    max: MaxContext,
                    count_all: CountContextAll,
                    count_numbers: CountContextNumbers,
                };
            };
        };
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
    try eval.stack.append(eval.sheet.gpa, res);
}

inline fn pushv(eval: *Interpreter, value: Value) Allocator.Error!void {
    return eval.push(.{ .value = value });
}

inline fn pushvAssumeCapacity(eval: *Interpreter, value: Value) void {
    eval.stack.appendAssumeCapacity(.{ .value = value });
}

pub fn reset(eval: *Interpreter) void {
    eval.stack.clearRetainingCapacity();
    eval.header = .none;
    eval.call_depth = 0;
    eval.is_volatile = false;
    eval.pc = undefined;
}

fn reserveStack(eval: *Interpreter, n: usize) Allocator.Error!void {
    try eval.stack.ensureUnusedCapacity(eval.sheet.gpa, n);
}

fn evalCellPos(eval: *Interpreter, pos: Position) !void {
    std.log.debug("EVAL {f}", .{pos});
    try eval.reserveStack(1);
    const cell_handle = eval.sheet.getCellHandleByPos(pos) orelse {
        eval.stack.appendAssumeCapacity(.{ .value = .none });
        return;
    };
    return try eval.evalCell(cell_handle);
}

fn evalCell(eval: *Interpreter, cell_handle: Sheet.Cell.Handle) !void {
    try eval.reserveStack(1);
    const cell = eval.sheet.getCellFromHandle(cell_handle);
    if (cell.expr.state == .up_to_date) {
        const value = try eval.sheet.cellValueToInterpreterValue(eval, cell);
        eval.stack.appendAssumeCapacity(.{ .value = value });
        return;
    }

    const root = cell.root().unwrap() orelse {
        // Cell doesn't have an expression, just a simple value
        cell.expr.state = .up_to_date;
        const value = try eval.sheet.cellValueToInterpreterValue(eval, cell);
        eval.stack.appendAssumeCapacity(.{ .value = value });
        return;
    };

    if (eval.call_depth >= max_depth) return error.NotEvaluable;

    eval.stack.appendAssumeCapacity(.{ .cell_header = .{
        .parent = eval.header,
        .return_address = eval.pc.addi(1),
        .cell_handle = cell_handle,
        .parent_is_volatile = eval.is_volatile,
    } });
    eval.is_volatile = false;
    eval.header = eval.stack.lastIndex().subi(1).toOptional();
    eval.pc = eval.sheet.ast.startFromEnd(root);
    eval.call_depth += 1;
    return error.Suspended;
}

fn evaluateBuiltin(eval: *Interpreter, builtin_tag: Node.Builtin.Tag, arg_count: u8) !Value {
    return switch (builtin_tag) {
        .sum => .{ .number = (try eval.mapArgs(arg_count, .sum)).total },
        .prod => .{ .number = (try eval.mapArgs(arg_count, .prod)).total },
        // TODO: This assumes that ranges do not overlap?
        .avg => {
            const result = try eval.mapArgs(arg_count, .avg);
            if (result.total_items == 0) return .{ .number = 0 };
            return .{ .number = result.total / @as(f64, @floatFromInt(result.total_items)) };
        },
        .max => .{ .number = (try eval.mapArgs(arg_count, .max)).max orelse 0 },
        .min => .{ .number = (try eval.mapArgs(arg_count, .min)).min orelse 0 },
        .upper => .{ .string = .{ .slice = try eval.evalUpper(arg_count) } },
        .lower => .{ .string = .{ .slice = try eval.evalLower(arg_count) } },
        .sqrt => .{ .number = try eval.evalSqrt(arg_count) },
        .round => .{ .number = try eval.evalRound(arg_count) },
        .floor => .{ .number = try eval.evalFloor(arg_count) },
        .ceil => .{ .number = try eval.evalCeil(arg_count) },
        .len => .{ .number = try eval.evalStringLen(arg_count) },
        .count => .{ .number = @floatFromInt((try eval.mapArgs(arg_count, .count_numbers)).total) },
        .count_all => .{ .number = @floatFromInt((try eval.mapArgs(arg_count, .count_all)).total) },
        .log => {
            if (arg_count != 2) return error.NotEvaluable;
            const base_result = eval.stack.pop().?.value;
            const n_result = eval.stack.pop().?.value;
            const base = try base_result.toNumber() orelse 10;
            const n = try n_result.toNumber() orelse 0;
            if (base <= 0 or base == 1 or n <= 0)
                return error.NotEvaluable;
            return .{ .number = std.math.log(f64, base, n) };
        },
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
    Suspended,
}!void {
    if (eval.call_depth >= max_depth) return error.NotEvaluable;
    // The arguments are at the top of the stack, with the function to call below.
    // Index of the value being called
    const index = eval.stack.lastIndex().subi(1).subi(arg_count);
    const callable = eval.stack.get(index).value;
    switch (callable) {
        .function => {
            const func = callable.function.root;
            assert(eval.sheet.ast.tag(func) == .function_body_start);
            const def = eval.sheet.ast.payload(func).function_body_start;
            if (def.arg_count != arg_count)
                return error.NotEvaluable;

            const old_header = eval.header;
            eval.header = index.toOptional();
            try eval.stack.inserti(
                eval.sheet.gpa,
                eval.stack.len() - 1 - arg_count,
                .{ .function_header = .{
                    .parent = old_header,
                    .return_address = eval.pc.addi(1),
                } },
            );
            eval.pc = func.addi(def.bodyStart());
            assert(eval.pc.lt(eval.sheet.ast.lastIndex()));
            eval.call_depth += 1;
        },
        // We don't need to insert a frame header because we don't actually 'jump'
        // anywhere in the AST to evaluate a builtin.
        .builtin_function => |f| {
            const old_header = eval.header;
            eval.header = index.toOptional();
            try eval.stack.inserti(
                eval.sheet.gpa,
                eval.stack.len() - 1 - arg_count,
                .{ .builtin_header = .{
                    .parent = old_header,
                    .return_address = eval.pc.addi(1),
                    .arg_count = arg_count,
                    .resume_state = switch (f.tag) {
                        .sum => .{ .map_args = .{ .op = .{ .sum = .{} } } },
                        .prod => .{ .map_args = .{ .op = .{ .prod = .{} } } },
                        .avg => .{ .map_args = .{ .op = .{ .avg = .{} } } },
                        .min => .{ .map_args = .{ .op = .{ .min = .{} } } },
                        .max => .{ .map_args = .{ .op = .{ .max = .{} } } },
                        .count_all => .{ .map_args = .{ .op = .{ .count_all = .{} } } },
                        .count => .{ .map_args = .{ .op = .{ .count_numbers = .{} } } },
                        else => .none,
                    },
                } },
            );
            eval.call_depth += 1;

            const res = try eval.evaluateBuiltin(f.tag, arg_count);
            eval.stack.shrinkRetainingCapacity(index);
            eval.pushvAssumeCapacity(res);
            eval.header = old_header;
            eval.pc = eval.pc.addi(1);
            eval.call_depth -= 1;
            assert(eval.pc.lt(eval.sheet.ast.lastIndex()));
        },
        else => return error.NotEvaluable,
    }
}

pub fn evaluate(eval: *Interpreter, start: Node.Index, cell_handle: Sheet.Cell.Handle) !void {
    eval.reset();

    const ast = &eval.sheet.ast;
    try eval.push(.{ .cell_header = .{
        .parent = eval.header,
        .return_address = eval.pc,
        .cell_handle = cell_handle,
        .parent_is_volatile = false,
    } });
    eval.header = eval.stack.lastIndex().subi(1).toOptional();
    eval.pc = start;
    eval.call_depth += 1;

    while (true) {
        if (eval.header.unwrap()) |header_index| {
            const entry = eval.stack.getPtr(header_index);
            if (entry.* == .builtin_header) {
                const header = entry.builtin_header;
                const index = header_index.addi(1);
                const builtin = eval.stack.get(index).value.builtin_function;
                if (entry.builtin_header.resume_state == .none)
                    entry.builtin_header.resume_state = .simple;

                const return_value = eval.evaluateBuiltin(
                    builtin.tag,
                    header.arg_count,
                ) catch |err| switch (err) {
                    error.Suspended => {
                        continue;
                    },
                    else => |e| return e,
                };
                eval.stack.shrinkRetainingCapacity(header_index);
                eval.pushvAssumeCapacity(return_value);
                eval.header = header.parent;
                eval.pc = header.return_address;
                eval.call_depth -= 1;
            }
        }

        std.log.debug("exec {t} ({d})", .{ ast.node(eval.pc), eval.pc });
        switch (ast.node(eval.pc)) {
            .end => {
                const header_index = eval.header.unwrap().?;
                const header = eval.stack.get(header_index).cell_header;

                const return_value = eval.stack.pop().?.value;
                eval.stack.shrinkRetainingCapacity(header_index);

                if (header.cell_handle != .none) {
                    const adjusted_return_value = try eval.sheet.setCellValue(
                        return_value,
                        header.cell_handle,
                    );
                    eval.stack.appendAssumeCapacity(.{ .value = adjusted_return_value });
                    if (eval.is_volatile) try eval.sheet.setCellVolatile(header.cell_handle);
                } else {
                    eval.stack.appendAssumeCapacity(.{ .value = return_value });
                }

                eval.header = header.parent;
                eval.pc = header.return_address;
                eval.is_volatile = header.parent_is_volatile;
                eval.call_depth -= 1;
                if (eval.header == .none)
                    break;
                continue;
            },
            .nil => try eval.pushv(.nil),
            .number => |n| try eval.pushv(.{ .number = n }),
            .rel_rel_value,
            .rel_abs_value,
            .abs_rel_value,
            .abs_abs_value,
            => |pos| {
                eval.evalCellPos(pos) catch |err| switch (err) {
                    error.Suspended => continue,
                    else => |e| return e,
                };
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
                        const func = eval.stack.get(f.addi(1)).value;
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
                assert(eval.pc.lt(eval.sheet.ast.lastIndex()));
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
                eval.call_depth -= 1;
                continue;
            },
            .function_parameter => unreachable,
            .function_capture => {},
            .function_call, .pipe_call => |f| {
                eval.call(f.arg_count) catch |err| switch (err) {
                    error.Suspended => {},
                    else => |e| return e,
                };
                continue;
            },
            .local_variable => |v| {
                // TODO: Should this resolve cell literals?
                const frame = eval.header.unwrap().?;
                assert(eval.stack.get(frame) == .function_header);
                const value = eval.stack.get(frame.addi(2).addi(v.offset));
                assert(value != .function_header);
                try eval.push(value);
            },
            .captured_variable => |v| {
                const frame = eval.header.unwrap().?;
                const func = eval.stack.get(frame.addi(1)).value.function;
                const value = func.captures[v.offset];
                try eval.pushv(value);
            },

            .assignment => return error.NotEvaluable,
            .builtin => |b| {
                try eval.pushv(.{ .builtin_function = .{ .tag = b.tag } });
            },
            .minus => {
                const rhs = eval.stack.pop().?.value;
                try eval.pushv(.{ .number = -(try rhs.toNumber() orelse 0) });
            },
            .plus => {
                const rhs = eval.stack.pop().?.value;
                try eval.pushv(.{ .number = @abs(try rhs.toNumber() orelse 0) });
            },
            .not => {
                const rhs = eval.stack.pop().?.value;
                try eval.pushv(.{
                    .number = @floatFromInt(@intFromBool(!rhs.boolean())),
                });
            },
            .concat => {
                const rhs = eval.stack.pop().?.value;
                const lhs = eval.stack.pop().?.value;
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
                const rhs = eval.stack.pop().?.value;
                const lhs = eval.stack.pop().?.value;
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
                const rhs = eval.stack.pop().?.value;
                const lhs = eval.stack.pop().?.value;
                const l = try lhs.toNumber() orelse 0;
                const r = try rhs.toNumber() orelse 0;
                if (r == 0) return error.DivideByZero;
                try eval.pushv(.{ .number = l / r });
            },
            .mod => {
                const rhs = eval.stack.pop().?.value;
                const lhs = eval.stack.pop().?.value;
                const l = try lhs.toNumber() orelse 0;
                const r = try rhs.toNumber() orelse 0;
                if (r <= 0) return error.DivideByZero;
                try eval.pushv(.{ .number = @rem(l, r) });
            },
            .reference => {
                const arg = eval.stack.pop().?.value;
                try eval.pushv(.{ .cell = arg.cell });
            },
            .dereference => {
                const arg = eval.stack.pop().?.value;
                const pos = switch (arg) {
                    .cell, .indirect_cell => |pos| pos,
                    else => return error.NotEvaluable,
                };
                if (arg == .indirect_cell) eval.is_volatile = true;
                eval.evalCellPos(pos) catch |err| switch (err) {
                    error.Suspended => continue,
                    else => |e| return e,
                };
            },
            // and/or have the same semantics as Lua's and/or operators.
            .logical_and => |rhs_length| {
                // const rhs = eval.stack.pop().?.value;
                const lhs = eval.stack.pop().?.value;

                if (lhs.boolean()) {
                    // Do nothing. This will evaluate the right hand side and push it to the stack.
                } else {
                    // Push the LHS to the stack and skip the RHS
                    eval.push(.{ .value = lhs }) catch unreachable;
                    eval.pc = eval.pc.addi(@intCast(rhs_length));
                    assert(eval.pc.lt(eval.sheet.ast.lastIndex()));
                }
            },
            .logical_or => |rhs_length| {
                const lhs = eval.stack.pop().?.value;

                if (lhs.boolean()) {
                    // Push the LHS to the stack and skip the RHS
                    eval.push(.{ .value = lhs }) catch unreachable;
                    eval.pc = eval.pc.addi(@intCast(rhs_length));
                    assert(eval.pc.lt(eval.sheet.ast.lastIndex()));
                } else {
                    // Do nothing. This will evaluate the right hand side and push it to the stack.
                }
            },
            inline .greater_than,
            .less_than,
            .greater_equals,
            .less_equals,
            => |_, t| {
                const rhs = eval.stack.pop().?.value;
                const lhs = eval.stack.pop().?.value;
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
                const rhs = eval.stack.pop().?.value;
                const lhs = eval.stack.pop().?.value;

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
                const rhs = eval.stack.pop().?.value;
                const lhs = eval.stack.pop().?.value;
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
        eval.pc = eval.pc.addi(1);
        assert(eval.pc.lt(ast.lastIndex()));
    }
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

const MapArgsIter = struct {
    eval: *Interpreter,
    arg_count: u8,
    i: u8 = 0,
    arg: StackEntry.BuiltinHeader.ResumeState.MapArgs.Arg = .none,

    fn suspendExecution(
        iter: *MapArgsIter,
        header_index: StackEntry.Index,
        arg: StackEntry.BuiltinHeader.ResumeState.MapArgs.Arg,
        ctx: anytype,
    ) error{Suspended} {
        iter.eval.stack.getPtr(header_index).builtin_header.resume_state = .{
            .map_args = .{
                .i = iter.i,
                .arg = arg,
                .op = switch (@TypeOf(ctx)) {
                    *SumContext => .{ .sum = ctx.* },
                    *ProdContext => .{ .prod = ctx.* },
                    *AvgContext => .{ .avg = ctx.* },
                    *MinContext => .{ .min = ctx.* },
                    *MaxContext => .{ .max = ctx.* },
                    *CountContextNumbers => .{ .count_numbers = ctx.* },
                    *CountContextAll => .{ .count_all = ctx.* },
                    else => comptime unreachable,
                },
            },
        };
        return error.Suspended;
    }

    /// Consumes arguments from the header index + 2.
    pub fn consume(iter: *MapArgsIter, ctx: anytype) !bool {
        if (iter.i >= iter.arg_count) return false;

        switch (iter.arg) {
            .cell => {
                iter.arg = .none;
                const arg = iter.eval.stack.pop().?.value;
                try ctx.func(arg);
                iter.i += 1;
                return true;
            },
            .pipeline => |*p| {
                if (p.cell) {
                    p.cell = false;
                    const arg = iter.eval.stack.pop().?.value;
                    try ctx.func(arg);
                }
            },
            .range => {
                const arg = iter.eval.stack.pop().?.value;
                try ctx.func(arg);
            },
            else => {},
        }

        const eval = iter.eval;
        const header_index = eval.header.unwrap().?;
        const arg_index = header_index.addi(2 + iter.i);
        const arg = eval.stack.get(arg_index).value;

        switch (arg) {
            inline .cell, .indirect_cell => |pos, t| {
                if (t == .indirect_cell) eval.is_volatile = true;
                eval.evalCellPos(pos) catch |err| switch (err) {
                    error.Suspended => {
                        return iter.suspendExecution(header_index, .cell, ctx);
                    },
                    else => |e| return e,
                };
                const res = eval.stack.pop().?.value;
                try ctx.func(res);
            },
            inline .range, .indirect_range => |range, t| {
                if (t == .indirect_range) eval.is_volatile = true;
                const rect = range.rect;
                var cell_iter = switch (eval.getBuiltinHeader().resume_state.map_args.arg) {
                    .range => |r| r,
                    else => eval.sheet.cell_tree.iterator2(
                        &.{ rect.tl.x, rect.tl.y },
                        &.{ rect.br.x, rect.br.y },
                    ),
                };
                while (try cell_iter.next()) |handle| {
                    eval.evalCell(handle) catch |err| switch (err) {
                        error.Suspended => {
                            return iter.suspendExecution(header_index, .{ .range = cell_iter }, ctx);
                        },
                        else => |e| return e,
                    };
                    const result = eval.stack.pop().?.value;
                    try ctx.func(result);
                }
            },
            .pipeline => |p| {
                var p_iter: PipelineIterator = .{
                    .eval = eval,
                    .p = p,
                    .i = 0,
                    .value = undefined,
                };
                switch (iter.arg) {
                    .pipeline => |p2| {
                        p_iter.i = p2.pipeline_i;
                        p_iter.value = p2.pipeline_value;
                    },
                    else => {},
                }

                while (p_iter.next()) |value| {
                    switch (value) {
                        inline .cell, .indirect_cell => |pos, t| {
                            if (t == .indirect_cell) eval.is_volatile = true;
                            eval.evalCellPos(pos) catch |err| switch (err) {
                                error.Suspended => {
                                    return iter.suspendExecution(header_index, .{
                                        .pipeline = .{
                                            .pipeline_i = p_iter.i,
                                            .pipeline_value = p_iter.value,
                                            .cell = true,
                                        },
                                    }, ctx);
                                },
                                else => |e| return e,
                            };

                            const result = eval.stack.pop().?.value;
                            try ctx.func(result);
                        },
                        else => try ctx.func(value),
                    }
                } else |err| switch (err) {
                    error.EndOfStream => {},
                    error.Suspended => {
                        return iter.suspendExecution(header_index, .{
                            .pipeline = .{
                                .pipeline_i = p_iter.i,
                                .pipeline_value = p_iter.value,
                            },
                        }, ctx);
                    },
                    else => |e| return e,
                }
            },
            .tuple => |t| {
                for (t.values) |v| {
                    try ctx.func(v);
                }
            },
            else => {
                try ctx.func(arg);
            },
        }

        iter.i += 1;
        eval.getBuiltinHeader().resume_state.map_args.arg = .none;
        iter.arg = .none;
        return true;
    }
};

fn mapArgs(
    eval: *Interpreter,
    arg_count: u8,
    comptime tag: std.meta.Tag(StackEntry.BuiltinHeader.ResumeState.MapArgs.Op),
) !@FieldType(StackEntry.BuiltinHeader.ResumeState.MapArgs.Op, @tagName(tag)) {
    const map = eval.stack.get(eval.header.unwrap().?).builtin_header.resume_state.map_args;
    var iter: MapArgsIter = .{
        .arg_count = arg_count,
        .eval = eval,
        .i = map.i,
        .arg = map.arg,
    };
    var ctx = @field(map.op, @tagName(tag));
    while (try iter.consume(&ctx)) {}
    return ctx;
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
                .filter => |*f| {
                    if (!f.continuing) {
                        f.continuing = true;

                        try eval.reserveStack(8);
                        eval.pushvAssumeCapacity(.{ .function = f.predicate });
                        eval.pushvAssumeCapacity(iter.value);
                        try eval.call(1);

                        return error.Suspended;
                    } else {
                        f.continuing = false;

                        const return_value = eval.stack.pop().?.value;
                        if (!return_value.boolean()) {
                            iter.i = 0;
                            continue;
                        }
                    }
                },
                .map => |*f| {
                    if (!f.continuing) {
                        f.continuing = true;
                        try eval.pushv(.{ .function = f.apply });
                        try eval.pushv(iter.value);
                        try eval.call(1);
                        return error.Suspended;
                    } else {
                        f.continuing = false;
                        iter.value = eval.stack.pop().?.value;
                    }
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
    const arg = try eval.functionArg(0);
    const str = try std.fmt.allocPrint(eval.arena, "{f}", .{eval.sheet.fmtInterpreterValue(arg)});
    for (str) |*c| c.* = std.ascii.toUpper(c.*);
    return str;
}

fn evalLower(eval: *Interpreter, arg_count: u8) ![]const u8 {
    if (arg_count != 1) return error.NotEvaluable;
    const arg = try eval.functionArg(0);
    const str = try std.fmt.allocPrint(eval.arena, "{f}", .{eval.sheet.fmtInterpreterValue(arg)});
    for (str) |*c| c.* = std.ascii.toLower(c.*);
    return str;
}

const ProdContext = struct {
    total: f64 = 1,

    fn func(ctx: *ProdContext, v: Value) !void {
        const n = try v.toNumber();
        ctx.total *= n orelse 1;
    }
};

const SumContext = struct {
    total: f64 = 0,

    fn func(ctx: *SumContext, v: Value) !void {
        const n = try v.toNumber();
        ctx.total += n orelse 0;
    }
};

const AvgContext = struct {
    total: f64 = 0,
    total_items: u65 = 0,

    fn func(ctx: *AvgContext, v: Value) !void {
        const n = try v.toNumber();
        ctx.total += n orelse return;
        ctx.total_items += 1;
    }
};

const MaxContext = struct {
    max: ?f64 = null,

    fn func(ctx: *MaxContext, v: Value) !void {
        const n = try v.toNumber();
        if (ctx.max == null or ctx.max.? < n orelse 0)
            ctx.max = n orelse 0;
    }
};

const MinContext = struct {
    min: ?f64 = null,

    fn func(ctx: *MinContext, v: Value) !void {
        const n = try v.toNumber();
        if (ctx.min == null or ctx.min.? > n orelse 0)
            ctx.min = n orelse 0;
    }
};

const CountContextAll = struct {
    total: u65 = 0,

    fn func(ctx: *CountContextAll, v: Value) !void {
        if (v != .none) ctx.total += 1;
    }
};

const CountContextNumbers = struct {
    total: u65 = 0,

    fn func(ctx: *CountContextNumbers, v: Value) !void {
        if (v == .number) ctx.total += 1;
    }
};

fn getBuiltinHeader(eval: *Interpreter) *StackEntry.BuiltinHeader {
    return &eval.stack.getPtr(eval.header.unwrap().?).builtin_header;
}

fn functionArg(eval: *Interpreter, n: u8) !Value {
    const header = eval.getBuiltinHeader().*;
    const arg_index = eval.header.unwrap().?.addi(2 + @as(u32, n));
    const arg = eval.stack.get(arg_index).value;
    return switch (header.resume_state) {
        // Initial state
        .none => sw: switch (arg) {
            .cell => |pos| {
                try eval.evalCellPos(pos);
                break :sw eval.stack.pop().?.value;
            },
            .indirect_cell => |pos| {
                eval.is_volatile = true;
                try eval.evalCellPos(pos);
                break :sw eval.stack.pop().?.value;
            },
            else => arg,
        },
        // Resuming
        .simple => eval.stack.pop().?.value,
        else => unreachable,
    };
}

fn evalSqrt(eval: *Interpreter, arg_count: u8) !f64 {
    if (arg_count != 1) return error.NotEvaluable;

    const arg = try eval.functionArg(0);
    const n = try arg.toNumber() orelse 0;
    if (n < 0) return error.NotEvaluable;
    return std.math.sqrt(n);
}

fn evalRound(eval: *Interpreter, arg_count: u8) !f64 {
    if (arg_count != 1) return error.NotEvaluable;
    const arg = try eval.functionArg(0);
    const n = try arg.toNumber() orelse 0;
    return std.math.round(n);
}

fn evalFloor(eval: *Interpreter, arg_count: u8) !f64 {
    if (arg_count != 1) return error.NotEvaluable;
    const arg = try eval.functionArg(0);
    const n = try arg.toNumber() orelse 0;
    return @floor(n);
}

fn evalCeil(eval: *Interpreter, arg_count: u8) !f64 {
    if (arg_count != 1) return error.NotEvaluable;
    const arg = try eval.functionArg(0);
    const n = try arg.toNumber() orelse 0;
    return @ceil(n);
}

fn evalStringLen(eval: *Interpreter, arg_count: u8) !f64 {
    if (arg_count != 1) return error.NotEvaluable;
    const arg = eval.stack.pop().?.value;
    return switch (arg) {
        // TODO: This sucks
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

fn evalFilter(eval: *Interpreter, arg_count: u8) !Value.Pipeline {
    if (arg_count != 2) return error.NotEvaluable;
    const arg2 = eval.stack.pop().?.value;
    const arg1 = eval.stack.pop().?.value;
    if (arg2 != .function) return error.NotEvaluable;
    var pipeline = try eval.toPipeline(arg1);
    const predicate = arg2.function;

    try pipeline.stages.append(eval.arena, .{
        .filter = .{ .predicate = predicate, .continuing = false },
    });

    return pipeline;
}

fn evalMap(eval: *Interpreter, arg_count: u8) !Value.Pipeline {
    if (arg_count != 2) return error.NotEvaluable;
    const arg2 = eval.stack.pop().?.value;
    const arg1 = eval.stack.pop().?.value;
    if (arg2 != .function) return error.NotEvaluable;
    var pipeline = try eval.toPipeline(arg1);
    const apply = arg2.function;

    try pipeline.stages.append(eval.arena, .{
        .map = .{ .apply = apply, .continuing = false },
    });

    return pipeline;
}

fn evalRange(eval: *Interpreter, arg_count: u8) !Value.Pipeline {
    if (arg_count != 2) return error.NotEvaluable;
    const end_result = eval.stack.pop().?.value;
    const start_result = eval.stack.pop().?.value;
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

fn evalWidth(eval: *Interpreter, arg_count: u8) !f64 {
    if (arg_count != 1) return error.NotEvaluable;
    const arg = try eval.functionArg(0);
    return switch (arg) {
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
    const arg = try eval.functionArg(0);
    return switch (arg) {
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
