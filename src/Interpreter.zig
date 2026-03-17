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
    boolean: bool,
    number: f64,
    string: *String,
    cell: Position,
    range: Range,
    function: Function,
    closure: *Closure,
    builtin_function: BuiltinFunction,
    indirect_range: Range,
    indirect_cell: Position,
    pipeline: *Pipeline,
    tuple: *Tuple,
    table: *Table,

    /// Returns a deep copy of the given value. Avoid when possible. Currently only used for
    /// storing tuples and pipelines in cells, which is a relatively rare use case.
    pub fn clone(v: Value, arena: Allocator) Allocator.Error!Value {
        switch (v) {
            .none,
            .nil,
            .err,
            .boolean,
            .number,
            .cell,
            .range,
            .function,
            .builtin_function,
            .indirect_range,
            .indirect_cell,
            => return v,
            .string => |s| {
                return .{ .string = try .dupe(arena, s.bytes()) };
            },
            .closure => |f| {
                const new_closure: *Value.Closure = try .create(arena, f.root, f.len);
                const captures = new_closure.captures();

                for (captures, f.captures()) |*new_capture, old_capture| {
                    new_capture.* = try old_capture.clone(arena);
                }
                return .{ .closure = new_closure };
            },
            .pipeline => |p| {
                const ret = try arena.create(Pipeline);
                const stages = try arena.dupe(Pipeline.Stage, p.stages.items);
                for (stages, p.stages.items) |*stage, old_stage| {
                    stage.* = switch (old_stage) {
                        .number_range,
                        .range,
                        .indirect_range,
                        => old_stage,
                        .tuple => |t| .{
                            .tuple = (try clone(.{ .tuple = t }, arena)).tuple,
                        },
                        .table => |t| .{
                            .table = (try clone(.{ .table = t }, arena)).table,
                        },
                        .filter => |v2| .{ .filter = try v2.clone(arena) },
                        .map => |v2| .{ .map = try v2.clone(arena) },
                    };
                }
                ret.* = .{ .stages = .fromOwnedSlice(stages) };
                return .{ .pipeline = ret };
            },
            .tuple => |t| {
                const new_t: *Value.Tuple = try .create(arena, t.len);

                for (new_t.values(), t.values()) |*new_value, old_value| {
                    new_value.* = try old_value.clone(arena);
                }
                return .{ .tuple = new_t };
            },
            .table => |t| {
                const new_t = try arena.create(Table);
                const new_map = try t.map.clone(arena);
                for (
                    new_map.keys(),
                    new_map.values(),
                    t.map.keys(),
                    t.map.values(),
                ) |*key_dest, *value_dest, key, value| {
                    const key_string: *Value.String = try .dupe(arena, key);
                    key_dest.* = key_string.bytes();
                    value_dest.* = try value.clone(arena);
                }
                new_t.* = .{ .map = new_map };
                return .{ .table = new_t };
            },
        }
    }

    pub const Table = struct {
        /// NOTE: The keys MUST be a heap allocated `String` type.
        map: std.StringArrayHashMapUnmanaged(Value),
    };

    pub const Tuple = struct {
        len: u32,

        const alignment: std.mem.Alignment = .max(.of(Tuple), .of(Value));
        const header_size = alignment.forward(@sizeOf(Tuple));

        pub fn create(gpa: Allocator, len: u32) Allocator.Error!*Tuple {
            const size = header_size + @sizeOf(Value) * @as(usize, len);
            const bytes = try gpa.alignedAlloc(u8, alignment, size);
            const ptr: *Tuple = @ptrCast(bytes);
            ptr.* = .{ .len = len };
            return ptr;
        }

        pub fn destroy(t: *Tuple, gpa: Allocator) void {
            const size = header_size + @sizeOf(Value) * @as(usize, t.len);
            const bytes: [*]align(alignment.toByteUnits()) u8 = @ptrCast(@alignCast(t));
            const slice = bytes[0..size];
            gpa.free(slice);
        }

        pub fn values(t: *Tuple) []Value {
            const ptr: [*]Value = @ptrFromInt(@intFromPtr(t) + header_size);
            return ptr[0..t.len];
        }
    };

    // Range/map/filter functions return a new pipeline
    pub const Pipeline = struct {
        slopped: bool = true,
        stages: std.ArrayList(Stage) = .empty,

        pub const Stage = union(enum) {
            number_range: struct { start: f64, end: f64 },
            range: CellRange,
            indirect_range: CellRange,
            tuple: *Tuple,
            table: *Table,

            filter: Value,
            map: Value,
        };

        pub const CellRange = struct {
            min: Sheet.CellTree.Point,
            max: Sheet.CellTree.Point,
        };

        /// The mutable state required when consuming a pipeline iteratively.
        pub const State = struct {
            /// Current stage of the pipeline being executed.
            i: usize,
            /// Current value of the pipeline.
            value: Value,
            /// True if we suspended when dereferencing a cell reference that resulted from a
            /// pipeline.
            cell: bool,
            /// State for the pipeline source.
            source: Source,

            /// State for the pipeline source.
            pub const Source = union(enum) {
                number_range: f64,
                range: Sheet.CellTree.QueryIterator,
                tuple: usize,
                none,
            };
        };
    };

    pub const String = struct {
        len: u32,

        const alignment: std.mem.Alignment = .max(.of(String), .of(u8));
        const header_size: usize = @sizeOf(String);

        pub fn create(gpa: Allocator, len: u32) Allocator.Error!*String {
            const size = header_size + len;
            const slice = try gpa.alignedAlloc(u8, alignment, size);
            const ret: *String = @ptrCast(slice.ptr);
            ret.* = .{ .len = len };
            return ret;
        }

        pub fn destroy(s: *String, gpa: Allocator) void {
            const ptr: [*]align(alignment.toByteUnits()) u8 = @ptrCast(s);
            const slice = ptr[0 .. header_size + s.len];
            gpa.free(slice);
        }

        pub fn bytes(s: *String) []u8 {
            const ptr: [*]u8 = @ptrCast(s);
            return ptr[header_size..][0..s.len];
        }

        pub fn dupe(gpa: Allocator, text: []const u8) Allocator.Error!*String {
            const ret = try create(gpa, @intCast(text.len));
            @memcpy(ret.bytes(), text);
            return ret;
        }

        pub fn allocPrint(gpa: Allocator, comptime fmt: []const u8, args: anytype) Allocator.Error!*String {
            const size = std.fmt.count(fmt, args);
            const str = try create(gpa, @intCast(size));
            const slice = std.fmt.bufPrint(str.bytes(), fmt, args) catch unreachable;
            assert(slice.len == str.len);
            return str;
        }
    };

    pub const Closure = struct {
        /// Index of the `function_body_start` node.
        root: Node.Index,
        len: u32,

        const alignment: std.mem.Alignment = .max(.of(Closure), .of(Value));
        const header_size = alignment.forward(@sizeOf(Closure));

        pub fn create(gpa: Allocator, root: Node.Index, capture_count: u32) Allocator.Error!*Closure {
            const size = header_size + @sizeOf(Value) * @as(usize, capture_count);
            const bytes = try gpa.alignedAlloc(u8, alignment, size);
            const ptr: *Closure = @ptrCast(bytes.ptr);
            ptr.* = .{ .root = root, .len = capture_count };
            return ptr;
        }

        pub fn destroy(c: *Closure, gpa: Allocator) void {
            const size = header_size + @sizeOf(Value) * @as(usize, c.len);
            const ptr: [*]align(alignment.toByteUnits()) u8 = @ptrCast(@alignCast(c));
            const bytes = ptr[0..size];
            gpa.free(bytes);
        }

        pub fn captures(c: *Closure) []Value {
            const ptr: [*]Value = @ptrFromInt(@intFromPtr(c) + header_size);
            return ptr[0..c.len];
        }
    };

    pub const Function = struct {
        /// Index of the `function_body_start` node.
        root: Node.Index,
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

    pub fn toBoolean(res: Value) bool {
        return switch (res) {
            .none => false,
            .nil => false,
            .err => false,
            .boolean => |b| b,
            .number => |n| n != 0,
            .string => true,
            .cell, .indirect_cell => true,
            .range, .indirect_range => true,
            .function, .closure, .builtin_function => true,
            .pipeline => true,
            .tuple => true,
            .table => true,
        };
    }

    /// Casts the value to a number. Returns `null` if value is an empty cell. Returns
    /// `error.InvalidCoercion` if the value cannot be casted to a number.
    fn toNumber(res: Value) !?f64 {
        return switch (res) {
            .none => null,
            .boolean => |b| @intFromBool(b),
            .number => |n| n,
            .string => |str| std.fmt.parseFloat(f64, str.bytes()) catch error.InvalidCoercion,
            .nil,
            .err,
            .cell,
            .indirect_cell,
            .range,
            .indirect_range,
            .function,
            .closure,
            .builtin_function,
            .pipeline,
            .tuple,
            .table,
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
                /// What kind of argument we're resuming at
                arg: Arg = .none,
                op: Op,

                pub const Arg = union(enum) {
                    pipeline: Value.Pipeline.State,
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
                    any: AnyContext,
                    collect: CollectContext,
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
        const value = Sheet.interpreterValueFromCell(cell.expr.value_tag, cell.value);
        eval.stack.appendAssumeCapacity(.{ .value = value });
        return;
    }

    const root = cell.root().unwrap() orelse {
        // Cell doesn't have an expression, just a simple value
        cell.expr.state = .up_to_date;
        const value = Sheet.interpreterValueFromCell(cell.expr.value_tag, cell.value);
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
        .upper => .{ .string = try eval.evalUpper(arg_count) },
        .lower => .{ .string = try eval.evalLower(arg_count) },
        .sqrt => .{ .number = try eval.evalSqrt(arg_count) },
        .round => .{ .number = try eval.evalRound(arg_count) },
        .floor => .{ .number = try eval.evalFloor(arg_count) },
        .ceil => .{ .number = try eval.evalCeil(arg_count) },
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
        .any => {
            const map = eval.stack.get(eval.header.unwrap().?).builtin_header.resume_state.map_args;
            var iter: MapArgsIter = .{
                .arg_count = arg_count,
                .eval = eval,
                .i = map.i,
                .arg = map.arg,
                .header_index = eval.header.unwrap().?,
            };
            var ctx: AnyContext = .{};
            while (iter.consume(&ctx) catch |err| switch (err) {
                error.Suspended => return error.Suspended,
                error.AnyContextFinished => {
                    return ctx.value;
                },
                else => |e| return e,
            }) {}
            return .nil;
        },
        .collect => {
            // TODO: Find a way to re-use the memory from the `.values` list in the context.
            const result = try eval.mapArgs(arg_count, .collect);
            const t: *Value.Tuple = try .create(eval.arena, @intCast(result.values.items.len));
            @memcpy(t.values(), result.values.items);
            return .{ .tuple = t };
        },
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
        .function, .closure => {
            const func = if (callable == .function) callable.function.root else callable.closure.root;
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
                        .any => .{ .map_args = .{ .op = .{ .any = .{} } } },
                        .collect => .{ .map_args = .{ .op = .{ .collect = .{ .arena = eval.arena } } } },
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
            .false => try eval.pushv(.{ .boolean = false }),
            .true => try eval.pushv(.{ .boolean = true }),
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
            .string_literal, .table_assignment => |str| {
                try eval.reserveStack(1);
                eval.pushvAssumeCapacity(.{ .string = try .dupe(eval.arena, ast.string(str)) });
            },
            .table => |t| {
                try eval.reserveStack(1);
                const table = try eval.arena.create(Value.Table);
                table.* = .{ .map = .empty };
                try table.map.ensureUnusedCapacity(eval.arena, t.arg_count);
                for (0..t.arg_count) |_| {
                    const value = eval.stack.pop().?.value;
                    const name = eval.stack.pop().?.value.string;
                    table.map.putAssumeCapacity(name.bytes(), value);
                }
                eval.pushvAssumeCapacity(.{ .table = table });
            },
            .tuple => |tuple| {
                assert(eval.stack.len() >= tuple.arg_count);
                if (tuple.arg_count == 0)
                    try eval.reserveStack(1);

                const t: *Value.Tuple = try .create(eval.arena, tuple.arg_count);
                for (t.values(), eval.stack.items()[eval.stack.len() - tuple.arg_count ..]) |*dest, src| {
                    dest.* = src.value;
                }
                eval.stack.shrinkRetainingCapacity(@enumFromInt(eval.stack.len() - tuple.arg_count));

                eval.pushvAssumeCapacity(.{ .tuple = t });
            },
            .invalidated_pos, .invalidated_range => return error.NotEvaluable,
            .function_body_start => |def| {
                // Capture any necessary values
                try eval.reserveStack(1);
                if (def.capture_count == 0) {
                    eval.pushvAssumeCapacity(.{ .function = .{ .root = eval.pc } });
                } else {
                    const captures = ast.nodes.subsliceIndex(
                        eval.pc.addi(def.captures()),
                        def.capture_count,
                    );
                    const c: *Value.Closure = try .create(eval.arena, eval.pc, def.capture_count);
                    for (c.captures(), captures.items(.data)) |*dest, data| {
                        const cap = data.function_capture;
                        var frame = eval.header;
                        while (frame.unwrap()) |f| : (frame = eval.stack.get(f).function_header.parent) {
                            const func = eval.stack.get(f.addi(1)).value;
                            const root = switch (func) {
                                .function => |f2| f2.root,
                                .closure => |c2| c2.root,
                                else => unreachable,
                            };
                            if (root == cap.scope) {
                                // Found the value
                                const value = eval.stack.get(f.addi(2).addi(cap.offset)).value;
                                dest.* = value;
                                break;
                            }
                        } else unreachable;
                    }

                    eval.pushvAssumeCapacity(.{ .closure = c });
                }
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
            .index => {
                const index = eval.stack.pop().?.value;
                const to_index = eval.stack.pop().?.value;
                switch (to_index) {
                    .tuple => {
                        const f = try index.toNumber() orelse 0;
                        if (f < 0 or f > std.math.maxInt(u32)) return error.NotEvaluable;
                        const n: u32 = @intFromFloat(f);
                        if (n >= to_index.tuple.len) return error.NotEvaluable;
                        eval.stack.appendAssumeCapacity(.{ .value = to_index.tuple.values()[n] });
                    },
                    .table => |t| {
                        if (index != .string) return error.NotEvaluable;
                        const value = t.map.get(index.string.bytes()) orelse .nil;
                        eval.pushvAssumeCapacity(value);
                    },
                    else => return error.NotEvaluable,
                }
            },
            .field => |field_name_str| {
                const lhs = eval.stack.pop().?.value;
                const rhs = eval.sheet.ast.string(field_name_str);
                switch (lhs) {
                    .table => |t| {
                        if (std.mem.eql(u8, rhs, "size")) {
                            eval.pushvAssumeCapacity(.{
                                .number = @floatFromInt(t.map.entries.len),
                            });
                        } else {
                            const value = t.map.get(rhs) orelse .nil;
                            eval.pushvAssumeCapacity(value);
                        }
                    },
                    .tuple => |t| {
                        if (std.mem.eql(u8, rhs, "len")) {
                            eval.pushvAssumeCapacity(.{ .number = t.len });
                        } else {
                            return error.NotEvaluable;
                        }
                    },
                    .string => |str| {
                        // TODO: Add `.graphemes`

                        if (std.mem.eql(u8, rhs, "size")) {
                            eval.pushvAssumeCapacity(.{ .number = str.len });
                        } else {
                            return error.NotEvaluable;
                        }
                    },
                    else => return error.NotEvaluable,
                }
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
                const closure = eval.stack.get(frame.addi(1)).value.closure;
                const value = closure.captures()[v.offset];
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
                    .boolean = !rhs.toBoolean(),
                });
            },
            .concat => {
                try eval.reserveStack(1);
                const rhs = eval.stack.pop().?.value;
                const lhs = eval.stack.pop().?.value;

                eval.pushvAssumeCapacity(.{ .string = try .allocPrint(eval.arena, "{f}{f}", .{
                    eval.sheet.fmtInterpreterValue(lhs),
                    eval.sheet.fmtInterpreterValue(rhs),
                }) });
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

                if (lhs.toBoolean()) {
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

                if (lhs.toBoolean()) {
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

                try eval.pushv(.{ .boolean = n });
            },
            inline .equals, .not_equals => |_, t| {
                const rhs = eval.stack.pop().?.value;
                const lhs = eval.stack.pop().?.value;

                // TODO: Vet equality semantics
                const n = switch (lhs) {
                    .none => false,
                    .nil => switch (rhs) {
                        .nil => true,
                        else => false,
                    },
                    .err => switch (rhs) {
                        .err => true,
                        else => false,
                    },
                    .boolean => |b1| switch (rhs) {
                        .boolean => |b2| b1 == b2,
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
                    .closure => |f1| switch (rhs) {
                        .closure => |f2| f1.root == f2.root,
                        else => false,
                    },
                    .builtin_function => |f1| switch (rhs) {
                        .builtin_function => |f2| f1.tag == f2.tag,
                        else => false,
                    },
                    .pipeline => false,
                    .tuple => false, // TODO
                    .table => false,
                };

                const b = switch (t) {
                    .equals => n,
                    .not_equals => !n,
                    else => comptime unreachable,
                };
                try eval.pushv(.{ .boolean = b });
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

fn toPipeline(eval: *Interpreter, v: Value) !*Value.Pipeline {
    switch (v) {
        .pipeline => return (try v.clone(eval.arena)).pipeline,
        .indirect_range => |r| {
            const p = try eval.arena.create(Value.Pipeline);
            p.* = .{};
            try p.stages.append(eval.arena, .{ .indirect_range = .{
                .min = r.rect.tl.array(),
                .max = r.rect.br.array(),
            } });
            return p;
        },
        .range => |r| {
            const p = try eval.arena.create(Value.Pipeline);
            p.* = .{};
            try p.stages.append(eval.arena, .{ .range = .{
                .min = r.rect.tl.array(),
                .max = r.rect.br.array(),
            } });
            return p;
        },
        .tuple => |t| {
            const p = try eval.arena.create(Value.Pipeline);
            p.* = .{};
            try p.stages.append(eval.arena, .{ .tuple = t });
            return p;
        },
        .table => |t| {
            const p = try eval.arena.create(Value.Pipeline);
            p.* = .{};
            try p.stages.append(eval.arena, .{ .table = t });
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
    header_index: StackEntry.Index,

    fn suspendExecution(
        iter: *MapArgsIter,
        arg: StackEntry.BuiltinHeader.ResumeState.MapArgs.Arg,
        ctx: anytype,
    ) error{Suspended} {
        iter.eval.stack.getPtr(iter.header_index).builtin_header.resume_state = .{
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
                    *AnyContext => .{ .any = ctx.* },
                    *CollectContext => .{ .collect = ctx.* },
                    else => comptime unreachable,
                },
            },
        };
        return error.Suspended;
    }

    fn suspendPipeline(iter: *MapArgsIter, p_iter: PipelineIterator, ctx: anytype) error{Suspended} {
        return iter.suspendExecution(.{
            .pipeline = .{
                .i = p_iter.i,
                .value = p_iter.value,
                .cell = p_iter.i == 0,
                .source = p_iter.source,
            },
        }, ctx);
    }

    fn pipelineIterator(iter: *MapArgsIter, p: *Value.Pipeline) PipelineIterator {
        return switch (iter.arg) {
            .pipeline => |p2| .{
                .eval = iter.eval,
                .p = p,
                .i = p2.i,
                .value = p2.value,
                .source = p2.source,
                .resuming = p2.i > 0,
            },
            else => .{
                .eval = iter.eval,
                .p = p,
                .i = 0,
                .value = undefined,
                .resuming = false,
                .source = switch (p.stages.items[0]) {
                    .number_range => |nr| .{ .number_range = nr.start },
                    .range, .indirect_range => |range| .{
                        .range = iter.eval.sheet.cell_tree.queryIterator(range.min, range.max),
                    },
                    .tuple, .table => .{ .tuple = 0 },
                    .map, .filter => unreachable,
                },
            },
        };
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
                        return iter.suspendExecution(.cell, ctx);
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
                    else => eval.sheet.cell_tree.queryIterator(
                        .{ rect.tl.x, rect.tl.y },
                        .{ rect.br.x, rect.br.y },
                    ),
                };
                while (cell_iter.next()) |handle| {
                    eval.evalCell(handle) catch |err| switch (err) {
                        error.Suspended => {
                            return iter.suspendExecution(.{ .range = cell_iter }, ctx);
                        },
                        else => |e| return e,
                    };
                    const result = eval.stack.pop().?.value;
                    try ctx.func(result);
                }
            },
            .pipeline => |p| {
                var p_iter = iter.pipelineIterator(p);

                // Consume values from the pipeline and apply the function to the resulting
                // values.
                while (p_iter.next()) |value| switch (value) {
                    inline .cell, .indirect_cell => |pos, t| {
                        if (t == .indirect_cell) eval.is_volatile = true;

                        // Dereference any cell references resulting from the pipeline and apply the
                        // function to the result.
                        eval.evalCellPos(pos) catch |err| switch (err) {
                            error.Suspended => {
                                assert(p_iter.i == 0);
                                // Suspend. The value resulting from evaluating this cell will be
                                // handled at the top of this function under the `p.cell` check.
                                return iter.suspendPipeline(p_iter, ctx);
                            },
                            else => |e| return e,
                        };

                        // The cell's value was already cached and we didn't need to suspend to
                        // evaluate it.
                        const result = eval.stack.pop().?.value;
                        try ctx.func(result);
                    },
                    else => try ctx.func(value),
                } else |err| switch (err) {
                    error.EndOfStream => {},
                    error.Suspended => {
                        // Pipeline itself suspended, likely to evaluate the function passed to
                        // something like map/filter.
                        return iter.suspendPipeline(p_iter, ctx);
                    },
                    else => |e| return e,
                }
            },
            .tuple => |t| {
                for (t.values()) |v| {
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
        .header_index = eval.header.unwrap().?,
    };
    var ctx = @field(map.op, @tagName(tag));
    while (try iter.consume(&ctx)) {}
    return ctx;
}

/// Iteratively pulls values from a pipeline.
const PipelineIterator = struct {
    eval: *Interpreter,
    p: *Value.Pipeline,
    i: usize,
    value: Value,
    source: Value.Pipeline.State.Source,
    resuming: bool,

    pub fn next(iter: *PipelineIterator) !Value {
        const p = iter.p;
        const eval = iter.eval;

        while (iter.i < p.stages.items.len) {
            switch (p.stages.items[iter.i]) {
                .number_range => |r| {
                    const current = iter.source.number_range;
                    if (current >= r.end) return error.EndOfStream;
                    iter.source.number_range += 1;
                    iter.value = .{ .number = current };
                },
                .range => {
                    const h = iter.source.range.next() orelse return error.EndOfStream;
                    const point = eval.sheet.cell_tree.entryItem(h, .point);
                    iter.value = .{ .cell = .fromArray(point.*) };
                },
                .indirect_range => {
                    const h = iter.source.range.next() orelse return error.EndOfStream;
                    const point = eval.sheet.cell_tree.entryItem(h, .point);
                    iter.value = .{ .indirect_cell = .fromArray(point.*) };
                },
                .tuple => |t| {
                    const index = iter.source.tuple;
                    if (index >= t.len) return error.EndOfStream;
                    iter.value = t.values()[index];
                    iter.source.tuple += 1;
                },
                .table => |t| {
                    const index = iter.source.tuple;
                    if (index >= t.map.entries.len) return error.EndOfStream;
                    const tuple: *Value.Tuple = try .create(eval.arena, 2);
                    const bytes = t.map.keys()[index];
                    const key: *Value.String = @ptrCast(@alignCast(
                        @constCast(bytes.ptr) - Value.String.header_size,
                    ));
                    tuple.values()[0..2].* = .{
                        .{ .string = key },
                        t.map.values()[index],
                    };
                    iter.value = .{ .tuple = tuple };
                    iter.source.tuple += 1;
                },
                .filter => |f| if (!iter.resuming) {
                    try eval.reserveStack(8);
                    eval.pushvAssumeCapacity(f);
                    eval.pushvAssumeCapacity(iter.value);
                    try eval.call(1);

                    return error.Suspended;
                } else {
                    iter.resuming = false;
                    const return_value = eval.stack.pop().?.value;
                    if (!return_value.toBoolean()) {
                        iter.i = 0;
                        continue;
                    }
                },
                .map => |f| if (!iter.resuming) {
                    try eval.reserveStack(8);
                    eval.pushvAssumeCapacity(f);
                    eval.pushvAssumeCapacity(iter.value);
                    try eval.call(1);
                    return error.Suspended;
                } else {
                    iter.resuming = false;
                    iter.value = eval.stack.pop().?.value;
                },
            }
            iter.i += 1;
        }

        iter.i = 0;
        return iter.value;
    }
};

fn evalUpper(eval: *Interpreter, arg_count: u8) !*Value.String {
    if (arg_count != 1) return error.NotEvaluable;
    const arg = try eval.functionArg(0);
    const str: *Value.String = try .allocPrint(eval.arena, "{f}", .{eval.sheet.fmtInterpreterValue(arg)});
    for (str.bytes()) |*c| c.* = std.ascii.toUpper(c.*);
    return str;
}

fn evalLower(eval: *Interpreter, arg_count: u8) !*Value.String {
    if (arg_count != 1) return error.NotEvaluable;
    const arg = try eval.functionArg(0);
    const str: *Value.String = try .allocPrint(eval.arena, "{f}", .{eval.sheet.fmtInterpreterValue(arg)});
    for (str.bytes()) |*c| c.* = std.ascii.toLower(c.*);
    return str;
}

const ProdContext = struct {
    total: f64 = 1,

    fn func(ctx: *ProdContext, v: Value) !void {
        const n = try v.toNumber();
        ctx.total *= n orelse 1;
    }
};

const CollectContext = struct {
    arena: Allocator,
    values: std.ArrayList(Value) = .empty,

    fn func(ctx: *CollectContext, v: Value) !void {
        try ctx.values.append(ctx.arena, v);
    }
};

const AnyContext = struct {
    value: Value = .nil,

    fn func(ctx: *AnyContext, v: Value) !void {
        ctx.value = v;
        return error.AnyContextFinished;
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

fn evalFilter(eval: *Interpreter, arg_count: u8) !*Value.Pipeline {
    if (arg_count != 2) return error.NotEvaluable;
    const arg2 = eval.stack.pop().?.value;
    const arg1 = eval.stack.pop().?.value;
    if (arg2 != .function and arg2 != .closure)
        return error.NotEvaluable;
    const pipeline = try eval.toPipeline(arg1);

    try pipeline.stages.append(eval.arena, .{ .filter = arg2 });
    return pipeline;
}

fn evalMap(eval: *Interpreter, arg_count: u8) !*Value.Pipeline {
    if (arg_count != 2) return error.NotEvaluable;
    const arg2 = eval.stack.pop().?.value;
    const arg1 = eval.stack.pop().?.value;
    if (arg2 != .function and arg2 != .closure)
        return error.NotEvaluable;
    const pipeline = try eval.toPipeline(arg1);

    try pipeline.stages.append(eval.arena, .{ .map = arg2 });
    return pipeline;
}

fn evalRange(eval: *Interpreter, arg_count: u8) !*Value.Pipeline {
    if (arg_count != 2) return error.NotEvaluable;
    const end_result = eval.stack.pop().?.value;
    const start_result = eval.stack.pop().?.value;
    const end = try end_result.toNumber() orelse return error.NotEvaluable;
    const start = try start_result.toNumber() orelse return error.NotEvaluable;
    if (start > end)
        return error.NotEvaluable;
    const ret = try eval.arena.create(Value.Pipeline);
    ret.* = .{};
    try ret.stages.ensureUnusedCapacity(eval.arena, 8);
    ret.stages.appendAssumeCapacity(.{ .number_range = .{
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
        .boolean,
        .number,
        .string,
        .function,
        .closure,
        .builtin_function,
        .pipeline,
        .tuple,
        .table,
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
        .boolean,
        .string,
        .function,
        .closure,
        .builtin_function,
        .pipeline,
        .tuple,
        .table,
        => return error.NotEvaluable,
    };
}
