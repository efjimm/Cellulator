const std = @import("std");
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
const MultiArrayList = @import("multi_array_list.zig").MultiArrayList;
const RTree = @import("tree.zig").RTree;
const DependentTree = @import("tree.zig").DependentTree;
const SkipList = @import("skip_list.zig").SkipList;

const Sheet = @This();

comptime {
    assert(@sizeOf(u64) <= @sizeOf(Reference));
}

refs: std.ArrayListUnmanaged(union {
    free: u64,
    ref: Reference,
}),

refs_free: u64 = std.math.maxInt(u64),

/// List of cells that need to be re-evaluated.
queued_cells: std.ArrayListUnmanaged(*Cell) = .{},

// TODO: Strings are stored as a part of command history, so index into that instead.
strings: std.AutoHashMapUnmanaged(*CellNode, []const u8) = .{},

/// True if there have been any changes since the last save
has_changes: bool = false,

undos: UndoList = .{},
redos: UndoList = .{},

undo_end_markers: std.AutoHashMapUnmanaged(u32, Marker) = .{},

/// Range tree mapping ranges to a list of ranges that depend on the first.
/// Used to query whether a cell belongs to a range and then update the cells
/// that depend on that range.
rtree: DependentTree(4),
/// Range tree containing just the positions of extant cells.
/// Used for quick lookup of all extant cells in a range.
cell_tree: RTree(*Cell, void, 4),

allocator: Allocator,

/// Cells, rows, and columns must live for the entire life of the sheet in order to support undo/redo.
/// So that means we can use an arena!
arena: Arena.State = .{},

cell_treap: CellTreap = .{},

rows: RowAxis,
cols: ColumnAxis,

search_buffer: std.ArrayListUnmanaged(std.ArrayListUnmanaged(*Cell)) = .{},

filepath: std.BoundedArray(u8, std.fs.max_path_bytes) = .{}, // TODO: Heap allocate this

pub const CellTreap = std.Treap(Cell, Cell.compare);
pub const ColumnAxis = SkipList(Column, 4, Column.Context);
pub const RowAxis = SkipList(Row, 4, Row.Context);

pub fn create(allocator: Allocator) !*Sheet {
    const sheet = try allocator.create(Sheet);
    errdefer allocator.destroy(sheet);

    sheet.* = .{
        .refs = .empty,
        .allocator = allocator,
        .cell_tree = .{ .sheet = sheet },
        .rtree = .init(sheet),
        .rows = .init(1),
        .cols = .init(1),
    };
    assert(sheet.cols.nodes.len == 0);

    return sheet;
}

pub fn destroy(sheet: *Sheet) void {
    var strings_iter = sheet.strings.iterator();
    while (strings_iter.next()) |kv| {
        sheet.allocator.free(kv.value_ptr.*);
    }
    sheet.strings.deinit(sheet.allocator);
    sheet.search_buffer.deinit(sheet.allocator);

    sheet.clearAndFreeUndos(.undo);
    sheet.clearAndFreeUndos(.redo);
    sheet.rtree.deinit(sheet.allocator);
    sheet.cell_tree.deinit(sheet.allocator);

    sheet.queued_cells.deinit(sheet.allocator);
    sheet.undo_end_markers.deinit(sheet.allocator);
    sheet.undos.deinit(sheet.allocator);
    sheet.redos.deinit(sheet.allocator);

    var node_iter = sheet.cell_treap.inorderIterator();
    while (node_iter.next()) |node| {
        node.key.deinit(sheet.allocator, sheet);
    }
    var arena = sheet.arena.promote(sheet.allocator);
    arena.deinit();
    sheet.rows.deinit(sheet.allocator);
    sheet.cols.deinit(sheet.allocator);
    sheet.refs.deinit(sheet.allocator);
    sheet.allocator.destroy(sheet);
}

fn compareAnchor(a: u32, b: u32) std.math.Order {
    return std.math.order(a, b);
}

const CellNode = CellTreap.Node;

fn getArena(sheet: *Sheet) Arena {
    return sheet.arena.promote(sheet.allocator);
}

fn arenaCreate(sheet: *Sheet, comptime T: type) !*T {
    var arena = sheet.getArena();
    defer sheet.arena = arena.state;

    return arena.allocator().create(T);
}

fn arenaDestroy(sheet: *Sheet, ptr: anytype) void {
    var arena = sheet.getArena();
    defer sheet.arena = arena.state;

    arena.allocator().destroy(ptr);
}

fn arenaReset(sheet: *Sheet, mode: Arena.ResetMode) bool {
    var arena = sheet.getArena();
    defer sheet.arena = arena.state;

    return arena.reset(mode);
}

const Marker = packed struct(u2) {
    undo: bool = false,
    redo: bool = false,
};

pub fn isUndoMarker(sheet: *Sheet, index: u32) bool {
    return if (sheet.undo_end_markers.get(index)) |marker| marker.undo else false;
}

pub fn isRedoMarker(sheet: *Sheet, index: u32) bool {
    return if (sheet.undo_end_markers.get(index)) |marker| marker.redo else false;
}

pub const UndoList = MultiArrayList(Undo);
pub const UndoType = enum { undo, redo };

pub const Undo = union(enum) {
    set_cell: struct {
        node: *CellNode,
        strings: []const u8,
    },
    delete_cell: Position,

    set_column_width: struct {
        col: Position.Int,
        width: u16,
    },
    set_column_precision: struct {
        col: Position.Int,
        precision: u8,
    },
    insert_row: PosInt,
    insert_col: PosInt,
    delete_row: PosInt,
    delete_col: PosInt,

    pub fn deinit(u: Undo, sheet: *Sheet) void {
        switch (u) {
            .set_cell => |data| {
                var t = data;
                t.node.key.ast.deinit(sheet.allocator, sheet);
                sheet.allocator.free(t.strings);
            },
            .delete_cell,
            .set_column_width,
            .set_column_precision,
            .insert_row,
            .insert_col,
            .delete_row,
            .delete_col,
            => {},
        }
    }
};

pub fn isEmpty(sheet: *const Sheet) bool {
    return sheet.cell_treap.root == null;
}

fn treapMax(node: *CellNode) *CellNode {
    var current = node;
    while (current.children[1]) |right| current = right;
    return current;
}

fn treapMin(comptime Tree: type, node: *Tree.Node) *Tree.Node {
    var current = node;
    while (current.children[0]) |left| current = left;
    return current;
}

pub fn treapNextNode(
    comptime Tree: type,
    comptime compareFn: anytype,
    entry: Tree.Entry,
) ?*Tree.Node {
    const key = entry.key;
    const node = entry.node;
    const parent = entry.context.inserted_under;

    if (node) |n| {
        if (n.children[1]) |right|
            return treapMin(Tree, right);
    }

    if (parent) |p| {
        if (p.children[0] == node and compareFn(key, p.key) == .lt)
            return parent;
    }

    var p = parent;
    var n = node;
    while (p != null and n == p.?.children[1]) {
        n = p;
        p = p.?.parent;
    }
    return p;
}

pub fn treapPrevNode(key: Position, node: ?*CellNode, parent: ?*CellNode) ?*CellNode {
    if (node) |n| {
        if (n.children[0]) |left| return treapMax(left);
    }

    if (parent) |p| {
        if (p.children[1] == node and Cell.compare(.{ .pos = key }, p.key) == .gt)
            return parent;
    }

    var p = parent;
    var n = node;
    while (p != null and n == p.?.children[0]) {
        n = p;
        p = p.?.parent;
    }
    return p;
}

pub fn clearRetainingCapacity(sheet: *Sheet, context: anytype) void {
    var iter = sheet.cell_treap.inorderIterator();
    while (iter.next()) |node| context.destroyAst(node.key.ast);
    sheet.cell_treap.root = null;
    sheet.rows.clearRetainingCapacity();
    sheet.cols.clearRetainingCapacity();

    sheet.queued_cells.clearRetainingCapacity();

    sheet.cell_tree.deinit(sheet.allocator);
    sheet.cell_tree = .{ .sheet = sheet };

    sheet.rtree.deinit(sheet.allocator);
    sheet.rtree = .init(sheet);

    var strings_iter = sheet.strings.valueIterator();
    while (strings_iter.next()) |string_ptr| {
        sheet.allocator.free(string_ptr.*);
    }

    const undo_slice = sheet.undos.slice();
    for (undo_slice.items(.tags), undo_slice.items(.data)) |tag, data| {
        switch (tag) {
            .set_cell => {
                sheet.allocator.free(data.set_cell.strings);
                context.destroyAst(data.set_cell.node.key.ast);
            },
            .delete_cell,
            .set_column_width,
            .set_column_precision,
            .insert_row,
            .insert_col,
            .delete_row,
            .delete_col,
            => {},
        }
    }

    const redo_slice = sheet.redos.slice();
    for (redo_slice.items(.tags), redo_slice.items(.data)) |tag, data| {
        switch (tag) {
            .set_cell => {
                sheet.allocator.free(data.set_cell.strings);
                context.destroyAst(data.set_cell.node.key.ast);
            },
            .delete_cell,
            .set_column_width,
            .set_column_precision,
            .insert_row,
            .insert_col,
            .delete_row,
            .delete_col,
            => {},
        }
    }

    sheet.undos.len = 0;
    sheet.redos.len = 0;
    sheet.undo_end_markers.clearRetainingCapacity();
    sheet.strings.clearRetainingCapacity();
    _ = sheet.arenaReset(.free_all);
}

