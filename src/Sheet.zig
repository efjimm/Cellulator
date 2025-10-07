const std = @import("std");
const build = @import("build");
const assert = std.debug.assert;
const log = std.log.scoped(.sheet);
const Arena = std.heap.ArenaAllocator;
const Allocator = std.mem.Allocator;

const builtin = @import("builtin");
const utils = @import("utils.zig");

const Position = @import("Position.zig").Position;
const PosInt = Position.Int;
const Rect = Position.Rect;

const Ast = @import("Ast.zig");
const Parser = @import("Parser.zig");
const NodeList = Ast.NodeList;
const FlatListPool = @import("flat_list_pool.zig").FlatListPool;
const PhTree = @import("phtree.zig").PhTree;

const Sheet = @This();

gpa: Allocator,

/// True if there have been any changes since the last save
has_changes: bool,

/// List of cells that need to be re-evaluated.
queued_cells: std.ArrayList(struct { Cell.Handle, Cell.Handle.Int }),
volatile_cells: std.ArrayList(struct { Cell.Handle, Cell.Handle.Int }),

/// Maps ranges to a list of cell handles that depend on them.
/// Used to query whether a cell belongs to a range and then update the cells
/// that depend on that range.
dependents: Dependents,

deps: std.ArrayList(Dep) = .empty,
free_deps: DepIndex = .none,

/// Range tree containing just the positions of extant cells.
/// Used for quick lookup of all extant cells in a range.
cell_tree: CellTree,

ast: Ast,

string_values: FlatListPool(u8),

// TODO: Only create columns for columns whose width/precision/whatever actually changes.
cols: Columns,

undos: std.MultiArrayList(Undo),
redos: std.MultiArrayList(Undo),

/// Stores cell handles referenced in bulk cell insert/delete undos.
cell_buffer: std.ArrayList(Cell.Handle) = .empty,

search_buffer: std.ArrayList(Dependents.Entry.Handle),

filepath: std.ArrayList(u8),

/// Used for temporary allocations
arena: std.heap.ArenaAllocator,

text_attrs: PhTree(TextAttrs, 2, Cell.Handle.Int),

lua_point_trees: std.StringHashMapUnmanaged(LuaDataPointTree) = .empty,

cell_value_ranges: std.ArrayList(Rect) = .empty,
closures: std.ArrayList(Ast.Value) = .empty,

needs_update: bool = true,

pub const RangeIndex = enum(u64) {
    invalid = std.math.maxInt(u64),
    _,
};

pub fn cellValueRange(sheet: *const Sheet, index: RangeIndex) *Rect {
    const n: usize = @intCast(@intFromEnum(index));
    return &sheet.cell_value_ranges.items[n];
}

pub fn pushCellValueRange(sheet: *Sheet, range: Rect) !RangeIndex {
    const n: u64 = @intCast(sheet.cell_value_ranges.items.len);
    try sheet.cell_value_ranges.append(sheet.gpa, range);
    return @enumFromInt(n);
}

// TODO: Expose 1 and 4 dimensional trees to Lua

/// Maps 2D points to lua tables. Can be created by lua scripts to store arbitrary Lua data in
/// PhTrees implemented in native code with high performance.
const LuaDataPointTree = PhTree(i32, 2, u32);

pub const TextAttrs = extern struct {
    alignment: Alignment,

    pub const Alignment = enum(u8) {
        left,
        right,
        center,
    };

    pub const default: TextAttrs = .{
        .alignment = .center,
    };

    pub const Handle = @FieldType(Sheet, "text_attrs").Entry.Handle;
};

const arena_retain_size = std.math.pow(usize, 2, 20);

pub const Dep = extern struct {
    handle: Cell.Handle,
    next: DepIndex,
};

pub const Columns = PhTree(Column, 1, u32);
pub const Dependents = PhTree(DepIndex, 4, usize);
pub const CellTree = PhTree(Cell, 2, usize);

pub const DepIndex = packed struct {
    n: u32,

    pub fn from(n: u32) DepIndex {
        assert(n < std.math.maxInt(u32));
        return .{ .n = n };
    }

    pub fn isValid(index: DepIndex) bool {
        return index != none;
    }

    pub const none: DepIndex = .{ .n = std.math.maxInt(u32) };
};

pub const UndoOpts = struct {
    undo_type: UndoType = .undo,
    clear_redos: bool = true,
};

comptime {
    assert(@sizeOf(Cell) <= 16);
}

pub const Cell = extern struct {
    /// Cached value of the cell
    value: Value = .{ .err = .fromError(error.NotEvaluable) },

    expr: packed struct(u64) {
        unused: u3 = 0,
        stored_volatile: bool = false,
        value_tag: Value.Tag = .err,

        /// State used for evaluating cells.
        state: enum(u3) {
            up_to_date,
            dirty,
            enqueued,
            computing,
            @"volatile",
        } = .up_to_date,
        is_volatile: bool,

        /// Root node of the abstract syntax tree representing the expression in the cell.
        index: Ast.Node.OptionalIndex = .none,
    },

    pub const Handle = CellTree.Entry.Handle;
    pub const Slice = CellTree.Slice;

    // Non-extern unions get a hidden tag in safe builds which makes serialising them annoying.
    // So we use an extern union here.
    pub const Value = extern union {
        number: f64,
        string: FlatListPool(u8).List.Index,
        err: Error,
        ref_cell: Position,
        ref_range: RangeIndex,
        simple_function: packed struct(u64) {
            unused: u16 = 0,
            index: Ast.Node.Index,
        },
        closure: packed struct(u64) {
            unused: u8 = 0,
            len: u8,
            /// Index into the `closures` array. The element at this index is a `function` value
            /// with no captures, storing the index of the function body. The next `len` elements
            /// are the captured values.
            index: u48,
        },

        pub const Tag = blk: {
            var t = @typeInfo(std.meta.FieldEnum(Value));
            t.@"enum".tag_type = u8;
            break :blk @Type(t);
        };
    };

    pub const Error = extern struct {
        tag: Tag,

        pub const Tag = blk: {
            var t = @typeInfo(std.meta.FieldEnum(Ast.EvalError));
            t.@"enum".tag_type = u8;
            break :blk @Type(t);
        };

        pub fn fromError(err: Ast.EvalError) Error {
            return switch (err) {
                inline else => |e| .{ .tag = @field(Tag, @errorName(e)) },
            };
        }

        pub fn getError(e: Error) Ast.EvalError {
            return switch (e.tag) {
                inline else => |tag| @field(Ast.EvalError, @tagName(tag)),
            };
        }
    };

    pub fn setValue(cell: *Cell, comptime tag: Value.Tag, value: @FieldType(Value, @tagName(tag))) void {
        cell.value = @unionInit(Value, @tagName(tag), value);
        cell.expr.value_tag = tag;
    }

    pub fn root(cell: *const Cell) Ast.Node.OptionalIndex {
        return cell.expr.index;
    }
};

pub const Column = extern struct {
    pub const default_width = 10;

    width: u16 = default_width,
    precision: u8 = 2,

    pub const Handle = Columns.Entry.Handle;
};

/// This is an extern struct instead of a tagged union for serialization purposes.
pub const Undo = extern struct {
    tag: Tag,
    payload: Payload,

    pub inline fn init(comptime tag: Tag, payload: @FieldType(Payload, @tagName(tag))) Undo {
        return .{
            .tag = tag,
            .payload = @unionInit(Payload, @tagName(tag), payload),
        };
    }

    pub const sentinel: Undo = .{ .tag = .sentinel, .payload = undefined };

    pub const Tag = blk: {
        const AutoTag = std.meta.FieldEnum(Payload);
        var info = @typeInfo(AutoTag);
        info.@"enum".tag_type = u8;
        break :blk @Type(info);
    };

    pub const Payload = extern union {
        sentinel: void,
        set_cell: Cell.Handle,
        delete_cell: Position,

        insert_cell: Cell.Handle,

        set_column_width: extern struct {
            col: Position.Int,
            width: u16,
        },
        set_column_precision: extern struct {
            col: Position.Int,
            precision: u8,
        },
        delete_columns: extern struct {
            start: u32,
            end: u32,
        },
        insert_columns: extern struct {
            start: u32,
            len: u32,
        },
        delete_rows: extern struct {
            start: u32,
            end: u32,
        },
        insert_rows: extern struct {
            start: u32,
            len: u32,
        },
        update_range: extern struct {
            ast_node: packed struct(u64) {
                index: Ast.Node.Index,
                unused: u16 = 0,
            },
            range: Rect,
        },
        update_pos: extern struct {
            node: packed struct(u64) {
                index: Ast.Node.Index,
                tag: Ast.Node.Tag,
                unused: u8 = 0,
            },
            pos: Position,
        },
        insert_dep: Dependents.Entry.Handle,
        update_dep: extern struct {
            handle: Dependents.Entry.Handle,
            point: Dependents.Point,
        },
        bulk_cell_delete: usize,
        bulk_cell_insert: usize,
        bulk_cell_delete_contiguous: CellHandleInterval,
        bulk_cell_insert_contiguous: CellHandleInterval,

        const CellHandleInterval = extern struct {
            start: Cell.Handle.Int,
            end: Cell.Handle.Int,
        };
    };
};

pub const UndoType = enum { undo, redo };

pub fn init(gpa: Allocator) !Sheet {
    var sheet: Sheet = .{
        .gpa = gpa,
        .has_changes = false,

        .queued_cells = .empty,
        .volatile_cells = .empty,

        .undos = .empty,
        .redos = .empty,

        .cell_tree = .empty,
        .dependents = .empty,
        .ast = .empty,
        .string_values = .empty,

        .cols = .empty,

        .search_buffer = .empty,

        .arena = .init(gpa),
        .filepath = .empty,

        .text_attrs = .empty,

        .lua_point_trees = .empty,
    };

    try sheet.undos.ensureTotalCapacity(gpa, 1);
    errdefer sheet.undos.deinit(gpa);
    try sheet.redos.ensureTotalCapacity(gpa, 1);
    errdefer sheet.redos.deinit(gpa);
    try sheet.filepath.ensureTotalCapacityPrecise(gpa, std.fs.max_path_bytes);

    return sheet;
}

pub fn deinit(sheet: *Sheet) void {
    sheet.search_buffer.deinit(sheet.gpa);
    sheet.lua_point_trees.deinit(sheet.gpa);
    sheet.filepath.deinit(sheet.gpa);
    sheet.cell_value_ranges.deinit(sheet.gpa);

    sheet.clearUndos(.undo);
    sheet.clearUndos(.redo);
    sheet.dependents.deinit(sheet.gpa);
    sheet.cell_tree.deinit(sheet.gpa);

    sheet.queued_cells.deinit(sheet.gpa);
    sheet.volatile_cells.deinit(sheet.gpa);
    sheet.undos.deinit(sheet.gpa);
    sheet.redos.deinit(sheet.gpa);

    sheet.cols.deinit(sheet.gpa);
    sheet.ast.deinit(sheet.gpa);
    sheet.string_values.deinit(sheet.gpa);
    sheet.deps.deinit(sheet.gpa);
    sheet.cell_buffer.deinit(sheet.gpa);
    sheet.text_attrs.deinit(sheet.gpa);
    sheet.closures.deinit(sheet.gpa);
    sheet.arena.deinit();
}

pub fn exprSlice(sheet: *const Sheet, root: Ast.Node.Index) NodeList {
    return sheet.ast.exprSlice(root);
}

const Lua = @import("zlua").Lua;

pub fn setTextAlignment(
    sheet: *Sheet,
    cell: Cell.Handle,
    new_alignment: TextAttrs.Alignment,
) !void {
    const res = try sheet.text_attrs.getOrPut(sheet.gpa, sheet.cell_tree.getPoint(cell));
    if (!res.found_existing)
        res.value_ptr.* = .default;
    res.value_ptr.alignment = new_alignment;
}

pub fn clearTextAttrs(sheet: *Sheet, cell: Cell.Handle) void {
    _ = sheet.text_attrs.remove(cell);
}

fn createDep(sheet: *Sheet, dep: Dep) !DepIndex {
    if (sheet.free_deps.isValid()) {
        const ret = sheet.free_deps;
        sheet.free_deps = sheet.deps.items[ret.n].next;
        sheet.deps.items[ret.n] = dep;
        return ret;
    }

    const ret: DepIndex = .from(@intCast(sheet.deps.items.len));
    try sheet.deps.append(sheet.gpa, dep);
    return ret;
}

fn createDepAssumeCapacity(sheet: *Sheet, dep: Dep) DepIndex {
    if (sheet.free_deps.isValid()) {
        const ret = sheet.free_deps;
        sheet.free_deps = sheet.deps.items[ret.n].next;
        sheet.deps.items[ret.n] = dep;
        return ret;
    }

    const ret: DepIndex = .from(@intCast(sheet.deps.items.len));
    sheet.deps.appendAssumeCapacity(dep);
    return ret;
}

fn destroyDep(sheet: *Sheet, dep: DepIndex) void {
    sheet.deps.items[dep.n].next = sheet.free_deps;
    sheet.free_deps = dep;
}

pub fn posFromCellHandle(sheet: *const Sheet, handle: Cell.Handle) Position {
    const point = sheet.cell_tree.getPoint(handle).*;
    return .init(point[0], point[1]);
}

pub fn rectFromCellHandle(sheet: *Sheet, handle: Cell.Handle) Rect {
    const point = sheet.cell_tree.getPoint(handle).*;
    const pos: Position = .init(point[0], point[1]);
    return .initSinglePos(pos);
}

pub fn getCellFromHandle(sheet: *const Sheet, handle: Cell.Handle) *Cell {
    return sheet.cell_tree.getValue(handle);
}

// TODO: Change u32 to u64
const SerializeHeader = extern struct {
    /// Magic number identifying a binary file as a cellulator file.
    magic: u32 = magic_number,
    /// A version field for when the binary output changes.
    version: u32 = binary_version,

    strings_buf_len: u32,

    dependents: Dependents.Header,
    deps_len: u32,
    deps_free: DepIndex,

    cell_tree: CellTree.Header,

    ast_nodes_len: u32,
    ast_nodes_cap: u32,

    string_values: FlatListPool(u8).Header,

    cols: Columns.Header,

    cells_buffer_len: u32,

    undos_len: u32,
    undos_cap: u32,
    redos_len: u32,
    redos_cap: u32,

    const magic_number: u32 = @bitCast([4]u8{ 'Z', 'C', 'Z', 'C' });
    const binary_version = 10;
};

pub fn serialize(sheet: *Sheet, file: std.fs.File) !void {
    assert(sheet.queued_cells.items.len == 0);

    const header: SerializeHeader = .{
        .strings_buf_len = @intCast(sheet.ast.strings.items.len),
        .dependents = sheet.dependents.getHeader(),
        .deps_len = @intCast(sheet.deps.items.len),
        .deps_free = sheet.free_deps,
        .cell_tree = sheet.cell_tree.getHeader(),
        .ast_nodes_len = @intCast(sheet.ast.nodes.len()),
        .ast_nodes_cap = @intCast(sheet.ast.nodes.capacity()),
        .string_values = sheet.string_values.getHeader(),
        .cols = sheet.cols.getHeader(),
        .cells_buffer_len = @intCast(sheet.cell_buffer.items.len),
        .undos_len = @intCast(sheet.undos.len),
        .undos_cap = @intCast(sheet.undos.capacity),
        .redos_len = @intCast(sheet.redos.len),
        .redos_cap = @intCast(sheet.redos.capacity),
    };

    var iovecs: [36][]const u8 =
        utils.ptrToIoVec(&header) ++
        utils.ptrToIoVec(sheet.ast.strings.items) ++
        sheet.dependents.iovecs() ++
        utils.ptrToIoVec(sheet.deps.items) ++
        sheet.cell_tree.iovecs() ++
        utils.multiArrayListSliceIoVec(&sheet.ast.nodes) ++
        sheet.string_values.iovecs() ++
        sheet.cols.iovecs() ++
        utils.ptrToIoVec(sheet.cell_buffer.items) ++
        utils.multiArrayListIoVec(&sheet.undos) ++
        utils.multiArrayListIoVec(&sheet.redos);

    var writer = file.writer(&.{});
    try writer.interface.writeVecAll(&iovecs);
}

pub fn deserialize(sheet: *Sheet, gpa: Allocator, file: std.fs.File) !void {
    var buf: [@sizeOf(SerializeHeader)]u8 = undefined;
    var reader = file.reader(&buf);
    const native_endian = builtin.target.cpu.arch.endian();
    const header = try reader.interface.takeStruct(SerializeHeader, native_endian);

    if (header.magic != SerializeHeader.magic_number) return error.InvalidFile;
    if (header.version != SerializeHeader.binary_version) return error.InvalidVersion;

    sheet.free_deps = header.deps_free;

    try sheet.ast.strings.ensureTotalCapacityPrecise(gpa, header.strings_buf_len);
    sheet.ast.strings.expandToCapacity();

    try sheet.deps.ensureTotalCapacityPrecise(gpa, header.deps_len);
    sheet.deps.expandToCapacity();

    try sheet.cell_buffer.ensureTotalCapacityPrecise(gpa, header.cells_buffer_len);
    sheet.cell_buffer.expandToCapacity();

    try sheet.dependents.initFromHeader(gpa, header.dependents);
    try sheet.cell_tree.initFromHeader(gpa, header.cell_tree);
    try sheet.ast.nodes.setAndExpandCapacity(gpa, header.ast_nodes_len, header.ast_nodes_cap);
    try sheet.string_values.initFromHeader(gpa, header.string_values);
    try sheet.cols.initFromHeader(gpa, header.cols);
    try utils.setAndExpandCapacity(&sheet.undos, gpa, header.undos_len, header.undos_cap);
    try utils.setAndExpandCapacity(&sheet.redos, gpa, header.redos_len, header.redos_cap);

    var iovecs =
        utils.ptrToIoVec(sheet.ast.strings.items) ++
        sheet.dependents.iovecs() ++
        utils.ptrToIoVec(sheet.deps.items) ++
        sheet.cell_tree.iovecs() ++
        utils.multiArrayListSliceIoVec(&sheet.ast.nodes) ++
        sheet.string_values.iovecs() ++
        sheet.cols.iovecs() ++
        utils.ptrToIoVec(sheet.cell_buffer.items) ++
        utils.multiArrayListIoVec(&sheet.undos) ++
        utils.multiArrayListIoVec(&sheet.redos);

    try reader.interface.readVecAll(&iovecs);
}

pub fn clearRetainingCapacity(sheet: *Sheet) void {
    sheet.queued_cells.clearRetainingCapacity();
    sheet.volatile_cells.clearRetainingCapacity();

    sheet.cell_tree.clearRetainingCapacity();

    sheet.dependents.clearRetainingCapacity();
    sheet.string_values.clearRetainingCapacity();

    sheet.undos.len = 0;
    sheet.redos.len = 0;
    sheet.ast.clearRetainingCapacity();
    sheet.cols.clearRetainingCapacity();
    _ = sheet.arena.reset(.{ .retain_with_limit = arena_retain_size });
}

