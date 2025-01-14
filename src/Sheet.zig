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

const ast = @import("ast.zig");
const RTree = @import("tree.zig").RTree;
const DependentTree = @import("tree.zig").DependentTree;
const SkipList = @import("skip_list.zig").SkipList;
const FlatListPool = @import("flat_list_pool.zig").FlatListPool;

const Sheet = @This();

allocator: Allocator,

/// True if there have been any changes since the last save
has_changes: bool,

/// List of cells that need to be re-evaluated.
queued_cells: std.ArrayListUnmanaged(CellHandle),

/// Stores the null terminated text of string literals. Cells contain an index into this buffer.
strings_buf: std.ArrayListUnmanaged(u8),

/// Range tree mapping ranges to a list of ranges that depend on the first.
/// Used to query whether a cell belongs to a range and then update the cells
/// that depend on that range.
dependents: DependentTree(4),

/// Range tree containing just the positions of extant cells.
/// Used for quick lookup of all extant cells in a range.
cell_tree: CellTree,

/// Treap containing cell information. Used for fast lookups of cell references.
cell_treap: CellTreap,

ast_nodes: std.MultiArrayList(ast.Node).Slice,

string_values: FlatListPool(u8),

rows: RowAxis,
cols: ColumnAxis,

undos: UndoList,
redos: UndoList,

search_buffer: std.ArrayListUnmanaged(DependentTree(4).ListIndex),

filepath: std.BoundedArray(u8, std.fs.max_path_bytes),

pub const CellTree = RTree(CellHandle, void, 4, rangeFromCellHandle, rectFromCellHandle, eqlCellHandles);
pub const CellTreap = @import("treap.zig").Treap(Cell, Cell.compare);
pub const CellHandle = CellTreap.Handle;
pub const ColumnAxis = SkipList(Column, 4, Column.Context);
pub const RowAxis = SkipList(Row, 4, Row.Context);

pub const StringIndex = packed struct {
    n: u32,

    pub fn from(n: u32) StringIndex {
        assert(n < std.math.maxInt(u32));
        return .{ .n = n };
    }

    pub fn isValid(index: StringIndex) bool {
        return index != invalid;
    }

    pub const invalid: StringIndex = .{ .n = std.math.maxInt(u32) };
};

fn getStringSlice(sheet: *Sheet, index: StringIndex) [:0]const u8 {
    if (!index.isValid()) return "";
    const ptr: [*:0]const u8 = @ptrCast(sheet.strings_buf.items[index.n..].ptr);
    return std.mem.span(ptr);
}

pub fn rangeFromCellHandle(sheet: *Sheet, handle: CellHandle) Range {
    return sheet.getCellFromHandle(handle).range();
}

pub fn rectFromCellHandle(sheet: *Sheet, handle: CellHandle) Rect {
    return sheet.rangeFromCellHandle(handle).rect(sheet);
}

pub fn eqlCellHandles(sheet: *Sheet, a: CellHandle, b: CellHandle) bool {
    return sheet.getCellFromHandle(a).eql(sheet.getCellFromHandle(b));
}

pub fn create(allocator: Allocator) !*Sheet {
    const sheet = try allocator.create(Sheet);
    errdefer allocator.destroy(sheet);

    sheet.* = .{
        .allocator = allocator,
        .has_changes = false,

        .queued_cells = .empty,
        .strings_buf = .empty,

        .undos = .empty,
        .redos = .empty,

        .cell_tree = .init(sheet),
        .dependents = .init(sheet),
        .cell_treap = .init(1_000_000),
        .ast_nodes = .empty,
        .string_values = .empty,

        .rows = .init(1),
        .cols = .init(1),

        .search_buffer = .empty,

        .filepath = .{},
    };
    assert(sheet.cols.nodes.len == 0);

    try sheet.undos.ensureTotalCapacity(allocator, 1);
    errdefer sheet.undos.deinit(allocator);
    try sheet.redos.ensureTotalCapacity(allocator, 1);

    return sheet;
}

pub fn createNoAlloc(allocator: Allocator) !*Sheet {
    const sheet = try allocator.create(Sheet);
    errdefer allocator.destroy(sheet);

    sheet.* = .{
        .allocator = allocator,
        .has_changes = false,

        .queued_cells = .empty,
        .strings_buf = .empty,

        .undos = .empty,
        .redos = .empty,

        .cell_tree = .init(sheet),
        .dependents = .init(sheet),
        .cell_treap = .init(1_000_000),
        .ast_nodes = .empty,
        .string_values = .empty,

        .rows = .init(1),
        .cols = .init(1),

        .search_buffer = .empty,

        .filepath = .{},
    };

    return sheet;
}

pub fn destroy(sheet: *Sheet) void {
    sheet.strings_buf.deinit(sheet.allocator);
    sheet.search_buffer.deinit(sheet.allocator);

    sheet.clearUndos(.undo);
    sheet.clearUndos(.redo);
    sheet.dependents.deinit(sheet.allocator);
    sheet.cell_tree.deinit(sheet.allocator);

    sheet.queued_cells.deinit(sheet.allocator);
    sheet.undos.deinit(sheet.allocator);
    sheet.redos.deinit(sheet.allocator);

    sheet.cell_treap.nodes.deinit(sheet.allocator);
    sheet.rows.deinit(sheet.allocator);
    sheet.cols.deinit(sheet.allocator);
    sheet.ast_nodes.deinit(sheet.allocator);
    sheet.string_values.deinit(sheet.allocator);
    sheet.allocator.destroy(sheet);
}

pub fn getCellFromHandle(sheet: *Sheet, handle: CellHandle) *Cell {
    return &sheet.cell_treap.node(handle).key;
}

const Marker = packed struct(u2) {
    undo: bool = false,
    redo: bool = false,
};

pub const UndoList = std.MultiArrayList(Undo);
pub const UndoType = enum { undo, redo };

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

    pub const Tag = enum(u8) {
        set_cell,
        delete_cell,
        set_column_width,
        set_column_precision,
        insert_row,
        insert_col,
        delete_row,
        delete_col,
        sentinel,
    };

    pub const Payload = extern union {
        set_cell: extern struct {
            handle: CellHandle,
            strings: StringIndex,
        },
        delete_cell: Position,

        set_column_width: extern struct {
            col: Position.Int,
            width: u16,
        },
        set_column_precision: extern struct {
            col: Position.Int,
            precision: u8,
        },
        insert_row: PosInt,
        insert_col: PosInt,
        delete_row: PosInt,
        delete_col: PosInt,
    };
};

const SerializeHeader = extern struct {
    /// Magic number identifying a binary file as a cellulator file.
    magic: u32 = magic_number,
    /// A version field for when the binary output changes.
    version: u32 = binary_version,

    strings_buf_len: u32,

    dependents: DependentTree(4).Header,
    cell_tree: CellTree.Header,

    cell_treap: CellTreap.Header,

    ast_nodes_len: u32,

    string_values: FlatListPool(u8).Header,

    rows: RowAxis.Header,
    cols: ColumnAxis.Header,

    undos_len: u32,
    redos_len: u32,

    const magic_number: u32 = @bitCast([4]u8{ 'Z', 'C', 'Z', 'C' });
    const binary_version = 1;
};

pub fn serialize(sheet: *Sheet, file: std.fs.File) !void {
    assert(sheet.queued_cells.items.len == 0);

    sheet.undos.shrinkAndFree(sheet.allocator, sheet.undos.len);
    sheet.redos.shrinkAndFree(sheet.allocator, sheet.redos.len);
    utils.shrinkMultiArrayListSlice(sheet.allocator, &sheet.ast_nodes);
    utils.shrinkMultiArrayListSlice(sheet.allocator, &sheet.cols.nodes);
    utils.shrinkMultiArrayListSlice(sheet.allocator, &sheet.rows.nodes);

    const header: SerializeHeader = .{
        .strings_buf_len = @intCast(sheet.strings_buf.items.len),
        .dependents = sheet.dependents.getHeader(),
        .cell_tree = sheet.cell_tree.getHeader(),
        .cell_treap = sheet.cell_treap.getHeader(),
        .ast_nodes_len = @intCast(sheet.ast_nodes.len),
        .string_values = sheet.string_values.getHeader(),
        .rows = sheet.rows.getHeader(),
        .cols = sheet.cols.getHeader(),
        .undos_len = @intCast(sheet.undos.len),
        .redos_len = @intCast(sheet.redos.len),
    };

    var iovecs = .{
        utils.ptrToIoVec(&header),
        utils.arrayListIoVec(&sheet.strings_buf),
    } ++ sheet.dependents.iovecs() ++ .{
        sheet.cell_tree.iovecs(),
        sheet.cell_treap.iovecs(),
        utils.multiArrayListSliceIoVec(&sheet.ast_nodes),
    } ++ sheet.string_values.iovecs() ++ .{
        sheet.rows.iovecs(),
        sheet.cols.iovecs(),
        utils.multiArrayListIoVec(&sheet.undos),
        utils.multiArrayListIoVec(&sheet.redos),
    };

    try file.writevAll(&iovecs);
}

pub fn deserialize(allocator: Allocator, file: std.fs.File) !*Sheet {
    const header = try file.reader().readStruct(SerializeHeader);

    if (header.magic != SerializeHeader.magic_number) return error.InvalidFile;
    if (header.version != SerializeHeader.binary_version) return error.InvalidVersion;

    const sheet = try createNoAlloc(allocator);
    errdefer sheet.destroy();

    var iovecs = [_]std.posix.iovec{
        try utils.prepArrayList(&sheet.strings_buf, allocator, header.strings_buf_len),
    } ++ try sheet.dependents.fromHeader(allocator, header.dependents, sheet) ++ .{
        try sheet.cell_tree.fromHeader(allocator, header.cell_tree, sheet),
        try sheet.cell_treap.fromHeader(allocator, header.cell_treap, 1_000_000),
        try utils.prepMultiArrayListSlice(&sheet.ast_nodes, allocator, header.ast_nodes_len),
    } ++ try sheet.string_values.fromHeader(sheet.allocator, header.string_values) ++ .{
        try sheet.rows.fromHeader(allocator, header.rows),
        try sheet.cols.fromHeader(allocator, header.cols),
        try utils.prepMultiArrayList(&sheet.undos, allocator, header.undos_len),
        try utils.prepMultiArrayList(&sheet.redos, allocator, header.redos_len),
    };

    _ = try file.readvAll(&iovecs);

    return sheet;
}

pub fn isEmpty(sheet: *const Sheet) bool {
    return sheet.cell_treap.root == null;
}

pub fn clearRetainingCapacity(sheet: *Sheet) void {
    // var iter = sheet.cell_treap.inorderIterator();
    // while (iter.next()) |node| node.key.ast.deinit(sheet.allocator);
    sheet.cell_treap.root = .invalid;
    sheet.rows.clearRetainingCapacity();
    sheet.cols.clearRetainingCapacity();

    sheet.queued_cells.clearRetainingCapacity();

    sheet.cell_tree.deinit(sheet.allocator);
    sheet.cell_tree = .init(sheet);

    sheet.dependents.deinit(sheet.allocator);
    sheet.dependents = .init(sheet);

    sheet.undos.len = 0;
    sheet.redos.len = 0;
    sheet.strings_buf.clearRetainingCapacity();
    sheet.cell_treap.nodes.clearRetainingCapacity();
}