pub fn loadFile(sheet: *Sheet, ast_allocator: Allocator, filepath: []const u8, context: anytype) !void {
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

    defer sheet.endUndoGroup();
    while (true) {
        var sfa = std.heap.stackFallback(8192, sheet.allocator);
        const a = sfa.get();

        const line = try reader.readUntilDelimiterOrEofAlloc(a, '\n', std.math.maxInt(u30)) orelse
            break;
        defer a.free(line);

        var ast = context.createAst();
        errdefer context.destroyAst(ast);
        ast.parse(ast_allocator, line) catch |err| switch (err) {
            error.UnexpectedToken,
            error.InvalidCellAddress,
            => {
                context.destroyAst(ast);
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };

        const data = ast.nodes.items(.data);
        const assignment = data[ast.rootNodeIndex()].assignment;
        const pos = data[assignment.lhs].pos;
        ast.splice(assignment.rhs);

        try sheet.setCell(pos, line, ast, .{});
    }
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
    while (iter.next()) |node| {
        const pos = node.key.position(sheet);
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
    ast: Ast.Slice,
    i: u32,

    fn init(sheet: *const Sheet, ast: Ast) ExprRangeIterator {
        return .{
            .ast = ast.toSlice(),
            .i = ast.nodes.len,
            .sheet = sheet,
        };
    }

    fn next(it: *ExprRangeIterator) ?Range {
        if (it.i == 0) return null;

        const slice = it.ast.nodes;
        const data = slice.items(.data);

        var iter = std.mem.reverseIterator(slice.items(.tags)[0..it.i]);
        defer it.i = @intCast(iter.index);

        return while (iter.next()) |tag| switch (tag) {
            .ref => {
                const index = data[iter.index].ref;
                const ref = it.sheet.refs.items[index].ref;
                break .{ .tl = ref, .br = ref };
            },
            .range => {
                const r = data[iter.index].range;
                const ref1 = it.sheet.refs.items[data[r.lhs].ref].ref;
                const ref2 = it.sheet.refs.items[data[r.rhs].ref].ref;
                break .{ .tl = ref1, .br = ref2 };
            },
            else => continue,
        } else null;
    }
};

/// Adds `dependent_range` as a dependent of all cells in `range`.
fn addRangeDependents(
    sheet: *Sheet,
    dependent: *Cell,
    range: Range,
) Allocator.Error!void {
    return sheet.rtree.put(sheet, range, dependent);
}

fn addExpressionDependents(
    sheet: *Sheet,
    dependent: *Cell,
    expr: Ast,
) Allocator.Error!void {
    var iter = ExprRangeIterator.init(sheet, expr);
    while (iter.next()) |range| {
        try sheet.addRangeDependents(dependent, range);
    }
}

/// Removes `cell` as a dependent of all cells in `rect`
fn removeRangeDependents(
    sheet: *Sheet,
    dependent: *Cell,
    range: Range,
) Allocator.Error!void {
    return sheet.rtree.removeValue(sheet, range, dependent);
}

/// Removes `cell` as a dependent of all ranges referenced by `expr`.
fn removeExprDependents(
    sheet: *Sheet,
    dependent: *Cell,
    expr: Ast,
) Allocator.Error!void {
    var iter = ExprRangeIterator.init(sheet, expr);
    while (iter.next()) |range| {
        try sheet.removeRangeDependents(dependent, range);
    }
}

/// Creates any necessary row/column anchors referred to in the expression
fn createAnchorsForExpression(sheet: *Sheet, expr: Ast) Allocator.Error!void {
    var iter = ExprRangeIterator.init(expr);
    while (iter.next()) |range| {
        _ = try sheet.createRow(range.tl.y);
        _ = try sheet.createColumn(range.tl.x);

        if (range.br.y != range.tl.y) _ = try sheet.createRow(range.br.y);
        if (range.br.x != range.tl.x) _ = try sheet.createColumn(range.br.x);
    }
}

pub fn firstCellInRow(sheet: *Sheet, row: Position.Int) !?Position {
    var iter = sheet.cell_tree.searchIterator(sheet.allocator, .{
        .tl = .{ .x = 0, .y = row },
        .br = .{ .x = std.math.maxInt(PosInt), .y = row },
    });
    defer iter.deinit();

    var min: ?PosInt = null;
    while (try iter.next()) |kv| {
        const x = sheet.cols.get(kv.key.col).?.index;
        if (min == null or x < min.?) min = x;
    }

    return if (min) |x| .{ .x = x, .y = row } else null;
}

pub fn lastCellInRow(sheet: *Sheet, row: Position.Int) !?Position {
    var iter = sheet.cell_tree.searchIterator(sheet.allocator, .{
        .tl = .{ .x = 0, .y = row },
        .br = .{ .x = std.math.maxInt(PosInt), .y = row },
    });
    defer iter.deinit();

    var max: ?PosInt = null;
    while (try iter.next()) |kv| {
        const x = sheet.cols.get(kv.key.col).?.index;
        if (max == null or x > max.?) max = x;
    }

    return if (max) |x| .{ .x = x, .y = row } else null;
}

// TODO: Optimize these

pub fn firstCellInColumn(sheet: *Sheet, col: Position.Int) !?Position {
    var iter = sheet.cell_tree.searchIterator(sheet.allocator, .{
        .tl = .{ .x = col, .y = 0 },
        .br = .{ .x = col, .y = std.math.maxInt(PosInt) },
    });
    defer iter.deinit();

    var min: ?PosInt = null;
    while (try iter.next()) |kv| {
        const y = sheet.rows.get(kv.key.row).?.index;
        if (min == null or y < min.?) min = y;
    }

    return if (min) |y| .{ .x = col, .y = y } else null;
}

pub fn lastCellInColumn(sheet: *Sheet, col: Position.Int) !?Position {
    var iter = sheet.cell_tree.searchIterator(sheet.allocator, .{
        .tl = .{ .x = col, .y = 0 },
        .br = .{ .x = col, .y = std.math.maxInt(PosInt) },
    });
    defer iter.deinit();

    var max: ?PosInt = null;
    while (try iter.next()) |kv| {
        const y = sheet.rows.get(kv.key.row).?.index;
        if (max == null or y > max.?) max = y;
    }

    return if (max) |y| .{ .x = col, .y = y } else null;
}

// These functions essentially do a binary search over a range using the cell range tree. It divides
// the range in two, checking if first half has a cell using the range tree. If it does, we divide
// the first side in two, and so on, until the range is one cell wide.

/// Given a range, find the first row that contains a cell
fn findExtantRow(sheet: *Sheet, range: Rect, p: enum { first, last }) !?PosInt {
    var r = range;
    var iter = sheet.cell_tree.searchIterator(sheet.allocator, r);
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

        iter.reset(first, &sheet.cell_tree);
        r = if (try iter.next() != null) first else last;
    } else unreachable;
}

/// Given a range, find the first column that contains a cell
fn findExtantCol(sheet: *Sheet, range: Rect, p: enum { first, last }) !?PosInt {
    var r = range;
    var iter = sheet.cell_tree.searchIterator(sheet.allocator, r);
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

        iter.reset(first, &sheet.cell_tree);
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

pub fn clearAndFreeUndos(sheet: *Sheet, comptime kind: UndoType) void {
    const list = switch (kind) {
        .undo => &sheet.undos,
        .redo => &sheet.redos,
    };

    const slice = list.slice();
    var i: u32 = 0;
    while (i < slice.len) : (i += 1) {
        slice.get(i).deinit(sheet);
    }
    list.len = 0;
    var iter = sheet.undo_end_markers.iterator();
    while (iter.next()) |entry| {
        switch (kind) {
            .undo => entry.value_ptr.undo = false,
            .redo => entry.value_ptr.redo = false,
        }
        if (@as(u2, @bitCast(entry.value_ptr.*)) == 0) {
            sheet.undo_end_markers.removeByPtr(entry.key_ptr);
        }
    }
}

pub fn endUndoGroup(sheet: *Sheet) void {
    if (sheet.undos.len == 0) return;
    const res = sheet.undo_end_markers.getOrPutAssumeCapacity(sheet.undos.len - 1);
    if (res.found_existing) {
        res.value_ptr.undo = true;
    } else {
        res.value_ptr.* = .{
            .undo = true,
        };
    }
}

fn endRedoGroup(sheet: *Sheet) void {
    if (sheet.redos.len == 0) return;
    const res = sheet.undo_end_markers.getOrPutAssumeCapacity(sheet.redos.len - 1);
    if (res.found_existing) {
        res.value_ptr.redo = true;
    } else {
        res.value_ptr.* = .{
            .redo = true,
        };
    }
}

fn unsetUndoEndMarker(sheet: *Sheet, index: u32) void {
    const ptr = sheet.undo_end_markers.getPtr(index).?;
    if (ptr.redo == false) {
        // Both values are now false, remove it from the map
        _ = sheet.undo_end_markers.remove(index);
    } else {
        ptr.undo = false;
    }
}

fn unsetRedoEndMarker(sheet: *Sheet, index: u32) void {
    const ptr = sheet.undo_end_markers.getPtr(index).?;
    if (ptr.undo == false) {
        // Both values are now false, remove it from the map
        _ = sheet.undo_end_markers.remove(index);
    } else {
        ptr.redo = false;
    }
}

pub fn ensureUndoCapacity(sheet: *Sheet, undo_type: UndoType, n: u32) Allocator.Error!void {
    try sheet.undo_end_markers.ensureUnusedCapacity(sheet.allocator, n);
    switch (undo_type) {
        .undo => try sheet.undos.ensureUnusedCapacity(sheet.allocator, n),
        .redo => try sheet.redos.ensureUnusedCapacity(sheet.allocator, n),
    }
}

pub fn pushUndo(sheet: *Sheet, u: Undo, opts: UndoOpts) Allocator.Error!void {
    const undo_type = opts.undo_type orelse return;
    // Ensure that we can add a group end marker later without allocating
    try sheet.undo_end_markers.ensureUnusedCapacity(sheet.allocator, 1);

    switch (undo_type) {
        .undo => {
            try sheet.undos.ensureUnusedCapacity(sheet.allocator, 1);
            sheet.undos.appendAssumeCapacity(u);
            if (opts.clear_redos) sheet.clearAndFreeUndos(.redo);
        },
        .redo => {
            try sheet.redos.append(sheet.allocator, u);
        },
    }
}

pub fn insertColumn(sheet: *Sheet, index: PosInt, undo_opts: UndoOpts) !void {
    try sheet.pushUndo(.{ .delete_col = index }, undo_opts);
    const values = sheet.cols.nodes.items(.value);

    for (values) |*value| {
        if (value.index >= index) {
            value.index += 1;
        }
    }
}

pub fn insertRow(sheet: *Sheet, index: PosInt, undo_opts: UndoOpts) !void {
    try sheet.pushUndo(.{ .delete_row = index }, undo_opts);
    const values = sheet.rows.nodes.items(.value);

    for (values) |*value| {
        if (value.index >= index) {
            value.index += 1;
        }
    }
}

pub fn doUndo(sheet: *Sheet, u: Undo, opts: UndoOpts) Allocator.Error!void {
    switch (u) {
        .set_cell => |t| try sheet.insertCellNode(t.strings, t.node, opts),
        .delete_cell => |pos| try sheet.deleteCell(pos, opts),
        .set_column_width => |t| try sheet.setWidth(t.col, t.width, opts),
        .set_column_precision => |t| try sheet.setPrecision(t.col, t.precision, opts),
        .insert_row => |index| try sheet.insertRow(index, opts),
        .insert_col => |index| try sheet.insertColumn(index, opts),
        .delete_row, .delete_col => {},
    }
}

pub fn undo(sheet: *Sheet) Allocator.Error!void {
    if (sheet.undos.len == 0) return;
    // All undo groups MUST end with a group marker - so remove it!
    sheet.unsetUndoEndMarker(sheet.undos.len - 1);

    defer sheet.endRedoGroup();

    const opts: UndoOpts = .{ .undo_type = .redo };
    while (sheet.undos.popOrNull()) |u| {
        errdefer {
            sheet.undos.appendAssumeCapacity(u);
            sheet.endUndoGroup();
        }
        try sheet.doUndo(u, opts);
        if (sheet.undos.len == 0 or sheet.isUndoMarker(sheet.undos.len - 1)) break;
    }
}

pub fn redo(sheet: *Sheet) Allocator.Error!void {
    if (sheet.redos.len == 0) return;
    // All undo groups MUST end with a group marker - so remove it!
    sheet.unsetRedoEndMarker(sheet.redos.len - 1);

    defer sheet.endUndoGroup();

    const opts: UndoOpts = .{ .clear_redos = false };
    while (sheet.redos.popOrNull()) |u| {
        errdefer {
            sheet.redos.appendAssumeCapacity(u);
            sheet.endRedoGroup();
        }
        try sheet.doUndo(u, opts);
        if (sheet.redos.len == 0 or sheet.isRedoMarker(sheet.redos.len - 1)) break;
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
    const col = sheet.cols.getPtr(handle).?;
    if (width == col.width) return;
    const old_width = col.width;
    col.width = width;
    // TODO: This should be done before the operation?
    try sheet.pushUndo(
        .{
            .set_column_width = .{
                .col = index,
                .width = old_width,
            },
        },
        opts,
    );
    sheet.endUndoGroup();
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
    try sheet.pushUndo(
        .{
            .set_column_precision = .{
                .col = index,
                .precision = old_precision,
            },
        },
        opts,
    );
    sheet.endUndoGroup();
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

/// Creates the cell at `pos` using the given expression, duplicating it's string literals.
pub fn setCell(
    sheet: *Sheet,
    pos: Position,
    source: []const u8,
    ast: Ast,
    undo_opts: UndoOpts,
) Allocator.Error!void {
    // Create row and column if they don't exist
    const row = try sheet.createRow(pos.y);
    const col = try sheet.createColumn(pos.x);

    const new_node = try sheet.arenaCreate(CellNode);
    errdefer sheet.arenaDestroy(new_node);

    const strings = try ast.dupeStrings(sheet.allocator, source);
    errdefer sheet.allocator.free(strings);

    var a = ast;
    try a.anchor(sheet);

    new_node.key = .{
        .row = row,
        .col = col,
        .ast = a,
    };
    return sheet.insertCellNode(strings, new_node, undo_opts);
}

// TODO: This function *really, really* sucks. Clean it up.
// TODO: null undo type causes a memory leak (not used anywhere)
/// Inserts a pre-allocated Cell node. Does not attempt to create any row/column anchors.
pub fn insertCellNode(
    sheet: *Sheet,
    strings: []const u8,
    new_node: *CellNode,
    undo_opts: UndoOpts,
) Allocator.Error!void {
    // TODO: Change this position to be a relative cell reference to this cell
    // This is done???
    const cell_ptr = &new_node.key;
    const pos = new_node.key.position(sheet);
    if (undo_opts.undo_type) |undo_type| {
        try sheet.ensureUndoCapacity(undo_type, 1);
    }
    try sheet.queued_cells.ensureUnusedCapacity(sheet.allocator, 1);

    try sheet.strings.ensureUnusedCapacity(sheet.allocator, 1);

    try sheet.cell_tree.put(sheet, cell_ptr, {});
    errdefer sheet.cell_tree.remove(cell_ptr) catch {};

    var entry = sheet.cell_treap.getEntryFor(new_node.key);
    const node = entry.node orelse {
        log.debug("Creating cell {}", .{new_node.key.rect(sheet).tl});
        try sheet.addExpressionDependents(cell_ptr, new_node.key.ast);
        const u = Undo{ .delete_cell = pos };

        entry.set(new_node);

        sheet.pushUndo(u, undo_opts) catch unreachable;
        sheet.has_changes = true;

        if (strings.len > 0) {
            // NoClobber because cell didn't exist in map, so strings shouldn't exist either
            // TODO: Make relative
            sheet.strings.putAssumeCapacityNoClobber(new_node, strings);
        }
        errdefer _ = sheet.strings.remove(new_node);
        sheet.enqueueUpdate(cell_ptr) catch unreachable;
        return;
    };

    log.debug("Overwriting cell {}", .{node.key.rect(sheet).tl});

    try sheet.removeExprDependents(cell_ptr, cell_ptr.ast);
    try sheet.addExpressionDependents(cell_ptr, cell_ptr.ast);
    errdefer {
        var iter = ExprRangeIterator.init(cell_ptr.ast);
        while (iter.next()) |r| {
            sheet.removeRangeDependents(cell_ptr, r) catch {};
        }
    }

    // Set value in tree to new node
    const cell = new_node.key;
    entry.set(new_node);
    // `entry.set` overwrites the .key field with the old value, for some reason.
    new_node.key = cell;

    const res = sheet.strings.getOrPutAssumeCapacity(new_node);
    const old_strings = if (res.found_existing) res.value_ptr.* else "";
    errdefer if (old_strings.len > 0) sheet.strings.putAssumeCapacity(new_node, old_strings);

    // const uindex = sheet.createUndoAst(node.key.ast, old_strings) catch unreachable;
    // errdefer sheet.undo_asts.destroy(uindex);

    if (strings.len > 0) {
        res.value_ptr.* = strings;
    } else {
        sheet.strings.removeByPtr(res.key_ptr);
    }
    errdefer _ = sheet.strings.removeByPtr(res.key_ptr);

    const u: Undo = .{
        .set_cell = .{
            .node = node,
            .strings = old_strings,
        },
    };
    sheet.pushUndo(u, undo_opts) catch unreachable;

    sheet.enqueueUpdate(cell_ptr) catch unreachable;
    if (node.key.value == .string) {
        sheet.allocator.free(std.mem.span(node.key.value.string));
    }
    sheet.has_changes = true;
}

pub fn deleteCellByPtr(
    sheet: *Sheet,
    cell: *Cell,
    undo_opts: UndoOpts,
) Allocator.Error!void {
    // Assert that this cell actually exists in the cell treap.
    const node = cell.node();
    assert(sheet.cell_treap.getEntryFor(cell.*).node == node);

    if (undo_opts.undo_type) |undo_type| {
        try sheet.ensureUndoCapacity(undo_type, 1);
    }
    try sheet.enqueueUpdate(cell);
    try sheet.removeExprDependents(cell, cell.ast);

    // FIXME: If this allocation fails we are left with an inconsistent state.
    //        This is actually a pain in the ass to fix...
    //        Maybe an RTree function to calculate the amount of mem needed
    //        for a removal ahead of time?
    //
    // TODO:  This is actually easy?
    try sheet.cell_tree.remove(cell);

    // TODO: re-use string buffer
    cell.setError(sheet.allocator);
    utils.treapRemove(CellTreap, &sheet.cell_treap, node);

    const strings = if (sheet.strings.fetchRemove(node)) |kv| kv.value else "";

    sheet.pushUndo(
        .{ .set_cell = .{ .node = node, .strings = strings } },
        undo_opts,
    ) catch unreachable;
    sheet.has_changes = true;
}

pub fn deleteCellByRef(
    sheet: *Sheet,
    ref: Reference,
    undo_opts: UndoOpts,
) Allocator.Error!void {
    const entry = sheet.cell_treap.getEntryFor(.{ .row = ref.row, .col = ref.col });
    const node = entry.node orelse return;
    return sheet.deleteCellByPtr(&node.key, undo_opts);
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
        try sheet.deleteCellByPtr(kv.key, .{});
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
    const row = sheet.getRowHandle(pos.y) orelse return null;
    const col = sheet.getColumnHandle(pos.x) orelse return null;
    const key: Cell = .{
        .row = row,
        .col = col,
    };

    const entry = sheet.cell_treap.getEntryFor(key);
    return if (entry.node) |n| &n.key else null;
}

pub fn getCellPtrByRef(sheet: *Sheet, ref: Reference) ?*Cell {
    const entry = sheet.cell_treap.getEntryFor(.{
        .row = ref.row,
        .col = ref.col,
    });
    return if (entry.node) |n| &n.key else null;
}

pub fn update(sheet: *Sheet) Allocator.Error!void {
    if (!sheet.needsUpdate()) return;

    log.debug("Updating cells...", .{});
    var timer = if (builtin.mode == .Debug)
        std.time.Timer.start() catch unreachable
    else {};

    defer sheet.queued_cells.clearRetainingCapacity();

    log.debug("Marking dirty cells", .{});
    for (sheet.queued_cells.items) |cell| {
        try sheet.markDirty(cell);
    }

    const context = EvalContext{ .sheet = sheet };
    // All dirty cells are reachable from the cells in queued_cells
    while (sheet.queued_cells.popOrNull()) |cell| {
        _ = context.evalCell(.{
            .row = cell.row,
            .col = cell.col,
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.CyclicalReference => {
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
    cell: *Cell,
) Allocator.Error!void {
    try sheet.queued_cells.append(sheet.allocator, cell);
    cell.state = .enqueued;
}

/// Marks all of the dependents of `pos` as dirty.
fn markDirty(
    sheet: *Sheet,
    cell: *Cell,
) Allocator.Error!void {
    sheet.search_buffer.clearRetainingCapacity();
    try sheet.rtree.rtree.searchBuffer(
        sheet.allocator,
        &sheet.search_buffer,
        Rect.initSinglePos(cell.position(sheet)),
    );

    for (sheet.search_buffer.items) |*list| {
        for (list.items) |c| {
            if (c.state != .dirty) {
                c.state = .dirty;
                try sheet.markDirty(c);
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

pub const Cell = struct {
    row: Row.Handle,
    col: Column.Handle,
    value: Value = .{ .err = error.NotEvaluable },
    ast: Ast = .{},
    state: enum {
        up_to_date,
        dirty,
        enqueued,
        computing,
    } = .up_to_date,

    pub const Value = union(enum) {
        number: f64,
        string: [*:0]const u8,
        err: Error,
    };

    pub const Error = Ast.EvalError;

    pub const key_bits = @typeInfo(usize).int.bits * 2;
    pub const Key = std.meta.Int(.unsigned, key_bits);

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

    pub fn node(cell: *Cell) *CellNode {
        return @fieldParentPtr("key", cell);
    }

    fn compare(a: Cell, b: Cell) std.math.Order {
        const a_key = key(a.row, a.col);
        const b_key = key(b.row, b.col);
        return std.math.order(a_key, b_key);
    }

    // TODO: Make sure this is always unique
    fn key(row: Row.Handle, col: Column.Handle) Key {
        assert(row.isValid());
        assert(col.isValid());
        const row_int = row.n;
        const col_int = col.n;
        const row_mul = comptime std.math.pow(Key, 2, @typeInfo(usize).int.bits);
        return row_int * row_mul + col_int;
    }

    pub fn fromExpression(a: Allocator, expr: []const u8) !Cell {
        return .{ .ast = try Ast.fromExpression(a, expr) };
    }

    // TODO: Re-organise functions that take a sheet as not being methods.
    pub fn deinit(cell: *Cell, a: Allocator, sheet: *Sheet) void {
        cell.ast.deinit(a, sheet);
        if (cell.value == .string) a.free(std.mem.span(cell.value.string));
        cell.* = undefined;
    }

    pub fn isError(cell: Cell) bool {
        return cell.value == .err;
    }

    pub fn setError(cell: *Cell, a: Allocator) void {
        if (cell.value == .string) {
            a.free(std.mem.span(cell.value.string));
        }
        cell.value = .{ .err = error.NotEvaluable };
    }

    pub inline fn getValue(cell: Cell) ?f64 {
        return switch (cell.value) {
            .number => |n| n,
            else => null,
        };
    }
};

/// Queues the dependents of `ref` for update.
fn queueDependents(sheet: *Sheet, ref: Reference) Allocator.Error!void {
    sheet.search_buffer.clearRetainingCapacity();
    try sheet.rtree.rtree.searchBuffer(
        sheet.allocator,
        &sheet.search_buffer,
        ref.rect(sheet),
    );

    for (sheet.search_buffer.items) |*value_list| {
        for (value_list.items) |cell| {
            if (cell.state == .dirty) {
                cell.state = .enqueued;
                try sheet.queued_cells.append(sheet.allocator, cell);
            }
        }
    }
}

pub const EvalContext = struct {
    sheet: *Sheet,

    pub fn evalCellByPtr(context: EvalContext, cell: *Cell) Ast.EvalError!Ast.EvalResult {
        switch (cell.state) {
            .up_to_date => {},
            .computing => return error.CyclicalReference,
            .enqueued, .dirty => {
                log.debug("Evaluating cell {}", .{cell.rect(
                    context.sheet,
                )});
                cell.state = .computing;

                // Get strings
                const strings = context.sheet.strings.get(cell.node()) orelse "";

                // Queue dependents before evaluating to ensure that errors are propagated to
                // dependents.
                try context.sheet.queueDependents(cell.reference());

                // Evaluate
                const res = cell.ast.eval(context.sheet, strings, context) catch |err| {
                    cell.value = .{ .err = err };
                    return err;
                };
                if (cell.value == .string)
                    context.sheet.allocator.free(std.mem.span(cell.value.string));
                cell.value = switch (res) {
                    .none => .{ .number = 0 },
                    .string => |str| .{ .string = str.ptr },
                    .number => |n| .{ .number = n },
                };
                cell.state = .up_to_date;
            },
        }

        return switch (cell.value) {
            .number => |n| .{ .number = n },
            .string => |ptr| .{ .string = std.mem.span(ptr) },
            .err => |err| err,
        };
    }

    /// Evaluates a cell and all of its dependencies.
    pub fn evalCell(context: EvalContext, ref: Reference) Ast.EvalError!Ast.EvalResult {
        const cell = context.sheet.getCellPtrByRef(ref) orelse {
            try context.sheet.queueDependents(ref);
            return .none;
        };

        return context.evalCellByPtr(cell);
    }
};

pub fn printCellExpression(sheet: *Sheet, pos: Position, writer: anytype) !void {
    const cell = sheet.getCellPtr(pos) orelse return;
    const strings = sheet.strings.get(cell.node()) orelse "";
    try cell.ast.print(sheet, strings, writer);
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

    var iter = sheet.cell_tree.searchIterator(sheet.allocator, .{
        .tl = .{ .x = column_index, .y = 0 },
        .br = .{ .x = column_index, .y = std.math.maxInt(PosInt) },
    });
    defer iter.deinit();

    var buf: std.BoundedArray(u8, 512) = .{};
    const writer = buf.writer();
    while (try iter.next()) |kv| {
        const cell = kv.key;
        switch (cell.value) {
            .err => {},
            .number => |n| {
                buf.len = 0;
                writer.print("{d:.[1]}", .{ n, precision }) catch unreachable;
                // Numbers are all ASCII, so 1 byte = 1 column
                const len: u16 = @intCast(buf.len);
                if (len > width) {
                    width = len;
                    if (width >= max_width) return width;
                }
            },
            .string => |ptr| {
                const str = std.mem.span(ptr);
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
pub const Reference = struct {
    // TODO: Remove these bools somehow.
    relative_row: bool = false,
    relative_col: bool = false,
    row: Row.Handle,
    col: Column.Handle,

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

pub const Range = struct {
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
    var asts: [4]Ast = undefined;
    for (&asts, exprs) |*ast, expr| {
        ast.* = try Ast.fromExpression(t.allocator, expr);
    }

    for (asts, exprs, 0..) |ast, expr, i| {
        try sheet.setCell(.{ .x = 0, .y = @intCast(i) }, expr, ast, .{});
    }

    try t.expectEqual(4, sheet.cellCount());
    for (asts, 0..) |ast, i| {
        try t.expectEqual(ast.nodes, sheet.getCell(.{ .x = 0, .y = @intCast(i) }).?.ast.nodes);
    }

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
                var ast = try Ast.fromExpression(a, expr);
                errdefer ast.deinit(a, sheet);
                try sheet.setCell(.{ .x = 0, .y = 0 }, expr, ast, .{});
            }

            {
                const expr = "a2 * a1 * a3";
                var ast = try Ast.fromExpression(a, expr);
                errdefer ast.deinit(a, sheet);
                try sheet.setCell(.{ .x = 1, .y = 0 }, expr, ast, .{});
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
        try Ast.fromExpression(t.allocator, "@sum(A0:B0)"),
        .{},
    );

    inline for (0..4) |i| {
        const str = std.fmt.comptimePrint("{d}", .{i});
        try sheet.setCell(
            try Position.fromAddress("A0"),
            str,
            try Ast.fromExpression(t.allocator, str),
            .{},
        );
        try sheet.setCell(
            try Position.fromAddress("B0"),
            "A0",
            try Ast.fromExpression(t.allocator, "A0"),
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
            _allocator: Allocator,
            _sheet: *Sheet,
            pos: Position,
            ast: Ast,
        ) !void {
            var c = ast;
            defer _sheet.endUndoGroup();
            _sheet.setCell(pos, "", c, .{}) catch |err| {
                c.deinit(_allocator);
                return err;
            };
            const last_undo = _sheet.undos.get(_sheet.undos.len - 1);
            try t.expectEqual(Undo{ .delete_cell = pos }, last_undo);
        }
    }._setCell;

    // Set cell values in random order
    try _setCell(a, sheet, try Position.fromAddress("B17"), try Ast.fromExpression(a, "A17+B16"));
    try _setCell(a, sheet, try Position.fromAddress("G8"), try Ast.fromExpression(a, "G7+F8"));
    try _setCell(a, sheet, try Position.fromAddress("A9"), try Ast.fromExpression(a, "A8+1"));
    try _setCell(a, sheet, try Position.fromAddress("G11"), try Ast.fromExpression(a, "G10+F11"));
    try _setCell(a, sheet, try Position.fromAddress("E16"), try Ast.fromExpression(a, "E15+D16"));
    try _setCell(a, sheet, try Position.fromAddress("G10"), try Ast.fromExpression(a, "G9+F10"));
    try _setCell(a, sheet, try Position.fromAddress("D2"), try Ast.fromExpression(a, "D1+C2"));
    try _setCell(a, sheet, try Position.fromAddress("F2"), try Ast.fromExpression(a, "F1+E2"));
    try _setCell(a, sheet, try Position.fromAddress("B18"), try Ast.fromExpression(a, "A18+B17"));
    try _setCell(a, sheet, try Position.fromAddress("D15"), try Ast.fromExpression(a, "D14+C15"));
    try _setCell(a, sheet, try Position.fromAddress("D20"), try Ast.fromExpression(a, "D19+C20"));
    try _setCell(a, sheet, try Position.fromAddress("E13"), try Ast.fromExpression(a, "E12+D13"));
    try _setCell(a, sheet, try Position.fromAddress("C12"), try Ast.fromExpression(a, "C11+B12"));
    try _setCell(a, sheet, try Position.fromAddress("A16"), try Ast.fromExpression(a, "A15+1"));
    try _setCell(a, sheet, try Position.fromAddress("A10"), try Ast.fromExpression(a, "A9+1"));
    try _setCell(a, sheet, try Position.fromAddress("C19"), try Ast.fromExpression(a, "C18+B19"));
    try _setCell(a, sheet, try Position.fromAddress("F0"), try Ast.fromExpression(a, "E0+1"));
    try _setCell(a, sheet, try Position.fromAddress("B4"), try Ast.fromExpression(a, "A4+B3"));
    try _setCell(a, sheet, try Position.fromAddress("C11"), try Ast.fromExpression(a, "C10+B11"));
    try _setCell(a, sheet, try Position.fromAddress("B6"), try Ast.fromExpression(a, "A6+B5"));
    try _setCell(a, sheet, try Position.fromAddress("G5"), try Ast.fromExpression(a, "G4+F5"));
    try _setCell(a, sheet, try Position.fromAddress("A18"), try Ast.fromExpression(a, "A17+1"));
    try _setCell(a, sheet, try Position.fromAddress("D1"), try Ast.fromExpression(a, "D0+C1"));
    try _setCell(a, sheet, try Position.fromAddress("G12"), try Ast.fromExpression(a, "G11+F12"));
    try _setCell(a, sheet, try Position.fromAddress("B5"), try Ast.fromExpression(a, "A5+B4"));
    try _setCell(a, sheet, try Position.fromAddress("D4"), try Ast.fromExpression(a, "D3+C4"));
    try _setCell(a, sheet, try Position.fromAddress("A5"), try Ast.fromExpression(a, "A4+1"));
    try _setCell(a, sheet, try Position.fromAddress("A0"), try Ast.fromExpression(a, "1"));
    try _setCell(a, sheet, try Position.fromAddress("D13"), try Ast.fromExpression(a, "D12+C13"));
    try _setCell(a, sheet, try Position.fromAddress("A15"), try Ast.fromExpression(a, "A14+1"));
    try _setCell(a, sheet, try Position.fromAddress("A20"), try Ast.fromExpression(a, "A19+1"));
    try _setCell(a, sheet, try Position.fromAddress("G19"), try Ast.fromExpression(a, "G18+F19"));
    try _setCell(a, sheet, try Position.fromAddress("G13"), try Ast.fromExpression(a, "G12+F13"));
    try _setCell(a, sheet, try Position.fromAddress("G17"), try Ast.fromExpression(a, "G16+F17"));
    try _setCell(a, sheet, try Position.fromAddress("C14"), try Ast.fromExpression(a, "C13+B14"));
    try _setCell(a, sheet, try Position.fromAddress("B8"), try Ast.fromExpression(a, "A8+B7"));
    try _setCell(a, sheet, try Position.fromAddress("D10"), try Ast.fromExpression(a, "D9+C10"));
    try _setCell(a, sheet, try Position.fromAddress("F19"), try Ast.fromExpression(a, "F18+E19"));
    try _setCell(a, sheet, try Position.fromAddress("B11"), try Ast.fromExpression(a, "A11+B10"));
    try _setCell(a, sheet, try Position.fromAddress("F9"), try Ast.fromExpression(a, "F8+E9"));
    try _setCell(a, sheet, try Position.fromAddress("G7"), try Ast.fromExpression(a, "G6+F7"));
    try _setCell(a, sheet, try Position.fromAddress("C10"), try Ast.fromExpression(a, "C9+B10"));
    try _setCell(a, sheet, try Position.fromAddress("C2"), try Ast.fromExpression(a, "C1+B2"));
    try _setCell(a, sheet, try Position.fromAddress("D0"), try Ast.fromExpression(a, "C0+1"));
    try _setCell(a, sheet, try Position.fromAddress("C18"), try Ast.fromExpression(a, "C17+B18"));
    try _setCell(a, sheet, try Position.fromAddress("D6"), try Ast.fromExpression(a, "D5+C6"));
    try _setCell(a, sheet, try Position.fromAddress("C0"), try Ast.fromExpression(a, "B0+1"));
    try _setCell(a, sheet, try Position.fromAddress("B14"), try Ast.fromExpression(a, "A14+B13"));
    try _setCell(a, sheet, try Position.fromAddress("B19"), try Ast.fromExpression(a, "A19+B18"));
    try _setCell(a, sheet, try Position.fromAddress("G16"), try Ast.fromExpression(a, "G15+F16"));
    try _setCell(a, sheet, try Position.fromAddress("C8"), try Ast.fromExpression(a, "C7+B8"));
    try _setCell(a, sheet, try Position.fromAddress("G4"), try Ast.fromExpression(a, "G3+F4"));
    try _setCell(a, sheet, try Position.fromAddress("D18"), try Ast.fromExpression(a, "D17+C18"));
    try _setCell(a, sheet, try Position.fromAddress("E17"), try Ast.fromExpression(a, "E16+D17"));
    try _setCell(a, sheet, try Position.fromAddress("D3"), try Ast.fromExpression(a, "D2+C3"));
    try _setCell(a, sheet, try Position.fromAddress("E20"), try Ast.fromExpression(a, "E19+D20"));
    try _setCell(a, sheet, try Position.fromAddress("C6"), try Ast.fromExpression(a, "C5+B6"));
    try _setCell(a, sheet, try Position.fromAddress("E2"), try Ast.fromExpression(a, "E1+D2"));
    try _setCell(a, sheet, try Position.fromAddress("C1"), try Ast.fromExpression(a, "C0+B1"));
    try _setCell(a, sheet, try Position.fromAddress("D17"), try Ast.fromExpression(a, "D16+C17"));
    try _setCell(a, sheet, try Position.fromAddress("C9"), try Ast.fromExpression(a, "C8+B9"));
    try _setCell(a, sheet, try Position.fromAddress("D12"), try Ast.fromExpression(a, "D11+C12"));
    try _setCell(a, sheet, try Position.fromAddress("F18"), try Ast.fromExpression(a, "F17+E18"));
    try _setCell(a, sheet, try Position.fromAddress("H0"), try Ast.fromExpression(a, "G0+1"));
    try _setCell(a, sheet, try Position.fromAddress("D8"), try Ast.fromExpression(a, "D7+C8"));
    try _setCell(a, sheet, try Position.fromAddress("B12"), try Ast.fromExpression(a, "A12+B11"));
    try _setCell(a, sheet, try Position.fromAddress("E19"), try Ast.fromExpression(a, "E18+D19"));
    try _setCell(a, sheet, try Position.fromAddress("A14"), try Ast.fromExpression(a, "A13+1"));
    try _setCell(a, sheet, try Position.fromAddress("E14"), try Ast.fromExpression(a, "E13+D14"));
    try _setCell(a, sheet, try Position.fromAddress("F14"), try Ast.fromExpression(a, "F13+E14"));
    try _setCell(a, sheet, try Position.fromAddress("A13"), try Ast.fromExpression(a, "A12+1"));
    try _setCell(a, sheet, try Position.fromAddress("A19"), try Ast.fromExpression(a, "A18+1"));
    try _setCell(a, sheet, try Position.fromAddress("A4"), try Ast.fromExpression(a, "A3+1"));
    try _setCell(a, sheet, try Position.fromAddress("F7"), try Ast.fromExpression(a, "F6+E7"));
    try _setCell(a, sheet, try Position.fromAddress("A7"), try Ast.fromExpression(a, "A6+1"));
    try _setCell(a, sheet, try Position.fromAddress("E11"), try Ast.fromExpression(a, "E10+D11"));
    try _setCell(a, sheet, try Position.fromAddress("B1"), try Ast.fromExpression(a, "A1+B0"));
    try _setCell(a, sheet, try Position.fromAddress("A11"), try Ast.fromExpression(a, "A10+1"));
    try _setCell(a, sheet, try Position.fromAddress("B16"), try Ast.fromExpression(a, "A16+B15"));
    try _setCell(a, sheet, try Position.fromAddress("E12"), try Ast.fromExpression(a, "E11+D12"));
    try _setCell(a, sheet, try Position.fromAddress("F11"), try Ast.fromExpression(a, "F10+E11"));
    try _setCell(a, sheet, try Position.fromAddress("F1"), try Ast.fromExpression(a, "F0+E1"));
    try _setCell(a, sheet, try Position.fromAddress("C4"), try Ast.fromExpression(a, "C3+B4"));
    try _setCell(a, sheet, try Position.fromAddress("G20"), try Ast.fromExpression(a, "G19+F20"));
    try _setCell(a, sheet, try Position.fromAddress("F16"), try Ast.fromExpression(a, "F15+E16"));
    try _setCell(a, sheet, try Position.fromAddress("D5"), try Ast.fromExpression(a, "D4+C5"));
    try _setCell(a, sheet, try Position.fromAddress("A17"), try Ast.fromExpression(a, "A16+1"));
    try _setCell(a, sheet, try Position.fromAddress("A22"), try Ast.fromExpression(a, "@sum(a0:g20)"));
    try _setCell(a, sheet, try Position.fromAddress("F4"), try Ast.fromExpression(a, "F3+E4"));
    try _setCell(a, sheet, try Position.fromAddress("B9"), try Ast.fromExpression(a, "A9+B8"));
    try _setCell(a, sheet, try Position.fromAddress("E4"), try Ast.fromExpression(a, "E3+D4"));
    try _setCell(a, sheet, try Position.fromAddress("F13"), try Ast.fromExpression(a, "F12+E13"));
    try _setCell(a, sheet, try Position.fromAddress("A1"), try Ast.fromExpression(a, "A0+1"));
    try _setCell(a, sheet, try Position.fromAddress("F3"), try Ast.fromExpression(a, "F2+E3"));
    try _setCell(a, sheet, try Position.fromAddress("F17"), try Ast.fromExpression(a, "F16+E17"));
    try _setCell(a, sheet, try Position.fromAddress("G14"), try Ast.fromExpression(a, "G13+F14"));
    try _setCell(a, sheet, try Position.fromAddress("D11"), try Ast.fromExpression(a, "D10+C11"));
    try _setCell(a, sheet, try Position.fromAddress("A2"), try Ast.fromExpression(a, "A1+1"));
    try _setCell(a, sheet, try Position.fromAddress("E9"), try Ast.fromExpression(a, "E8+D9"));
    try _setCell(a, sheet, try Position.fromAddress("B15"), try Ast.fromExpression(a, "A15+B14"));
    try _setCell(a, sheet, try Position.fromAddress("E18"), try Ast.fromExpression(a, "E17+D18"));
    try _setCell(a, sheet, try Position.fromAddress("E8"), try Ast.fromExpression(a, "E7+D8"));
    try _setCell(a, sheet, try Position.fromAddress("G18"), try Ast.fromExpression(a, "G17+F18"));
    try _setCell(a, sheet, try Position.fromAddress("A6"), try Ast.fromExpression(a, "A5+1"));
    try _setCell(a, sheet, try Position.fromAddress("C3"), try Ast.fromExpression(a, "C2+B3"));
    try _setCell(a, sheet, try Position.fromAddress("B0"), try Ast.fromExpression(a, "A0+1"));
    try _setCell(a, sheet, try Position.fromAddress("E10"), try Ast.fromExpression(a, "E9+D10"));
    try _setCell(a, sheet, try Position.fromAddress("B7"), try Ast.fromExpression(a, "A7+B6"));
    try _setCell(a, sheet, try Position.fromAddress("C7"), try Ast.fromExpression(a, "C6+B7"));
    try _setCell(a, sheet, try Position.fromAddress("D9"), try Ast.fromExpression(a, "D8+C9"));
    try _setCell(a, sheet, try Position.fromAddress("D14"), try Ast.fromExpression(a, "D13+C14"));
    try _setCell(a, sheet, try Position.fromAddress("B20"), try Ast.fromExpression(a, "A20+B19"));
    try _setCell(a, sheet, try Position.fromAddress("E7"), try Ast.fromExpression(a, "E6+D7"));
    try _setCell(a, sheet, try Position.fromAddress("E0"), try Ast.fromExpression(a, "D0+1"));
    try _setCell(a, sheet, try Position.fromAddress("A3"), try Ast.fromExpression(a, "A2+1"));
    try _setCell(a, sheet, try Position.fromAddress("G9"), try Ast.fromExpression(a, "G8+F9"));
    try _setCell(a, sheet, try Position.fromAddress("C17"), try Ast.fromExpression(a, "C16+B17"));
    try _setCell(a, sheet, try Position.fromAddress("F5"), try Ast.fromExpression(a, "F4+E5"));
    try _setCell(a, sheet, try Position.fromAddress("F6"), try Ast.fromExpression(a, "F5+E6"));
    try _setCell(a, sheet, try Position.fromAddress("G3"), try Ast.fromExpression(a, "G2+F3"));
    try _setCell(a, sheet, try Position.fromAddress("E5"), try Ast.fromExpression(a, "E4+D5"));
    try _setCell(a, sheet, try Position.fromAddress("A8"), try Ast.fromExpression(a, "A7+1"));
    try _setCell(a, sheet, try Position.fromAddress("B13"), try Ast.fromExpression(a, "A13+B12"));
    try _setCell(a, sheet, try Position.fromAddress("B3"), try Ast.fromExpression(a, "A3+B2"));
    try _setCell(a, sheet, try Position.fromAddress("D19"), try Ast.fromExpression(a, "D18+C19"));
    try _setCell(a, sheet, try Position.fromAddress("B2"), try Ast.fromExpression(a, "A2+B1"));
    try _setCell(a, sheet, try Position.fromAddress("C5"), try Ast.fromExpression(a, "C4+B5"));
    try _setCell(a, sheet, try Position.fromAddress("G6"), try Ast.fromExpression(a, "G5+F6"));
    try _setCell(a, sheet, try Position.fromAddress("F12"), try Ast.fromExpression(a, "F11+E12"));
    try _setCell(a, sheet, try Position.fromAddress("E1"), try Ast.fromExpression(a, "E0+D1"));
    try _setCell(a, sheet, try Position.fromAddress("C15"), try Ast.fromExpression(a, "C14+B15"));
    try _setCell(a, sheet, try Position.fromAddress("A12"), try Ast.fromExpression(a, "A11+1"));
    try _setCell(a, sheet, try Position.fromAddress("G1"), try Ast.fromExpression(a, "G0+F1"));
    try _setCell(a, sheet, try Position.fromAddress("D16"), try Ast.fromExpression(a, "D15+C16"));
    try _setCell(a, sheet, try Position.fromAddress("F20"), try Ast.fromExpression(a, "F19+E20"));
    try _setCell(a, sheet, try Position.fromAddress("E6"), try Ast.fromExpression(a, "E5+D6"));
    try _setCell(a, sheet, try Position.fromAddress("E15"), try Ast.fromExpression(a, "E14+D15"));
    try _setCell(a, sheet, try Position.fromAddress("F8"), try Ast.fromExpression(a, "F7+E8"));
    try _setCell(a, sheet, try Position.fromAddress("F10"), try Ast.fromExpression(a, "F9+E10"));
    try _setCell(a, sheet, try Position.fromAddress("C16"), try Ast.fromExpression(a, "C15+B16"));
    try _setCell(a, sheet, try Position.fromAddress("C20"), try Ast.fromExpression(a, "C19+B20"));
    try _setCell(a, sheet, try Position.fromAddress("E3"), try Ast.fromExpression(a, "E2+D3"));
    try _setCell(a, sheet, try Position.fromAddress("B10"), try Ast.fromExpression(a, "A10+B9"));
    try _setCell(a, sheet, try Position.fromAddress("G2"), try Ast.fromExpression(a, "G1+F2"));
    try _setCell(a, sheet, try Position.fromAddress("D7"), try Ast.fromExpression(a, "D6+C7"));
    try _setCell(a, sheet, try Position.fromAddress("G15"), try Ast.fromExpression(a, "G14+F15"));
    try _setCell(a, sheet, try Position.fromAddress("G0"), try Ast.fromExpression(a, "F0+1"));
    try _setCell(a, sheet, try Position.fromAddress("F15"), try Ast.fromExpression(a, "F14+E15"));
    try _setCell(a, sheet, try Position.fromAddress("C13"), try Ast.fromExpression(a, "C12+B13"));

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

    for (sheet.undos.items(.tags)) |tag| {
        try t.expectEqual(std.meta.Tag(Undo).delete_cell, tag);
    }

    const UndoIterator = struct {
        undos: MultiArrayList(Undo).Slice,
        index: u32 = 0,

        pub fn next(iter: *@This()) Undo {
            if (iter.index >= iter.undos.len) unreachable;
            defer iter.index += 1;
            return iter.undos.get(iter.index);
        }
    };

    var iter = UndoIterator{ .undos = sheet.undos.slice() };
    // Check that undos are in the correct order
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B17") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G8") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A9") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G11") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E16") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G10") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D2") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F2") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B18") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D15") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D20") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E13") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C12") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A16") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A10") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C19") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F0") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B4") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C11") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B6") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G5") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A18") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D1") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G12") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B5") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D4") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A5") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A0") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D13") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A15") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A20") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G19") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G13") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G17") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C14") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B8") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D10") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F19") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B11") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F9") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G7") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C10") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C2") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D0") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C18") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D6") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C0") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B14") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B19") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G16") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C8") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G4") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D18") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E17") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D3") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E20") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C6") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E2") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C1") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D17") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C9") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D12") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F18") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("H0") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D8") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B12") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E19") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A14") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E14") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F14") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A13") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A19") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A4") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F7") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A7") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E11") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B1") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A11") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B16") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E12") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F11") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F1") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C4") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G20") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F16") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D5") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A17") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A22") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F4") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B9") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E4") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F13") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A1") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F3") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F17") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G14") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D11") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A2") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E9") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B15") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E18") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E8") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G18") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A6") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C3") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B0") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E10") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B7") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C7") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D9") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D14") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B20") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E7") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E0") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A3") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G9") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C17") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F5") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F6") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G3") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E5") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A8") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B13") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B3") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D19") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B2") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C5") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G6") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F12") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E1") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C15") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A12") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G1") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D16") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F20") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E6") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E15") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F8") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F10") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C16") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C20") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("E3") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("B10") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G2") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("D7") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G15") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G0") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F15") }, iter.next());
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C13") }, iter.next());

    // Check undos
    try t.expectEqual(@as(usize, 149), sheet.undos.len);
    try t.expectEqual(@as(usize, 0), sheet.redos.len);

    try sheet.undo();
    try t.expectEqual(@as(usize, 148), sheet.undos.len);
    try t.expectEqual(@as(usize, 1), sheet.redos.len);
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("F15") }, sheet.undos.get(sheet.undos.len - 1));

    try sheet.redo();
    try t.expectEqual(@as(usize, 149), sheet.undos.len);
    try t.expectEqual(@as(usize, 0), sheet.redos.len);
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C13") }, sheet.undos.get(sheet.undos.len - 1));

    try sheet.deleteCell(try Position.fromAddress("A22"), .{});
    try sheet.deleteCell(try Position.fromAddress("G20"), .{});
    sheet.endUndoGroup();

    try t.expectEqual(@as(usize, 151), sheet.undos.len);
    try t.expectEqual(@as(usize, 0), sheet.redos.len);
    try sheet.undo();
    try t.expectEqual(@as(usize, 149), sheet.undos.len);
    try t.expectEqual(@as(usize, 2), sheet.redos.len);
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("C13") }, sheet.undos.get(sheet.undos.len - 1));
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("G20") }, sheet.redos.get(0));
    try t.expectEqual(Undo{ .delete_cell = try Position.fromAddress("A22") }, sheet.redos.get(1));

    try sheet.undo();
    try t.expectEqual(@as(usize, 148), sheet.undos.len);
    try t.expectEqual(@as(usize, 3), sheet.redos.len);
    try sheet.undo();
    try t.expectEqual(@as(usize, 147), sheet.undos.len);
    try t.expectEqual(@as(usize, 4), sheet.redos.len);

    try sheet.redo();
    try t.expectEqual(@as(usize, 148), sheet.undos.len);
    try t.expectEqual(@as(usize, 3), sheet.redos.len);
    try sheet.redo();
    try t.expectEqual(@as(usize, 149), sheet.undos.len);
    try t.expectEqual(@as(usize, 2), sheet.redos.len);
    try sheet.redo();
    try t.expectEqual(@as(usize, 151), sheet.undos.len);
    try t.expectEqual(@as(usize, 0), sheet.redos.len);
    try sheet.redo();
    try t.expectEqual(@as(usize, 151), sheet.undos.len);
    try t.expectEqual(@as(usize, 0), sheet.redos.len);

    const _setCellText = struct {
        fn func(_allocator: Allocator, _sheet: *Sheet, pos: Position, expr: []const u8) !void {
            var ast = try Ast.fromStringExpression(_allocator, expr);
            errdefer ast.deinit(_allocator);
            try _sheet.setCell(pos, expr, ast, .{});
            _sheet.endUndoGroup();
            try t.expectEqual(ast.nodes, _sheet.getCell(pos).?.ast.nodes);
        }
    }.func;

    try _setCellText(a, sheet, try Position.fromAddress("A0"), "'1'");
    try _setCellText(a, sheet, try Position.fromAddress("B0"), "A0 # '2'");
    try _setCellText(a, sheet, try Position.fromAddress("C0"), "B0 # '3'");
    try _setCellText(a, sheet, try Position.fromAddress("D0"), "C0 # '4'");
    try _setCellText(a, sheet, try Position.fromAddress("E0"), "D0 # '5'");
    try _setCellText(a, sheet, try Position.fromAddress("F0"), "E0 # '6'");
    try _setCellText(a, sheet, try Position.fromAddress("G0"), "F0 # '7'");
    try _setCellText(a, sheet, try Position.fromAddress("H0"), "G0 # '8'");
    try _setCellText(a, sheet, try Position.fromAddress("A1"), "A0 # '2'");
    try _setCellText(a, sheet, try Position.fromAddress("B1"), "A1 # B0");
    try _setCellText(a, sheet, try Position.fromAddress("C1"), "B1 # C0");
    try _setCellText(a, sheet, try Position.fromAddress("D1"), "C1 # D0");
    try _setCellText(a, sheet, try Position.fromAddress("E1"), "D1 # E0");
    try _setCellText(a, sheet, try Position.fromAddress("F1"), "E1 # F0");
    try _setCellText(a, sheet, try Position.fromAddress("G1"), "F1 # G0");
    try _setCellText(a, sheet, try Position.fromAddress("A2"), "A1 # '3'");
    try _setCellText(a, sheet, try Position.fromAddress("B2"), "A2 # B1");
    try _setCellText(a, sheet, try Position.fromAddress("C2"), "B2 # C1");
    try _setCellText(a, sheet, try Position.fromAddress("D2"), "C2 # D1");
    try _setCellText(a, sheet, try Position.fromAddress("E2"), "D2 # E1");
    try _setCellText(a, sheet, try Position.fromAddress("F2"), "E2 # F1");
    try _setCellText(a, sheet, try Position.fromAddress("G2"), "F2 # G1");
    try _setCellText(a, sheet, try Position.fromAddress("A3"), "A2 # '4'");
    try _setCellText(a, sheet, try Position.fromAddress("B3"), "A3 # B2");
    try _setCellText(a, sheet, try Position.fromAddress("C3"), "B3 # C2");
    try _setCellText(a, sheet, try Position.fromAddress("D3"), "C3 # D2");
    try _setCellText(a, sheet, try Position.fromAddress("E3"), "D3 # E2");
    try _setCellText(a, sheet, try Position.fromAddress("F3"), "E3 # F2");
    try _setCellText(a, sheet, try Position.fromAddress("G3"), "F3 # G2");
    try _setCellText(a, sheet, try Position.fromAddress("A4"), "A3 # '5'");
    try _setCellText(a, sheet, try Position.fromAddress("B4"), "A4 # B3");
    try _setCellText(a, sheet, try Position.fromAddress("C4"), "B4 # C3");
    try _setCellText(a, sheet, try Position.fromAddress("D4"), "C4 # D3");
    try _setCellText(a, sheet, try Position.fromAddress("E4"), "D4 # E3");
    try _setCellText(a, sheet, try Position.fromAddress("F4"), "E4 # F3");
    try _setCellText(a, sheet, try Position.fromAddress("G4"), "F4 # G3");
    try _setCellText(a, sheet, try Position.fromAddress("A5"), "A4 # '6'");
    try _setCellText(a, sheet, try Position.fromAddress("B5"), "A5 # B4");
    try _setCellText(a, sheet, try Position.fromAddress("C5"), "B5 # C4");
    try _setCellText(a, sheet, try Position.fromAddress("D5"), "C5 # D4");
    try _setCellText(a, sheet, try Position.fromAddress("E5"), "D5 # E4");
    try _setCellText(a, sheet, try Position.fromAddress("F5"), "E5 # F4");
    try _setCellText(a, sheet, try Position.fromAddress("G5"), "F5 # G4");
    try _setCellText(a, sheet, try Position.fromAddress("A6"), "A5 # '7'");
    try _setCellText(a, sheet, try Position.fromAddress("B6"), "A6 # B5");
    try _setCellText(a, sheet, try Position.fromAddress("C6"), "B6 # C5");
    try _setCellText(a, sheet, try Position.fromAddress("D6"), "C6 # D5");
    try _setCellText(a, sheet, try Position.fromAddress("E6"), "D6 # E5");
    try _setCellText(a, sheet, try Position.fromAddress("F6"), "E6 # F5");
    try _setCellText(a, sheet, try Position.fromAddress("G6"), "F6 # G5");
    try _setCellText(a, sheet, try Position.fromAddress("A7"), "A6 # '8'");
    try _setCellText(a, sheet, try Position.fromAddress("B7"), "A7 # B6");
    try _setCellText(a, sheet, try Position.fromAddress("C7"), "B7 # C6");
    try _setCellText(a, sheet, try Position.fromAddress("D7"), "C7 # D6");
    try _setCellText(a, sheet, try Position.fromAddress("E7"), "D7 # E6");
    try _setCellText(a, sheet, try Position.fromAddress("F7"), "E7 # F6");
    try _setCellText(a, sheet, try Position.fromAddress("G7"), "F7 # G6");
    try _setCellText(a, sheet, try Position.fromAddress("A8"), "A7 # '9'");
    try _setCellText(a, sheet, try Position.fromAddress("B8"), "A8 # B7");
    try _setCellText(a, sheet, try Position.fromAddress("C8"), "B8 # C7");
    try _setCellText(a, sheet, try Position.fromAddress("D8"), "C8 # D7");
    try _setCellText(a, sheet, try Position.fromAddress("E8"), "D8 # E7");
    try _setCellText(a, sheet, try Position.fromAddress("F8"), "E8 # F7");
    try _setCellText(a, sheet, try Position.fromAddress("G8"), "F8 # G7");
    try _setCellText(a, sheet, try Position.fromAddress("A9"), "A8 # '0'");
    try _setCellText(a, sheet, try Position.fromAddress("B9"), "A9 # B8");
    try _setCellText(a, sheet, try Position.fromAddress("C9"), "B9 # C8");
    try _setCellText(a, sheet, try Position.fromAddress("D9"), "C9 # D8");
    try _setCellText(a, sheet, try Position.fromAddress("E9"), "D9 # E8");
    try _setCellText(a, sheet, try Position.fromAddress("F9"), "E9 # F8");
    try _setCellText(a, sheet, try Position.fromAddress("G9"), "F9 # G8");
    try _setCellText(a, sheet, try Position.fromAddress("A10"), "A9 # '1'");
    try _setCellText(a, sheet, try Position.fromAddress("B10"), "A10 # B9");
    try _setCellText(a, sheet, try Position.fromAddress("C10"), "B10 # C9");
    try _setCellText(a, sheet, try Position.fromAddress("D10"), "C10 # D9");
    try _setCellText(a, sheet, try Position.fromAddress("E10"), "D10 # E9");
    try _setCellText(a, sheet, try Position.fromAddress("F10"), "E10 # F9");
    try _setCellText(a, sheet, try Position.fromAddress("G10"), "F10 # G9");
    try _setCellText(a, sheet, try Position.fromAddress("A11"), "A10 # '2'");
    try _setCellText(a, sheet, try Position.fromAddress("B11"), "A11 # B10");
    try _setCellText(a, sheet, try Position.fromAddress("C11"), "B11 # C10");
    try _setCellText(a, sheet, try Position.fromAddress("D11"), "C11 # D10");
    try _setCellText(a, sheet, try Position.fromAddress("E11"), "D11 # E10");
    try _setCellText(a, sheet, try Position.fromAddress("F11"), "E11 # F10");
    try _setCellText(a, sheet, try Position.fromAddress("G11"), "F11 # G10");
    try _setCellText(a, sheet, try Position.fromAddress("A12"), "A11 # '3'");
    try _setCellText(a, sheet, try Position.fromAddress("B12"), "A12 # B11");
    try _setCellText(a, sheet, try Position.fromAddress("C12"), "B12 # C11");
    try _setCellText(a, sheet, try Position.fromAddress("D12"), "C12 # D11");
    try _setCellText(a, sheet, try Position.fromAddress("E12"), "D12 # E11");
    try _setCellText(a, sheet, try Position.fromAddress("F12"), "E12 # F11");
    try _setCellText(a, sheet, try Position.fromAddress("G12"), "F12 # G11");
    try _setCellText(a, sheet, try Position.fromAddress("A13"), "A12 # '4'");
    try _setCellText(a, sheet, try Position.fromAddress("B13"), "A13 # B12");
    try _setCellText(a, sheet, try Position.fromAddress("C13"), "B13 # C12");
    try _setCellText(a, sheet, try Position.fromAddress("D13"), "C13 # D12");
    try _setCellText(a, sheet, try Position.fromAddress("E13"), "D13 # E12");
    try _setCellText(a, sheet, try Position.fromAddress("F13"), "E13 # F12");
    try _setCellText(a, sheet, try Position.fromAddress("G13"), "F13 # G12");
    try _setCellText(a, sheet, try Position.fromAddress("A14"), "A13 # '5'");
    try _setCellText(a, sheet, try Position.fromAddress("B14"), "A14 # B13");
    try _setCellText(a, sheet, try Position.fromAddress("C14"), "B14 # C13");
    try _setCellText(a, sheet, try Position.fromAddress("D14"), "C14 # D13");
    try _setCellText(a, sheet, try Position.fromAddress("E14"), "D14 # E13");
    try _setCellText(a, sheet, try Position.fromAddress("F14"), "E14 # F13");
    try _setCellText(a, sheet, try Position.fromAddress("G14"), "F14 # G13");
    try _setCellText(a, sheet, try Position.fromAddress("A15"), "A14 # '6'");
    try _setCellText(a, sheet, try Position.fromAddress("B15"), "A15 # B14");
    try _setCellText(a, sheet, try Position.fromAddress("C15"), "B15 # C14");
    try _setCellText(a, sheet, try Position.fromAddress("D15"), "C15 # D14");
    try _setCellText(a, sheet, try Position.fromAddress("E15"), "D15 # E14");
    try _setCellText(a, sheet, try Position.fromAddress("F15"), "E15 # F14");
    try _setCellText(a, sheet, try Position.fromAddress("G15"), "F15 # G14");
    try _setCellText(a, sheet, try Position.fromAddress("A16"), "A15 # '7'");
    try _setCellText(a, sheet, try Position.fromAddress("B16"), "A16 # B15");
    try _setCellText(a, sheet, try Position.fromAddress("C16"), "B16 # C15");
    try _setCellText(a, sheet, try Position.fromAddress("D16"), "C16 # D15");
    try _setCellText(a, sheet, try Position.fromAddress("E16"), "D16 # E15");
    try _setCellText(a, sheet, try Position.fromAddress("F16"), "E16 # F15");
    try _setCellText(a, sheet, try Position.fromAddress("G16"), "F16 # G15");
    try _setCellText(a, sheet, try Position.fromAddress("A17"), "A16 # '8'");
    try _setCellText(a, sheet, try Position.fromAddress("B17"), "A17 # B16");
    try _setCellText(a, sheet, try Position.fromAddress("C17"), "B17 # C16");
    try _setCellText(a, sheet, try Position.fromAddress("D17"), "C17 # D16");
    try _setCellText(a, sheet, try Position.fromAddress("E17"), "D17 # E16");
    try _setCellText(a, sheet, try Position.fromAddress("F17"), "E17 # F16");
    try _setCellText(a, sheet, try Position.fromAddress("G17"), "F17 # G16");
    try _setCellText(a, sheet, try Position.fromAddress("A18"), "A17 # '9'");
    try _setCellText(a, sheet, try Position.fromAddress("B18"), "A18 # B17");
    try _setCellText(a, sheet, try Position.fromAddress("C18"), "B18 # C17");
    try _setCellText(a, sheet, try Position.fromAddress("D18"), "C18 # D17");
    try _setCellText(a, sheet, try Position.fromAddress("E18"), "D18 # E17");
    try _setCellText(a, sheet, try Position.fromAddress("F18"), "E18 # F17");
    try _setCellText(a, sheet, try Position.fromAddress("G18"), "F18 # G17");
    try _setCellText(a, sheet, try Position.fromAddress("A19"), "A18 # '0'");
    try _setCellText(a, sheet, try Position.fromAddress("B19"), "A19 # B18");
    try _setCellText(a, sheet, try Position.fromAddress("C19"), "B19 # C18");
    try _setCellText(a, sheet, try Position.fromAddress("D19"), "C19 # D18");
    try _setCellText(a, sheet, try Position.fromAddress("E19"), "D19 # E18");
    try _setCellText(a, sheet, try Position.fromAddress("F19"), "E19 # F18");
    try _setCellText(a, sheet, try Position.fromAddress("G19"), "F19 # G18");
    try _setCellText(a, sheet, try Position.fromAddress("A20"), "A19 # '1'");
    try _setCellText(a, sheet, try Position.fromAddress("B20"), "A20 # B19");
    try _setCellText(a, sheet, try Position.fromAddress("C20"), "B20 # C19");
    try _setCellText(a, sheet, try Position.fromAddress("D20"), "C20 # D19");
    try _setCellText(a, sheet, try Position.fromAddress("E20"), "D20 # E19");
    try _setCellText(a, sheet, try Position.fromAddress("F20"), "E20 # F19");
    try _setCellText(a, sheet, try Position.fromAddress("G20"), "F20 # G19");

    try sheet.update();

    // Only checks the eval results of some of the cells, checking all is kinda slow
    const strings = @embedFile("strings.csv");
    var line_iter = std.mem.tokenizeScalar(u8, strings, '\n');
    var y: PosInt = 0;
    while (line_iter.next()) |line| : (y += 1) {
        var col_iter = std.mem.tokenizeScalar(u8, line, ',');
        var x: PosInt = 0;
        while (col_iter.next()) |col| : (x += 1) {
            const str = std.mem.span(sheet.getCell(.{ .x = x, .y = y }).?.value.string);
            try t.expectEqualStrings(col, str);
        }
    }

    try t.expectEqual(
        Undo{ .delete_cell = try Position.fromAddress("G20") },
        sheet.undos.get(sheet.undos.len - 1),
    );
}