const Tokenizer = @import("Tokenizer.zig");

const CsvAssignment = struct {
    pos: Position,
    f: f64,
    root: Ast.Node.OptionalIndex,
};

const Assignment = struct {
    root: Ast.Node.Index,
    is_volatile: bool,
    pos: Position,
};

const AssignmentsContext = struct {
    /// Column major ordering so we can easily get the indexes of the columns we need to
    /// create.
    pub fn lessThan(_: @This(), a: Assignment, b: Assignment) bool {
        const a_int = @as(u64, a.pos.x) * (std.math.maxInt(u32) + 1) + a.pos.y;
        const b_int = @as(u64, b.pos.x) * (std.math.maxInt(u32) + 1) + b.pos.y;
        return a_int < b_int;
    }

    pub fn lessThanCsv(_: @This(), a: CsvAssignment, b: CsvAssignment) bool {
        const a_int = @as(u64, a.pos.x) * (std.math.maxInt(u32) + 1) + a.pos.y;
        const b_int = @as(u64, b.pos.x) * (std.math.maxInt(u32) + 1) + b.pos.y;
        return a_int < b_int;
    }

    pub fn eql(_: @This(), a: anytype, b: anytype) bool {
        return a.pos == b.pos;
    }
};

/// Parses many cell assignments in bulk, appending their AST nodes to `Sheet.ast.nodes`.
/// Returns the total byte length of all parsed string literals. The assignments are
/// guaranteed to be deduplicated based on position.
fn bulkParse(
    sheet: *Sheet,
    src: []const u8,
    tokens_allocator: std.mem.Allocator,
    tokens: *std.MultiArrayList(Tokenizer.Token),
    cells_allocator: std.mem.Allocator,
    assignments: *std.ArrayList(Assignment),
) !void {
    const line_count = blk: {
        var line_count: u32 = 1;
        for (src) |c| {
            if (c == '\n') line_count += 1;
        }
        break :blk line_count;
    };

    try sheet.ensureUnusedAstNodeCapacity(line_count * 2);
    try assignments.ensureTotalCapacity(cells_allocator, line_count + 1);
    try tokens.ensureTotalCapacity(tokens_allocator, src.len / 2);

    tokens.clearRetainingCapacity();
    var reader: std.io.Reader = .fixed(src);
    var t: Tokenizer = .init(&reader);
    while (true) {
        const token = t.next() catch unreachable;
        try tokens.append(tokens_allocator, token);
        if (token.tag == .eof) break;
    }

    const token_tags = tokens.items(.tag);
    const token_starts = tokens.items(.start);

    var p: Parser = try .init(sheet.gpa, src, token_tags, token_starts, &sheet.ast, .{});
    defer p.deinit();
    while (true) {
        const last_state = sheet.ast.save();
        const res = p.nextStatement() catch |err| switch (err) {
            error.UnexpectedToken,
            error.InvalidCellAddress,
            error.InvalidBuiltin,
            => {
                @branchHint(.unlikely);
                p.tok_i += 1;
                continue;
            },
            error.OutOfMemory => |e| {
                @branchHint(.cold);
                return e;
            },
        } orelse break;

        // Non assignments are ignored
        if (res.destination == null) {
            sheet.ast.restore(last_state);
            continue;
        }

        const expr_root, const pos = sheet.ast.spliceLast();

        assignments.appendAssumeCapacity(.{
            .pos = pos,
            .root = expr_root,
            .is_volatile = res.is_volatile,
        });
    }
    if (assignments.items.len == 0) {
        @branchHint(.unlikely);
        return;
    }

    std.mem.sortUnstable(
        Assignment,
        assignments.items,
        AssignmentsContext{},
        AssignmentsContext.lessThan,
    );
    const new_len = utils.collapseRepeats(
        Assignment,
        assignments.items,
        AssignmentsContext{},
    );
    assignments.items.len = new_len;
}

fn resetArena(sheet: *Sheet) void {
    _ = sheet.arena.reset(.{ .retain_with_limit = arena_retain_size });
}

// Optimized for bulk loading
pub fn interpretSource(sheet: *Sheet, r: *std.io.Reader) !void {
    assert(r.buffer.len > 0);
    errdefer sheet.clearRetainingCapacity();

    const arena = sheet.arena.allocator();
    defer sheet.resetArena();

    var assignments: std.ArrayList(Assignment) = .empty;
    var tokens: std.MultiArrayList(Tokenizer.Token) = .empty;

    while (true) {
        r.fill(r.buffer.len) catch |err| switch (err) {
            error.EndOfStream => if (r.bufferedLen() == 0) break,
            else => |e| return e,
        };
        const bytes = r.buffered();
        const end = std.mem.lastIndexOfScalar(u8, bytes, '\n') orelse bytes.len;
        const src = bytes[0..end];
        r.toss(@min(end + 1, bytes.len));

        assignments.clearRetainingCapacity();
        tokens.clearRetainingCapacity();
        const ast_nodes_start = sheet.ast.lastIndex();
        try sheet.bulkParse(src, arena, &tokens, arena, &assignments);
        if (assignments.items.len == 0) continue;

        const dependent_count = blk: {
            var dependent_count: Cell.Handle.Int = 0;
            var iter: Ast.ExpressionIterator = .init(sheet.ast.nodes, ast_nodes_start);
            while (iter.prev()) |root| {
                dependent_count += sheet.ast.countDependencies(root.toOptional());
            }
            break :blk dependent_count;
        };

        // Count the number of columns required
        const col_count = blk: {
            var col_count: u32 = 1;
            for (
                assignments.items[0 .. assignments.items.len - 1],
                assignments.items[1..],
            ) |assignment, next_assignment| {
                const x1 = assignment.pos.x;
                const x2 = next_assignment.pos.x;
                if (x1 != x2) col_count += 1;
            }
            break :blk col_count;
        };

        try sheet.ensureUnusedCellCapacity(assignments.items.len);
        try sheet.dependents.ensureUnusedCapacity(sheet.gpa, dependent_count);
        try sheet.deps.ensureUnusedCapacity(sheet.gpa, dependent_count);
        try sheet.undos.ensureUnusedCapacity(sheet.gpa, 2); // + 1 for sentinel

        try sheet.ensureUnusedColumnCapacity(col_count);
        try sheet.ensureUnusedCellQueueCapacity(1);
        var total_volatile: usize = 0;
        for (assignments.items) |assignment| {
            if (assignment.is_volatile) total_volatile += 1;
        }
        try sheet.volatile_cells.ensureUnusedCapacity(sheet.gpa, total_volatile);
        errdefer comptime unreachable;

        const new_cells = sheet.cell_tree.addMany(assignments.items.len);

        sheet.undos.appendAssumeCapacity(.init(.bulk_cell_delete_contiguous, .{
            .start = new_cells.offset,
            .end = new_cells.end(),
        }));

        sheet.queued_cells.appendAssumeCapacity(.{
            new_cells.handle(0),
            new_cells.len,
        });

        sheet.has_changes = true;

        for (assignments.items, 0..) |assignment, i| {
            const pos = assignment.pos;

            new_cells.set(i, .{
                .parent = .none,
                .point = pos.array(),
                .value = .{
                    .expr = .{
                        .state = .enqueued,
                        .index = assignment.root.toOptional(),
                        .is_volatile = assignment.is_volatile,
                    },
                },
            });

            const handle = new_cells.handle(i);

            if (assignment.is_volatile) {
                // TODO: Sort cells by volatility first, so we can add all volatile cells with just
                //       a single entry.
                sheet.volatile_cells.appendAssumeCapacity(.{ handle, 1 });
            }
            sheet.cell_tree.insertAssumeCapacityNoClobber(&pos.array(), handle);
            sheet.addCellAsDependentOfExprRanges(handle, assignment.root.toOptional());
        }
    }
}

// TODO: Optimize this.
pub fn loadCsv(sheet: *Sheet, r: *std.io.Reader) !void {
    errdefer sheet.clearRetainingCapacity();

    const arena = sheet.arena.allocator();
    defer sheet.resetArena();

    var assignments: std.ArrayList(CsvAssignment) = .empty;

    var col: u32 = 0;
    var row: u32 = 0;
    while (true) {
        r.fill(r.buffer.len) catch |err| switch (err) {
            error.EndOfStream => if (r.bufferedLen() == 0) break,
            else => |e| return e,
        };
        const bytes = r.buffered();
        const end = if (bytes.len < r.buffer.len)
            bytes.len
        else
            std.mem.lastIndexOfScalar(u8, bytes, ',') orelse {
                // A single value is larger than the buffer, ignore it
                r.tossBuffered();
                _ = r.discardDelimiterInclusive(',') catch |err| switch (err) {
                    error.EndOfStream => break,
                    else => |e| return e,
                };
                continue;
            };
        const src = bytes[0..end];
        r.toss(@min(end + 1, bytes.len));

        assignments.clearRetainingCapacity();
        var lines = std.mem.splitScalar(u8, src, '\n');
        var prev_col = col;
        var j: usize = 0;
        while (lines.next()) |line| : (row += 1) {
            var fields = std.mem.splitScalar(u8, line, ',');
            while (fields.next()) |field| : ({
                col += 1;
                j += field.len + 1;
            }) {
                if (field.len == 0) continue;

                const pos: Position = .init(col, row);
                var ass: CsvAssignment = .{ .pos = pos, .f = 0, .root = .none };
                if (std.fmt.parseFloat(f64, field)) |f| {
                    ass.f = f;
                } else |_| {
                    // TODO: Don't make these into ASTs, just set the Cell's value.
                    try sheet.ast.nodes.ensureUnusedCapacity(sheet.gpa, 2);
                    try sheet.ast.strings.ensureUnusedCapacity(sheet.gpa, field.len);
                    const string_start = sheet.ast.strings.items.len;
                    sheet.ast.strings.appendSliceAssumeCapacity(field);
                    const asts = sheet.ast.nodes.appendManyAssumeCapacity(2);
                    asts.seti(0, .{
                        .tag = .string_literal,
                        .data = .{
                            .string_literal = .{
                                .start = @intCast(string_start),
                                .end = @intCast(string_start + field.len),
                            },
                        },
                    });
                    asts.seti(1, .{
                        .tag = .end,
                        .data = .{ .end = .{ .length = 1 } },
                    });
                    ass.root = asts.index(0).toOptional();
                }
                try assignments.append(arena, ass);
            }
            prev_col = col;
            col = 0;
        }
        row -= 1;
        col = prev_col;

        std.mem.sortUnstable(
            CsvAssignment,
            assignments.items,
            AssignmentsContext{},
            AssignmentsContext.lessThanCsv,
        );

        const col_count = blk: {
            var col_count: u32 = 1;
            for (
                assignments.items[0 .. assignments.items.len - 1],
                assignments.items[1..],
            ) |assignment, next_assignment| {
                const x1 = assignment.pos.x;
                const x2 = next_assignment.pos.x;
                if (x1 != x2) col_count += 1;
            }
            break :blk col_count;
        };

        try sheet.ensureUnusedCellCapacity(assignments.items.len);
        try sheet.ensureUnusedColumnCapacity(col_count);
        try sheet.ensureUnusedUndoCapacity(2);
        try sheet.ensureUnusedCellQueueCapacity(1);

        const new_cells = sheet.cell_tree.addMany(assignments.items.len);

        for (assignments.items, 0..) |assignment, i| {
            const pos = assignment.pos;

            new_cells.set(i, .{
                .parent = .none,
                .point = pos.array(),
                .value = .{
                    .expr = .{
                        .value_tag = .number,
                        .state = if (assignment.root == .none) .up_to_date else .enqueued,
                        .index = assignment.root,
                        .is_volatile = false,
                    },
                    .value = .{ .number = assignment.f },
                },
            });

            const handle = new_cells.handle(i);
            sheet.cell_tree.insertAssumeCapacityNoClobber(&pos.array(), handle);
            sheet.addCellAsDependentOfExprRanges(handle, assignment.root);
        }

        sheet.queued_cells.appendAssumeCapacity(.{
            new_cells.handle(0),
            new_cells.len,
        });
    }
}

pub fn writeFile(
    sheet: *Sheet,
    opts: struct {
        filepath: ?[]const u8 = null,
    },
) !void {
    const filepath = opts.filepath orelse sheet.filepath.items;
    if (filepath.len == 0)
        return error.EmptyFileName;

    var buf: [8192]u8 = undefined;
    var atomic_file = try std.fs.cwd().atomicFile(filepath, .{ .write_buffer = &buf });
    defer atomic_file.deinit();

    const w = &atomic_file.file_writer.interface;
    if (std.mem.endsWith(u8, filepath, ".csv")) {
        try sheet.writeCsv(w);
    } else {
        try sheet.writeContents(w);
    }
    try atomic_file.finish();

    if (opts.filepath) |path|
        sheet.setFilePath(path);
}

// TODO: This is dumb
pub fn writeContents(sheet: *Sheet, writer: *std.io.Writer) !void {
    var iter = sheet.cell_tree.iterator();
    while (iter.next()) |handle| {
        const p = sheet.cell_tree.getPoint(handle).*;
        const pos: Position = .init(p[0], p[1]);
        try writer.print("let {f}=", .{pos});
        try sheet.printCellExpression(pos, writer);
        try writer.writeByte('\n');
    }

    try writer.flush();
}

pub fn writeCsv(sheet: *Sheet, writer: *std.io.Writer) !void {
    const arena = sheet.arena.allocator();
    defer sheet.resetArena();

    const cap = sheet.cell_tree.entries.len - sheet.cell_tree.freelist_entries_count;
    var handles: std.ArrayList(Cell.Handle) = .empty;
    try handles.ensureTotalCapacityPrecise(arena, cap);
    try sheet.cell_tree.queryWindow(arena, &@splat(0), &@splat(std.math.maxInt(u32)), &handles);

    const Context = struct {
        tree: *const CellTree,

        pub fn lessThan(ctx: @This(), a: Cell.Handle, b: Cell.Handle) bool {
            const a_pos: Position = .fromArray(ctx.tree.getPoint(a).*);
            const b_pos: Position = .fromArray(ctx.tree.getPoint(b).*);
            return a_pos.hash() < b_pos.hash();
        }
    };

    std.mem.sortUnstable(Cell.Handle, handles.items, Context{ .tree = &sheet.cell_tree }, Context.lessThan);

    var last_line: u32 = 0;
    var last_col: u32 = 0;
    for (handles.items) |handle| {
        const p = sheet.cell_tree.getPoint(handle).*;
        if (p[1] != last_line) {
            try writer.splatByteAll('\n', p[1] - last_line);
            last_col = 0;
        }

        if (p[0] != last_col) {
            try writer.splatByteAll(',', p[0] - last_col);
        }
        const cell = sheet.cell_tree.getValue(handle);
        try sheet.formatCell(cell, writer);
        last_line = p[1];
        last_col = p[0];
    }

    try writer.flush();
}

pub fn formatCell(sheet: *const Sheet, cell: *const Cell, w: *std.io.Writer) !void {
    switch (cell.expr.value_tag) {
        .number => {
            try w.print("{d}", .{cell.value.number});
        },
        .string => {
            const string = sheet.cellStringValue(cell);
            try w.writeAll(string);
        },
        .err => {
            try w.writeAll("ERROR");
        },
        .ref_cell => {
            try w.print("&{f}", .{cell.value.ref_cell});
        },
        .ref_range => {
            const range = sheet.cellValueRange(cell.value.ref_range);
            try w.print("{f}:{f}", .{ range.tl, range.br });
        },
        .simple_function => {
            try sheet.ast.print(cell.value.simple_function.index, w);
        },
        .closure => {
            const root = sheet.closures.items[cell.value.closure.index].function.root;
            try sheet.ast.print(root, w);
        },
    }
}

fn addCellAsDependentOfExprRanges(
    sheet: *Sheet,
    dependent: Cell.Handle,
    expr_root: Ast.Node.OptionalIndex,
) void {
    if (expr_root == .none) return;
    var ctx: AddDependenciesContext = .{
        .sheet = sheet,
        .dependent = dependent,
    };
    sheet.ast.traverseDependencies(expr_root, &ctx, AddDependenciesContext.func);
}

const AddDependenciesContext = struct {
    sheet: *Sheet,
    dependent: Cell.Handle,

    pub fn func(ctx: *AddDependenciesContext, range: Rect) void {
        log.debug("Adding {f} as a dependent of {f}", .{
            ctx.sheet.rectFromCellHandle(ctx.dependent).tl,
            range,
        });

        const res = ctx.sheet.dependents.getOrPutAssumeCapacity(&range.array());
        const head_ptr = res.value_ptr;
        if (!res.found_existing) {
            head_ptr.* = .none;
        }

        const index = ctx.sheet.createDepAssumeCapacity(.{
            .handle = ctx.dependent,
            .next = head_ptr.*,
        });
        head_ptr.* = index;
    }
};

const RemoveDependenciesContext = struct {
    sheet: *Sheet,
    dependent: Cell.Handle,
    destroy: bool,

    pub fn func(ctx: *const RemoveDependenciesContext, range: Rect) void {
        log.debug("Removing {f} as a dependent of {f}", .{
            ctx.sheet.rectFromCellHandle(ctx.dependent),
            range,
        });
        const sheet = ctx.sheet;
        const dependent = ctx.dependent;
        const p = range.array();
        const head = sheet.dependents.find(&p) orelse return;

        while (head.isValid() and sheet.deps.items[head.n].handle == dependent) {
            const old_head = head.*;
            head.* = sheet.deps.items[head.n].next;
            sheet.destroyDep(old_head);
        }

        if (!head.isValid()) {
            if (sheet.dependents.remove(&p)) |kv_handle| {
                if (ctx.destroy) sheet.dependents.destroyValue(kv_handle);
            }
            return;
        }

        var prev = head.*;
        var index = sheet.deps.items[head.n].next;
        while (index.isValid()) : (index = sheet.deps.items[index.n].next) {
            if (sheet.deps.items[index.n].handle == dependent) {
                sheet.deps.items[prev.n].next = sheet.deps.items[index.n].next;
                sheet.destroyDep(index);
                break;
            }

            prev = index;
        }

        if (!head.isValid()) {
            if (sheet.dependents.remove(&p)) |kv_handle|
                if (ctx.destroy) sheet.dependents.destroyValue(kv_handle);
        }
    }
};

fn ensureExpressionDependentsCapacity(sheet: *Sheet, root: Ast.Node.Index) Allocator.Error!void {
    const dependent_count = sheet.ast.countDependencies(root.toOptional());
    try sheet.dependents.ensureUnusedCapacity(sheet.gpa, dependent_count);
    try sheet.deps.ensureUnusedCapacity(sheet.gpa, dependent_count);
}

fn removeCellAsDependentOfExpr(
    sheet: *Sheet,
    dependent: Cell.Handle,
    expr_root: Ast.Node.OptionalIndex,
    comptime destroy: bool,
) void {
    const ctx: RemoveDependenciesContext = .{
        .sheet = sheet,
        .dependent = dependent,
        .destroy = destroy,
    };
    sheet.ast.traverseDependencies(expr_root, &ctx, RemoveDependenciesContext.func);
}