pub fn interpretFile(sheet: *Sheet, reader: std.io.AnyReader) !void {
    defer sheet.endUndoGroup();
    while (true) {
        var sfa = std.heap.stackFallback(8192, sheet.allocator);
        const a = sfa.get();

        const line = try reader.readUntilDelimiterOrEofAlloc(a, '\n', std.math.maxInt(u30)) orelse
            break;
        defer a.free(line);

        const expr_root = ast.fromSource(sheet, line) catch |err| {
            switch (err) {
                error.UnexpectedToken,
                error.InvalidCellAddress,
                => continue,
                error.OutOfMemory => return error.OutOfMemory,
            }
        };

        const data = sheet.ast_nodes.items(.data);
        const assignment = data[expr_root.n].assignment;
        const pos = data[assignment.lhs.n].pos;

        const spliced_root = ast.splice(&sheet.ast_nodes, assignment.rhs);

        try sheet.setCell(pos, line, spliced_root, .{});
    }
}

pub fn loadFile(sheet: *Sheet, filepath: []const u8) !void {
    const file = std.fs.cwd().openFile(filepath, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            sheet.setFilePath(filepath);
            sheet.has_changes = false;
            return;
        },
        else => return err,
    };
    defer file.close();

    sheet.setFilePath(filepath);
    defer sheet.has_changes = false;

    var buf = std.io.bufferedReader(file.reader());
    const reader = buf.reader();
    log.debug("Loading file {s}", .{filepath});

    try sheet.interpretFile(reader.any());
}

pub fn writeFile(
    sheet: *Sheet,
    opts: struct {
        filepath: ?[]const u8 = null,
    },
) !void {
    const filepath = opts.filepath orelse sheet.filepath.slice();
    if (filepath.len == 0) {
        return error.EmptyFileName;
    }

    var atomic_file = try std.fs.cwd().atomicFile(filepath, .{});
    defer atomic_file.deinit();

    var buf = std.io.bufferedWriter(atomic_file.file.writer());
    const writer = buf.writer();

    var iter = sheet.cell_treap.inorderIterator();
    while (iter.next()) |handle| {
        const cell = sheet.getCellFromHandle(handle);
        const pos = cell.position(sheet);
        try writer.print("let {} = ", .{pos});
        try sheet.printCellExpression(pos, writer);
        try writer.writeByte('\n');
    }

    try buf.flush();
    try atomic_file.finish();

    if (opts.filepath) |path| {
        sheet.setFilePath(path);
    }
}

/// Iterator over the cells referenced by an expression, as ranges.
/// Singular cell references are treated as a single-celled range.
const ExprRangeIterator = struct {
    sheet: *const Sheet,
    i: ast.Index,
    start: ast.Index,

    fn init(sheet: *const Sheet, expr_root: ast.Index) ExprRangeIterator {
        return .{
            .sheet = sheet,
            .i = .from(expr_root.n + 1),
            .start = ast.leftMostChild(sheet.ast_nodes, expr_root),
        };
    }

    fn next(it: *ExprRangeIterator) ?Range {
        if (it.i == it.start) return null;

        const data = it.sheet.ast_nodes.items(.data);

        var iter = std.mem.reverseIterator(it.sheet.ast_nodes.items(.tag)[it.start.n..it.i.n]);
        defer it.i = .from(@intCast(it.start.n + iter.index));

        while (iter.next()) |tag| switch (tag) {
            .ref_rel_rel, .ref_rel_abs, .ref_abs_rel, .ref_abs_abs => {
                const ref: *const Reference = @ptrCast(&data[it.start.n + iter.index]);
                return .{ .tl = ref.*, .br = ref.* };
            },
            .range => {
                const r = data[it.start.n + iter.index].range;
                const ref1: *const Reference = @ptrCast(&data[r.lhs.n]);
                const ref2: *const Reference = @ptrCast(&data[r.rhs.n]);
                _ = iter.next().?;
                _ = iter.next().?;
                return .{ .tl = ref1.*, .br = ref2.* };
            },
            else => {},
        };

        return null;
    }
};

/// Adds `dependent_range` as a dependent of all cells in `range`.
fn addRangeDependents(
    sheet: *Sheet,
    dependent: CellHandle,
    range: Range,
) Allocator.Error!void {
    log.debug("Adding {} as a dependent of {}", .{
        sheet.rectFromCellHandle(dependent).tl,
        range.rect(sheet),
    });
    return sheet.dependents.put(range, dependent);
}

fn addExpressionDependents(
    sheet: *Sheet,
    dependent: CellHandle,
    expr_root: ast.Index,
) Allocator.Error!void {
    var iter: ExprRangeIterator = .init(sheet, expr_root);
    while (iter.next()) |range| {
        try sheet.addRangeDependents(dependent, range);
    }
}

/// Removes `cell` as a dependent of all cells in `rect`
fn removeRangeDependents(
    sheet: *Sheet,
    dependent: CellHandle,
    range: Range,
) Allocator.Error!void {
    log.debug("Removing {} as a dependent of {}", .{
        sheet.rectFromCellHandle(dependent),
        range.rect(sheet),
    });
    return sheet.dependents.removeValue(range, dependent);
}

/// Removes `cell` as a dependent of all ranges referenced by `expr`.
fn removeExprDependents(
    sheet: *Sheet,
    dependent: CellHandle,
    expr_root: ast.Index,
) Allocator.Error!void {
    var iter = ExprRangeIterator.init(sheet, expr_root);
    while (iter.next()) |range| {
        try sheet.removeRangeDependents(dependent, range);
    }
}

/// Creates any necessary row/column anchors referred to in the expression
fn createAnchorsForExpression(sheet: *Sheet, expr: ast) Allocator.Error!void {
    var iter = ExprRangeIterator.init(expr);
    while (iter.next()) |range| {
        _ = try sheet.createRow(range.tl.y);
        _ = try sheet.createColumn(range.tl.x);

        if (range.br.y != range.tl.y) _ = try sheet.createRow(range.br.y);
        if (range.br.x != range.tl.x) _ = try sheet.createColumn(range.br.x);
    }
}

pub fn firstCellInRow(sheet: *Sheet, row: Position.Int) !?Position {
    var iter = try sheet.cell_tree.searchIterator(sheet.allocator, .{
        .tl = .{ .x = 0, .y = row },
        .br = .{ .x = std.math.maxInt(PosInt), .y = row },
    });
    defer iter.deinit();

    var min: ?PosInt = null;
    while (try iter.next()) |kv| {
        const cell = sheet.getCellFromHandle(kv.key);
        const x = sheet.cols.get(cell.col).?.index;
        if (min == null or x < min.?) min = x;
    }

    return if (min) |x| .{ .x = x, .y = row } else null;
}

pub fn lastCellInRow(sheet: *Sheet, row: Position.Int) !?Position {
    var iter = try sheet.cell_tree.searchIterator(sheet.allocator, .{
        .tl = .{ .x = 0, .y = row },
        .br = .{ .x = std.math.maxInt(PosInt), .y = row },
    });
    defer iter.deinit();

    var max: ?PosInt = null;
    while (try iter.next()) |kv| {
        const cell = sheet.getCellFromHandle(kv.key);
        const x = sheet.cols.get(cell.col).?.index;
        if (max == null or x > max.?) max = x;
    }

    return if (max) |x| .{ .x = x, .y = row } else null;
}

// TODO: Optimize these

pub fn firstCellInColumn(sheet: *Sheet, col: Position.Int) !?Position {
    var iter = try sheet.cell_tree.searchIterator(sheet.allocator, .{
        .tl = .{ .x = col, .y = 0 },
        .br = .{ .x = col, .y = std.math.maxInt(PosInt) },
    });
    defer iter.deinit();

    var min: ?PosInt = null;
    while (try iter.next()) |kv| {
        const cell = sheet.getCellFromHandle(kv.key);
        const y = sheet.rows.get(cell.row).?.index;
        if (min == null or y < min.?) min = y;
    }

    return if (min) |y| .{ .x = col, .y = y } else null;
}

pub fn lastCellInColumn(sheet: *Sheet, col: Position.Int) !?Position {
    var iter = try sheet.cell_tree.searchIterator(sheet.allocator, .{
        .tl = .{ .x = col, .y = 0 },
        .br = .{ .x = col, .y = std.math.maxInt(PosInt) },
    });
    defer iter.deinit();

    var max: ?PosInt = null;
    while (try iter.next()) |kv| {
        const cell = sheet.getCellFromHandle(kv.key);
        const y = sheet.rows.get(cell.row).?.index;
        if (max == null or y > max.?) max = y;
    }

    return if (max) |y| .{ .x = col, .y = y } else null;
}

// These functions essentially do a binary search over a range using the cell range tree. It divides
// the range in two, checking if first half has a cell using the range tree. If it does, we divide
// the first side in two, and so on, until the range is one cell wide.

/// Given a range, find the first row that contains a cell
fn findExtantRow(sheet: *Sheet, rect: Rect, p: enum { first, last }) !?PosInt {
    var sfa = std.heap.stackFallback(1024, sheet.allocator);
    const allocator = sfa.get();

    var r = rect;
    var iter = try sheet.cell_tree.searchIterator(allocator, r);
    defer iter.deinit();

    if (try iter.next() == null) return null; // Range does not contain any cells

    return while (true) {
        const height = r.br.y - r.tl.y;
        if (height == 0) break r.br.y;

        const left_height = height / 2;
        const left: Rect = .{
            .tl = r.tl,
            .br = .{ .x = r.br.x, .y = r.tl.y + left_height },
        };

        const right: Rect = .{
            .tl = .{ .x = r.tl.x, .y = r.tl.y + left_height + 1 },
            .br = r.br,
        };

        const first, const last = switch (p) {
            .first => .{ left, right },
            .last => .{ right, left },
        };

        try iter.reset(first, &sheet.cell_tree);
        r = if (try iter.next() != null) first else last;
    } else unreachable;
}

/// Given a range, find the first column that contains a cell
fn findExtantCol(sheet: *Sheet, range: Rect, p: enum { first, last }) !?PosInt {
    var sfa = std.heap.stackFallback(1024, sheet.allocator);
    const allocator = sfa.get();

    var r = range;
    var iter = try sheet.cell_tree.searchIterator(allocator, r);
    defer iter.deinit();

    if (try iter.next() == null) return null; // Range does not contain any cells

    return while (true) {
        const width = r.br.x - r.tl.x;
        if (width == 0) break r.br.x;

        const left_width = width / 2;
        const left: Rect = .{
            .tl = r.tl,
            .br = .{ .x = r.tl.x + left_width, .y = r.br.y },
        };

        const right: Rect = .{
            .tl = .{ .x = r.tl.x + left_width + 1, .y = r.tl.y },
            .br = r.br,
        };

        const first, const last = switch (p) {
            .first => .{ left, right },
            .last => .{ right, left },
        };

        try iter.reset(first, &sheet.cell_tree);
        r = if (try iter.next() != null) first else last;
    } else unreachable;
}

pub fn nextPopulatedCell(sheet: *Sheet, pos: Position) !?Position {
    const remaining_row: Rect = if (pos.x != std.math.maxInt(PosInt))
        .{
            .tl = .{ .x = pos.x + 1, .y = pos.y },
            .br = .{ .x = std.math.maxInt(PosInt), .y = pos.y },
        }
    else if (pos.y != std.math.maxInt(PosInt))
        .{
            .tl = .{ .x = 0, .y = pos.y + 1 },
            .br = .{ .x = std.math.maxInt(PosInt), .y = pos.y + 1 },
        }
    else
        return null;

    if (try sheet.findExtantCol(remaining_row, .first)) |col_index| {
        return .{
            .x = col_index,
            .y = remaining_row.br.y,
        };
    }

    if (pos.y == std.math.maxInt(PosInt)) return null;

    const range: Rect = .{
        .tl = .{ .x = 0, .y = pos.y + 1 },
        .br = .{ .x = std.math.maxInt(PosInt), .y = std.math.maxInt(PosInt) },
    };
    if (try sheet.findExtantRow(range, .first)) |y| {
        const row: Rect = .{
            .tl = .{ .x = 0, .y = y },
            .br = .{ .x = std.math.maxInt(PosInt), .y = y },
        };
        if (try sheet.findExtantCol(row, .first)) |x| {
            return .{
                .x = x,
                .y = y,
            };
        }
    }

    return null;
}