test "Cell assignment, updating, evaluation" {
    if (@import("compile_opts").fast_tests) {
        return error.SkipZigTest;
    }

    try std.testing.checkAllAllocationFailures(std.testing.allocator, testCellEvaluation, .{});
}

fn expectCellEquals(sheet: *Sheet, address: []const u8, expected_value: f64) !void {
    const cell = sheet.getCellPtr(try .fromAddress(address)) orelse return error.CellNotFound;
    try std.testing.expectApproxEqRel(expected_value, cell.value.number, 0.001);
}

fn expectCellError(sheet: *Sheet, address: []const u8) !void {
    const cell = sheet.getCellPtr(try .fromAddress(address)) orelse return error.CellNotFound;
    if (!cell.isError()) return error.UnexpectedValue;
}

test "Cell error propagation" {
    const sheet = try Sheet.create(std.testing.allocator);
    defer sheet.destroy();

    try sheet.setCell(
        .fromValidAddress("A0"),
        "10",
        try .fromExpression(std.testing.allocator, "10"),
        .{},
    );

    try sheet.update();
    try expectCellEquals(sheet, "A0", 10);

    try sheet.setCell(
        .fromValidAddress("B0"),
        "A0",
        try .fromExpression(std.testing.allocator, "A0"),
        .{},
    );

    try sheet.update();
    try expectCellEquals(sheet, "B0", 10);

    try sheet.setCell(
        .fromValidAddress("A0"),
        "A0",
        try .fromExpression(std.testing.allocator, "A0"),
        .{},
    );

    try sheet.update();
    try expectCellError(sheet, "A0");
    try expectCellError(sheet, "B0");
}