pub fn firstCellInRow(sheet: *Sheet, row: Position.Int) ?Position {
    const x = sheet.findExtantCol(.init(0, row, std.math.maxInt(u32), row), .first) orelse return null;
    return .init(x, row);
}

pub fn lastCellInRow(sheet: *Sheet, row: Position.Int) ?Position {
    const x = sheet.findExtantCol(.init(0, row, std.math.maxInt(u32), row), .last) orelse return null;
    return .init(x, row);
}

pub fn firstCellInColumn(sheet: *Sheet, col: Position.Int) ?Position {
    const y = sheet.findExtantRow(
        .init(col, 0, col, std.math.maxInt(u32)),
        .first,
    ) orelse return null;
    return .init(col, y);
}

pub fn lastCellInColumn(sheet: *Sheet, col: Position.Int) ?Position {
    const y = sheet.findExtantRow(
        .init(col, 0, col, std.math.maxInt(u32)),
        .last,
    ) orelse return null;
    return .init(col, y);
}

// TODO: Optimize these functions by using a binary search on increasingly larger ranges.
/// Given a range, find the first or last row that contains a cell
fn findExtantRow(sheet: *Sheet, r: Rect, comptime p: enum { first, last }) ?PosInt {
    const Context = struct {
        min: ?PosInt = null,
        max: ?PosInt = null,
        sheet: *const Sheet,

        pub fn func(ctx: *@This(), handle: Cell.Handle) !void {
            const pos = ctx.sheet.posFromCellHandle(handle);
            switch (p) {
                .first => if (ctx.min == null or pos.y < ctx.min.?) {
                    ctx.min = pos.y;
                },
                .last => if (ctx.max == null or pos.y > ctx.max.?) {
                    ctx.max = pos.y;
                },
            }
        }
    };

    var ctx: Context = .{ .sheet = sheet };
    sheet.cell_tree.traverse(
        &r.tl.array(),
        &r.br.array(),
        &ctx,
    ) catch unreachable;

    return switch (p) {
        .first => ctx.min,
        .last => ctx.max,
    };
}

/// Given a range, find the first or last column that contains a cell
fn findExtantCol(sheet: *Sheet, r: Rect, comptime p: enum { first, last }) ?PosInt {
    const Context = struct {
        min: ?PosInt = null,
        max: ?PosInt = null,
        sheet: *const Sheet,

        pub fn func(ctx: *@This(), handle: Cell.Handle) !void {
            const pos = ctx.sheet.posFromCellHandle(handle);
            switch (p) {
                .first => if (ctx.min == null or pos.x < ctx.min.?) {
                    ctx.min = pos.x;
                },
                .last => if (ctx.max == null or pos.x > ctx.max.?) {
                    ctx.max = pos.x;
                },
            }
        }
    };

    var ctx: Context = .{ .sheet = sheet };
    sheet.cell_tree.traverse(
        &r.tl.array(),
        &r.br.array(),
        &ctx,
    ) catch unreachable;

    return switch (p) {
        .first => ctx.min,
        .last => ctx.max,
    };
}

pub fn nextPopulatedCell(sheet: *Sheet, pos: Position) ?Position {
    const remaining_row: Rect = blk: {
        if (pos.x != std.math.maxInt(PosInt)) {
            @branchHint(.likely);
            break :blk .{
                .tl = .{ .x = pos.x + 1, .y = pos.y },
                .br = .{ .x = std.math.maxInt(PosInt), .y = pos.y },
            };
        }
        if (pos.y != std.math.maxInt(PosInt)) break :blk .{
            .tl = .{ .x = 0, .y = pos.y + 1 },
            .br = .{ .x = std.math.maxInt(PosInt), .y = pos.y + 1 },
        } else {
            @branchHint(.cold);
            return null;
        }
    };

    if (sheet.findExtantCol(remaining_row, .first)) |col_index| {
        return .{ .x = col_index, .y = remaining_row.br.y };
    }

    if (pos.y == std.math.maxInt(PosInt)) {
        @branchHint(.unlikely);
        return null;
    }

    const range: Rect = .{
        .tl = .{ .x = 0, .y = pos.y + 1 },
        .br = .{ .x = std.math.maxInt(PosInt), .y = std.math.maxInt(PosInt) },
    };
    if (sheet.findExtantRow(range, .first)) |y| {
        const row: Rect = .{
            .tl = .{ .x = 0, .y = y },
            .br = .{ .x = std.math.maxInt(PosInt), .y = y },
        };
        if (sheet.findExtantCol(row, .first)) |x|
            return .init(x, y);
    }

    return null;
}

pub fn prevPopulatedCell(sheet: *Sheet, pos: Position) ?Position {
    const remaining_row: Rect = if (pos.x != 0) .{
        .tl = .{ .x = 0, .y = pos.y },
        .br = .{ .x = pos.x - 1, .y = pos.y },
    } else if (pos.y != 0) .{
        .tl = .{ .x = 0, .y = pos.y - 1 },
        .br = .{ .x = std.math.maxInt(PosInt), .y = pos.y - 1 },
    } else {
        @branchHint(.unlikely);
        return null;
    };

    if (sheet.findExtantCol(remaining_row, .last)) |col_index| {
        return .{
            .x = col_index,
            .y = remaining_row.br.y,
        };
    }

    if (pos.y == 0) return null;

    const range: Rect = .{
        .tl = .{ .x = 0, .y = 0 },
        .br = .{ .x = std.math.maxInt(PosInt), .y = pos.y - 1 },
    };
    if (sheet.findExtantRow(range, .last)) |y| {
        const row: Rect = .{
            .tl = .{ .x = 0, .y = y },
            .br = .{ .x = std.math.maxInt(PosInt), .y = y },
        };
        if (sheet.findExtantCol(row, .last)) |x| {
            return .{
                .x = x,
                .y = y,
            };
        }
    }

    return null;
}

pub fn clearUndos(sheet: *Sheet, comptime kind: UndoType) void {
    const list = switch (kind) {
        .undo => &sheet.undos,
        .redo => &sheet.redos,
    };

    list.len = 0;
}

pub fn endUndoGroup(sheet: *Sheet) void {
    if (sheet.undos.len == 0 or sheet.undos.items(.tag)[sheet.undos.len - 1] == .sentinel)
        return;
    sheet.undos.appendAssumeCapacity(.sentinel);
}

fn endRedoGroup(sheet: *Sheet) void {
    if (sheet.redos.len == 0) return;
    sheet.redos.appendAssumeCapacity(.sentinel);
}

pub fn ensureUnusedUndoCapacity(sheet: *Sheet, n: u32) Allocator.Error!void {
    try sheet.undos.ensureUnusedCapacity(sheet.gpa, n + 1);
    try sheet.redos.ensureUnusedCapacity(sheet.gpa, n + 1);
}

pub fn pushUndo(sheet: *Sheet, u: Undo, opts: UndoOpts) Allocator.Error!void {
    try sheet.ensureUnusedUndoCapacity(1);
    switch (opts.undo_type) {
        .undo => {
            sheet.undos.appendAssumeCapacity(u);
            if (opts.clear_redos) sheet.clearUndos(.redo);
        },
        .redo => {
            sheet.redos.appendAssumeCapacity(u);
        },
    }
}

pub fn pushUndoAssumeCapacity(sheet: *Sheet, u: Undo, opts: UndoOpts) void {
    const undo_type = opts.undo_type;
    assert(sheet.undos.capacity > sheet.undos.len);
    switch (undo_type) {
        .undo => {
            sheet.undos.appendAssumeCapacity(u);
            if (opts.clear_redos) sheet.clearUndos(.redo);
        },
        .redo => {
            sheet.redos.appendAssumeCapacity(u);
        },
    }
}

pub fn doUndo(sheet: *Sheet, u: Undo, opts: UndoOpts) Allocator.Error!void {
    // log.debug("undo {}", .{u.tag});
    switch (u.tag) {
        .set_cell => sheet.insertCellNode(u.payload.set_cell, opts),
        .delete_cell => try sheet.deleteCell(u.payload.delete_cell, opts),
        .insert_cell => {
            const handle = u.payload.insert_cell;
            const p = sheet.cell_tree.getPoint(handle).*;
            _ = try sheet.cell_tree.insert(sheet.gpa, &p, handle);
            try sheet.enqueueUpdate(handle);
        },
        .set_column_width => {
            const p = u.payload.set_column_width;
            try sheet.setWidth(p.col, p.width, opts);
        },
        .set_column_precision => {
            const p = u.payload.set_column_precision;
            try sheet.setPrecision(p.col, p.precision, opts);
        },
        .delete_columns => {
            const p = u.payload.delete_columns;
            try sheet.deleteColOrRowRange(p.start, p.end, opts, .col);
        },
        .insert_columns => {
            const p = u.payload.insert_columns;
            sheet.insertColumns(p.start, p.len, opts) catch |err| switch (err) {
                // This isn't possible for undos
                error.Overflow => unreachable,
                else => |e| return e,
            };
        },
        .delete_rows => {
            const p = u.payload.delete_rows;
            try sheet.deleteColOrRowRange(p.start, p.end, opts, .row);
        },
        .insert_rows => {
            const p = u.payload.insert_rows;
            sheet.insertRows(p.start, p.len, opts) catch |err| switch (err) {
                // This isn't possible for undos
                error.Overflow => unreachable,
                else => |e| return e,
            };
        },
        .update_range => {
            const p = u.payload.update_range;
            try sheet.updateRange(p.ast_node.index, p.range);
        },
        .update_pos => {
            const pos = u.payload.update_pos.pos;
            const i = u.payload.update_pos.node.index;
            const tag = u.payload.update_pos.node.tag;
            try sheet.updatePos(i, pos, tag);
        },
        .insert_dep => {
            const handle = u.payload.insert_dep;
            const p = sheet.dependents.getPoint(handle).*;
            _ = try sheet.dependents.insert(sheet.gpa, &p, handle);
            var n = sheet.dependents.getValue(handle).*;
            while (n.isValid()) : (n = sheet.deps.items[n.n].next) {
                const cell = sheet.deps.items[n.n].handle;
                try sheet.enqueueUpdate(cell);
            }
        },
        .update_dep => {
            const handle = u.payload.update_dep.handle;
            const new_point = u.payload.update_dep.point;
            assert(handle != .none);

            const p = sheet.dependents.getPoint(handle);

            _ = sheet.dependents.removeHandle(handle);
            p.* = new_point;
            _ = sheet.dependents.insertAssumeCapacity(p, handle);
        },
        .bulk_cell_delete => {
            const index = u.payload.bulk_cell_delete;
            const handles = sheet.getUndoCellsSlice(index);

            sheet.bulkDeleteCellHandles(handles);

            try sheet.pushUndo(.init(.bulk_cell_insert, index), opts);
        },
        .bulk_cell_insert => {
            const index = u.payload.bulk_cell_insert;
            const handles = sheet.getUndoCellsSlice(index);

            try sheet.ensureUnusedCellQueueCapacity(handles.len);
            sheet.bulkInsertCellHandles(handles);

            try sheet.pushUndo(.init(.bulk_cell_delete, index), opts);
        },
        .bulk_cell_delete_contiguous => {
            const p = u.payload.bulk_cell_delete_contiguous;
            sheet.bulkDeleteCellHandlesContiguous(p.start, p.end);
            try sheet.pushUndo(.init(.bulk_cell_insert_contiguous, p), opts);
        },
        .bulk_cell_insert_contiguous => {
            const p = u.payload.bulk_cell_delete_contiguous;
            sheet.bulkInsertCellHandlesContiguous(p.start, p.end);
            try sheet.pushUndo(.init(.bulk_cell_delete_contiguous, p), opts);
        },
        .sentinel => {},
    }
}

fn bulkDeleteCellHandles(sheet: *Sheet, handles: []const Cell.Handle) void {
    for (handles) |handle| {
        const cell = sheet.getCellFromHandle(handle);
        // TODO: Doing this in a separate loop from removeHandle might be better
        sheet.removeCellAsDependentOfExpr(handle, cell.root(), true);
        sheet.setCellError(cell);
        sheet.cell_tree.removeHandle(handle);
        cell.expr.state = .enqueued;
        sheet.queued_cells.appendAssumeCapacity(.{ handle, 1 });
    }
}

fn bulkDeleteCellHandlesContiguous(sheet: *Sheet, start: Cell.Handle.Int, end: Cell.Handle.Int) void {
    const cells = sheet.cell_tree.slice(start, end - start);
    for (cells.values(), 0..) |*cell, i| {
        const handle = cells.handle(i);
        // TODO: Doing this in a separate loop from removeHandle might be better
        sheet.removeCellAsDependentOfExpr(handle, cell.root(), true);
        sheet.setCellError(cell);
        sheet.cell_tree.removeHandle(handle);
    }
}

// Inserts cell handles, asserting that they do not overwrite any existing cells.
// Asserts that the cell tree, dependents tree, have enough capacity.
// Enqueues the cells for update.
fn bulkInsertCellHandles(sheet: *Sheet, handles: []const Cell.Handle) void {
    for (handles) |handle| {
        sheet.queued_cells.appendAssumeCapacity(.{ handle, 1 });
    }

    for (handles) |handle| {
        const cell = sheet.getCellFromHandle(handle);
        const p = sheet.cell_tree.getPoint(handle).*;
        sheet.cell_tree.insertAssumeCapacityNoClobber(&p, handle);
        sheet.addCellAsDependentOfExprRanges(handle, cell.root());
        cell.expr.state = .enqueued;
    }
}

fn bulkInsertCellHandlesContiguous(sheet: *Sheet, start: Cell.Handle.Int, end: Cell.Handle.Int) void {
    sheet.queued_cells.appendAssumeCapacity(.{ .from(start), end - start });

    const cells = sheet.cell_tree.slice(start, end - start);
    for (cells.values(), cells.points(), 0..) |*cell, *p, i| {
        const handle = cells.handle(i);
        sheet.cell_tree.insertAssumeCapacityNoClobber(p, handle);
        sheet.addCellAsDependentOfExprRanges(handle, cell.root());
        cell.expr.state = .enqueued;
    }
}

fn getUndoCellsSlice(sheet: *Sheet, index: usize) []Cell.Handle {
    for (sheet.cell_buffer.items[index..], index..) |handle, i| {
        if (handle == .none) {
            assert(i > index);
            return sheet.cell_buffer.items[index..i];
        }
    }

    unreachable;
}

fn updatePos(
    sheet: *Sheet,
    index: Ast.Node.Index,
    new_pos: Position,
    new_tag: Ast.Node.Tag,
) !void {
    switch (new_tag) {
        .rel_rel, .rel_abs, .abs_rel, .abs_abs => {},
        else => assert(false),
    }
    // const tag = sheet.ast.nodes.items(.tag)[index.n];
    // assert(tag == .pos or tag == .invalidated_pos);
    try sheet.ensureUnusedUndoCapacity(1);

    sheet.ast.nodes.ptr(index, .data).rel_rel = new_pos;
    sheet.ast.nodes.ptr(index, .tag).* = new_tag;
}

fn updateRange(sheet: *Sheet, index: Ast.Node.Index, new_range: Rect) !void {
    const tag = sheet.ast.tag(index);
    assert(tag == .range or tag == .invalidated_range);
    try sheet.ensureUnusedUndoCapacity(1);

    const r = index.subi(1);
    const l = sheet.ast.leftMostChild(r).subi(1);
    sheet.ast.nodes.ptr(l, .data).rel_rel = new_range.tl;
    sheet.ast.nodes.ptr(r, .data).rel_rel = new_range.br;
    sheet.ast.nodes.ptr(index, .tag).* = .range;
}

pub fn undo(sheet: *Sheet) Allocator.Error!void {
    if (sheet.undos.len == 0) return;

    // All undo groups MUST end with a group marker
    const last_undo = sheet.undos.pop().?;
    assert(last_undo.tag == .sentinel);

    defer sheet.endRedoGroup();

    const opts: UndoOpts = .{ .undo_type = .redo };
    while (sheet.undos.pop()) |u| {
        assert(u.tag != .sentinel);
        errdefer {
            sheet.endUndoGroup();
            sheet.undos.appendAssumeCapacity(u);
        }
        const old_undos_len = sheet.undos.len;
        try sheet.doUndo(u, opts);
        assert(sheet.undos.len == old_undos_len);
        if (sheet.undos.len == 0 or sheet.undos.items(.tag)[sheet.undos.len - 1] == .sentinel)
            break;
    }
}

pub fn redo(sheet: *Sheet) Allocator.Error!void {
    if (sheet.redos.len == 0) return;

    // All undo groups MUST end with a group marker - so remove it!
    const last = sheet.redos.pop().?;
    assert(last.tag == .sentinel);

    defer sheet.endUndoGroup();

    const opts: UndoOpts = .{ .clear_redos = false };
    while (sheet.redos.pop()) |u| {
        assert(u.tag != .sentinel);
        errdefer {
            sheet.endRedoGroup();
            sheet.redos.appendAssumeCapacity(u);
        }
        const old_redos_len = sheet.redos.len;
        try sheet.doUndo(u, opts);
        assert(sheet.redos.len == old_redos_len);
        if (sheet.redos.len == 0 or sheet.redos.items(.tag)[sheet.redos.len - 1] == .sentinel)
            break;
    }
}

pub fn setWidth(
    sheet: *Sheet,
    column_index: Position.Int,
    width: u16,
    opts: UndoOpts,
) Allocator.Error!void {
    if (sheet.getColumnHandle(column_index)) |col| {
        try sheet.setColWidth(col, column_index, width, opts);
    }
}

pub fn setColWidth(
    sheet: *Sheet,
    handle: Column.Handle,
    index: Position.Int,
    width: u16,
    opts: UndoOpts,
) Allocator.Error!void {
    try sheet.ensureUnusedUndoCapacity(1);
    const col = sheet.cols.getValue(handle);
    if (width == col.width) return;
    const old_width = col.width;
    col.width = width;
    sheet.pushUndo(.init(.set_column_width, .{
        .col = index,
        .width = old_width,
    }), opts) catch unreachable;
}

pub fn incWidth(
    sheet: *Sheet,
    column_index: Position.Int,
    n: u16,
    opts: UndoOpts,
) Allocator.Error!void {
    if (!sheet.columnIsPopulated(column_index)) return;
    try sheet.ensureUnusedUndoCapacity(1);

    const res = try sheet.cols.getOrPut(sheet.gpa, &.{column_index});
    if (!res.found_existing) res.value_ptr.* = .{};

    try sheet.setColWidth(res.handle, column_index, res.value_ptr.width +| n, opts);
}

pub fn decWidth(
    sheet: *Sheet,
    column_index: Position.Int,
    n: u16,
    opts: UndoOpts,
) Allocator.Error!void {
    if (!sheet.columnIsPopulated(column_index)) return;
    try sheet.ensureUnusedUndoCapacity(1);

    const res = try sheet.cols.getOrPut(sheet.gpa, &.{column_index});
    if (!res.found_existing) res.value_ptr.* = .{};

    try sheet.setColWidth(res.handle, column_index, res.value_ptr.width -| n, opts);
}