pub fn prevPopulatedCell(sheet: *Sheet, pos: Position) !?Position {
    const remaining_row: Rect = if (pos.x != 0)
        .{
            .tl = .{ .x = 0, .y = pos.y },
            .br = .{ .x = pos.x - 1, .y = pos.y },
        }
    else if (pos.y != 0)
        .{
            .tl = .{ .x = 0, .y = pos.y - 1 },
            .br = .{ .x = std.math.maxInt(PosInt), .y = pos.y - 1 },
        }
    else
        return null;

    if (try sheet.findExtantCol(remaining_row, .last)) |col_index| {
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
    if (try sheet.findExtantRow(range, .last)) |y| {
        const row: Rect = .{
            .tl = .{ .x = 0, .y = y },
            .br = .{ .x = std.math.maxInt(PosInt), .y = y },
        };
        if (try sheet.findExtantCol(row, .last)) |x| {
            return .{
                .x = x,
                .y = y,
            };
        }
    }

    return null;
}

pub const UndoOpts = struct {
    undo_type: ?UndoType = .undo,
    clear_redos: bool = true,
};

pub fn clearUndos(sheet: *Sheet, comptime kind: UndoType) void {
    const list = switch (kind) {
        .undo => &sheet.undos,
        .redo => &sheet.redos,
    };

    list.len = 0;
}

pub fn endUndoGroup(sheet: *Sheet) void {
    if (sheet.undos.len == 0) return;
    sheet.undos.appendAssumeCapacity(.sentinel);
}

fn endRedoGroup(sheet: *Sheet) void {
    if (sheet.redos.len == 0) return;
    sheet.redos.appendAssumeCapacity(.sentinel);
}

pub fn ensureUndoCapacity(sheet: *Sheet, undo_type: UndoType, n: u32) Allocator.Error!void {
    switch (undo_type) {
        .undo => try sheet.undos.ensureUnusedCapacity(sheet.allocator, n + 1),
        .redo => try sheet.redos.ensureUnusedCapacity(sheet.allocator, n + 1),
    }
}

pub fn pushUndo(sheet: *Sheet, u: Undo, opts: UndoOpts) Allocator.Error!void {
    const undo_type = opts.undo_type orelse return;

    try sheet.ensureUndoCapacity(undo_type, 1);
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

pub fn insertColumn(sheet: *Sheet, index: PosInt, undo_opts: UndoOpts) !void {
    try sheet.pushUndo(.init(.delete_col, index), undo_opts);
    const values = sheet.cols.nodes.items(.value);

    for (values) |*value| {
        if (value.index >= index) {
            value.index += 1;
        }
    }
}

pub fn insertRow(sheet: *Sheet, index: PosInt, undo_opts: UndoOpts) !void {
    try sheet.pushUndo(.init(.delete_row, index), undo_opts);
    const values = sheet.rows.nodes.items(.value);

    for (values) |*value| {
        if (value.index >= index) {
            value.index += 1;
        }
    }
}

pub fn doUndo(sheet: *Sheet, u: Undo, opts: UndoOpts) Allocator.Error!void {
    switch (u.tag) {
        .set_cell => try sheet.insertCellNode(u.payload.set_cell.handle, opts),
        .delete_cell => try sheet.deleteCell(u.payload.delete_cell, opts),
        .set_column_width => {
            const p = u.payload.set_column_width;
            try sheet.setWidth(p.col, p.width, opts);
        },
        .set_column_precision => {
            const p = u.payload.set_column_precision;
            try sheet.setPrecision(p.col, p.precision, opts);
        },
        .insert_row => try sheet.insertRow(u.payload.insert_row, opts),
        .insert_col => try sheet.insertColumn(u.payload.insert_col, opts),
        .delete_row, .delete_col => {},
        .sentinel => {},
    }
}

pub fn undo(sheet: *Sheet) Allocator.Error!void {
    if (sheet.undos.len == 0) return;

    // All undo groups MUST end with a group marker - so remove it!
    const last_undo = sheet.undos.pop();
    assert(last_undo.tag == .sentinel);

    defer sheet.endRedoGroup();

    const tags = sheet.undos.items(.tag);
    const opts: UndoOpts = .{ .undo_type = .redo };
    while (sheet.undos.popOrNull()) |u| {
        errdefer {
            sheet.undos.appendAssumeCapacity(u);
            sheet.endUndoGroup();
        }
        try sheet.doUndo(u, opts);
        if (sheet.undos.len == 0 or tags[sheet.undos.len - 1] == .sentinel)
            break;
    }
}

pub fn redo(sheet: *Sheet) Allocator.Error!void {
    if (sheet.redos.len == 0) return;

    // All undo groups MUST end with a group marker - so remove it!
    const last = sheet.redos.pop();
    assert(last.tag == .sentinel);

    defer sheet.endUndoGroup();

    const tags = sheet.redos.items(.tag);
    const opts: UndoOpts = .{ .clear_redos = false };
    while (sheet.redos.popOrNull()) |u| {
        errdefer {
            sheet.redos.appendAssumeCapacity(u);
            sheet.endRedoGroup();
        }
        try sheet.doUndo(u, opts);
        if (sheet.redos.len == 0 or tags[sheet.redos.len - 1] == .sentinel)
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
    try sheet.ensureUndoCapacity(.undo, 1);
    const col = sheet.cols.getPtr(handle).?;
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
    if (sheet.getColumnHandle(column_index)) |handle| {
        const col = sheet.cols.get(handle).?;
        try sheet.setColWidth(handle, column_index, col.width +| n, opts);
    }
}

pub fn decWidth(
    sheet: *Sheet,
    column_index: Position.Int,
    n: u16,
    opts: UndoOpts,
) Allocator.Error!void {
    if (sheet.getColumnHandle(column_index)) |handle| {
        const col = sheet.cols.get(handle).?;
        const new_width = @max(col.width -| n, 1);
        try sheet.setColWidth(handle, column_index, new_width, opts);
    }
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
    const col = sheet.cols.getPtr(handle).?;
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
    if (sheet.getColumnHandle(column_index)) |handle| {
        const col = sheet.cols.get(handle).?;
        try sheet.setColPrecision(handle, column_index, col.precision +| n, opts);
    }
}

pub fn decPrecision(
    sheet: *Sheet,
    column_index: Position.Int,
    n: u8,
    opts: UndoOpts,
) Allocator.Error!void {
    if (sheet.getColumnHandle(column_index)) |handle| {
        const col = sheet.cols.get(handle).?;
        try sheet.setColPrecision(handle, column_index, col.precision -| n, opts);
    }
}

pub fn cellCount(sheet: *Sheet) Position.HashInt {
    var iter = sheet.cell_treap.inorderIterator();
    var count: Position.HashInt = 0;
    while (iter.next()) |_| count += 1;
    return count;
}

pub fn needsUpdate(sheet: *const Sheet) bool {
    return sheet.queued_cells.items.len > 0;
}

fn dupeAstStrings(
    sheet: *Sheet,
    source: []const u8,
    nodes: ast.NodeSlice,
    root_node: ast.Index,
) StringIndex {
    assert(root_node.n < nodes.len);
    const start = ast.leftMostChild(nodes, root_node);
    assert(start.n <= root_node.n);

    const tags = nodes.items(.tag)[start.n .. root_node.n + 1];
    const data = nodes.items(.data)[start.n .. root_node.n + 1];

    const ret: StringIndex = .from(@intCast(sheet.strings_buf.items.len));

    // Append contents of all string literals to the list, and update their `start` and `end`
    // indices to be into this list.
    for (tags, 0..) |tag, i| {
        if (tag == .string_literal) {
            const str = &data[i].string_literal;
            const bytes = source[str.start..str.end];
            str.start = @intCast(sheet.strings_buf.items.len);
            str.end = @intCast(str.start + bytes.len);
            sheet.strings_buf.appendSliceAssumeCapacity(bytes);
        }
    }
    sheet.strings_buf.appendAssumeCapacity(0);
    return ret;
}

/// Creates the cell at `pos` using the given expression, duplicating its string literals.
pub fn setCell(
    sheet: *Sheet,
    pos: Position,
    source: []const u8,
    expr_root: ast.Index,
    undo_opts: UndoOpts,
) Allocator.Error!void {
    // Create row and column if they don't exist
    try sheet.cell_treap.nodes.ensureUnusedCapacity(sheet.allocator, 1);
    try sheet.strings_buf.ensureUnusedCapacity(sheet.allocator, source.len + 1);
    const row = try sheet.createRow(pos.y);
    const col = try sheet.createColumn(pos.x);

    const new_node = sheet.cell_treap.createNodeAssumeCapacity();
    errdefer sheet.cell_treap.nodes.items.len -= 1;

    const strings = sheet.dupeAstStrings(source, sheet.ast_nodes, expr_root);
    errdefer sheet.strings_buf.items.len = strings.n;

    try sheet.anchorAst(expr_root);

    sheet.cell_treap.node(new_node).key = .{
        .row = row,
        .col = col,
        .expr_root = expr_root,
        .strings = strings,
    };
    return sheet.insertCellNode(new_node, undo_opts);
}

// TODO: This function *really, really* sucks. Clean it up.
// TODO: null undo type causes a memory leak (not used anywhere)
/// Inserts a pre-allocated Cell node. Does not attempt to create any row/column anchors.
pub fn insertCellNode(
    sheet: *Sheet,
    handle: CellHandle,
    undo_opts: UndoOpts,
) Allocator.Error!void {
    const new_node = sheet.cell_treap.node(handle);
    const cell_ptr = &new_node.key;
    const pos = new_node.key.position(sheet);
    if (undo_opts.undo_type) |undo_type| {
        try sheet.ensureUndoCapacity(undo_type, 1);
    }

    try sheet.queued_cells.ensureUnusedCapacity(sheet.allocator, 1);
    try sheet.cell_tree.ensureUnusedCapacity(1);

    var entry = sheet.cell_treap.getEntryFor(new_node.key);
    const existing_handle = entry.node.get() orelse {
        log.debug("Creating cell {}", .{new_node.key.rect(sheet).tl});
        try sheet.addExpressionDependents(handle, new_node.key.expr_root);
        errdefer comptime unreachable;

        sheet.cell_tree.putContextAssumeCapacity(handle, {}, {});

        const u: Undo = .init(.delete_cell, pos);

        entry.set(handle);

        sheet.pushUndo(u, undo_opts) catch unreachable;
        sheet.has_changes = true;

        sheet.enqueueUpdate(handle) catch unreachable;
        return;
    };

    const node = sheet.cell_treap.node(existing_handle);

    log.debug("Overwriting cell {}", .{node.key.rect(sheet).tl});

    try sheet.removeExprDependents(handle, cell_ptr.expr_root);
    try sheet.addExpressionDependents(handle, cell_ptr.expr_root);
    errdefer comptime unreachable;

    sheet.cell_tree.putContextAssumeCapacity(handle, {}, {});

    const old_strings = entry.key.strings;

    // Set value in tree to new node
    const cell = new_node.key;
    entry.set(handle);
    // `entry.set` overwrites the .key field with the old value, for some reason.
    new_node.key = cell;

    const u: Undo = .init(.set_cell, .{
        .handle = existing_handle,
        .strings = old_strings,
    });
    sheet.pushUndo(u, undo_opts) catch unreachable;

    sheet.enqueueUpdate(handle) catch unreachable;
    sheet.setCellError(&node.key);
    sheet.has_changes = true;
}

pub fn deleteCellByPtr(
    sheet: *Sheet,
    cell: *Cell,
    undo_opts: UndoOpts,
) Allocator.Error!void {
    const node = cell.node();
    const handle = sheet.cell_treap.handleFromNode(node);

    if (undo_opts.undo_type) |undo_type| {
        try sheet.ensureUndoCapacity(undo_type, 1);
    }
    try sheet.enqueueUpdate(handle);
    try sheet.removeExprDependents(handle, cell.expr_root);

    // TODO: If this allocation fails we are left with an inconsistent state.
    //        This is actually a pain in the ass to fix...
    //        Maybe an RTree function to calculate the amount of mem needed
    //        for a removal ahead of time?
    //
    sheet.cell_tree.remove(handle) catch @panic("TODO"); // TODO: Probably save the current file before we panic

    // TODO: re-use string buffer
    sheet.setCellError(cell);
    sheet.cell_treap.remove(handle);

    sheet.pushUndo(.init(.set_cell, .{
        .handle = handle,
        .strings = node.key.strings,
    }), undo_opts) catch unreachable;
    sheet.has_changes = true;
}

pub fn deleteCellByRef(
    sheet: *Sheet,
    ref: Reference,
    undo_opts: UndoOpts,
) Allocator.Error!void {
    const entry = sheet.cell_treap.getEntryFor(.{ .row = ref.row, .col = ref.col });
    const handle = entry.node.get() orelse return;
    return sheet.deleteCellByPtr(&sheet.cell_treap.node(handle).key, undo_opts);
}

pub fn deleteCell(
    sheet: *Sheet,
    pos: Position,
    undo_opts: UndoOpts,
) Allocator.Error!void {
    const row = sheet.getRowHandle(pos.y) orelse return;
    const col = sheet.getColumnHandle(pos.x) orelse return;
    return sheet.deleteCellByRef(.{ .row = row, .col = col }, undo_opts);
}

pub noinline fn deleteCellsInRange(sheet: *Sheet, range: Rect) Allocator.Error!void {
    var sfa = std.heap.stackFallback(4096, sheet.allocator);
    const allocator = sfa.get();

    const kvs = try sheet.cell_tree.search(allocator, range);
    defer allocator.free(kvs);

    for (kvs) |kv| {
        try sheet.deleteCellByPtr(&sheet.cell_treap.node(kv.key).key, .{});
    }
}

pub fn getRowHandle(sheet: *Sheet, index: PosInt) ?Row.Handle {
    const handle = sheet.rows.search(.{ .index = index });
    return if (handle.isValid()) handle else null;
}

pub fn getCell(sheet: *Sheet, pos: Position) ?Cell {
    return if (sheet.getCellPtr(pos)) |ptr| ptr.* else null;
}

pub fn getCellPtr(sheet: *Sheet, pos: Position) ?*Cell {
    log.debug("GET {}", .{pos});
    const row = sheet.getRowHandle(pos.y) orelse {
        log.debug("NO ROW", .{});
        return null;
    };
    const col = sheet.getColumnHandle(pos.x) orelse {
        log.debug("NO COL", .{});
        return null;
    };
    const key: Cell = .{
        .row = row,
        .col = col,
    };

    const entry = sheet.cell_treap.getEntryFor(key);
    if (entry.node.get()) |n|
        return &sheet.cell_treap.node(n).key;

    log.debug(
        "NO NODE FOR {}, HAVE {}",
        .{ pos, sheet.cell_treap.nodes.items[0].key.position(sheet) },
    );
    return null;
}

pub fn getCellHandleByRef(sheet: *Sheet, ref: Reference) ?CellHandle {
    const entry = sheet.cell_treap.getEntryFor(.{
        .row = ref.row,
        .col = ref.col,
    });
    return entry.node.get();
}

pub fn update(sheet: *Sheet) Allocator.Error!void {
    if (!sheet.needsUpdate()) return;

    log.debug("Updating cells...", .{});
    var timer = if (builtin.mode == .Debug)
        std.time.Timer.start() catch unreachable
    else {};

    defer sheet.queued_cells.clearRetainingCapacity();

    log.debug("Marking dirty cells", .{});

    var sfa = std.heap.stackFallback(16384, sheet.allocator);
    var dirty_cells: std.ArrayList(CellHandle) = .init(sfa.get());
    defer dirty_cells.deinit();

    for (sheet.queued_cells.items) |cell| {
        try sheet.markDirty(cell, &dirty_cells);
    }

    while (dirty_cells.popOrNull()) |cell| {
        try sheet.markDirty(cell, &dirty_cells);
    }
    log.debug("Finished marking", .{});

    // All dirty cells are reachable from the cells in queued_cells
    while (sheet.queued_cells.popOrNull()) |handle| {
        _ = sheet.evalCellByHandle(handle) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CyclicalReference => {
                const cell = sheet.getCellFromHandle(handle);
                log.info("Cyclical reference encountered while evaluating {}", .{
                    cell.rect(sheet).tl,
                });
            },
            else => {},
        };
    }

    if (builtin.mode == .Debug) {
        log.debug("Finished cell update in {d} ms", .{
            @as(f64, @floatFromInt(timer.read())) / std.time.ns_per_ms,
        });
    }
}

/// Marks the cell at `pos` as needing to be updated.
pub fn enqueueUpdate(
    sheet: *Sheet,
    handle: CellHandle,
) Allocator.Error!void {
    try sheet.queued_cells.append(sheet.allocator, handle);
    sheet.getCellFromHandle(handle).state = .enqueued;
}

/// Marks all of the dependents of `pos` as dirty. Any children that also need to be marked dirty
/// are appended to `dirty_cells`. This was previously done recursively which resulted in a stack
/// overflow on large sheets.
fn markDirty(
    sheet: *Sheet,
    handle: CellHandle,
    dirty_cells: *std.ArrayList(CellHandle),
) Allocator.Error!void {
    const cell = &sheet.cell_treap.node(handle).key;
    sheet.search_buffer.clearRetainingCapacity();
    try sheet.dependents.rtree.searchBuffer(
        sheet.allocator,
        &sheet.search_buffer,
        Rect.initSinglePos(cell.position(sheet)),
    );

    for (sheet.search_buffer.items) |list_index| {
        const items = sheet.dependents.flat.items(list_index);
        for (items) |h| {
            const c = &sheet.cell_treap.node(h).key;
            if (c.state != .dirty) {
                log.debug("Marked {} as dirty", .{c.position(sheet)});
                c.state = .dirty;
                try dirty_cells.append(h);
            }
        }
    }
}

pub fn getFilePath(sheet: *const Sheet) []const u8 {
    return sheet.filepath.constSlice();
}

// TODO: Allow for renaming sheets.

/// Returns the name of the sheet.
/// Currently this is the basename of the filepath, with the extension
/// stripped.
pub fn getName(sheet: *const Sheet) []const u8 {
    return std.fs.path.stem(sheet.getFilePath());
}

pub fn setFilePath(sheet: *Sheet, filepath: []const u8) void {
    sheet.filepath.len = 0;
    sheet.filepath.appendSliceAssumeCapacity(filepath);
}

pub fn cellStringValue(sheet: *Sheet, cell: *const Cell) []const u8 {
    assert(cell.value_type == .string);
    return sheet.string_values.items(cell.value.string);
}

pub fn freeCellString(sheet: *Sheet, cell: *Cell) void {
    assert(cell.value_type == .string);
    sheet.string_values.destroyList(cell.value.string);
}

pub fn setCellError(sheet: *Sheet, cell: *Cell) void {
    if (cell.value_type == .string)
        sheet.string_values.destroyList(cell.value.string);

    cell.setValue(.err, .fromError(error.NotEvaluable));
}

pub const Cell = extern struct {
    row: Row.Handle,
    col: Column.Handle,

    /// Cached value of the cell
    value: Value = .{ .err = .fromError(error.NotEvaluable) },

    /// Tag denoting the type of value. A tagged union would add extra unnecessary padding.
    value_type: Value.Tag = .err,

    /// State used for evaluating cells.
    state: enum(u8) {
        up_to_date,
        dirty,
        enqueued,
        computing,
    } = .up_to_date,

    /// Abstract syntax tree representing the expression in the cell.
    expr_root: ast.Index = .invalid,

    strings: StringIndex = .invalid,

    // Non-extern unions get a hidden tag in safe builds which makes serialising them annoying.
    // So we use an extern union here.
    pub const Value = extern union {
        number: f64,
        string: FlatListPool(u8).List.Index,
        err: Error,

        pub const Tag = blk: {
            const t = @typeInfo(std.meta.FieldEnum(Value)).@"enum";
            break :blk @Type(.{ .@"enum" = .{
                .tag_type = u8,
                .fields = t.fields,
                .decls = &.{},
                .is_exhaustive = t.is_exhaustive,
            } });
        };
    };

    pub const Error = extern struct {
        tag: Tag,

        pub const Tag = blk: {
            const t = @typeInfo(std.meta.FieldEnum(ast.EvalError));
            break :blk @Type(.{
                .@"enum" = .{
                    .tag_type = u8,
                    .fields = t.@"enum".fields,
                    .decls = &.{},
                    .is_exhaustive = true,
                },
            });
        };

        pub fn fromError(err: ast.EvalError) Error {
            return switch (err) {
                inline else => |e| .{ .tag = @field(Tag, @errorName(e)) },
            };
        }

        pub fn getError(e: Error) ast.EvalError {
            return switch (e.tag) {
                inline else => |tag| @field(ast.EvalError, @tagName(tag)),
            };
        }
    };

    pub fn reference(cell: *const Cell) Reference {
        return .{
            .row = cell.row,
            .col = cell.col,
        };
    }

    pub fn range(cell: *const Cell) Range {
        return .{ .tl = cell.reference(), .br = cell.reference() };
    }

    pub inline fn position(cell: Cell, sheet: *Sheet) Position {
        return .{
            .x = sheet.cols.get(cell.col).?.index,
            .y = sheet.rows.get(cell.row).?.index,
        };
    }

    pub inline fn eql(a: *const Cell, b: *const Cell) bool {
        return a.row == b.row and a.col == b.col;
    }

    pub inline fn rect(cell: Cell, sheet: *Sheet) Rect {
        return .{
            .tl = cell.position(sheet),
            .br = cell.position(sheet),
        };
    }

    pub fn node(cell: *Cell) *CellTreap.Node {
        return @fieldParentPtr("key", cell);
    }

    fn compare(a: Cell, b: Cell) std.math.Order {
        const a_key: u64 = @bitCast(a.reference());
        const b_key: u64 = @bitCast(b.reference());
        return std.math.order(a_key, b_key);
    }

    pub fn fromExpression(sheet: *Sheet, expr: []const u8) !Cell {
        return .{ .expr_root = try ast.fromExpression(sheet, expr) };
    }

    pub fn isError(cell: Cell) bool {
        return cell.value_type == .err;
    }

    pub fn setValue(cell: *Cell, comptime tag: Value.Tag, value: @FieldType(Value, @tagName(tag))) void {
        cell.value = @unionInit(Value, @tagName(tag), value);
        cell.value_type = tag;
    }
};

/// Queues the dependents of `ref` for update.
fn queueDependents(sheet: *Sheet, ref: Reference) Allocator.Error!void {
    sheet.search_buffer.clearRetainingCapacity();
    try sheet.dependents.rtree.searchBuffer(
        sheet.allocator,
        &sheet.search_buffer,
        ref.rect(sheet),
    );

    for (sheet.search_buffer.items) |list_index| {
        const values = sheet.dependents.flat.items(list_index);
        for (values) |handle| {
            const cell = &sheet.cell_treap.node(handle).key;
            if (cell.state == .dirty) {
                cell.state = .enqueued;
                try sheet.queued_cells.append(sheet.allocator, handle);
            }
        }
    }
}
pub fn evalCellByHandle(sheet: *Sheet, handle: CellHandle) ast.EvalError!ast.EvalResult {
    const cell = sheet.getCellFromHandle(handle);
    log.debug("Evaluating cell {}", .{cell.rect(sheet)});
    switch (cell.state) {
        .up_to_date => {},
        .computing => return error.CyclicalReference,
        .enqueued, .dirty => {
            cell.state = .computing;

            // Queue dependents before evaluating to ensure that errors are propagated to
            // dependents.
            try sheet.queueDependents(cell.reference());

            // Evaluate
            const res = ast.eval(
                sheet.ast_nodes,
                cell.expr_root,
                sheet,
                sheet.strings_buf.items,
                sheet,
            ) catch |err| {
                cell.setValue(.err, Cell.Error.fromError(err));
                return err;
            };

            if (cell.value_type == .string)
                sheet.string_values.destroyList(cell.value.string);

            switch (res) {
                .none => cell.setValue(.number, 0),
                .number => |n| cell.setValue(.number, n),
                .string => |str| {
                    defer sheet.allocator.free(str);
                    try sheet.string_values.ensureUnusedCapacity(sheet.allocator, str.len);
                    const list = try sheet.string_values.createList(sheet.allocator);
                    sheet.string_values.appendSliceAssumeCapacity(list, str);
                    cell.setValue(.string, list);
                },
            }
            cell.state = .up_to_date;
        },
    }

    return switch (cell.value_type) {
        .number => .{ .number = cell.value.number },
        .string => .{ .cell_string = .{
            .sheet = sheet,
            .list_index = cell.value.string,
        } },
        .err => cell.value.err.getError(),
    };
}

/// Evaluates a cell and all of its dependencies.
pub fn evalCell(sheet: *Sheet, ref: Reference) ast.EvalError!ast.EvalResult {
    const cell = sheet.getCellHandleByRef(ref) orelse {
        try sheet.queueDependents(ref);
        return .none;
    };

    return sheet.evalCellByHandle(cell);
}

pub fn printCellExpression(sheet: *Sheet, pos: Position, writer: anytype) !void {
    const cell = sheet.getCellPtr(pos) orelse return;
    try ast.print(
        sheet.ast_nodes,
        cell.expr_root,
        sheet,
        sheet.strings_buf.items,
        writer,
    );
}

pub const Row = struct {
    index: PosInt,

    pub const Handle = RowAxis.Handle;

    pub const Context = struct {
        pub fn order(_: Context, a: Row, b: Row) std.math.Order {
            return std.math.order(a.index, b.index);
        }
    };
};

pub const Column = struct {
    pub const default_width = 10;

    index: PosInt,
    width: u16 = default_width,
    precision: u8 = 2,

    pub const Handle = ColumnAxis.Handle;

    pub const Context = struct {
        pub fn order(_: Context, a: Column, b: Column) std.math.Order {
            return std.math.order(a.index, b.index);
        }
    };
};

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

pub fn createRow(sheet: *Sheet, index: PosInt) !Row.Handle {
    var handle = sheet.rows.search(.{ .index = index });
    if (!handle.isValid()) {
        log.debug("Creating row {}", .{index});
        handle = try sheet.rows.insert(sheet.allocator, .{ .index = index });
    }

    assert(handle.isValid());
    return handle;
}

pub fn createColumn(sheet: *Sheet, index: PosInt) !Column.Handle {
    var handle = sheet.cols.search(.{ .index = index });
    if (!handle.isValid()) {
        log.debug("Creating column {}", .{index});
        handle = try sheet.cols.insert(sheet.allocator, .{ .index = index });
    }

    assert(handle.isValid());
    return handle;
}

pub fn getColumn(sheet: *Sheet, index: PosInt) ?Column {
    const handle = sheet.cols.search(.{ .index = index });
    return sheet.cols.get(handle);
}

pub fn getColumnHandle(sheet: *Sheet, index: PosInt) ?Column.Handle {
    const handle = sheet.cols.search(.{ .index = index });
    return if (handle.isValid()) handle else null;
}

pub fn widthNeededForColumn(
    sheet: *Sheet,
    column_index: PosInt,
    precision: u8,
    max_width: u16,
) !u16 {
    var width: u16 = Column.default_width;

    var iter = try sheet.cell_tree.searchIterator(sheet.allocator, .{
        .tl = .{ .x = column_index, .y = 0 },
        .br = .{ .x = column_index, .y = std.math.maxInt(PosInt) },
    });
    defer iter.deinit();

    var buf: std.BoundedArray(u8, 512) = .{};
    const writer = buf.writer();
    while (try iter.next()) |kv| {
        const cell = &sheet.cell_treap.node(kv.key).key;
        switch (cell.value_type) {
            .err => {},
            .number => {
                const n = cell.value.number;
                buf.len = 0;
                writer.print("{d:.[1]}", .{ n, precision }) catch unreachable;
                // Numbers are all ASCII, so 1 byte = 1 column
                const len: u16 = @intCast(buf.len);
                if (len > width) {
                    width = len;
                    if (width >= max_width) return width;
                }
            },
            .string => {
                const str = sheet.cellStringValue(cell);
                const w = utils.strWidth(str, max_width);
                if (w > width) {
                    width = w;
                    if (width >= max_width) return width;
                }
            },
        }
    }

    return width;
}

/// Anchors the AST to the given sheet, by replacing all 'dumb' coordinate references with
/// references to the row/column handles in `sheet`.
pub fn anchorAst(sheet: *Sheet, root: ast.Index) Allocator.Error!void {
    const nodes = sheet.ast_nodes;
    const start = ast.leftMostChild(nodes, root);
    const tags = nodes.items(.tag)[start.n .. root.n + 1];
    const data = nodes.items(.data)[start.n .. root.n + 1];

    const pos_count = blk: {
        var count: u32 = 0;
        for (tags) |tag|
            count += @intFromBool(tag == .pos);
        break :blk count;
    };

    if (pos_count == 0) return;

    try sheet.rows.ensureUnusedCapacity(sheet.allocator, pos_count);
    try sheet.cols.ensureUnusedCapacity(sheet.allocator, pos_count);

    for (tags, data) |*tag, *d| {
        if (tag.* == .pos) {
            const row = sheet.createRow(d.pos.y) catch unreachable;
            const col = sheet.createColumn(d.pos.x) catch unreachable;

            const ref: Reference = .{
                .row = row,
                .col = col,
            };

            tag.* = .ref_rel_rel;
            d.* = .{ .ref_rel_rel = ref };
        }
    }
}

const PositionContext = struct {
    pub fn eql(_: PositionContext, p1: Position, p2: Position) bool {
        return p1.y == p2.y and p1.x == p2.x;
    }

    pub fn hash(_: PositionContext, pos: Position) u64 {
        return pos.hash();
    }
};

/// Reference to a specific cell in the sheet. References contain pointers to rows/columns and as
/// such are 'automatically' adjusted when rows/columns are deleted.
pub const Reference = extern struct {
    row: Row.Handle,
    col: Column.Handle,

    pub fn init(row: Row.Handle, col: Column.Handle) Reference {
        return .{ .row = row, .col = col };
    }

    pub inline fn resolve(pos: Reference, sheet: *Sheet) Position {
        return .{
            .x = sheet.cols.get(pos.col).?.index,
            .y = sheet.rows.get(pos.row).?.index,
        };
    }

    pub inline fn rect(ref: Reference, sheet: *Sheet) Rect {
        return .{
            .tl = ref.resolve(sheet),
            .br = ref.resolve(sheet),
        };
    }

    pub fn range(ref: Reference) Range {
        return .{ .tl = ref, .br = ref };
    }

    pub inline fn eql(a: Reference, b: Reference) bool {
        return a.row == b.row and a.col == b.col;
    }
};

pub const Range = extern struct {
    tl: Reference,
    br: Reference,

    pub inline fn rect(r: Range, sheet: *Sheet) Rect {
        return .{
            .tl = r.tl.resolve(sheet),
            .br = r.br.resolve(sheet),
        };
    }

    pub inline fn eql(a: Range, b: Range) bool {
        return Reference.eql(a.tl, b.tl) and Reference.eql(a.br, b.br);
    }

    pub fn range(r: Range) Range {
        return r;
    }

    pub fn fromRect(sheet: *Sheet, r: Rect) Range {
        return .{
            .tl = .{
                .row = sheet.getRowHandle(r.tl.y).?,
                .col = sheet.getColumnHandle(r.tl.x).?,
            },
            .br = .{
                .row = sheet.getRowHandle(r.br.y).?,
                .col = sheet.getColumnHandle(r.br.x).?,
            },
        };
    }
};

test "Sheet basics" {
    const t = std.testing;

    const sheet = try Sheet.create(t.allocator);
    defer sheet.destroy();

    try t.expectEqual(0, sheet.cellCount());
    try t.expectEqualStrings("", sheet.filepath.slice());

    const exprs: []const []const u8 = &.{ "50 + 5", "500 * 2 / 34 + 1", "a0", "a2 * a1" };
    var roots: [4]ast.Index = undefined;
    for (&roots, exprs) |*root, expr| {
        root.* = try ast.fromExpression(sheet, expr);
    }

    for (roots, exprs, 0..) |root, expr, i| {
        try sheet.setCell(.{ .x = 0, .y = @intCast(i) }, expr, root, .{});
    }

    try t.expectEqual(4, sheet.cellCount());

    try sheet.update();

    try sheet.deleteCell(.{ .x = 0, .y = 0 }, .{});

    try t.expectEqual(3, sheet.cellCount());
}

test "setCell allocations" {
    const t = std.testing;
    const Test = struct {
        fn testSetCellAllocs(a: Allocator) !void {
            const sheet = try Sheet.create(a);
            defer sheet.destroy();

            {
                const expr = "a4 * a1 * a3";
                const expr_root = try ast.fromExpression(sheet, expr);
                try sheet.setCell(.{ .x = 0, .y = 0 }, expr, expr_root, .{});
            }

            {
                const expr = "a2 * a1 * a3";
                const expr_root = try ast.fromExpression(sheet, expr);
                try sheet.setCell(.{ .x = 1, .y = 0 }, expr, expr_root, .{});
            }

            try sheet.deleteCell(.{ .x = 0, .y = 0 }, .{});

            try sheet.update();
        }
    };

    try t.checkAllAllocationFailures(t.allocator, Test.testSetCellAllocs, .{});
}

// TODO: Expand test
test "Load file" {
    const t = std.testing;

    const ZC = @import("ZC.zig");
    var zc: ZC = undefined;
    try zc.init(t.allocator, .{ .ui = false });
    defer zc.deinit();

    try zc.setCellString(try Position.fromAddress("B0"), "B0", .{});
    try zc.updateCells();
    try zc.setCellString(try Position.fromAddress("B0"), "C0", .{});
    try zc.updateCells();
    try zc.setCellString(try Position.fromAddress("C0"), "10", .{});
    try zc.updateCells();

    try zc.loadCmd("erm.zc");
    try zc.updateCells();
}

test "Update values" {
    const t = std.testing;
    const sheet = try Sheet.create(t.allocator);
    defer sheet.destroy();

    try sheet.setCell(
        try Position.fromAddress("C0"),
        "@sum(A0:B0)",
        try ast.fromExpression(sheet, "@sum(A0:B0)"),
        .{},
    );

    inline for (0..4) |i| {
        const str = std.fmt.comptimePrint("{d}", .{i});
        try sheet.setCell(
            try Position.fromAddress("A0"),
            str,
            try ast.fromExpression(sheet, str),
            .{},
        );
        try sheet.setCell(
            try Position.fromAddress("B0"),
            "A0",
            try ast.fromExpression(sheet, "A0"),
            .{},
        );
        try sheet.update();
    }
    try sheet.update();
    const cell = sheet.getCellPtr(try Position.fromAddress("C0")).?;
    try t.expectEqual(6.0, cell.value.number);
}

// TODO: This test is dumb, way too broad and slow.
fn testCellEvaluation(a: Allocator) !void {
    const t = std.testing;
    const sheet = try Sheet.create(a);
    defer sheet.destroy();

    const _setCell = struct {
        fn _setCell(
            _sheet: *Sheet,
            pos: Position,
            expr_root: ast.Index,
        ) !void {
            try _sheet.setCell(pos, "", expr_root, .{});
            _sheet.endUndoGroup();
        }
    }._setCell;

    // Set cell values in random order
    try _setCell(sheet, try .fromAddress("B17"), try ast.fromExpression(sheet, "A17+B16"));
    try _setCell(sheet, try .fromAddress("G8"), try ast.fromExpression(sheet, "G7+F8"));
    try _setCell(sheet, try .fromAddress("A9"), try ast.fromExpression(sheet, "A8+1"));
    try _setCell(sheet, try .fromAddress("G11"), try ast.fromExpression(sheet, "G10+F11"));
    try _setCell(sheet, try .fromAddress("E16"), try ast.fromExpression(sheet, "E15+D16"));
    try _setCell(sheet, try .fromAddress("G10"), try ast.fromExpression(sheet, "G9+F10"));
    try _setCell(sheet, try .fromAddress("D2"), try ast.fromExpression(sheet, "D1+C2"));
    try _setCell(sheet, try .fromAddress("F2"), try ast.fromExpression(sheet, "F1+E2"));
    try _setCell(sheet, try .fromAddress("B18"), try ast.fromExpression(sheet, "A18+B17"));
    try _setCell(sheet, try .fromAddress("D15"), try ast.fromExpression(sheet, "D14+C15"));
    try _setCell(sheet, try .fromAddress("D20"), try ast.fromExpression(sheet, "D19+C20"));
    try _setCell(sheet, try .fromAddress("E13"), try ast.fromExpression(sheet, "E12+D13"));
    try _setCell(sheet, try .fromAddress("C12"), try ast.fromExpression(sheet, "C11+B12"));
    try _setCell(sheet, try .fromAddress("A16"), try ast.fromExpression(sheet, "A15+1"));
    try _setCell(sheet, try .fromAddress("A10"), try ast.fromExpression(sheet, "A9+1"));
    try _setCell(sheet, try .fromAddress("C19"), try ast.fromExpression(sheet, "C18+B19"));
    try _setCell(sheet, try .fromAddress("F0"), try ast.fromExpression(sheet, "E0+1"));
    try _setCell(sheet, try .fromAddress("B4"), try ast.fromExpression(sheet, "A4+B3"));
    try _setCell(sheet, try .fromAddress("C11"), try ast.fromExpression(sheet, "C10+B11"));
    try _setCell(sheet, try .fromAddress("B6"), try ast.fromExpression(sheet, "A6+B5"));
    try _setCell(sheet, try .fromAddress("G5"), try ast.fromExpression(sheet, "G4+F5"));
    try _setCell(sheet, try .fromAddress("A18"), try ast.fromExpression(sheet, "A17+1"));
    try _setCell(sheet, try .fromAddress("D1"), try ast.fromExpression(sheet, "D0+C1"));
    try _setCell(sheet, try .fromAddress("G12"), try ast.fromExpression(sheet, "G11+F12"));
    try _setCell(sheet, try .fromAddress("B5"), try ast.fromExpression(sheet, "A5+B4"));
    try _setCell(sheet, try .fromAddress("D4"), try ast.fromExpression(sheet, "D3+C4"));
    try _setCell(sheet, try .fromAddress("A5"), try ast.fromExpression(sheet, "A4+1"));
    try _setCell(sheet, try .fromAddress("A0"), try ast.fromExpression(sheet, "1"));
    try _setCell(sheet, try .fromAddress("D13"), try ast.fromExpression(sheet, "D12+C13"));
    try _setCell(sheet, try .fromAddress("A15"), try ast.fromExpression(sheet, "A14+1"));
    try _setCell(sheet, try .fromAddress("A20"), try ast.fromExpression(sheet, "A19+1"));
    try _setCell(sheet, try .fromAddress("G19"), try ast.fromExpression(sheet, "G18+F19"));
    try _setCell(sheet, try .fromAddress("G13"), try ast.fromExpression(sheet, "G12+F13"));
    try _setCell(sheet, try .fromAddress("G17"), try ast.fromExpression(sheet, "G16+F17"));
    try _setCell(sheet, try .fromAddress("C14"), try ast.fromExpression(sheet, "C13+B14"));
    try _setCell(sheet, try .fromAddress("B8"), try ast.fromExpression(sheet, "A8+B7"));
    try _setCell(sheet, try .fromAddress("D10"), try ast.fromExpression(sheet, "D9+C10"));
    try _setCell(sheet, try .fromAddress("F19"), try ast.fromExpression(sheet, "F18+E19"));
    try _setCell(sheet, try .fromAddress("B11"), try ast.fromExpression(sheet, "A11+B10"));
    try _setCell(sheet, try .fromAddress("F9"), try ast.fromExpression(sheet, "F8+E9"));
    try _setCell(sheet, try .fromAddress("G7"), try ast.fromExpression(sheet, "G6+F7"));
    try _setCell(sheet, try .fromAddress("C10"), try ast.fromExpression(sheet, "C9+B10"));
    try _setCell(sheet, try .fromAddress("C2"), try ast.fromExpression(sheet, "C1+B2"));
    try _setCell(sheet, try .fromAddress("D0"), try ast.fromExpression(sheet, "C0+1"));
    try _setCell(sheet, try .fromAddress("C18"), try ast.fromExpression(sheet, "C17+B18"));
    try _setCell(sheet, try .fromAddress("D6"), try ast.fromExpression(sheet, "D5+C6"));
    try _setCell(sheet, try .fromAddress("C0"), try ast.fromExpression(sheet, "B0+1"));
    try _setCell(sheet, try .fromAddress("B14"), try ast.fromExpression(sheet, "A14+B13"));
    try _setCell(sheet, try .fromAddress("B19"), try ast.fromExpression(sheet, "A19+B18"));
    try _setCell(sheet, try .fromAddress("G16"), try ast.fromExpression(sheet, "G15+F16"));
    try _setCell(sheet, try .fromAddress("C8"), try ast.fromExpression(sheet, "C7+B8"));
    try _setCell(sheet, try .fromAddress("G4"), try ast.fromExpression(sheet, "G3+F4"));
    try _setCell(sheet, try .fromAddress("D18"), try ast.fromExpression(sheet, "D17+C18"));
    try _setCell(sheet, try .fromAddress("E17"), try ast.fromExpression(sheet, "E16+D17"));
    try _setCell(sheet, try .fromAddress("D3"), try ast.fromExpression(sheet, "D2+C3"));
    try _setCell(sheet, try .fromAddress("E20"), try ast.fromExpression(sheet, "E19+D20"));
    try _setCell(sheet, try .fromAddress("C6"), try ast.fromExpression(sheet, "C5+B6"));
    try _setCell(sheet, try .fromAddress("E2"), try ast.fromExpression(sheet, "E1+D2"));
    try _setCell(sheet, try .fromAddress("C1"), try ast.fromExpression(sheet, "C0+B1"));
    try _setCell(sheet, try .fromAddress("D17"), try ast.fromExpression(sheet, "D16+C17"));
    try _setCell(sheet, try .fromAddress("C9"), try ast.fromExpression(sheet, "C8+B9"));
    try _setCell(sheet, try .fromAddress("D12"), try ast.fromExpression(sheet, "D11+C12"));
    try _setCell(sheet, try .fromAddress("F18"), try ast.fromExpression(sheet, "F17+E18"));
    try _setCell(sheet, try .fromAddress("H0"), try ast.fromExpression(sheet, "G0+1"));
    try _setCell(sheet, try .fromAddress("D8"), try ast.fromExpression(sheet, "D7+C8"));
    try _setCell(sheet, try .fromAddress("B12"), try ast.fromExpression(sheet, "A12+B11"));
    try _setCell(sheet, try .fromAddress("E19"), try ast.fromExpression(sheet, "E18+D19"));
    try _setCell(sheet, try .fromAddress("A14"), try ast.fromExpression(sheet, "A13+1"));
    try _setCell(sheet, try .fromAddress("E14"), try ast.fromExpression(sheet, "E13+D14"));
    try _setCell(sheet, try .fromAddress("F14"), try ast.fromExpression(sheet, "F13+E14"));
    try _setCell(sheet, try .fromAddress("A13"), try ast.fromExpression(sheet, "A12+1"));
    try _setCell(sheet, try .fromAddress("A19"), try ast.fromExpression(sheet, "A18+1"));
    try _setCell(sheet, try .fromAddress("A4"), try ast.fromExpression(sheet, "A3+1"));
    try _setCell(sheet, try .fromAddress("F7"), try ast.fromExpression(sheet, "F6+E7"));
    try _setCell(sheet, try .fromAddress("A7"), try ast.fromExpression(sheet, "A6+1"));
    try _setCell(sheet, try .fromAddress("E11"), try ast.fromExpression(sheet, "E10+D11"));
    try _setCell(sheet, try .fromAddress("B1"), try ast.fromExpression(sheet, "A1+B0"));
    try _setCell(sheet, try .fromAddress("A11"), try ast.fromExpression(sheet, "A10+1"));
    try _setCell(sheet, try .fromAddress("B16"), try ast.fromExpression(sheet, "A16+B15"));
    try _setCell(sheet, try .fromAddress("E12"), try ast.fromExpression(sheet, "E11+D12"));
    try _setCell(sheet, try .fromAddress("F11"), try ast.fromExpression(sheet, "F10+E11"));
    try _setCell(sheet, try .fromAddress("F1"), try ast.fromExpression(sheet, "F0+E1"));
    try _setCell(sheet, try .fromAddress("C4"), try ast.fromExpression(sheet, "C3+B4"));
    try _setCell(sheet, try .fromAddress("G20"), try ast.fromExpression(sheet, "G19+F20"));
    try _setCell(sheet, try .fromAddress("F16"), try ast.fromExpression(sheet, "F15+E16"));
    try _setCell(sheet, try .fromAddress("D5"), try ast.fromExpression(sheet, "D4+C5"));
    try _setCell(sheet, try .fromAddress("A17"), try ast.fromExpression(sheet, "A16+1"));
    try _setCell(sheet, try .fromAddress("A22"), try ast.fromExpression(sheet, "@sum(a0:g20)"));
    try _setCell(sheet, try .fromAddress("F4"), try ast.fromExpression(sheet, "F3+E4"));
    try _setCell(sheet, try .fromAddress("B9"), try ast.fromExpression(sheet, "A9+B8"));
    try _setCell(sheet, try .fromAddress("E4"), try ast.fromExpression(sheet, "E3+D4"));
    try _setCell(sheet, try .fromAddress("F13"), try ast.fromExpression(sheet, "F12+E13"));
    try _setCell(sheet, try .fromAddress("A1"), try ast.fromExpression(sheet, "A0+1"));
    try _setCell(sheet, try .fromAddress("F3"), try ast.fromExpression(sheet, "F2+E3"));
    try _setCell(sheet, try .fromAddress("F17"), try ast.fromExpression(sheet, "F16+E17"));
    try _setCell(sheet, try .fromAddress("G14"), try ast.fromExpression(sheet, "G13+F14"));
    try _setCell(sheet, try .fromAddress("D11"), try ast.fromExpression(sheet, "D10+C11"));
    try _setCell(sheet, try .fromAddress("A2"), try ast.fromExpression(sheet, "A1+1"));
    try _setCell(sheet, try .fromAddress("E9"), try ast.fromExpression(sheet, "E8+D9"));
    try _setCell(sheet, try .fromAddress("B15"), try ast.fromExpression(sheet, "A15+B14"));
    try _setCell(sheet, try .fromAddress("E18"), try ast.fromExpression(sheet, "E17+D18"));
    try _setCell(sheet, try .fromAddress("E8"), try ast.fromExpression(sheet, "E7+D8"));
    try _setCell(sheet, try .fromAddress("G18"), try ast.fromExpression(sheet, "G17+F18"));
    try _setCell(sheet, try .fromAddress("A6"), try ast.fromExpression(sheet, "A5+1"));
    try _setCell(sheet, try .fromAddress("C3"), try ast.fromExpression(sheet, "C2+B3"));
    try _setCell(sheet, try .fromAddress("B0"), try ast.fromExpression(sheet, "A0+1"));
    try _setCell(sheet, try .fromAddress("E10"), try ast.fromExpression(sheet, "E9+D10"));
    try _setCell(sheet, try .fromAddress("B7"), try ast.fromExpression(sheet, "A7+B6"));
    try _setCell(sheet, try .fromAddress("C7"), try ast.fromExpression(sheet, "C6+B7"));
    try _setCell(sheet, try .fromAddress("D9"), try ast.fromExpression(sheet, "D8+C9"));
    try _setCell(sheet, try .fromAddress("D14"), try ast.fromExpression(sheet, "D13+C14"));
    try _setCell(sheet, try .fromAddress("B20"), try ast.fromExpression(sheet, "A20+B19"));
    try _setCell(sheet, try .fromAddress("E7"), try ast.fromExpression(sheet, "E6+D7"));
    try _setCell(sheet, try .fromAddress("E0"), try ast.fromExpression(sheet, "D0+1"));
    try _setCell(sheet, try .fromAddress("A3"), try ast.fromExpression(sheet, "A2+1"));
    try _setCell(sheet, try .fromAddress("G9"), try ast.fromExpression(sheet, "G8+F9"));
    try _setCell(sheet, try .fromAddress("C17"), try ast.fromExpression(sheet, "C16+B17"));
    try _setCell(sheet, try .fromAddress("F5"), try ast.fromExpression(sheet, "F4+E5"));
    try _setCell(sheet, try .fromAddress("F6"), try ast.fromExpression(sheet, "F5+E6"));
    try _setCell(sheet, try .fromAddress("G3"), try ast.fromExpression(sheet, "G2+F3"));
    try _setCell(sheet, try .fromAddress("E5"), try ast.fromExpression(sheet, "E4+D5"));
    try _setCell(sheet, try .fromAddress("A8"), try ast.fromExpression(sheet, "A7+1"));
    try _setCell(sheet, try .fromAddress("B13"), try ast.fromExpression(sheet, "A13+B12"));
    try _setCell(sheet, try .fromAddress("B3"), try ast.fromExpression(sheet, "A3+B2"));
    try _setCell(sheet, try .fromAddress("D19"), try ast.fromExpression(sheet, "D18+C19"));
    try _setCell(sheet, try .fromAddress("B2"), try ast.fromExpression(sheet, "A2+B1"));
    try _setCell(sheet, try .fromAddress("C5"), try ast.fromExpression(sheet, "C4+B5"));
    try _setCell(sheet, try .fromAddress("G6"), try ast.fromExpression(sheet, "G5+F6"));
    try _setCell(sheet, try .fromAddress("F12"), try ast.fromExpression(sheet, "F11+E12"));
    try _setCell(sheet, try .fromAddress("E1"), try ast.fromExpression(sheet, "E0+D1"));
    try _setCell(sheet, try .fromAddress("C15"), try ast.fromExpression(sheet, "C14+B15"));
    try _setCell(sheet, try .fromAddress("A12"), try ast.fromExpression(sheet, "A11+1"));
    try _setCell(sheet, try .fromAddress("G1"), try ast.fromExpression(sheet, "G0+F1"));
    try _setCell(sheet, try .fromAddress("D16"), try ast.fromExpression(sheet, "D15+C16"));
    try _setCell(sheet, try .fromAddress("F20"), try ast.fromExpression(sheet, "F19+E20"));
    try _setCell(sheet, try .fromAddress("E6"), try ast.fromExpression(sheet, "E5+D6"));
    try _setCell(sheet, try .fromAddress("E15"), try ast.fromExpression(sheet, "E14+D15"));
    try _setCell(sheet, try .fromAddress("F8"), try ast.fromExpression(sheet, "F7+E8"));
    try _setCell(sheet, try .fromAddress("F10"), try ast.fromExpression(sheet, "F9+E10"));
    try _setCell(sheet, try .fromAddress("C16"), try ast.fromExpression(sheet, "C15+B16"));
    try _setCell(sheet, try .fromAddress("C20"), try ast.fromExpression(sheet, "C19+B20"));
    try _setCell(sheet, try .fromAddress("E3"), try ast.fromExpression(sheet, "E2+D3"));
    try _setCell(sheet, try .fromAddress("B10"), try ast.fromExpression(sheet, "A10+B9"));
    try _setCell(sheet, try .fromAddress("G2"), try ast.fromExpression(sheet, "G1+F2"));
    try _setCell(sheet, try .fromAddress("D7"), try ast.fromExpression(sheet, "D6+C7"));
    try _setCell(sheet, try .fromAddress("G15"), try ast.fromExpression(sheet, "G14+F15"));
    try _setCell(sheet, try .fromAddress("G0"), try ast.fromExpression(sheet, "F0+1"));
    try _setCell(sheet, try .fromAddress("F15"), try ast.fromExpression(sheet, "F14+E15"));
    try _setCell(sheet, try .fromAddress("C13"), try ast.fromExpression(sheet, "C12+B13"));

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

    try testCell(sheet, "A0", 1.00);
    try testCell(sheet, "B0", 2.00);
    try testCell(sheet, "C0", 3.00);
    try testCell(sheet, "D0", 4.00);
    try testCell(sheet, "E0", 5.00);
    try testCell(sheet, "F0", 6.00);
    try testCell(sheet, "G0", 7.00);
    try testCell(sheet, "H0", 8.00);
    try testCell(sheet, "A1", 2.00);
    try testCell(sheet, "B1", 4.00);
    try testCell(sheet, "C1", 7.00);
    try testCell(sheet, "D1", 11.00);
    try testCell(sheet, "E1", 16.00);
    try testCell(sheet, "F1", 22.00);
    try testCell(sheet, "G1", 29.00);
    try testCell(sheet, "A2", 3.00);
    try testCell(sheet, "B2", 7.00);
    try testCell(sheet, "C2", 14.00);
    try testCell(sheet, "D2", 25.00);
    try testCell(sheet, "E2", 41.00);
    try testCell(sheet, "F2", 63.00);
    try testCell(sheet, "G2", 92.00);
    try testCell(sheet, "A3", 4.00);
    try testCell(sheet, "B3", 11.00);
    try testCell(sheet, "C3", 25.00);
    try testCell(sheet, "D3", 50.00);
    try testCell(sheet, "E3", 91.00);
    try testCell(sheet, "F3", 154.00);
    try testCell(sheet, "G3", 246.00);
    try testCell(sheet, "A4", 5.00);
    try testCell(sheet, "B4", 16.00);
    try testCell(sheet, "C4", 41.00);
    try testCell(sheet, "D4", 91.00);
    try testCell(sheet, "E4", 182.00);
    try testCell(sheet, "F4", 336.00);
    try testCell(sheet, "G4", 582.00);
    try testCell(sheet, "A5", 6.00);
    try testCell(sheet, "B5", 22.00);
    try testCell(sheet, "C5", 63.00);
    try testCell(sheet, "D5", 154.00);
    try testCell(sheet, "E5", 336.00);
    try testCell(sheet, "F5", 672.00);
    try testCell(sheet, "G5", 1254.00);
    try testCell(sheet, "A6", 7.00);
    try testCell(sheet, "B6", 29.00);
    try testCell(sheet, "C6", 92.00);
    try testCell(sheet, "D6", 246.00);
    try testCell(sheet, "E6", 582.00);
    try testCell(sheet, "F6", 1254.00);
    try testCell(sheet, "G6", 2508.00);
    try testCell(sheet, "A7", 8.00);
    try testCell(sheet, "B7", 37.00);
    try testCell(sheet, "C7", 129.00);
    try testCell(sheet, "D7", 375.00);
    try testCell(sheet, "E7", 957.00);
    try testCell(sheet, "F7", 2211.00);
    try testCell(sheet, "G7", 4719.00);
    try testCell(sheet, "A8", 9.00);
    try testCell(sheet, "B8", 46.00);
    try testCell(sheet, "C8", 175.00);
    try testCell(sheet, "D8", 550.00);
    try testCell(sheet, "E8", 1507.00);
    try testCell(sheet, "F8", 3718.00);
    try testCell(sheet, "G8", 8437.00);
    try testCell(sheet, "A9", 10.00);
    try testCell(sheet, "B9", 56.00);
    try testCell(sheet, "C9", 231.00);
    try testCell(sheet, "D9", 781.00);
    try testCell(sheet, "E9", 2288.00);
    try testCell(sheet, "F9", 6006.00);
    try testCell(sheet, "G9", 14443.00);
    try testCell(sheet, "A10", 11.00);
    try testCell(sheet, "B10", 67.00);
    try testCell(sheet, "C10", 298.00);
    try testCell(sheet, "D10", 1079.00);
    try testCell(sheet, "E10", 3367.00);
    try testCell(sheet, "F10", 9373.00);
    try testCell(sheet, "G10", 23816.00);
    try testCell(sheet, "A11", 12.00);
    try testCell(sheet, "B11", 79.00);
    try testCell(sheet, "C11", 377.00);
    try testCell(sheet, "D11", 1456.00);
    try testCell(sheet, "E11", 4823.00);
    try testCell(sheet, "F11", 14196.00);
    try testCell(sheet, "G11", 38012.00);
    try testCell(sheet, "A12", 13.00);
    try testCell(sheet, "B12", 92.00);
    try testCell(sheet, "C12", 469.00);
    try testCell(sheet, "D12", 1925.00);
    try testCell(sheet, "E12", 6748.00);
    try testCell(sheet, "F12", 20944.00);
    try testCell(sheet, "G12", 58956.00);
    try testCell(sheet, "A13", 14.00);
    try testCell(sheet, "B13", 106.00);
    try testCell(sheet, "C13", 575.00);
    try testCell(sheet, "D13", 2500.00);
    try testCell(sheet, "E13", 9248.00);
    try testCell(sheet, "F13", 30192.00);
    try testCell(sheet, "G13", 89148.00);
    try testCell(sheet, "A14", 15.00);
    try testCell(sheet, "B14", 121.00);
    try testCell(sheet, "C14", 696.00);
    try testCell(sheet, "D14", 3196.00);
    try testCell(sheet, "E14", 12444.00);
    try testCell(sheet, "F14", 42636.00);
    try testCell(sheet, "G14", 131784.00);
    try testCell(sheet, "A15", 16.00);
    try testCell(sheet, "B15", 137.00);
    try testCell(sheet, "C15", 833.00);
    try testCell(sheet, "D15", 4029.00);
    try testCell(sheet, "E15", 16473.00);
    try testCell(sheet, "F15", 59109.00);
    try testCell(sheet, "G15", 190893.00);
    try testCell(sheet, "A16", 17.00);
    try testCell(sheet, "B16", 154.00);
    try testCell(sheet, "C16", 987.00);
    try testCell(sheet, "D16", 5016.00);
    try testCell(sheet, "E16", 21489.00);
    try testCell(sheet, "F16", 80598.00);
    try testCell(sheet, "G16", 271491.00);
    try testCell(sheet, "A17", 18.00);
    try testCell(sheet, "B17", 172.00);
    try testCell(sheet, "C17", 1159.00);
    try testCell(sheet, "D17", 6175.00);
    try testCell(sheet, "E17", 27664.00);
    try testCell(sheet, "F17", 108262.00);
    try testCell(sheet, "G17", 379753.00);
    try testCell(sheet, "A18", 19.00);
    try testCell(sheet, "B18", 191.00);
    try testCell(sheet, "C18", 1350.00);
    try testCell(sheet, "D18", 7525.00);
    try testCell(sheet, "E18", 35189.00);
    try testCell(sheet, "F18", 143451.00);
    try testCell(sheet, "G18", 523204.00);
    try testCell(sheet, "A19", 20.00);
    try testCell(sheet, "B19", 211.00);
    try testCell(sheet, "C19", 1561.00);
    try testCell(sheet, "D19", 9086.00);
    try testCell(sheet, "E19", 44275.00);
    try testCell(sheet, "F19", 187726.00);
    try testCell(sheet, "G19", 710930.00);
    try testCell(sheet, "A20", 21.00);
    try testCell(sheet, "B20", 232.00);
    try testCell(sheet, "C20", 1793.00);
    try testCell(sheet, "D20", 10879.00);
    try testCell(sheet, "E20", 55154.00);
    try testCell(sheet, "F20", 242880.00);
    try testCell(sheet, "G20", 953810.00);
    try testCell(sheet, "A22", 4668856.00);

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

    var fbs = std.io.fixedBufferStream(commands);
    try sheet.interpretFile(fbs.reader().any());
    try sheet.update();

    // Only checks the eval results of some of the cells, checking all is kinda slow
    const strings = @embedFile("strings.csv");
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
        std.debug.print("Expected cell {} to not exist\n", .{pos});
        return error.CellExists;
    }
}

pub fn expectRangeNonExtant(sheet: *Sheet, address: []const u8) !void {
    var iter = std.mem.tokenizeScalar(u8, address, ':');
    const tl = iter.next() orelse return error.MalformedAddress;
    const br = iter.next() orelse return error.MalformedAddress;
    const rect: Rect = .initPos(
        try .fromAddress(tl),
        try .fromAddress(br),
    );

    var sfa = std.heap.stackFallback(4096, sheet.allocator);
    const a = sfa.get();

    const items = try sheet.cell_tree.search(a, rect);
    defer a.free(items);

    if (items.len != 0) {
        var bw = std.io.bufferedWriter(std.io.getStdErr().writer());
        const w = bw.writer();
        try w.print("Expected cells {} to not exist, found", .{rect});
        for (items) |item| {
            const handle = item.key;
            const cell = sheet.getCellFromHandle(handle);
            try w.print(" {}", .{cell.position(sheet)});
        }
        try w.writeByte('\n');
        try bw.flush();
        return error.CellExists;
    }
}

pub fn expectCellEquals(sheet: *Sheet, address: []const u8, expected_value: f64) !void {
    const pos: Position = try .fromAddress(address);
    const cell = sheet.getCellPtr(pos) orelse return error.CellNotFound;
    if (cell.value_type != .number) {
        std.debug.print(
            "Cell {} has value type {}, expected number\n",
            .{ pos, cell.value_type },
        );
        return error.TestExpectedCellsEql;
    }
    if (!std.math.approxEqRel(f64, expected_value, cell.value.number, 0.001)) {
        std.debug.print(
            "Cell {} with value {d} not within tolerance of expected value {d}\n",
            .{ pos, cell.value.number, expected_value },
        );
        return error.TestExpectedCellsEql;
    }
}

pub fn expectCellEqualsString(sheet: *Sheet, address: []const u8, expected_value: []const u8) !void {
    const pos: Position = try .fromAddress(address);
    const cell = sheet.getCellPtr(pos) orelse return error.CellNotFound;
    if (cell.value_type != .string) {
        std.debug.print("Cell {} has value type {}, expected string '{s}'\n", .{
            pos, cell.value_type, expected_value,
        });
        return error.TestExpectedCellsEqlStrings;
    }
    const str = sheet.string_values.items(cell.value.string);
    if (!std.mem.eql(u8, expected_value, str)) {
        std.debug.print("Cell {} does not have expected string value\n", .{pos});
        return std.testing.expectEqualStrings(expected_value, str);
    }
}

pub fn expectCellError(sheet: *Sheet, address: []const u8) !void {
    const pos: Position = try .fromAddress(address);
    const cell = sheet.getCellPtr(pos) orelse return error.CellNotFound;
    if (!cell.isError()) {
        std.debug.print("Expected cell {} to have error, but has value type {}\n", .{
            pos, cell.value_type,
        });
        return error.UnexpectedValue;
    }
}

test "Cell error propagation" {
    const sheet = try Sheet.create(std.testing.allocator);
    defer sheet.destroy();

    try sheet.setCell(
        .fromValidAddress("A0"),
        "10",
        try ast.fromExpression(sheet, "10"),
        .{},
    );

    try sheet.update();
    try expectCellEquals(sheet, "A0", 10);

    try sheet.setCell(
        .fromValidAddress("B0"),
        "A0",
        try ast.fromExpression(sheet, "A0"),
        .{},
    );

    try sheet.update();
    try expectCellEquals(sheet, "B0", 10);

    try sheet.setCell(
        .fromValidAddress("A0"),
        "A0",
        try ast.fromExpression(sheet, "A0"),
        .{},
    );

    try sheet.update();
    try expectCellError(sheet, "A0");
    try expectCellError(sheet, "B0");
}

test "DupeStrings" {
    const t = std.testing;
    const sheet = try Sheet.create(t.allocator);
    defer sheet.destroy();

    {
        const source = "let a0 = 'this is epic' # 'nice' # 'string!'";
        const expr_root = try ast.fromSource(sheet, source);

        try sheet.strings_buf.ensureUnusedCapacity(sheet.allocator, source.len);
        const strings = sheet.dupeAstStrings(
            source,
            sheet.ast_nodes,
            expr_root,
        );

        try t.expectEqualStrings("this is epicnicestring!", sheet.getStringSlice(strings));
    }

    {
        const source = "let a0 = b0";
        const expr_root = try ast.fromSource(sheet, source);

        try sheet.strings_buf.ensureUnusedCapacity(sheet.allocator, source.len);
        const strings = sheet.dupeAstStrings(
            source,
            sheet.ast_nodes,
            expr_root,
        );
        try t.expectEqualStrings("", sheet.getStringSlice(strings));
    }
}

test "Overwrite with string" {
    const t = std.testing;
    const sheet = try Sheet.create(t.allocator);
    defer sheet.destroy();

    inline for (.{
        .{ "A0", "'one'" },
        .{ "A0", "'two'" },
    }) |data| {
        const address, const source = data;
        try sheet.setCell(
            .fromValidAddress(address),
            source,
            try ast.fromExpression(sheet, source),
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
    const sheet = try Sheet.create(t.allocator);
    defer sheet.destroy();

    inline for (.{
        .{ "A0", "'one'" },
        .{ "A0", "B0" },
    }) |data| {
        const address, const source = data;
        try sheet.setCell(
            .fromValidAddress(address),
            source,
            try ast.fromExpression(sheet, source),
            .{},
        );

        try sheet.update();
    }
}

pub fn printCellDependents(sheet: *Sheet, address: []const u8) !void {
    const pos = Position.fromValidAddress(address);
    var iter = try sheet.dependents.searchIterator(sheet.allocator, .{ .tl = pos, .br = pos });
    defer iter.deinit();

    while (try iter.next()) |item| {
        const slice = sheet.dependents.flat.items(item.value_ptr.*);
        log.debug("{} is depended on by", .{pos});
        for (slice) |handle| {
            log.debug("    {} ({d})", .{
                sheet.cell_treap.node(handle).key.rect(sheet),
                handle.n,
            });
        }
    }
}

fn testSetCell(sheet: *Sheet, address: []const u8, expr: []const u8) !void {
    try sheet.setCell(.fromValidAddress(address), expr, try ast.fromExpression(sheet, expr), .{});
}

fn testSetCellPos(sheet: *Sheet, pos: Position, expr: []const u8) !void {
    try sheet.setCell(pos, expr, try ast.fromExpression(sheet, expr), .{});
}

test "Dependencies" {
    const bytes =
        \\ let A0 = 10
        \\ let B0 = 20
        \\ let A1 = A0 * 2
        \\ let B1 = B0 * 2
    ;

    var fbs = std.io.fixedBufferStream(bytes);

    const sheet = try create(std.testing.allocator);
    defer sheet.destroy();

    try sheet.interpretFile(fbs.reader().any());
    try sheet.update();

    try testSetCell(sheet, "A2", "A0 * 3");
    try sheet.update();

    try testSetCell(sheet, "b0", "2");
    try sheet.update();

    try expectCellEquals(sheet, "A0", 10);
    try expectCellEquals(sheet, "A1", 20);
    try expectCellEquals(sheet, "A2", 30);
    try expectCellEquals(sheet, "B0", 2);
    try expectCellEquals(sheet, "B1", 4);
}

test "Fuzzer input" {
    if (true) return error.SkipZigTest;
    const file = std.fs.cwd().openFile("sheet-fuzz-out", .{ .mode = .read_write }) catch
        return error.SkipZigTest;
    defer file.close();

    const len = try file.reader().readInt(u64, .little);
    var buf: [4096]u8 = undefined;
    const bytes_read = try file.readAll(buf[0..len]);
    if (bytes_read != len) return error.BadFile;

    try fuzzNumbers(buf[0..len]);
}

fn fuzzNumbers(input: []const u8) !void {
    if (map) |m| {
        const len: *u64 = @ptrCast(m.ptr);
        len.* = input.len;
        @memcpy(m[8..][0..input.len], input);
    }

    const sheet = try create(std.testing.allocator);
    defer sheet.destroy();

    const Operation = union(enum(u1)) {
        insert: extern struct {
            pos: Position,
            number_or_ref: extern union { f: u64, pos: Position },
            rand: bool,
        } align(1),
        delete: Position align(1),
    };

    const slice: []align(1) const Operation = std.mem.bytesAsSlice(
        Operation,
        input[0 .. input.len - input.len % @sizeOf(Operation)],
    );

    for (slice) |t| {
        switch (t) {
            // Insert a random expression
            .insert => |data| {
                const pos: Position = .init(data.pos.x % 5, data.pos.y % 5);

                var buf: std.BoundedArray(u8, 1024) = .{};
                if (data.rand) {
                    try buf.writer().print("{d}", .{data.number_or_ref.f});
                } else {
                    const p: Position = .init(
                        data.number_or_ref.pos.x % 5,
                        data.number_or_ref.pos.y % 5,
                    );
                    try buf.writer().print("{}", .{p});
                }

                const a = try ast.fromExpression(sheet, buf.constSlice());
                try sheet.setCell(pos, buf.constSlice(), a, .{});
            },
            .delete => |pos| {
                try sheet.deleteCell(pos, .{});
            },
        }

        try sheet.update();
    }
}

var map: ?[]align(std.mem.page_size) u8 = null;

test "Fuzz sheet" {
    {
        const file = try std.fs.cwd().createFile("sheet-fuzz-out", .{ .read = true });
        defer file.close();

        try std.posix.ftruncate(file.handle, 4096);
        map = try std.posix.mmap(
            null,
            4096,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );
    }
    try std.testing.fuzz(fuzzNumbers, .{});
}