pub fn setPrecision(
    sheet: *Sheet,
    column_index: Position.Int,
    precision: u8,
    opts: UndoOpts,
) Allocator.Error!void {
    if (sheet.getColumnHandle(column_index)) |handle| {
        try sheet.setColPrecision(handle, column_index, precision, opts);
    }
}

pub fn setColPrecision(
    sheet: *Sheet,
    handle: Column.Handle,
    index: Position.Int,
    precision: u8,
    opts: UndoOpts,
) Allocator.Error!void {
    const col = sheet.cols.getValue(handle);
    if (precision == col.precision) return;

    const old_precision = col.precision;
    col.precision = precision;
    try sheet.pushUndo(.init(.set_column_precision, .{
        .col = index,
        .precision = old_precision,
    }), opts);
}

pub fn incPrecision(
    sheet: *Sheet,
    column_index: Position.Int,
    n: u8,
    opts: UndoOpts,
) Allocator.Error!void {
    if (!sheet.columnIsPopulated(column_index)) return;
    try sheet.ensureUnusedUndoCapacity(1);

    const res = try sheet.cols.getOrPut(sheet.gpa, &.{column_index});
    if (!res.found_existing) res.value_ptr.* = .{};

    try sheet.setColPrecision(res.handle, column_index, res.value_ptr.precision +| n, opts);
}

pub fn decPrecision(
    sheet: *Sheet,
    column_index: Position.Int,
    n: u8,
    opts: UndoOpts,
) Allocator.Error!void {
    if (!sheet.columnIsPopulated(column_index)) return;
    try sheet.ensureUnusedUndoCapacity(1);

    const res = try sheet.cols.getOrPut(sheet.gpa, &.{column_index});
    if (!res.found_existing) res.value_ptr.* = .{};

    try sheet.setColPrecision(res.handle, column_index, res.value_ptr.precision -| n, opts);
}

const ExistsContext = struct {
    found: bool = false,

    pub fn func(ctx: *@This(), _: Cell.Handle) !void {
        ctx.found = true;
        return error.Finished;
    }
};

pub fn columnIsPopulated(sheet: *const Sheet, col: Position.Int) bool {
    var ctx: ExistsContext = .{};
    sheet.cell_tree.traverse(
        &.{ col, 0 },
        &.{ col, std.math.maxInt(Position.Int) },
        &ctx,
    ) catch {};
    return ctx.found;
}

pub fn rowIsPopulated(sheet: *const Sheet, row: Position.Int) bool {
    var ctx: ExistsContext = .{};
    sheet.cell_tree.traverse(
        &.{ 0, row },
        &.{ std.math.maxInt(Position.Int), row },
        &ctx,
    ) catch {};
    return ctx.found;
}

pub fn needsUpdate(sheet: *const Sheet) bool {
    return sheet.needs_update or sheet.queued_cells.items.len > 0;
}

fn ensureUnusedCellCapacity(sheet: *Sheet, n: usize) !void {
    try sheet.cell_tree.ensureUnusedCapacity(sheet.gpa, n);
}

fn ensureUnusedCellQueueCapacity(sheet: *Sheet, n: usize) !void {
    try sheet.queued_cells.ensureUnusedCapacity(sheet.gpa, n);
}

fn ensureUnusedColumnCapacity(sheet: *Sheet, n: usize) !void {
    try sheet.cols.ensureUnusedCapacity(sheet.gpa, n);
}

fn ensureUnusedAstNodeCapacity(sheet: *Sheet, n: usize) !void {
    try sheet.ast.nodes.ensureUnusedCapacity(sheet.gpa, n);
}

fn ensureUnusedCellBufferCapacity(sheet: *Sheet, n: usize) !void {
    try sheet.cell_buffer.ensureUnusedCapacity(sheet.gpa, n);
}

/// Deletes a cell range, pushing a `.bulk_cell_insert` undo. Asserts that `undo_cell_buffer` and the
/// respective undo stack has enough capacity.
fn deleteCellRangeAssumeCapacity(sheet: *Sheet, range: Rect, opts: UndoOpts) u32 {
    // assert(sheet.cell_buffer.capacity - sheet.cell_buffer.items.len >= range.area() + 1);
    assert(opts.undo_type == .redo or sheet.undos.capacity - sheet.undos.len > 0);
    assert(opts.undo_type == .undo or sheet.redos.capacity - sheet.redos.len > 0);

    const existing_cells: []const Cell.Handle, const deleted_index: u32 = blk: {
        const buf = &sheet.cell_buffer;
        const start = buf.items.len;
        sheet.cell_tree.queryWindow(
            sheet.gpa,
            &range.tl.array(),
            &range.br.array(),
            buf,
        ) catch unreachable;

        if (buf.items.len == start) {
            return std.math.maxInt(u32);
        }

        buf.appendAssumeCapacity(.none);
        break :blk .{ buf.items[start .. buf.items.len - 1], @intCast(start) };
    };

    for (existing_cells) |cell_handle| {
        const old_cell = sheet.getCellFromHandle(cell_handle);
        sheet.removeCellAsDependentOfExpr(cell_handle, old_cell.root(), true);
        sheet.cell_tree.removeHandle(cell_handle);
        sheet.setCellError(old_cell);
        old_cell.expr.state = .enqueued;
    }

    if (existing_cells.len > 0) {
        sheet.pushUndoAssumeCapacity(.init(.bulk_cell_insert, deleted_index), opts);
    }

    return deleted_index;
}

pub fn insertIncrementingCellRange(
    sheet: *Sheet,
    range: Rect,
    start: f64,
    incr: f64,
    opts: UndoOpts,
) !void {
    const area = std.math.cast(usize, range.area()) orelse {
        @branchHint(.cold);
        return error.OutOfMemory;
    };
    const width = std.math.cast(usize, range.width2()) orelse {
        @branchHint(.cold);
        return error.OutOfMemory;
    };
    try sheet.ensureUnusedCellCapacity(area);
    try sheet.ensureUnusedAstNodeCapacity(area);
    // One for deleting existing cells, one for inserting new cells
    try sheet.ensureUnusedUndoCapacity(2);
    try sheet.ensureUnusedCellQueueCapacity(1);
    try sheet.ensureUnusedCellBufferCapacity(area + 1); // Can't overflow, we'll OOM before that
    try sheet.ensureUnusedColumnCapacity(width);
    errdefer comptime unreachable;
    sheet.needs_update = true;

    _ = sheet.deleteCellRangeAssumeCapacity(range, opts);

    const new_cells = sheet.bulkCreateCellRange(range);
    assert(new_cells.len == area);

    sheet.queued_cells.appendAssumeCapacity(.{ new_cells.handle(0), area });
    for (new_cells.values(), 0..) |*value, i| {
        const f: f64 = @floatFromInt(i);
        value.* = .{
            .value = .{ .number = start + incr * f },
            .expr = .{
                .value_tag = .number,
                .state = .up_to_date,
                .index = .none,
                .is_volatile = false,
            },
        };
    }

    assert(new_cells.len > 0);
    for (new_cells.points(), new_cells.values(), 0..) |*p, *cell, i| {
        const handle = new_cells.handle(i);
        sheet.cell_tree.insertAssumeCapacityNoClobber(p, handle);
        sheet.addCellAsDependentOfExprRanges(handle, cell.root());
        cell.expr.state = .enqueued;
    }

    sheet.pushUndoAssumeCapacity(.init(.bulk_cell_delete_contiguous, .{
        .start = new_cells.offset,
        .end = new_cells.end(),
    }), opts);
}

/// Creates a new cell handle for every cell in `range`. Only sets the point field of each handle.
/// Only allocates memory for the cell tree.
///
/// Asserts that the `area.range() <= std.math.maxInt(usize)`
fn bulkCreateCellRange(sheet: *Sheet, range: Rect) CellTree.Slice {
    const area: usize = @intCast(range.area());
    const new_cells = sheet.cell_tree.addMany(area);

    var i: usize = 0;
    var y: u64 = range.tl.y;
    while (y <= range.br.y) : (y += 1) {
        var x: u64 = range.tl.x;
        while (x <= range.br.x) : (x += 1) {
            new_cells.getPoint(i).* = .{
                @intCast(x),
                @intCast(y),
            };
            i += 1;
        }
    }

    return new_cells;
}

pub const BulkSetCellOptions = struct {
    value: Cell.Value = .{ .err = .fromError(error.NotEvaluable) },
    tag: Cell.Value.Tag = .err,
    undo_opts: UndoOpts = .{},
};

/// Sets all cells in `range` to `expr`.
pub fn insertCellRange(
    sheet: *Sheet,
    range: Rect,
    expr: Parser.OptionalResult,
    opts: BulkSetCellOptions,
) !void {
    const need_cell_eval = opts.tag == .err;
    // Pre-allocate memory
    const area = std.math.cast(usize, range.area()) orelse {
        @branchHint(.cold);
        return error.OutOfMemory;
    };
    const width = std.math.cast(usize, range.width2()) orelse {
        @branchHint(.cold);
        return error.OutOfMemory;
    };
    try sheet.ensureUnusedCellCapacity(area);
    if (need_cell_eval)
        try sheet.ensureUnusedCellQueueCapacity(1);
    if (expr.root.unwrap()) |root|
        try sheet.ensureExpressionDependentsCapacity(root);
    try sheet.ensureUnusedColumnCapacity(width);
    try sheet.ensureUnusedUndoCapacity(2);
    try sheet.ensureUnusedCellBufferCapacity(area + 1);

    const ref_count = sheet.ast.countDependencies(expr.root);
    try sheet.deps.ensureUnusedCapacity(sheet.gpa, area * ref_count);
    if (expr.is_volatile) {
        try sheet.volatile_cells.ensureUnusedCapacity(sheet.gpa, 1);
    }
    errdefer comptime unreachable;
    sheet.needs_update = true;

    _ = sheet.deleteCellRangeAssumeCapacity(range, opts.undo_opts);

    const new_cells = sheet.cell_tree.addMany(area);
    if (expr.is_volatile)
        sheet.volatile_cells.appendAssumeCapacity(.{ new_cells.handle(0), new_cells.len });

    // Create dependency information
    // For each range we depend on, prepend the cell handle of every cell we're creating
    const Context = struct {
        sheet: *Sheet,
        new_cells: CellTree.Slice,
        area: usize,

        pub fn func(ctx: *const @This(), r: Rect) void {
            const p = r.array();
            const res = ctx.sheet.dependents.getOrPutAssumeCapacity(&p);
            const head = res.value_ptr;
            if (!res.found_existing) head.* = .none;

            const start = ctx.sheet.deps.items.len;
            const new_deps = ctx.sheet.deps.addManyAtAssumeCapacity(ctx.sheet.deps.items.len, ctx.area);
            // TODO: Make this suck less
            for (new_deps, start + 1.., 0..) |*dep, i, j| {
                dep.* = .{
                    .handle = ctx.new_cells.handle(j),
                    .next = .from(@intCast(i)),
                };
            }
            new_deps[new_deps.len - 1].next = head.*;
            head.* = .from(@intCast(start));
        }
    };

    const ctx: Context = .{
        .sheet = sheet,
        .new_cells = new_cells,
        .area = area,
    };
    sheet.ast.traverseDependencies(expr.root, &ctx, Context.func);

    if (need_cell_eval) {
        sheet.queued_cells.appendAssumeCapacity(.{ new_cells.handle(0), area });
    }

    const cell: Cell = .{
        .value = opts.value,
        .expr = .{
            .value_tag = opts.tag,
            .state = if (need_cell_eval) .enqueued else .up_to_date,
            .index = expr.root,
            .is_volatile = expr.is_volatile,
        },
    };
    // All created cells share the same cell value
    @memset(new_cells.values(), cell);
    @memset(new_cells.parents(), .none);

    // TODO: These inserts get slow when we start inserting millions of cells at once.
    //       Each insert does a separate lookup. We should find some way to exploit the internal
    //       layout of the phtree to make inserting consecutive points faster.
    //       We could build the tree bottom-up?
    const points = new_cells.points();
    var y: u32 = range.tl.y;
    while (y <= range.br.y) : (y += 1) {
        var x: u32 = range.tl.x;
        while (x <= range.br.x) : (x += 1) {
            const y_off = (y - range.tl.y) * width;
            const x_off = x - range.tl.x;

            const off = y_off + x_off;
            const p: CellTree.Point = .{ @intCast(x), @intCast(y) };
            points[off] = p;

            const handle = new_cells.handle(off);
            sheet.cell_tree.insertAssumeCapacityNoClobber(&p, handle);
        }
    }

    sheet.pushUndoAssumeCapacity(.init(.bulk_cell_delete_contiguous, .{
        .start = new_cells.offset,
        .end = new_cells.end(),
    }), opts.undo_opts);
}

/// Creates the cell at `pos` using the given expression, duplicating its string literals.
pub fn setCell(
    sheet: *Sheet,
    pos: Position,
    expr: Parser.Result,
    undo_opts: UndoOpts,
) Allocator.Error!void {
    try sheet.ensureUnusedCellCapacity(1);
    try sheet.ensureUnusedCellQueueCapacity(1);
    try sheet.ensureExpressionDependentsCapacity(expr.root);
    try sheet.ensureUnusedUndoCapacity(1);
    if (expr.is_volatile) {
        try sheet.volatile_cells.ensureUnusedCapacity(sheet.gpa, 1);
        std.log.debug("Set {f} to volatile expression", .{pos});
    }
    errdefer comptime unreachable;

    const cell = sheet.cell_tree.createValueAssumeCapacity(&pos.array(), .{
        .expr = .{ .index = expr.root.toOptional(), .is_volatile = expr.is_volatile },
    });
    if (expr.is_volatile) {
        sheet.volatile_cells.appendAssumeCapacity(.{ cell, 1 });
    }

    sheet.insertCellNode(cell, undo_opts);
}

/// Inserts a pre-allocated Cell node. Does not attempt to create any row/column anchors.
fn insertCellNode(
    sheet: *Sheet,
    handle: Cell.Handle,
    undo_opts: UndoOpts,
) void {
    const point = sheet.cell_tree.getPoint(handle).*;
    const pos: Position = .init(point[0], point[1]);
    const cell_ptr = sheet.getCellFromHandle(handle);

    const old_handle = sheet.cell_tree.insertAssumeCapacity(&point, handle);

    var u: Undo = undefined;
    if (old_handle == .none) {
        log.debug("Creating cell {f}", .{pos});
        sheet.addCellAsDependentOfExprRanges(handle, cell_ptr.root());

        u = .init(.delete_cell, pos);
    } else {
        log.debug("Overwriting cell {f}", .{pos});

        const old_cell_ptr = sheet.getCellFromHandle(old_handle);
        sheet.removeCellAsDependentOfExpr(old_handle, old_cell_ptr.root(), true);
        sheet.addCellAsDependentOfExprRanges(handle, cell_ptr.root());

        sheet.setCellError(old_cell_ptr);

        u = .init(.set_cell, old_handle);
    }

    sheet.pushUndo(u, undo_opts) catch unreachable;
    sheet.enqueueUpdate(handle) catch unreachable;
    sheet.has_changes = true;
}

fn deleteCellByHandle(
    sheet: *Sheet,
    handle: Cell.Handle,
    undo_opts: UndoOpts,
) Allocator.Error!void {
    const cell = sheet.getCellFromHandle(handle);

    try sheet.ensureUnusedUndoCapacity(1);

    try sheet.enqueueUpdate(handle);
    sheet.removeCellAsDependentOfExpr(handle, cell.root(), true);

    sheet.setCellError(cell);
    _ = sheet.cell_tree.removeHandle(handle);

    sheet.pushUndo(.init(.set_cell, handle), undo_opts) catch unreachable;
    sheet.has_changes = true;
}

pub fn deleteCell(
    sheet: *Sheet,
    pos: Position,
    undo_opts: UndoOpts,
) Allocator.Error!void {
    const handle = sheet.cell_tree.findEntry(&pos.array());

    if (handle != .none)
        return sheet.deleteCellByHandle(handle, undo_opts);
}

pub fn deleteCellRange(sheet: *Sheet, r: Rect, opts: UndoOpts) Allocator.Error!void {
    const area: usize = std.math.cast(usize, r.area() +| 1) orelse
        return error.OutOfMemory;
    try sheet.ensureUnusedUndoCapacity(1);
    try sheet.cell_buffer.ensureUnusedCapacity(sheet.gpa, area);
    try sheet.ensureUnusedCellQueueCapacity(area);
    const n = sheet.deleteCellRangeAssumeCapacity(r, opts);
    // TODO: Use an index type for this
    if (n == std.math.maxInt(u32)) return;
    for (sheet.cell_buffer.items[n .. sheet.cell_buffer.items.len - 1]) |cell| {
        sheet.queued_cells.appendAssumeCapacity(.{ cell, 1 });
    }
}

pub fn getCell(sheet: *Sheet, pos: Position) ?Cell {
    return if (sheet.getCellPtr(pos)) |ptr| ptr.* else null;
}

pub fn getCellPtr(sheet: *Sheet, pos: Position) ?*Cell {
    return sheet.cell_tree.find(&pos.array());
}

pub fn getCellHandleByPos(sheet: *Sheet, pos: Position) ?Cell.Handle {
    const handle = sheet.cell_tree.findEntry(&pos.array());
    if (handle != .none) return handle;
    return null;
}

// TODO: Investigate if just looping over every cell tree and dependent tree value is faster than
//       doing a window query.
//
// This naive implementation is shockingly fast with ph trees. R-trees could never!
pub fn deleteColOrRowRange(
    sheet: *Sheet,
    start: u32,
    /// Inclusive end index
    end: u32,
    undo_opts: UndoOpts,
    comptime axis: enum { row, col },
) !void {
    assert(start <= end);
    const deleted_count = end - start + 1;

    const arena = sheet.arena.allocator();
    defer sheet.resetArena();

    // List of cells that are affected
    var cells: std.ArrayList(Cell.Handle) = .empty;
    // List of dependency ranges that need to be updated
    var deps: std.ArrayList(Dependents.Entry.Handle) = .empty;
    // List of dependency ranges whose depending cells will need to be re-calculated
    var intersecting_deps: std.ArrayList(Dependents.Entry.Handle) = .empty;
    // List of columns whose position needs to be adjusted
    var cols: std.ArrayList(Column.Handle) = .empty;

    const max = std.math.maxInt(u32);

    const tl_point: [2]u32, const br_point: [2]u32 = switch (axis) {
        .row => .{ .{ 0, start }, .{ max, start } },
        .col => .{ .{ start, 0 }, .{ start, max } },
    };

    try sheet.cell_tree.queryWindow(arena, &tl_point, &.{ max, max }, &cells);
    try sheet.dependents.queryWindowRect(arena, tl_point, .{ max, max }, &deps);
    try sheet.dependents.queryWindowRect(arena, tl_point, br_point, &intersecting_deps);
    if (axis == .col)
        try sheet.cols.queryWindow(arena, &.{start}, &.{max}, &cols);

    const index = switch (axis) {
        .col => 0,
        .row => 1,
    };

    const f = switch (axis) {
        .row => "y",
        .col => "x",
    };

    const undo_count = blk: {
        var undo_count: u32 = 1; // For sentinel

        for (cells.items) |handle| {
            const p = sheet.cell_tree.getPoint(handle).*;
            undo_count += @intFromBool(p[index] >= start and p[index] <= end);
        }

        for (deps.items) |handle| {
            assert(handle != sheet.dependents.freelist_entries_head);
            const p = sheet.dependents.getPoint(handle).*;
            const needs_resize_or_delete = !(p[index] > end or (p[index] < start and p[index + 2] > end));
            undo_count += @intFromBool(needs_resize_or_delete);
        }

        var iter = sheet.ast.nodes.reverseIterator();
        while (iter.next()) |i| switch (sheet.ast.tag(i)) {
            .rel_rel, .rel_abs, .abs_rel, .abs_abs => {
                const pos = sheet.ast.payload(i).rel_rel;
                if (@field(pos, f) >= start) undo_count += 1;
            },
            .invalidated_range => {
                iter.skip(2);
            },
            .range => {
                const rhs = i.subi(1);
                const lhs = sheet.ast.leftMostChild(rhs).subi(1);
                const tl = sheet.ast.payload(lhs).rel_rel;
                const br = sheet.ast.payload(rhs).rel_rel;
                const tl_f = @field(tl, f);
                const br_f = @field(br, f);
                const needs_resize_or_delete = !(tl_f > end or (tl_f < start and br_f > end));
                if (needs_resize_or_delete)
                    undo_count += 1;
                iter.skip(2);
            },
            else => {},
        };

        break :blk undo_count;
    };

    // Count of the number of cells who depend on a range that intersects with
    var queue_count: usize = 0;
    for (intersecting_deps.items) |handle| {
        const root = sheet.dependents.getValue(handle).*;
        var n = root;
        while (n.isValid()) : (n = sheet.deps.items[n.n].next) {
            queue_count += 1;
        }
    }

    try sheet.ensureUnusedCellQueueCapacity(queue_count + cells.items.len);
    try sheet.ensureUnusedUndoCapacity(undo_count);
    errdefer comptime unreachable;

    // Enqueue all cells who depend on a range intersecting the deletion
    for (intersecting_deps.items) |dep_handle| {
        const root = sheet.dependents.getValue(dep_handle).*;
        var n = root;
        assert(n.isValid());
        while (n.isValid()) : (n = sheet.deps.items[n.n].next) {
            const cell_handle = sheet.deps.items[n.n].handle;
            sheet.queued_cells.appendAssumeCapacity(.{ cell_handle, 1 });
            sheet.getCellFromHandle(cell_handle).expr.state = .enqueued;
        }
    }
    for (cells.items) |handle| {
        sheet.queued_cells.appendAssumeCapacity(.{ handle, 1 });
    }

    // Remove cells in the range from dependency graph
    for (cells.items) |handle| {
        const p = sheet.cell_tree.getPoint(handle);
        sheet.cell_tree.removeHandle(handle);

        if (p[index] >= start and p[index] <= end) {
            sheet.removeCellAsDependentOfExpr(
                handle,
                sheet.getCellFromHandle(handle).root(),
                false,
            );
        }
    }

    for (cells.items) |handle| {
        const p = sheet.cell_tree.getPoint(handle);
        if (p[index] >= start and p[index] <= end) {
            // TODO: batch these inserts
            sheet.pushUndoAssumeCapacity(.init(.set_cell, handle), undo_opts);
        } else {
            p[index] -= deleted_count;
            _ = sheet.cell_tree.insertAssumeCapacity(p, handle);
        }
        sheet.getCellFromHandle(handle).expr.state = .enqueued;
    }

    if (axis == .col) {
        for (cols.items) |handle| {
            const p = sheet.cols.getPoint(handle);
            assert(p[index] >= start);

            sheet.cols.removeHandle(handle);

            if (p[index] > end) {
                p[index] -= end - start + 1;
                _ = sheet.cols.insertAssumeCapacity(p, handle);
            }
        }
    }

    // Cases
    //  Deletion entirely contains range
    //   -> Needs to be deleted and restored on undo
    //  Deletion contains range start or end
    //   -> Needs to be resized and restored on undo
    //  Deletion is in the middle of the range
    //   -> Range end needs to be decremented, no undo
    //  Deletion is before range and does not intersect it
    //   -> Range start and end needs to be decremented, no undo
    for (deps.items) |handle| {
        const p = sheet.dependents.getPoint(handle);
        sheet.dependents.removeHandle(handle);
        const head = sheet.dependents.getValue(handle);
        if (!head.isValid()) {
            sheet.dependents.destroyValue(handle);
            continue;
        }

        if (p[index] >= start) {
            if (p[index + 2] <= end) {
                // Deletion entirely contains range
                sheet.pushUndoAssumeCapacity(.init(.insert_dep, handle), undo_opts);
            } else if (p[index] <= end) {
                // Deletion contains range start
                sheet.pushUndoAssumeCapacity(.init(.update_dep, .{
                    .handle = handle,
                    .point = p.*,
                }), undo_opts);
                p[index] = start;
                p[index + 2] -= deleted_count;
                _ = sheet.dependents.insertAssumeCapacity(p, handle);
            } else {
                // Deletion does not intersect with range
                // This is undone by the .insert undo
                p[index] -= deleted_count;
                p[index + 2] -= deleted_count;
                sheet.dependents.insertAssumeCapacityNoClobber(p, handle);
            }
        } else if (p[index + 2] <= end) {
            // Deletion contains range end
            // Resizes the range, so a special undo is required
            sheet.pushUndoAssumeCapacity(.init(.update_dep, .{
                .handle = handle,
                .point = p.*,
            }), undo_opts);
            p[index + 2] = start - 1;
            _ = sheet.dependents.insertAssumeCapacity(p, handle);
        } else {
            // Deletion is in the middle of the range
            // This is undone by the .insert undo
            p[index + 2] -= deleted_count;
            _ = sheet.dependents.insertAssumeCapacity(p, handle);
        }
    }

    var iter = sheet.ast.nodes.reverseIterator();
    while (iter.next()) |i| switch (sheet.ast.tag(i)) {
        .rel_rel, .abs_abs, .rel_abs, .abs_rel => {
            const pos = &sheet.ast.nodes.ptr(i, .data).rel_rel;
            const n = @field(pos, f);
            if (n >= start) {
                sheet.pushUndoAssumeCapacity(.init(.update_pos, .{
                    .node = .{ .index = i, .tag = sheet.ast.tag(i) },
                    .pos = pos.*,
                }), undo_opts);

                if (n <= end) {
                    sheet.ast.nodes.ptr(i, .tag).* = .invalidated_pos;
                } else {
                    @field(pos, f) -= deleted_count;
                }
            }
        },
        .invalidated_range => {
            iter.skip(2);
        },
        .range => {
            const rhs = i.subi(1);
            const lhs = sheet.ast.leftMostChild(rhs).subi(1);
            const tl = &sheet.ast.nodes.ptr(lhs, .data).rel_rel;
            const br = &sheet.ast.nodes.ptr(rhs, .data).rel_rel;
            const u: Undo = .init(.update_range, .{
                .ast_node = .{ .index = i },
                .range = .{ .tl = tl.*, .br = br.* },
            });

            const tl_f = &@field(tl, f);
            const br_f = &@field(br, f);
            if (tl_f.* >= start) {
                if (br_f.* <= end) {
                    sheet.pushUndoAssumeCapacity(u, undo_opts);
                    // Lies entirely in the deleted range
                    sheet.ast.nodes.ptr(i, .tag).* = .invalidated_range;
                } else if (tl_f.* <= end) {
                    sheet.pushUndoAssumeCapacity(u, undo_opts);
                    tl_f.* = start;
                    br_f.* -= deleted_count;
                } else {
                    tl_f.* -= deleted_count;
                    br_f.* -= deleted_count;
                }
            } else if (br_f.* >= start) {
                if (br_f.* <= end) {
                    sheet.pushUndoAssumeCapacity(u, undo_opts);
                    br_f.* = start - 1;
                } else {
                    br_f.* -= end - start + 1;
                }
            }

            iter.skip(2);
        },
        else => {},
    };

    const undo_tag: Undo.Tag = switch (axis) {
        .row => .insert_rows,
        .col => .insert_columns,
    };

    sheet.pushUndoAssumeCapacity(.init(undo_tag, .{
        .start = start,
        .len = deleted_count,
    }), undo_opts);
}

pub fn insertColsOrRows(
    sheet: *Sheet,
    index: u32,
    n: u32,
    undo_opts: UndoOpts,
    comptime axis: enum { col, row },
) !void {
    assert(n > 0);

    const dim = switch (axis) {
        .col => 0,
        .row => 1,
    };

    // Check if columns would overflow
    const largest = sheet.cell_tree.largestDim(dim);
    if (largest != .none) {
        const p = sheet.cell_tree.getPoint(largest).*[dim];
        if (std.math.maxInt(u32) - p < n)
            return error.Overflow;
    }

    const arena = sheet.arena.allocator();
    defer sheet.resetArena();

    var cells: std.ArrayList(Cell.Handle) = .empty;
    var deps: std.ArrayList(Dependents.Entry.Handle) = .empty;
    var cols: std.ArrayList(Column.Handle) = .empty;

    const f = switch (axis) {
        .col => "x",
        .row => "y",
    };

    const undo_count = blk: {
        var undo_count: u32 = 1;
        const nodes = &sheet.ast.nodes;
        var iter = nodes.reverseIterator();
        while (iter.next()) |i| switch (sheet.ast.tag(i)) {
            .rel_rel, .rel_abs, .abs_rel, .abs_abs => {
                const pos = sheet.ast.payload(i).rel_rel;
                const pos_f = @field(pos, f);
                if (pos_f >= index) undo_count += 1;
            },
            .invalidated_range => iter.skip(2),
            .range => {
                const rhs = i.subi(1);
                const lhs = sheet.ast.leftMostChild(rhs).subi(1);
                const tl = sheet.ast.payload(lhs).rel_rel;
                const br = sheet.ast.payload(rhs).rel_rel;
                const tl_f = @field(tl, f);
                const br_f = @field(br, f);
                if (tl_f >= index or br_f >= index)
                    undo_count += 1;
                iter.skip(2);
            },
            else => {},
        };

        break :blk undo_count;
    };

    try sheet.ensureUnusedUndoCapacity(undo_count);
    if (axis == .col)
        try sheet.cols.ensureUnusedCapacity(sheet.gpa, n);

    const max = std.math.maxInt(u32);

    const top_left: [2]u32 = switch (axis) {
        .col => .{ index, 0 },
        .row => .{ 0, index },
    };

    try sheet.cell_tree.queryWindow(arena, &top_left, &.{ max, max }, &cells);
    try sheet.dependents.queryWindowRect(arena, top_left, .{ max, max }, &deps);
    if (axis == .col)
        try sheet.cols.queryWindow(arena, &.{index}, &.{max}, &cols);
    errdefer comptime unreachable;

    // Create new columns
    if (axis == .col) {
        // Remove affected cols
        for (cols.items) |handle| {
            sheet.cols.removeHandle(handle);
        }

        // Reinsert affected cols with adjusted positions
        for (cols.items) |handle| {
            const p = sheet.cols.getPoint(handle);
            assert(p[0] >= index);
            p[0] += n;
            _ = sheet.cols.insertAssumeCapacity(p, handle);
        }
    }

    // Remove affected cells
    for (cells.items) |handle| {
        const p = sheet.cell_tree.getPoint(handle);
        assert(p[dim] >= index);
        sheet.cell_tree.removeHandle(handle);
    }

    // Re-insert affected cells with adjusted positions
    for (cells.items) |handle| {
        const p = sheet.cell_tree.getPoint(handle);
        p[dim] += n;
        sheet.cell_tree.insertAssumeCapacityNoClobber(p, handle);
    }

    // Remove affected dependency ranges
    for (deps.items) |handle| {
        const p = sheet.dependents.getPoint(handle);
        assert(p[dim] >= p[dim]);
        sheet.dependents.removeHandle(handle);
    }

    // Re-insert affected dependency ranges with adjustments
    for (deps.items) |handle| {
        const p = sheet.dependents.getPoint(handle);
        if (p[dim] >= index) {
            p[dim] += n;
            p[dim + 2] += n;
            _ = sheet.dependents.insertAssumeCapacity(p, handle);
        } else {
            assert(p[dim + 2] >= index);
            p[dim + 2] += n;
            _ = sheet.dependents.insertAssumeCapacity(p, handle);
        }
    }

    // TODO: Could we store these in a ph-tree, and AST pos nodes store a handle into that tree.
    //       This would allow looking up all affected nodes in the AST easier. But is it even
    //       needed?
    // Adjust all affected position/range references in cell expressions
    const nodes = sheet.ast.nodes;
    var iter = nodes.reverseIterator();
    while (iter.next()) |i| switch (sheet.ast.tag(i)) {
        .rel_rel, .rel_abs, .abs_rel, .abs_abs => {
            const pos = &nodes.ptr(i, .data).rel_rel;
            if (@field(pos, f) >= index) {
                sheet.pushUndoAssumeCapacity(.init(.update_pos, .{
                    .node = .{ .index = i, .tag = sheet.ast.tag(i) },
                    .pos = pos.*,
                }), undo_opts);
                @field(pos, f) += n;
            }
        },
        .invalidated_range => iter.skip(2),
        .range => {
            const rhs = i.subi(1);
            const lhs = sheet.ast.leftMostChild(rhs).subi(1);
            const tl = &nodes.ptr(lhs, .data).rel_rel;
            const br = &nodes.ptr(rhs, .data).rel_rel;
            assert(tl.x <= br.x);
            assert(tl.y <= br.y);

            const u: Undo = .init(.update_range, .{
                .ast_node = .{ .index = i },
                .range = .{ .tl = tl.*, .br = br.* },
            });

            if (@field(tl, f) >= index) {
                sheet.pushUndoAssumeCapacity(u, undo_opts);
                @field(tl, f) += n;
                @field(br, f) += n;
            } else if (@field(br, f) >= index) {
                sheet.pushUndoAssumeCapacity(u, undo_opts);
                @field(br, f) += n;
            }

            iter.skip(2);
        },
        else => {},
    };

    const undo_tag: Undo.Tag = switch (axis) {
        .col => .delete_columns,
        .row => .delete_rows,
    };

    sheet.pushUndoAssumeCapacity(.init(undo_tag, .{
        .start = index,
        .end = index + n - 1,
    }), undo_opts);
}

pub fn insertColumns(sheet: *Sheet, index: u32, n: u32, undo_opts: UndoOpts) !void {
    return sheet.insertColsOrRows(index, n, undo_opts, .col);
}

pub fn insertRows(sheet: *Sheet, index: u32, n: u32, undo_opts: UndoOpts) !void {
    return sheet.insertColsOrRows(index, n, undo_opts, .row);
}

pub fn evaluate(sheet: *Sheet, root_node: Ast.Node.Index) !Ast.Value {
    var interp: Ast.Interpreter = .{
        .arena = sheet.arena.allocator(),
        .sheet = sheet,
    };
    defer sheet.resetArena();

    _ = try interp.evaluate(sheet.ast.leftMostChild(root_node));
    const res = try interp.pop(.any);

    if (res == .string)
        return .{ .string = .{ .slice = try sheet.gpa.dupe(u8, res.string.bytes()) } };

    return res;
}

pub fn update(sheet: *Sheet) Allocator.Error!void {
    if (!sheet.needsUpdate()) return;

    // log.debug("Updating cells...", .{});
    var timer = if (builtin.mode == .Debug)
        std.time.Timer.start() catch unreachable
    else {};

    defer sheet.queued_cells.clearRetainingCapacity();

    // log.debug("Marking dirty cells", .{});

    var dirty_cells: std.ArrayList(Cell.Handle) = .empty;
    const arena = sheet.arena.allocator();
    defer sheet.resetArena();

    for (sheet.queued_cells.items) |data| {
        const cell_start, const len = data;
        const cells = sheet.cell_tree.slice(cell_start.int(), len);
        for (0..cells.len) |i| {
            try sheet.markDirty(arena, cells.handle(i), &dirty_cells);
        }
    }

    for (sheet.volatile_cells.items) |data| {
        const cell_start, const len = data;
        const cells = sheet.cell_tree.slice(cell_start.int(), len);
        for (0..cells.len) |i| {
            try sheet.markDirty(arena, cells.handle(i), &dirty_cells);
            sheet.getCellFromHandle(cells.handle(i)).expr.state = .@"volatile";
        }
    }

    while (dirty_cells.pop()) |cell| {
        try sheet.markDirty(arena, cell, &dirty_cells);
    }

    var eval: Ast.Interpreter = .{
        .arena = arena,
        .sheet = sheet,
    };

    for (sheet.volatile_cells.items) |data| {
        const handle_start, const len = data;
        const cells = sheet.cell_tree.slice(handle_start.int(), len);
        for (0..cells.len) |i| {
            _ = sheet.evalCellByHandle(&eval, cells.handle(i)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.CyclicalReference => {
                    // const point = sheet.cell_tree.getPoint(handle).*;
                    // log.info("Cyclical reference encountered while evaluating {}", .{
                    //     Position.init(point[0], point[1]),
                    // });
                },
                else => {},
            };
        }
    }

    while (sheet.queued_cells.pop()) |data| {
        const handle_start, const len = data;
        const cells = sheet.cell_tree.slice(handle_start.int(), len);
        for (0..cells.len) |i| {
            _ = sheet.evalCellByHandle(&eval, cells.handle(i)) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.CyclicalReference => {
                    // const point = sheet.cell_tree.getPoint(handle).*;
                    // log.info("Cyclical reference encountered while evaluating {}", .{
                    //     Position.init(point[0], point[1]),
                    // });
                },
                else => {},
            };
        }
    }

    if (builtin.mode == .Debug) {
        log.debug("Finished cell update in {d} ms", .{
            @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_ms,
        });
    }

    sheet.needs_update = false;
}

pub fn enqueueUpdate(
    sheet: *Sheet,
    handle: Cell.Handle,
) Allocator.Error!void {
    try sheet.queued_cells.append(sheet.gpa, .{ handle, 1 });
    sheet.getCellFromHandle(handle).expr.state = .enqueued;
}

/// Marks all of the dependents of `pos` as dirty. Any children that also need to be marked dirty
/// are appended to `dirty_cells`. This was previously done recursively which resulted in a stack
/// overflow on large sheets.
fn markDirty(
    sheet: *Sheet,
    gpa: std.mem.Allocator,
    handle: Cell.Handle,
    dirty_cells: *std.ArrayList(Cell.Handle),
) Allocator.Error!void {
    sheet.search_buffer.clearRetainingCapacity();

    const list = &sheet.search_buffer;
    const pos = sheet.posFromCellHandle(handle);
    try sheet.dependents.queryWindowRect(
        sheet.gpa,
        pos.array(),
        pos.array(),
        list,
    );

    for (list.items) |dependent_handle| {
        const head = sheet.dependents.getValue(dependent_handle).*;
        var index = head;
        while (index.isValid()) : (index = sheet.deps.items[index.n].next) {
            const h = sheet.deps.items[index.n].handle;
            const c = sheet.getCellFromHandle(h);
            if (c.expr.state != .dirty) {
                c.expr.state = .dirty;
                try dirty_cells.append(gpa, h);
            }
        }
    }
}

// TODO: This is dumb
pub fn getFilePath(sheet: *const Sheet) []const u8 {
    return sheet.filepath.items;
}

/// Returns the name of the sheet.
/// Currently this is the basename of the filepath, with the extension
/// stripped.
pub fn getName(sheet: *const Sheet) []const u8 {
    return std.fs.path.stem(sheet.getFilePath());
}

pub fn setFilePath(sheet: *Sheet, filepath: []const u8) void {
    sheet.filepath.clearRetainingCapacity();
    sheet.filepath.appendSliceAssumeCapacity(filepath);
}

pub fn cellStringValue(sheet: *const Sheet, cell: *const Cell) []const u8 {
    assert(cell.expr.value_tag == .string);
    return sheet.string_values.items(cell.value.string);
}

pub fn freeCellString(sheet: *Sheet, cell: *Cell) void {
    assert(cell.expr.value_tag == .string);
    sheet.string_values.destroyList(cell.value.string);
}

pub fn setCellError(sheet: *Sheet, cell: *Cell) void {
    if (cell.root() == .none) return;
    if (cell.expr.value_tag == .string)
        sheet.string_values.destroyList(cell.value.string);

    cell.setValue(.err, .fromError(error.NotEvaluable));
}

/// Queues the dependents of `ref` for update.
fn queueDependents(sheet: *Sheet, rect: Rect) Allocator.Error!void {
    sheet.search_buffer.clearRetainingCapacity();

    const list = &sheet.search_buffer;
    try sheet.dependents.queryWindowRect(
        sheet.gpa,
        rect.tl.array(),
        rect.br.array(),
        list,
    );

    for (list.items) |dependent_handle| {
        const head = sheet.dependents.getValue(dependent_handle).*;
        var index = head;
        while (index.isValid()) : (index = sheet.deps.items[index.n].next) {
            const handle = sheet.deps.items[index.n].handle;
            const cell = sheet.getCellFromHandle(handle);
            if (cell.expr.state == .dirty) {
                cell.expr.state = .enqueued;
                try sheet.queued_cells.append(sheet.gpa, .{ handle, 1 });
            }
        }
    }
}

pub fn evalCellByHandle(
    sheet: *Sheet,
    eval: *Ast.Interpreter,
    handle: Cell.Handle,
) Ast.EvalError!Ast.Value {
    const cell = sheet.getCellFromHandle(handle);
    sw: switch (cell.expr.state) {
        .up_to_date => {},
        .computing => return error.CyclicalReference,
        .enqueued, .dirty, .@"volatile" => {
            const root = cell.root().unwrap() orelse {
                cell.expr.state = .up_to_date;
                break :sw;
            };
            cell.expr.state = .computing;

            const pos = sheet.posFromCellHandle(handle);
            log.debug("eval {f}", .{pos});
            // Queue dependents before evaluating to ensure that errors are propagated to
            // dependents.
            try sheet.queueDependents(sheet.rectFromCellHandle(handle));

            const start = sheet.ast.leftMostChild(root);
            const old_volatility = eval.is_volatile;
            defer eval.is_volatile = old_volatility;
            eval.is_volatile = false;

            const res = eval.evaluate(start) catch |err| {
                cell.setValue(.err, .fromError(err));

                if (eval.is_volatile) {
                    cell.expr.is_volatile = true;
                    if (!cell.expr.stored_volatile) {
                        std.log.debug("Volatile cell {any}", .{handle});
                        try sheet.volatile_cells.append(sheet.gpa, .{ handle, 1 });
                        cell.expr.stored_volatile = true;
                    }
                }

                return err;
            };

            if (res.is_volatile) {
                cell.expr.is_volatile = true;
                if (!cell.expr.stored_volatile) {
                    std.log.debug("Volatile cell {any}", .{handle});
                    try sheet.volatile_cells.append(sheet.gpa, .{ handle, 1 });
                    cell.expr.stored_volatile = true;
                }
            }

            if (cell.expr.value_tag == .string)
                sheet.string_values.destroyList(cell.value.string);

            const value = eval.pop(.any) catch |err| {
                cell.setValue(.err, .fromError(err));
                return err;
            };

            switch (value) {
                .none => cell.setValue(.number, 0),
                .number => |n| cell.setValue(.number, n),
                .string => |str| {
                    const bytes = str.bytes();
                    const list = try sheet.string_values.createList(sheet.gpa);
                    errdefer sheet.string_values.destroyList(list);
                    try sheet.string_values.ensureUnusedCapacity(sheet.gpa, list, @intCast(bytes.len));

                    sheet.string_values.appendSliceAssumeCapacity(list, bytes);
                    cell.setValue(.string, list);
                },
                .cell, .indirect_cell => |p| {
                    cell.setValue(.ref_cell, p);
                    cell.expr.state = .up_to_date;
                    return .{ .indirect_cell = p };
                },
                .range, .indirect_range => |range| {
                    cell.setValue(.ref_range, try sheet.pushCellValueRange(range.rect));
                    cell.expr.state = .up_to_date;
                    return .{ .indirect_range = range };
                },
                .function => |f| {
                    if (f.captures.len > 0) {
                        const index = sheet.closures.items.len;
                        try sheet.closures.ensureUnusedCapacity(sheet.gpa, 1 + f.captures.len);
                        sheet.closures.appendAssumeCapacity(.{ .function = .{ .root = f.root } });
                        sheet.closures.appendSliceAssumeCapacity(f.captures);
                        cell.setValue(.closure, .{
                            .len = @intCast(f.captures.len),
                            .index = @intCast(index),
                        });
                    } else {
                        cell.setValue(.simple_function, .{ .index = f.root });
                    }
                },
            }

            cell.expr.state = .up_to_date;
            return value;
        },
    }

    return switch (cell.expr.value_tag) {
        .number => .{ .number = cell.value.number },
        .string => .{
            .string = .{
                .cell = .{
                    .sheet = sheet,
                    .list_index = cell.value.string,
                },
            },
        },
        .err => cell.value.err.getError(),
        .ref_cell => .{ .indirect_cell = cell.value.ref_cell },
        .ref_range => .{ .indirect_range = .{ .rect = sheet.cellValueRange(cell.value.ref_range).* } },
        .simple_function => .{ .function = .{ .root = cell.value.simple_function.index } },
        .closure => {
            const closure = cell.value.closure;
            const captured = sheet.closures.items[closure.index + 1 ..][0..closure.len];
            const copied = try eval.arena.dupe(Ast.Value, captured);
            const root = sheet.closures.items[closure.index].function.root;
            return .{ .function = .{ .root = root, .captures = copied } };
        },
    };
}

pub fn evalCellByPos(sheet: *Sheet, eval: *Ast.Interpreter, pos: Position) Ast.EvalError!Ast.Value {
    if (sheet.getCellHandleByPos(pos)) |cell| {
        return sheet.evalCellByHandle(eval, cell);
    }

    try sheet.queueDependents(.initSinglePos(pos));
    return .none;
}

pub fn printCellExpression(sheet: *Sheet, pos: Position, w: *std.io.Writer) !void {
    const cell = sheet.getCellPtr(pos) orelse return;
    if (cell.root() == .none) {
        try sheet.formatCell(cell, w);
        return;
    }
    if (cell.root().unwrap()) |root|
        try sheet.ast.print(root, w);
}

const FmtData = struct {
    sheet: *Sheet,
    pos: Position,
};

pub fn formatCellExpression(d: FmtData, writer: *std.io.Writer) !void {
    try d.sheet.printCellExpression(d.pos, writer);
}

pub fn fmtCellExpr(sheet: *Sheet, pos: Position) std.fmt.Alt(FmtData, formatCellExpression) {
    return .{ .data = .{ .pos = pos, .sheet = sheet } };
}

fn setRowOrColumn(
    sheet: *Sheet,
    comptime T: type,
    comptime Tree: type,
    tree: *Tree,
    value: anytype,
) !*T {
    var entry = tree.getEntryFor(value);
    if (entry.node) |node| {
        node.key = value;
    } else {
        const new_node = try sheet.arenaCreate(Tree.Node);
        entry.set(new_node);
    }
    return &entry.node.?.key;
}

pub fn createColumnAssumeCapacity(sheet: *Sheet, index: PosInt) Column.Handle {
    const res = sheet.cols.getOrPutAssumeCapacity(&.{index});
    if (!res.found_existing) {
        log.debug("Created column {}", .{index});
        res.value_ptr.* = .{};
    }
    return res.handle;
}

pub fn getColumn(sheet: *Sheet, index: PosInt) ?Column {
    if (sheet.cols.find(&.{index})) |value_ptr|
        return value_ptr.*;
    return null;
}

pub inline fn getColumnByHandleOrDefault(sheet: *Sheet, handle: Column.Handle) Column {
    return if (handle != .none) sheet.cols.getValue(handle).* else .{};
}

pub inline fn getTextAttrs(sheet: *Sheet, handle: TextAttrs.Handle) TextAttrs {
    return if (handle != .none) sheet.text_attrs.getValue(handle).* else .default;
}

pub fn getColumnHandle(sheet: *Sheet, index: PosInt) ?Column.Handle {
    const handle = sheet.cols.findEntry(&.{index});
    return if (handle != .none) handle else null;
}

fn roundUp(a: anytype, multiple: anytype) @TypeOf(a) {
    return ((a + (multiple - 1)) / multiple) * multiple;
}

pub fn copyRangeTo(sheet: *Sheet, src: Rect, dest: Rect, comptime adjust: Adjust) !void {
    assert(!Rect.eql(src, dest));
    defer sheet.resetArena();
    const arena = sheet.arena.allocator();

    const width_add: u32 = @intCast(roundUp(dest.width2(), src.width2()) - 1);
    const height_add: u32 = @intCast(roundUp(dest.height2(), src.height2()) - 1);
    const real_dest: Rect = .init(
        dest.tl.x,
        dest.tl.y,
        dest.tl.x +| width_add,
        dest.tl.y +| height_add,
    );
    const tile_x = std.math.divCeil(u64, real_dest.width2(), src.width2()) catch unreachable;
    const tile_y = std.math.divCeil(u64, real_dest.height2(), src.height2()) catch unreachable;
    const tile_count = tile_x * tile_y;

    var cells: std.ArrayList(Cell.Handle) = .empty;
    try cells.ensureTotalCapacity(arena, 128);
    try sheet.cell_tree.queryWindow(arena, &src.tl.array(), &src.br.array(), &cells);

    if (cells.items.len == 0) return;

    const cell_count = std.math.cast(usize, cells.items.len * tile_count + 1) orelse
        return error.OutOfMemory;

    try sheet.ensureUnusedUndoCapacity(2);
    try sheet.cell_buffer.ensureUnusedCapacity(sheet.gpa, cell_count);

    var total_asts_len: usize = 0;
    var total_deps: usize = 0;
    for (cells.items) |cell| { // TODO: This kinda sucks
        const root = sheet.getCellFromHandle(cell).root().unwrap() orelse continue;

        const count = sheet.ast.countDependencies(root.toOptional());
        const left = sheet.ast.leftMostChild(root);
        total_asts_len += @intFromEnum(root.sub(left)) + 2;
        total_deps += tile_count * count;
    }

    try sheet.ensureUnusedCellCapacity(cell_count - 1);
    try sheet.deps.ensureUnusedCapacity(sheet.gpa, total_deps);
    try sheet.ensureUnusedCellQueueCapacity(cell_count - 1);
    if (adjust == .adjust) {
        try sheet.dependents.ensureUnusedCapacity(sheet.gpa, cell_count - 1);
        try sheet.ensureUnusedAstNodeCapacity(@intCast(total_asts_len * tile_count));
    }
    errdefer comptime unreachable;

    const new_cells = sheet.createCellCopiesContiguous(
        cells.items,
        src,
        dest.tl,
        tile_x,
        tile_y,
        adjust,
    );

    _ = sheet.deleteCellRangeAssumeCapacity(real_dest, .{});
    sheet.bulkInsertCellHandlesContiguous(
        new_cells.offset,
        new_cells.end(),
    );
    sheet.pushUndo(.init(.bulk_cell_delete_contiguous, .{
        .start = new_cells.offset,
        .end = new_cells.end(),
    }), .{}) catch unreachable;
}

pub const Adjust = enum { adjust, no_adjust };

/// Copies all the cells in `cell_handles`, returning a slice of the created cells. The cells are
/// not inserted into the tree.
///
/// The point of each cell is set to src + (dest - origin).
fn createCellCopiesContiguous(
    sheet: *Sheet,
    cell_handles: []const Cell.Handle,
    origin: Rect,
    dest: Position,
    tile_x: u64,
    tile_y: u64,
    comptime adjust: Adjust,
) Cell.Slice {
    const x_diff, const y_diff = dest.diff(origin.tl);
    assert(x_diff != 0 or y_diff != 0);
    const height = origin.height2();
    const width = origin.width2();

    var slice = sheet.cell_tree.endSlice(0);

    for (cell_handles) |src_handle| {
        const src_point = sheet.cell_tree.getPoint(src_handle);
        const src_pos: Position = .init(src_point[0], src_point[1]);

        const diffed_x, var ox = @addWithOverflow(src_pos.x, x_diff);
        const diffed_y, var oy = @addWithOverflow(src_pos.y, y_diff);
        if (ox == 1 or oy == 1) {
            @branchHint(.unlikely);
            continue;
        }
        const new_x: u32 = @intCast(diffed_x);
        const new_y: u32 = @intCast(diffed_y);

        const src_cell = sheet.getCellFromHandle(src_handle).*;
        if (src_cell.root() == .none) {
            var i: u64 = 0;
            while (i < tile_x * tile_y) : (i += 1) {
                const x: u32 = @intCast(i % tile_x);
                const y: u32 = @intCast(i / tile_x);

                const max = std.math.maxInt(u32);
                if (x * width > max or y * height > max) {
                    @branchHint(.unlikely);
                    continue;
                }

                const wadd: u32 = @intCast(x * width);
                const hadd: u32 = @intCast(y * height);
                const tiled_x, ox = @addWithOverflow(new_x, wadd);
                const tiled_y, oy = @addWithOverflow(new_y, hadd);
                if (ox == 1 or oy == 1) {
                    @branchHint(.unlikely);
                    continue;
                }

                const tiled_diff_x, ox = @addWithOverflow(x_diff, wadd);
                const tiled_diff_y, oy = @addWithOverflow(y_diff, hadd);
                _ = tiled_diff_x;
                _ = tiled_diff_y;
                if (ox == 1 or oy == 1) {
                    @branchHint(.unlikely);
                    continue;
                }

                switch (src_cell.expr.value_tag) {
                    .number, .string, .err => {},
                    .ref_cell, .ref_range, .simple_function, .closure => unreachable,
                }

                slice.append(.{
                    .point = .{ @intCast(tiled_x), @intCast(tiled_y) },
                    .parent = .none,
                    .value = src_cell,
                });
            }

            continue;
        }

        // TODO: Handle none index
        const orig_asts = sheet.ast.exprSliceEnd(src_cell.root().unwrap().?);

        var i: u64 = 0;
        while (i < tile_x * tile_y) : (i += 1) {
            const x: u32 = @intCast(i % tile_x);
            const y: u32 = @intCast(i / tile_x);

            const max = std.math.maxInt(u32);
            if (x * width > max or y * height > max) {
                @branchHint(.unlikely);
                continue;
            }

            const wadd: u32 = @intCast(x * width);
            const hadd: u32 = @intCast(y * height);
            const tiled_x, ox = @addWithOverflow(new_x, wadd);
            const tiled_y, oy = @addWithOverflow(new_y, hadd);
            if (ox == 1 or oy == 1) {
                @branchHint(.unlikely);
                continue;
            }

            const tiled_diff_x, ox = @addWithOverflow(x_diff, wadd);
            const tiled_diff_y, oy = @addWithOverflow(y_diff, hadd);
            if (ox == 1 or oy == 1) {
                @branchHint(.unlikely);
                continue;
            }

            if (adjust == .adjust) {
                const new_asts = sheet.ast.nodes.appendManyAssumeCapacity(orig_asts.len());

                for (
                    orig_asts.items(.tag),
                    orig_asts.items(.data),
                    new_asts.items(.tag),
                    new_asts.items(.data),
                ) |src_tag, src_data, *dest_tag, *dest_data| {
                    dest_tag.* = src_tag;
                    dest_data.* = src_data;
                    switch (src_tag) {
                        .rel_rel => {
                            const added_x, ox = @addWithOverflow(dest_data.rel_rel.x, tiled_diff_x);
                            const added_y, oy = @addWithOverflow(dest_data.rel_rel.y, tiled_diff_y);
                            if (ox == 1 or oy == 1 or added_x < 0 or added_y < 0) {
                                @branchHint(.unlikely);
                                dest_tag.* = .invalidated_pos;
                                continue;
                            }

                            dest_data.rel_rel.x = @intCast(added_x);
                            dest_data.rel_rel.y = @intCast(added_y);
                        },
                        .abs_abs => {},
                        .rel_abs => {
                            const added_x, ox = @addWithOverflow(dest_data.rel_rel.x, tiled_diff_x);
                            if (ox == 1 or added_x < 0) {
                                @branchHint(.unlikely);
                                dest_tag.* = .invalidated_pos;
                                continue;
                            }

                            dest_data.rel_rel.x = @intCast(added_x);
                        },
                        .abs_rel => {
                            const added_y, oy = @addWithOverflow(dest_data.rel_rel.y, tiled_diff_y);
                            if (oy == 1 or added_y < 0) {
                                @branchHint(.unlikely);
                                dest_tag.* = .invalidated_pos;
                                continue;
                            }

                            dest_data.rel_rel.y = @intCast(added_y);
                        },
                        else => {},
                    }
                }
            }

            const expr_root: Ast.Node.OptionalIndex = switch (adjust) {
                .adjust => @enumFromInt(sheet.ast.nodes.len() - 2),
                .no_adjust => src_cell.root(),
            };

            slice.append(.{
                .point = .{ @intCast(tiled_x), @intCast(tiled_y) },
                .parent = .none,
                .value = .{
                    .expr = .{
                        .index = expr_root,
                        .is_volatile = src_cell.expr.is_volatile,
                        .state = .enqueued,
                    },
                },
            });
        }
    }

    sheet.cell_tree.commitSlice(&slice);
    return slice;
}

pub fn parseFromExpression(
    sheet: *Sheet,
    src: []const u8,
) !Parser.Result {
    return sheet.ast.parseFromExpression(sheet.gpa, src, .{});
}

pub fn parseFromExpressionDiag(
    sheet: *Sheet,
    src: []const u8,
    diagnostics: ?*Parser.Diagnostics,
) !Parser.Result {
    return sheet.ast.parseFromExpression(sheet.gpa, src, .{ .diagnostics = diagnostics });
}

test "Sheet basics" {
    const t = std.testing;

    var sheet = try Sheet.init(t.allocator);
    defer sheet.deinit();

    const exprs: []const []const u8 = &.{ "50 + 5", "500 * 2 / 34 + 1", "a0", "a2 * a1" };

    for (exprs, 0..) |src, i| {
        const expr = try sheet.parseFromExpression(src);
        try sheet.setCell(.{ .x = 0, .y = @intCast(i) }, expr, .{});
    }

    try sheet.deleteCell(.init(0, 0), .{});
}

test "setCell allocations" {
    const t = std.testing;
    const Test = struct {
        fn testSetCellAllocs(a: Allocator) !void {
            var sheet = try Sheet.init(a);
            defer sheet.deinit();

            {
                const src = "a4 * a1 * a3";
                const expr = try sheet.parseFromExpression(src);
                try sheet.setCell(.{ .x = 0, .y = 0 }, expr, .{});
            }

            {
                const src = "a2 * a1 * a3";
                const expr = try sheet.parseFromExpression(src);
                try sheet.setCell(.{ .x = 1, .y = 0 }, expr, .{});
            }

            try sheet.deleteCell(.{ .x = 0, .y = 0 }, .{});

            try sheet.update();
        }
    };

    try t.checkAllAllocationFailures(t.allocator, Test.testSetCellAllocs, .{});
}

test "Update values" {
    const t = std.testing;
    var sheet = try Sheet.init(t.allocator);
    defer sheet.deinit();

    try sheet.setCell(
        try Position.fromAddress("C0"),
        try sheet.parseFromExpression("@sum(A0:B0)"),
        .{},
    );

    inline for (0..4) |i| {
        const str = std.fmt.comptimePrint("{d}", .{i});
        try sheet.setCell(
            try Position.fromAddress("A0"),
            try sheet.parseFromExpression(str),
            .{},
        );
        try sheet.setCell(
            try Position.fromAddress("B0"),
            try sheet.parseFromExpression("A0"),
            .{},
        );
        try sheet.update();
    }
    try sheet.update();
    const cell = sheet.getCellPtr(try Position.fromAddress("C0")).?;
    try t.expectEqual(6.0, cell.value.number);
}

fn testCellEvaluation(a: Allocator) !void {
    const t = std.testing;
    var sheet = try Sheet.init(a);
    defer sheet.deinit();

    // Set cell values in random order
    const set_cells =
        \\let B17 = A17+B16
        \\let G8 = G7+F8
        \\let A9 = A8+1
        \\let G11 = G10+F11
        \\let E16 = E15+D16
        \\let G10 = G9+F10
        \\let D2 = D1+C2
        \\let F2 = F1+E2
        \\let B18 = A18+B17
        \\let D15 = D14+C15
        \\let D20 = D19+C20
        \\let E13 = E12+D13
        \\let C12 = C11+B12
        \\let A16 = A15+1
        \\let A10 = A9+1
        \\let C19 = C18+B19
        \\let F0 = E0+1
        \\let B4 = A4+B3
        \\let C11 = C10+B11
        \\let B6 = A6+B5
        \\let G5 = G4+F5
        \\let A18 = A17+1
        \\let D1 = D0+C1
        \\let G12 = G11+F12
        \\let B5 = A5+B4
        \\let D4 = D3+C4
        \\let A5 = A4+1
        \\let A0 = 1
        \\let D13 = D12+C13
        \\let A15 = A14+1
        \\let A20 = A19+1
        \\let G19 = G18+F19
        \\let G13 = G12+F13
        \\let G17 = G16+F17
        \\let C14 = C13+B14
        \\let B8 = A8+B7
        \\let D10 = D9+C10
        \\let F19 = F18+E19
        \\let B11 = A11+B10
        \\let F9 = F8+E9
        \\let G7 = G6+F7
        \\let C10 = C9+B10
        \\let C2 = C1+B2
        \\let D0 = C0+1
        \\let C18 = C17+B18
        \\let D6 = D5+C6
        \\let C0 = B0+1
        \\let B14 = A14+B13
        \\let B19 = A19+B18
        \\let G16 = G15+F16
        \\let C8 = C7+B8
        \\let G4 = G3+F4
        \\let D18 = D17+C18
        \\let E17 = E16+D17
        \\let D3 = D2+C3
        \\let E20 = E19+D20
        \\let C6 = C5+B6
        \\let E2 = E1+D2
        \\let C1 = C0+B1
        \\let D17 = D16+C17
        \\let C9 = C8+B9
        \\let D12 = D11+C12
        \\let F18 = F17+E18
        \\let H0 = G0+1
        \\let D8 = D7+C8
        \\let B12 = A12+B11
        \\let E19 = E18+D19
        \\let A14 = A13+1
        \\let E14 = E13+D14
        \\let F14 = F13+E14
        \\let A13 = A12+1
        \\let A19 = A18+1
        \\let A4 = A3+1
        \\let F7 = F6+E7
        \\let A7 = A6+1
        \\let E11 = E10+D11
        \\let B1 = A1+B0
        \\let A11 = A10+1
        \\let B16 = A16+B15
        \\let E12 = E11+D12
        \\let F11 = F10+E11
        \\let F1 = F0+E1
        \\let C4 = C3+B4
        \\let G20 = G19+F20
        \\let F16 = F15+E16
        \\let D5 = D4+C5
        \\let A17 = A16+1
        \\let A22 = @sum(a0:g20)
        \\let F4 = F3+E4
        \\let B9 = A9+B8
        \\let E4 = E3+D4
        \\let F13 = F12+E13
        \\let A1 = A0+1
        \\let F3 = F2+E3
        \\let F17 = F16+E17
        \\let G14 = G13+F14
        \\let D11 = D10+C11
        \\let A2 = A1+1
        \\let E9 = E8+D9
        \\let B15 = A15+B14
        \\let E18 = E17+D18
        \\let E8 = E7+D8
        \\let G18 = G17+F18
        \\let A6 = A5+1
        \\let C3 = C2+B3
        \\let B0 = A0+1
        \\let E10 = E9+D10
        \\let B7 = A7+B6
        \\let C7 = C6+B7
        \\let D9 = D8+C9
        \\let D14 = D13+C14
        \\let B20 = A20+B19
        \\let E7 = E6+D7
        \\let E0 = D0+1
        \\let A3 = A2+1
        \\let G9 = G8+F9
        \\let C17 = C16+B17
        \\let F5 = F4+E5
        \\let F6 = F5+E6
        \\let G3 = G2+F3
        \\let E5 = E4+D5
        \\let A8 = A7+1
        \\let B13 = A13+B12
        \\let B3 = A3+B2
        \\let D19 = D18+C19
        \\let B2 = A2+B1
        \\let C5 = C4+B5
        \\let G6 = G5+F6
        \\let F12 = F11+E12
        \\let E1 = E0+D1
        \\let C15 = C14+B15
        \\let A12 = A11+1
        \\let G1 = G0+F1
        \\let D16 = D15+C16
        \\let F20 = F19+E20
        \\let E6 = E5+D6
        \\let E15 = E14+D15
        \\let F8 = F7+E8
        \\let F10 = F9+E10
        \\let C16 = C15+B16
        \\let C20 = C19+B20
        \\let E3 = E2+D3
        \\let B10 = A10+B9
        \\let G2 = G1+F2
        \\let D7 = D6+C7
        \\let G15 = G14+F15
        \\let G0 = F0+1
        \\let F15 = F14+E15
        \\let C13 = C12+B13
    ;
    var reader: std.io.Reader = .fixed(set_cells);
    try sheet.interpretSource(&reader);
    try sheet.update();

    // Test that updating this takes less than 100 ms
    const begin = try std.time.Instant.now();
    try sheet.update();
    const elapsed_time = (try std.time.Instant.now()).since(begin);
    t.expect(@as(f64, @floatFromInt(elapsed_time)) / std.time.ns_per_ms < 100) catch |err| {
        std.debug.print("Got time {d}\n", .{@as(f64, @floatFromInt(elapsed_time)) / std.time.ns_per_ms});
        return err;
    };

    // Test values of cells
    const testCell = struct {
        pub fn testCell(_sheet: *Sheet, pos: []const u8, expected: f64) !void {
            const cell = _sheet.getCell(try Position.fromAddress(pos)) orelse return error.CellNotFound;
            try t.expectApproxEqRel(expected, cell.value.number, 0.001);
        }
    }.testCell;

    try testCell(&sheet, "A0", 1.00);
    try testCell(&sheet, "B0", 2.00);
    try testCell(&sheet, "C0", 3.00);
    try testCell(&sheet, "D0", 4.00);
    try testCell(&sheet, "E0", 5.00);
    try testCell(&sheet, "F0", 6.00);
    try testCell(&sheet, "G0", 7.00);
    try testCell(&sheet, "H0", 8.00);
    try testCell(&sheet, "A1", 2.00);
    try testCell(&sheet, "B1", 4.00);
    try testCell(&sheet, "C1", 7.00);
    try testCell(&sheet, "D1", 11.00);
    try testCell(&sheet, "E1", 16.00);
    try testCell(&sheet, "F1", 22.00);
    try testCell(&sheet, "G1", 29.00);
    try testCell(&sheet, "A2", 3.00);
    try testCell(&sheet, "B2", 7.00);
    try testCell(&sheet, "C2", 14.00);
    try testCell(&sheet, "D2", 25.00);
    try testCell(&sheet, "E2", 41.00);
    try testCell(&sheet, "F2", 63.00);
    try testCell(&sheet, "G2", 92.00);
    try testCell(&sheet, "A3", 4.00);
    try testCell(&sheet, "B3", 11.00);
    try testCell(&sheet, "C3", 25.00);
    try testCell(&sheet, "D3", 50.00);
    try testCell(&sheet, "E3", 91.00);
    try testCell(&sheet, "F3", 154.00);
    try testCell(&sheet, "G3", 246.00);
    try testCell(&sheet, "A4", 5.00);
    try testCell(&sheet, "B4", 16.00);
    try testCell(&sheet, "C4", 41.00);
    try testCell(&sheet, "D4", 91.00);
    try testCell(&sheet, "E4", 182.00);
    try testCell(&sheet, "F4", 336.00);
    try testCell(&sheet, "G4", 582.00);
    try testCell(&sheet, "A5", 6.00);
    try testCell(&sheet, "B5", 22.00);
    try testCell(&sheet, "C5", 63.00);
    try testCell(&sheet, "D5", 154.00);
    try testCell(&sheet, "E5", 336.00);
    try testCell(&sheet, "F5", 672.00);
    try testCell(&sheet, "G5", 1254.00);
    try testCell(&sheet, "A6", 7.00);
    try testCell(&sheet, "B6", 29.00);
    try testCell(&sheet, "C6", 92.00);
    try testCell(&sheet, "D6", 246.00);
    try testCell(&sheet, "E6", 582.00);
    try testCell(&sheet, "F6", 1254.00);
    try testCell(&sheet, "G6", 2508.00);
    try testCell(&sheet, "A7", 8.00);
    try testCell(&sheet, "B7", 37.00);
    try testCell(&sheet, "C7", 129.00);
    try testCell(&sheet, "D7", 375.00);
    try testCell(&sheet, "E7", 957.00);
    try testCell(&sheet, "F7", 2211.00);
    try testCell(&sheet, "G7", 4719.00);
    try testCell(&sheet, "A8", 9.00);
    try testCell(&sheet, "B8", 46.00);
    try testCell(&sheet, "C8", 175.00);
    try testCell(&sheet, "D8", 550.00);
    try testCell(&sheet, "E8", 1507.00);
    try testCell(&sheet, "F8", 3718.00);
    try testCell(&sheet, "G8", 8437.00);
    try testCell(&sheet, "A9", 10.00);
    try testCell(&sheet, "B9", 56.00);
    try testCell(&sheet, "C9", 231.00);
    try testCell(&sheet, "D9", 781.00);
    try testCell(&sheet, "E9", 2288.00);
    try testCell(&sheet, "F9", 6006.00);
    try testCell(&sheet, "G9", 14443.00);
    try testCell(&sheet, "A10", 11.00);
    try testCell(&sheet, "B10", 67.00);
    try testCell(&sheet, "C10", 298.00);
    try testCell(&sheet, "D10", 1079.00);
    try testCell(&sheet, "E10", 3367.00);
    try testCell(&sheet, "F10", 9373.00);
    try testCell(&sheet, "G10", 23816.00);
    try testCell(&sheet, "A11", 12.00);
    try testCell(&sheet, "B11", 79.00);
    try testCell(&sheet, "C11", 377.00);
    try testCell(&sheet, "D11", 1456.00);
    try testCell(&sheet, "E11", 4823.00);
    try testCell(&sheet, "F11", 14196.00);
    try testCell(&sheet, "G11", 38012.00);
    try testCell(&sheet, "A12", 13.00);
    try testCell(&sheet, "B12", 92.00);
    try testCell(&sheet, "C12", 469.00);
    try testCell(&sheet, "D12", 1925.00);
    try testCell(&sheet, "E12", 6748.00);
    try testCell(&sheet, "F12", 20944.00);
    try testCell(&sheet, "G12", 58956.00);
    try testCell(&sheet, "A13", 14.00);
    try testCell(&sheet, "B13", 106.00);
    try testCell(&sheet, "C13", 575.00);
    try testCell(&sheet, "D13", 2500.00);
    try testCell(&sheet, "E13", 9248.00);
    try testCell(&sheet, "F13", 30192.00);
    try testCell(&sheet, "G13", 89148.00);
    try testCell(&sheet, "A14", 15.00);
    try testCell(&sheet, "B14", 121.00);
    try testCell(&sheet, "C14", 696.00);
    try testCell(&sheet, "D14", 3196.00);
    try testCell(&sheet, "E14", 12444.00);
    try testCell(&sheet, "F14", 42636.00);
    try testCell(&sheet, "G14", 131784.00);
    try testCell(&sheet, "A15", 16.00);
    try testCell(&sheet, "B15", 137.00);
    try testCell(&sheet, "C15", 833.00);
    try testCell(&sheet, "D15", 4029.00);
    try testCell(&sheet, "E15", 16473.00);
    try testCell(&sheet, "F15", 59109.00);
    try testCell(&sheet, "G15", 190893.00);
    try testCell(&sheet, "A16", 17.00);
    try testCell(&sheet, "B16", 154.00);
    try testCell(&sheet, "C16", 987.00);
    try testCell(&sheet, "D16", 5016.00);
    try testCell(&sheet, "E16", 21489.00);
    try testCell(&sheet, "F16", 80598.00);
    try testCell(&sheet, "G16", 271491.00);
    try testCell(&sheet, "A17", 18.00);
    try testCell(&sheet, "B17", 172.00);
    try testCell(&sheet, "C17", 1159.00);
    try testCell(&sheet, "D17", 6175.00);
    try testCell(&sheet, "E17", 27664.00);
    try testCell(&sheet, "F17", 108262.00);
    try testCell(&sheet, "G17", 379753.00);
    try testCell(&sheet, "A18", 19.00);
    try testCell(&sheet, "B18", 191.00);
    try testCell(&sheet, "C18", 1350.00);
    try testCell(&sheet, "D18", 7525.00);
    try testCell(&sheet, "E18", 35189.00);
    try testCell(&sheet, "F18", 143451.00);
    try testCell(&sheet, "G18", 523204.00);
    try testCell(&sheet, "A19", 20.00);
    try testCell(&sheet, "B19", 211.00);
    try testCell(&sheet, "C19", 1561.00);
    try testCell(&sheet, "D19", 9086.00);
    try testCell(&sheet, "E19", 44275.00);
    try testCell(&sheet, "F19", 187726.00);
    try testCell(&sheet, "G19", 710930.00);
    try testCell(&sheet, "A20", 21.00);
    try testCell(&sheet, "B20", 232.00);
    try testCell(&sheet, "C20", 1793.00);
    try testCell(&sheet, "D20", 10879.00);
    try testCell(&sheet, "E20", 55154.00);
    try testCell(&sheet, "F20", 242880.00);
    try testCell(&sheet, "G20", 953810.00);
    try testCell(&sheet, "A22", 4668856.00);

    const commands =
        \\let A0 = '1'
        \\let B0 = A0 # '2'
        \\let C0 = B0 # '3'
        \\let D0 = C0 # '4'
        \\let E0 = D0 # '5'
        \\let F0 = E0 # '6'
        \\let G0 = F0 # '7'
        \\let H0 = G0 # '8'
        \\let A1 = A0 # '2'
        \\let B1 = A1 # B0
        \\let C1 = B1 # C0
        \\let D1 = C1 # D0
        \\let E1 = D1 # E0
        \\let F1 = E1 # F0
        \\let G1 = F1 # G0
        \\let A2 = A1 # '3'
        \\let B2 = A2 # B1
        \\let C2 = B2 # C1
        \\let D2 = C2 # D1
        \\let E2 = D2 # E1
        \\let F2 = E2 # F1
        \\let G2 = F2 # G1
        \\let A3 = A2 # '4'
        \\let B3 = A3 # B2
        \\let C3 = B3 # C2
        \\let D3 = C3 # D2
        \\let E3 = D3 # E2
        \\let F3 = E3 # F2
        \\let G3 = F3 # G2
        \\let A4 = A3 # '5'
        \\let B4 = A4 # B3
        \\let C4 = B4 # C3
        \\let D4 = C4 # D3
        \\let E4 = D4 # E3
        \\let F4 = E4 # F3
        \\let G4 = F4 # G3
        \\let A5 = A4 # '6'
        \\let B5 = A5 # B4
        \\let C5 = B5 # C4
        \\let D5 = C5 # D4
        \\let E5 = D5 # E4
        \\let F5 = E5 # F4
        \\let G5 = F5 # G4
        \\let A6 = A5 # '7'
        \\let B6 = A6 # B5
        \\let C6 = B6 # C5
        \\let D6 = C6 # D5
        \\let E6 = D6 # E5
        \\let F6 = E6 # F5
        \\let G6 = F6 # G5
        \\let A7 = A6 # '8'
        \\let B7 = A7 # B6
        \\let C7 = B7 # C6
        \\let D7 = C7 # D6
        \\let E7 = D7 # E6
        \\let F7 = E7 # F6
        \\let G7 = F7 # G6
        \\let A8 = A7 # '9'
        \\let B8 = A8 # B7
        \\let C8 = B8 # C7
        \\let D8 = C8 # D7
        \\let E8 = D8 # E7
        \\let F8 = E8 # F7
        \\let G8 = F8 # G7
        \\let A9 = A8 # '0'
        \\let B9 = A9 # B8
        \\let C9 = B9 # C8
        \\let D9 = C9 # D8
        \\let E9 = D9 # E8
        \\let F9 = E9 # F8
        \\let G9 = F9 # G8
        \\let A10 = A9 # '1'
        \\let B10 = A10 # B9
        \\let C10 = B10 # C9
        \\let D10 = C10 # D9
        \\let E10 = D10 # E9
        \\let F10 = E10 # F9
        \\let G10 = F10 # G9
        \\let A11 = A10 # '2'
        \\let B11 = A11 # B10
        \\let C11 = B11 # C10
        \\let D11 = C11 # D10
        \\let E11 = D11 # E10
        \\let F11 = E11 # F10
        \\let G11 = F11 # G10
        \\let A12 = A11 # '3'
        \\let B12 = A12 # B11
        \\let C12 = B12 # C11
        \\let D12 = C12 # D11
        \\let E12 = D12 # E11
        \\let F12 = E12 # F11
        \\let G12 = F12 # G11
        \\let A13 = A12 # '4'
        \\let B13 = A13 # B12
        \\let C13 = B13 # C12
        \\let D13 = C13 # D12
        \\let E13 = D13 # E12
        \\let F13 = E13 # F12
        \\let G13 = F13 # G12
        \\let A14 = A13 # '5'
        \\let B14 = A14 # B13
        \\let C14 = B14 # C13
        \\let D14 = C14 # D13
        \\let E14 = D14 # E13
        \\let F14 = E14 # F13
        \\let G14 = F14 # G13
        \\let A15 = A14 # '6'
        \\let B15 = A15 # B14
        \\let C15 = B15 # C14
        \\let D15 = C15 # D14
        \\let E15 = D15 # E14
        \\let F15 = E15 # F14
        \\let G15 = F15 # G14
        \\let A16 = A15 # '7'
        \\let B16 = A16 # B15
        \\let C16 = B16 # C15
        \\let D16 = C16 # D15
        \\let E16 = D16 # E15
        \\let F16 = E16 # F15
        \\let G16 = F16 # G15
        \\let A17 = A16 # '8'
        \\let B17 = A17 # B16
        \\let C17 = B17 # C16
        \\let D17 = C17 # D16
        \\let E17 = D17 # E16
        \\let F17 = E17 # F16
        \\let G17 = F17 # G16
        \\let A18 = A17 # '9'
        \\let B18 = A18 # B17
        \\let C18 = B18 # C17
        \\let D18 = C18 # D17
        \\let E18 = D18 # E17
        \\let F18 = E18 # F17
        \\let G18 = F18 # G17
        \\let A19 = A18 # '0'
        \\let B19 = A19 # B18
        \\let C19 = B19 # C18
        \\let D19 = C19 # D18
        \\let E19 = D19 # E18
        \\let F19 = E19 # F18
        \\let G19 = F19 # G18
        \\let A20 = A19 # '1'
        \\let B20 = A20 # B19
        \\let C20 = B20 # C19
        \\let D20 = C20 # D19
        \\let E20 = D20 # E19
        \\let F20 = E20 # F19
        \\let G20 = F20 # G19
    ;

    reader = .fixed(commands);
    sheet.clearRetainingCapacity();
    try sheet.interpretSource(&reader);
    try sheet.update();

    // Only checks the eval results of some of the cells, checking all is kinda slow
    const strings =
        \\1,12,123,1234
        \\12,1212,1212123,12121231234
        \\123,1231212,12312121212123,1231212121212312121231234
        \\1234,12341231212,1234123121212312121212123,12341231212123121212121231231212121212312121231234
        \\12345,1234512341231212,12345123412312121234123121212312121212123,1234512341231212123412312121231212121212312341231212123121212121231231212121212312121231234
        \\123456,1234561234512341231212,123456123451234123121212345123412312121234123121212312121212123,1234561234512341231212123451234123121212341231212123121212121231234512341231212123412312121231212121212312341231212123121212121231231212121212312121231234
        \\1234567,12345671234561234512341231212,12345671234561234512341231212123456123451234123121212345123412312121234123121212312121212123,123456712345612345123412312121234561234512341231212123451234123121212341231212123121212121231234561234512341231212123451234123121212341231212123121212121231234512341231212123412312121231212121212312341231212123121212121231231212121212312121231234
        \\12345678,1234567812345671234561234512341231212,123456781234567123456123451234123121212345671234561234512341231212123456123451234123121212345123412312121234123121212312121212123,123456781234567123456123451234123121212345671234561234512341231212123456123451234123121212345123412312121234123121212312121212123123456712345612345123412312121234561234512341231212123451234123121212341231212123121212121231234561234512341231212123451234123121212341231212123121212121231234512341231212123412312121231212121212312341231212123121212121231231212121212312121231234
        \\123456789,1234567891234567812345671234561234512341231212,1234567891234567812345671234561234512341231212123456781234567123456123451234123121212345671234561234512341231212123456123451234123121212345123412312121234123121212312121212123,1234567891234567812345671234561234512341231212123456781234567123456123451234123121212345671234561234512341231212123456123451234123121212345123412312121234123121212312121212123123456781234567123456123451234123121212345671234561234512341231212123456123451234123121212345123412312121234123121212312121212123123456712345612345123412312121234561234512341231212123451234123121212341231212123121212121231234561234512341231212123451234123121212341231212123121212121231234512341231212123412312121231212121212312341231212123121212121231231212121212312121231234
    ;
    var line_iter = std.mem.tokenizeScalar(u8, strings, '\n');
    var y: PosInt = 0;
    while (line_iter.next()) |line| : (y += 1) {
        var col_iter = std.mem.tokenizeScalar(u8, line, ',');
        var x: PosInt = 0;
        while (col_iter.next()) |col| : (x += 1) {
            const cell = sheet.getCell(.init(x, y)).?;
            const str = sheet.cellStringValue(&cell);
            try t.expectEqualStrings(col, str);
        }
    }
}

test "Cell assignment, updating, evaluation" {
    if (build.fast_tests) {
        return error.SkipZigTest;
    }

    try std.testing.checkAllAllocationFailures(std.testing.allocator, testCellEvaluation, .{});
}

pub fn expectCellNonExtant(sheet: *Sheet, address: []const u8) !void {
    const pos: Position = try .fromAddress(address);
    if (sheet.getCellPtr(pos) != null) {
        std.debug.print("Expected cell {f} to not exist\n", .{pos});
        return error.CellExists;
    }
}

pub fn expectRangeNonExtant(sheet: *Sheet, address: []const u8) !void {
    var iter = std.mem.tokenizeScalar(u8, address, ':');
    const tl = iter.next() orelse return error.MalformedAddress;
    const br = iter.next() orelse return error.MalformedAddress;
    const r: Rect = .initPos(
        try .fromAddress(tl),
        try .fromAddress(br),
    );

    var sfa = std.heap.stackFallback(4096, sheet.gpa);
    const a = sfa.get();

    var results: std.ArrayList(Cell.Handle) = .empty;
    defer results.deinit(a);
    try sheet.cell_tree.queryWindow(a, &r.tl.array(), &r.br.array(), &results);

    if (results.items.len != 0) {
        var buf: [4096]u8 = undefined;
        var bw = std.fs.File.stderr().writer(&buf);
        try bw.interface.print("Expected cells {f} to not exist, found", .{r});
        for (results.items) |handle| {
            const p = sheet.cell_tree.getPoint(handle).*;
            const pos: Position = .init(p[0], p[1]);
            try bw.interface.print(" {f}", .{pos});
        }
        try bw.interface.writeByte('\n');
        try bw.interface.flush();
        return error.CellExists;
    }
}

pub fn expectCellEquals(sheet: *Sheet, address: []const u8, expected_value: f64) !void {
    const pos: Position = try .fromAddress(address);
    const cell = sheet.getCellPtr(pos) orelse return error.CellNotFound;
    if (cell.expr.value_tag != .number) {
        std.debug.print(
            "Cell {f} has value type {}, expected number\n",
            .{ pos, cell.expr.value_tag },
        );
        return error.TestExpectedCellsEql;
    }
    if (!std.math.approxEqRel(f64, expected_value, cell.value.number, 0.001)) {
        std.debug.print(
            "Cell {f} ({f}) with value {d} not within tolerance of expected value {d}\n",
            .{
                pos,
                fmtCellExpr(sheet, pos),
                cell.value.number,
                expected_value,
            },
        );
        return error.TestExpectedCellsEql;
    }
}

pub fn expectCellEqualsString(sheet: *Sheet, address: []const u8, expected_value: []const u8) !void {
    const pos: Position = try .fromAddress(address);
    const cell = sheet.getCellPtr(pos) orelse {
        std.debug.print("Could not find cell '{s}'\n", .{address});
        return error.CellNotFound;
    };
    if (cell.expr.value_tag != .string) {
        std.debug.print("Cell {f} has value type {}, expected string '{s}'\n", .{
            pos, cell.expr.value_tag, expected_value,
        });
        return error.TestExpectedCellsEqlStrings;
    }
    const str = sheet.string_values.items(cell.value.string);
    if (!std.mem.eql(u8, expected_value, str)) {
        std.debug.print("Cell {f} does not have expected string value\n", .{pos});
        return std.testing.expectEqualStrings(expected_value, str);
    }
}

pub fn expectCellError(sheet: *Sheet, address: []const u8) !void {
    const pos: Position = try .fromAddress(address);
    const cell = sheet.getCellPtr(pos) orelse return error.CellNotFound;
    if (cell.expr.value_tag != .err) {
        std.debug.print("Expected cell {f} to have error, but has value type {}\n", .{
            pos, cell.expr.value_tag,
        });
        return error.UnexpectedValue;
    }
}

test "Cell error propagation" {
    var sheet = try Sheet.init(std.testing.allocator);
    defer sheet.deinit();

    try sheet.setCell(
        .fromValidAddress("A0"),
        try sheet.parseFromExpression("10"),
        .{},
    );

    try sheet.update();
    try expectCellEquals(&sheet, "A0", 10);

    try sheet.setCell(
        .fromValidAddress("B0"),
        try sheet.parseFromExpression("A0"),
        .{},
    );

    try sheet.update();
    try expectCellEquals(&sheet, "B0", 10);

    try sheet.setCell(
        .fromValidAddress("A0"),
        try sheet.parseFromExpression("A0"),
        .{},
    );

    try sheet.update();
    try expectCellError(&sheet, "A0");
    try expectCellError(&sheet, "B0");
}

test "Overwrite with string" {
    const t = std.testing;
    var sheet = try Sheet.init(t.allocator);
    defer sheet.deinit();

    inline for (.{
        .{ "A0", "'one'" },
        .{ "A0", "'two'" },
    }) |data| {
        const address, const source = data;
        try sheet.setCell(
            .fromValidAddress(address),
            try sheet.parseFromExpression(source),
            .{},
        );

        try sheet.update();
        sheet.endUndoGroup();
    }

    try sheet.undo();
    try sheet.update();

    try sheet.redo();
    try sheet.update();
}

test "Overwrite with reference" {
    const t = std.testing;
    var sheet = try Sheet.init(t.allocator);
    defer sheet.deinit();

    inline for (.{
        .{ "A0", "'one'" },
        .{ "A0", "B0" },
    }) |data| {
        const address, const source = data;
        try sheet.setCell(
            .fromValidAddress(address),
            try sheet.parseFromExpression(source),
            .{},
        );

        try sheet.update();
    }
}

fn testSetCell(sheet: *Sheet, address: []const u8, src: []const u8) !void {
    try sheet.setCell(.fromValidAddress(address), try sheet.parseFromExpression(src), .{});
}

fn testSetCellPos(sheet: *Sheet, pos: Position, expr: []const u8) !void {
    try sheet.setCell(pos, expr, try Parser.parseFromExpression(sheet, expr), .{});
}

test "Dependencies" {
    const bytes =
        \\ let A0 = 10
        \\ let B0 = 20
        \\ let A1 = A0 * 2
        \\ let B1 = B0 * 2
        \\
    ;

    var reader: std.io.Reader = .fixed(bytes);

    var sheet = try init(std.testing.allocator);
    defer sheet.deinit();

    try sheet.interpretSource(&reader);
    try sheet.update();

    try testSetCell(&sheet, "A2", "A0 * 3");
    try sheet.update();

    try testSetCell(&sheet, "b0", "2");
    try sheet.update();

    try expectCellEquals(&sheet, "A0", 10);
    try expectCellEquals(&sheet, "A1", 20);
    try expectCellEquals(&sheet, "A2", 30);
    try expectCellEquals(&sheet, "B0", 2);
    try expectCellEquals(&sheet, "B1", 4);
}

test "insert column overflow" {
    var sheet = try init(std.testing.allocator);
    defer sheet.deinit();

    try sheet.setCell(
        .init(std.math.maxInt(u32) - 1, 0),
        try sheet.parseFromExpression("5"),
        .{},
    );
    const res = sheet.insertColumns(0, 2, .{});
    try std.testing.expectError(error.Overflow, res);
}

test "insert row overflow" {
    var sheet = try init(std.testing.allocator);
    defer sheet.deinit();

    try sheet.setCell(.init(0, std.math.maxInt(u32) - 1), try sheet.parseFromExpression("5"), .{});
    try sheet.insertRows(0, 1, .{});
    try std.testing.expectError(error.Overflow, sheet.insertRows(0, 1, .{}));
}

test "delete col dependency data" {
    var sheet = try init(std.testing.allocator);
    defer sheet.deinit();

    try sheet.testSetCell("A0", "B0");
    try std.testing.expect(sheet.dependents.find(&.{ 1, 0, 1, 0 }) != null);
    try sheet.deleteColOrRowRange(0, 0, .{}, .col);
    try std.testing.expect(sheet.dependents.find(&.{ 1, 0, 1, 0 }) == null);
}

test "delete row dependency data" {
    var sheet = try init(std.testing.allocator);
    defer sheet.deinit();

    try sheet.testSetCell("A0", "A1");
    try std.testing.expect(sheet.dependents.find(&.{ 0, 1, 0, 1 }) != null);
    try sheet.deleteColOrRowRange(0, 0, .{}, .row);
    try std.testing.expect(sheet.dependents.find(&.{ 0, 1, 0, 1 }) == null);
}

test "undo delete column" {
    var sheet = try init(std.testing.allocator);
    defer sheet.deinit();

    try sheet.testSetCell("B0", "A0");
    sheet.endUndoGroup();
    try sheet.update();

    try sheet.expectCellEquals("B0", 0);
    try sheet.deleteColOrRowRange(0, 0, .{}, .col);
    sheet.endUndoGroup();
    try sheet.update();

    try sheet.expectCellError("A0");
    try sheet.undo();
    try sheet.update();

    const kv = sheet.dependents.findEntry(&.{ 0, 0, 0, 0 });
    try std.testing.expect(kv != .none);
    const head = sheet.deps.items[kv.int()];
    try std.testing.expectEqualSlices(u32, &.{ 1, 0 }, sheet.cell_tree.getPoint(head.handle));

    try sheet.expectCellEquals("B0", 0);
}

test "something" {
    var sheet = try init(std.testing.allocator);
    defer sheet.deinit();

    try sheet.testSetCell("E1", "@sum(B0:D0)");
    sheet.endUndoGroup();

    try sheet.deleteColOrRowRange(3, 3, .{}, .col);
    sheet.endUndoGroup();

    try sheet.undo();

    try sheet.redo();

    try sheet.testSetCell("E2", "D0");
    sheet.endUndoGroup();

    try sheet.deleteColOrRowRange(2, 2, .{}, .col);
    sheet.endUndoGroup();

    try sheet.undo();
    try sheet.redo();

    try sheet.testSetCell("E2", "D0");
    sheet.endUndoGroup();

    try sheet.deleteColOrRowRange(1, 3, .{}, .col);
    sheet.endUndoGroup();
}

test "delete same col twice with dependency" {
    var sheet = try init(std.testing.allocator);
    defer sheet.deinit();

    try sheet.testSetCell("A0", "B0");
    sheet.endUndoGroup();

    try sheet.deleteColOrRowRange(0, 0, .{}, .col);
    sheet.endUndoGroup();

    try sheet.deleteColOrRowRange(0, 0, .{}, .col);
    sheet.endUndoGroup();
}

test "tree root getting set to invalid" {
    var sheet = try init(std.testing.allocator);
    defer sheet.deinit();

    try sheet.testSetCell("A0", "1");
    try sheet.testSetCell("B0", "A0 * 2");
    try sheet.testSetCell("C0", "B0 * 2");
    try sheet.testSetCell("A1", "@sum(A0:C0)");
    sheet.endUndoGroup();

    try sheet.update();

    try sheet.expectCellEquals("A0", 1);
    try sheet.expectCellEquals("B0", 2);
    try sheet.expectCellEquals("C0", 4);
    try sheet.expectCellEquals("A1", 7);

    try sheet.deleteColOrRowRange(0, 0, .{}, .col);
    sheet.endUndoGroup();

    try sheet.update();

    try sheet.expectCellNonExtant("C0");
    try sheet.expectCellError("A0");
    try sheet.expectCellError("B0");

    try sheet.undo();
    try sheet.update();

    try sheet.expectCellEquals("A0", 1);
    try sheet.expectCellEquals("B0", 2);
    try sheet.expectCellEquals("C0", 4);
    try sheet.expectCellEquals("A1", 7);
}

test "read source with duplicate entries" {
    const src =
        \\let a0 = 10
        \\let a0 = 20
        \\let b0 = a0 * 2
        \\let b0 = 5
        \\
    ;

    var sheet = try init(std.testing.allocator);
    defer sheet.deinit();

    var r: std.io.Reader = .fixed(src);
    try sheet.interpretSource(&r);

    try sheet.update();

    try sheet.expectCellEquals("A0", 20);
    try sheet.expectCellEquals("B0", 5);
}

test "read source with invalid statements" {
    const src =
        \\1
        \\2
        \\1 + 2
        \\a0
        \\a0 * 2
        \\a0 = 10
        \\ungabunga
        \\a
        \\le a0 = 10
    ;

    var sheet = try init(std.testing.allocator);
    defer sheet.deinit();

    var r: std.io.Reader = .fixed(src);
    try sheet.interpretSource(&r);

    try sheet.update();
}

test "save csv" {
    const src1 =
        \\let a0 = 10
        \\let b0 = 20
        \\let c0 = 30
        \\let d5 = 10
        \\let a1 = 3
        \\let c2 = 5
    ;

    var sheet = try init(std.testing.allocator);
    defer sheet.deinit();

    var r: std.io.Reader = .fixed(src1);
    try sheet.interpretSource(&r);
    try sheet.update();

    try sheet.expectCellEquals("a0", 10);
    try sheet.expectCellEquals("b0", 20);
    try sheet.expectCellEquals("c0", 30);
    try sheet.expectCellEquals("d5", 10);
    try sheet.expectCellEquals("a1", 3);
    try sheet.expectCellEquals("c2", 5);

    var aw: std.io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();

    try sheet.writeCsv(&aw.writer);
    const expected1 =
        \\10,20,30
        \\3
        \\,,5
        \\
        \\
        \\,,,10
    ;
    try std.testing.expectEqualStrings(expected1, aw.written());
}

test "load csv" {
    const src =
        \\10,20,30
        \\3
        \\,,5
        \\
        \\
        \\,,,10
    ;

    var sheet = try init(std.testing.allocator);
    defer sheet.deinit();

    var r: std.io.Reader = .fixed(src);
    try sheet.loadCsv(&r);
    try sheet.update();
}
