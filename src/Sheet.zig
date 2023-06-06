const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils.zig");
const Ast = @import("Ast.zig").Ast(false);
const MAX = std.math.maxInt(u16);
const ArrayMemoryPool = @import("array_memory_pool.zig").ArrayMemoryPool;

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const Sheet = @This();
const NodeList = std.ArrayList(Position);
const NodeListUnmanaged = std.ArrayListUnmanaged(Position);

const log = std.log.scoped(.sheet);

const ArrayPositionContext = struct {
    pub fn eql(_: @This(), p1: Position, p2: Position, _: usize) bool {
        return p1.y == p2.y and p1.x == p2.x;
    }

    pub fn hash(_: @This(), pos: Position) u32 {
        return pos.hash();
    }
};

/// std.HashMap and std.ArrayHasMap require slightly different contexts.
const PositionContext = struct {
    pub fn eql(_: @This(), p1: Position, p2: Position) bool {
        return p1.y == p2.y and p1.x == p2.x;
    }

    pub fn hash(_: @This(), pos: Position) u64 {
        return pos.hash();
    }
};

const CellMap = std.ArrayHashMapUnmanaged(Position, Cell, ArrayPositionContext, false);

/// Used for cell evaluation
const NodeMap = std.HashMapUnmanaged(Position, NodeMark, PositionContext, 99);

/// Used for cell evaluation
const NodeMark = enum {
    temporary,
    permanent,
};

/// ArrayHashMap mapping spreadsheet positions to cells.
cells: CellMap = .{},

/// Maps column indexes (0 - 65535) to `Column` structs containing info about that column.
columns: std.AutoArrayHashMapUnmanaged(u16, Column) = .{},
filepath: std.BoundedArray(u8, std.fs.MAX_PATH_BYTES) = .{},

/// Map containing cells which have already been visited during evaluation.node_list
visited_nodes: NodeMap = .{},
/// Cell positions sorted topologically, used for order of evaluation when evaluating all cells.
sorted_nodes: NodeListUnmanaged = .{},

/// If true, the next call to Sheet.update will re-evaluate all cells in the sheet.
needs_update: bool = false,

/// True if there have been any changes since the last save
has_changes: bool = false,

undos: UndoList = .{},
redos: UndoList = .{},
undo_asts: ArrayMemoryPool(Ast, u32) = .{},

allocator: Allocator,

pub const UndoList = std.MultiArrayList(Undo);
pub const AstMap = std.AutoArrayHashMapUnmanaged(u32, Ast);

pub const UndoType = enum { undo, redo };

pub const Undo = union(enum) {
    group_end,

    set_cell: struct {
        pos: Position,
        index: u32,
    },
    delete_cell: Position,
    set_column_width: struct {
        col: u16,
        width: u16,
    },
    set_column_precision: struct {
        col: u16,
        precision: u8,
    },
};

pub fn init(allocator: Allocator) Sheet {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(sheet: *Sheet) void {
    for (sheet.cells.values()) |*cell| {
        cell.deinit(sheet.allocator);
    }

    sheet.clearAndFreeUndos(.undo);
    sheet.clearAndFreeUndos(.redo);

    sheet.undos.deinit(sheet.allocator);
    sheet.redos.deinit(sheet.allocator);
    sheet.undo_asts.deinit(sheet.allocator);
    sheet.cells.deinit(sheet.allocator);
    sheet.visited_nodes.deinit(sheet.allocator);
    sheet.sorted_nodes.deinit(sheet.allocator);
    sheet.columns.deinit(sheet.allocator);
    sheet.* = undefined;
}

pub const UndoOpts = struct {
    undo_type: UndoType = .undo,
    clear_redos: bool = true,
};

fn createUndoAst(sheet: *Sheet, ast: Ast) Allocator.Error!u32 {
    return sheet.undo_asts.createWithInit(sheet.allocator, ast);
}

fn freeUndoAst(sheet: *Sheet, index: u32) void {
    var ast = sheet.undo_asts.get(index);
    ast.deinit(sheet.allocator);
    sheet.undo_asts.destroy(index);
}

pub fn clearAndFreeUndos(sheet: *Sheet, comptime kind: UndoType) void {
    const list = switch (kind) {
        .undo => &sheet.undos,
        .redo => &sheet.redos,
    };

    const slice = list.slice();
    const data = slice.items(.data);

    for (slice.items(.tags), 0..) |tag, i| {
        switch (tag) {
            .set_cell => sheet.freeUndoAst(data[i].set_cell.index),
            .delete_cell,
            .set_column_width,
            .set_column_precision,
            .group_end,
            => {},
        }
    }
    list.len = 0;
}

pub fn endUndoGroup(sheet: *Sheet) void {
    if (sheet.undos.len > 0 and sheet.undos.items(.tags)[sheet.undos.len - 1] != .group_end) {
        sheet.undos.appendAssumeCapacity(.group_end);
    }
}

fn endRedoGroup(sheet: *Sheet) void {
    if (sheet.redos.len > 0 and sheet.redos.items(.tags)[sheet.redos.len - 1] != .group_end) {
        sheet.redos.appendAssumeCapacity(.group_end);
    }
}

pub fn pushUndo(sheet: *Sheet, u: Undo, opts: UndoOpts) Allocator.Error!void {
    switch (opts.undo_type) {
        .undo => {
            // Ensure capacity for 3 elements so the group marker can be always
            // added without extra error handling.
            try sheet.undos.ensureUnusedCapacity(sheet.allocator, 3);
            sheet.undos.appendAssumeCapacity(u);
            if (opts.clear_redos) sheet.clearAndFreeUndos(.redo);
        },
        .redo => {
            try sheet.redos.ensureUnusedCapacity(sheet.allocator, 3);
            sheet.redos.appendAssumeCapacity(u);
        },
    }
}

pub fn undo(sheet: *Sheet) Allocator.Error!void {
    const _u = sheet.undos.popOrNull() orelse return;
    // All undo groups MUST end with a group marker.
    assert(_u == .group_end);

    defer {
        sheet.endUndoGroup();
        sheet.endRedoGroup();
    }

    const opts = .{ .undo_type = .redo };
    while (sheet.undos.popOrNull()) |u| switch (u) {
        .group_end => break,
        .set_cell => |t| {
            errdefer sheet.freeUndoAst(t.index);
            const ast = sheet.undo_asts.get(t.index);
            try sheet.setCellAst(t.pos, ast, opts);
        },
        .delete_cell => |pos| {
            try sheet.deleteCell(pos, opts);
        },
        .set_column_width => |t| try sheet.setWidth(t.col, t.width, opts),
        .set_column_precision => |t| try sheet.setPrecision(t.col, t.precision, opts),
    };
}

pub fn redo(sheet: *Sheet) Allocator.Error!void {
    const _u = sheet.redos.popOrNull() orelse return;
    // All undo groups MUST end with a group marker.
    assert(_u == .group_end);

    defer {
        sheet.endUndoGroup();
        sheet.endRedoGroup();
    }

    const opts = .{ .clear_redos = false };
    while (sheet.redos.popOrNull()) |u| switch (u) {
        .group_end => break,
        .set_cell => |t| {
            errdefer sheet.freeUndoAst(t.index);
            const ast = sheet.undo_asts.get(t.index);
            try sheet.setCellAst(t.pos, ast, opts);
        },
        .delete_cell => |pos| {
            try sheet.deleteCell(pos, opts);
        },
        .set_column_width => |t| try sheet.setWidth(t.col, t.width, opts),
        .set_column_precision => |t| try sheet.setPrecision(t.col, t.precision, opts),
    };
}

pub fn setWidth(
    sheet: *Sheet,
    column_index: u16,
    width: u16,
    opts: UndoOpts,
) Allocator.Error!void {
    if (sheet.columns.getPtr(column_index)) |col| {
        try sheet.setColWidth(col, column_index, width, opts);
    }
}

pub fn setColWidth(
    sheet: *Sheet,
    col: *Column,
    index: u16,
    width: u16,
    opts: UndoOpts,
) Allocator.Error!void {
    if (width == col.width) return;
    const old_width = col.width;
    col.width = width;
    try sheet.pushUndo(
        .{
            .set_column_width = .{
                .col = index,
                .width = old_width,
            },
        },
        opts,
    );
}

pub fn incWidth(
    sheet: *Sheet,
    column_index: u16,
    n: u16,
    opts: UndoOpts,
) Allocator.Error!void {
    if (sheet.columns.getPtr(column_index)) |col| {
        try sheet.setColWidth(col, column_index, col.width +| n, opts);
    }
}

pub fn decWidth(
    sheet: *Sheet,
    column_index: u16,
    n: u16,
    opts: UndoOpts,
) Allocator.Error!void {
    if (sheet.columns.getPtr(column_index)) |col| {
        try sheet.setColWidth(col, column_index, col.width -| n, opts);
    }
}

pub fn setPrecision(
    sheet: *Sheet,
    column_index: u16,
    precision: u8,
    opts: UndoOpts,
) Allocator.Error!void {
    if (sheet.columns.getPtr(column_index)) |col| {
        try sheet.setColPrecision(col, column_index, precision, opts);
    }
}

pub fn setColPrecision(
    sheet: *Sheet,
    col: *Column,
    index: u16,
    precision: u8,
    opts: UndoOpts,
) Allocator.Error!void {
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
}

pub fn incPrecision(
    sheet: *Sheet,
    column_index: u16,
    n: u8,
    opts: UndoOpts,
) Allocator.Error!void {
    if (sheet.columns.getPtr(column_index)) |col| {
        try sheet.setColPrecision(col, column_index, col.precision +| n, opts);
    }
}

pub fn decPrecision(
    sheet: *Sheet,
    column_index: u16,
    n: u8,
    opts: UndoOpts,
) Allocator.Error!void {
    if (sheet.columns.getPtr(column_index)) |col| {
        try sheet.setColPrecision(col, column_index, col.precision -| n, opts);
    }
}

pub fn cellCount(sheet: *Sheet) u32 {
    return @intCast(u32, sheet.cells.entries.len);
}

pub fn colCount(sheet: *Sheet) u32 {
    return @intCast(u32, sheet.columns.entries.len);
}

/// Allocates enough space for `new_capacity` cells
pub fn ensureTotalCapacity(sheet: *Sheet, new_capacity: usize) Allocator.Error!void {
    return sheet.cells.ensureTotalCapacity(sheet.allocator, new_capacity);
}

pub fn setCellAst(
    sheet: *Sheet,
    position: Position,
    ast: Ast,
    undo_opts: UndoOpts,
) Allocator.Error!void {
    const col_entry = try sheet.columns.getOrPut(sheet.allocator, position.x);
    sheet.needs_update = true;

    if (!col_entry.found_existing) {
        col_entry.value_ptr.* = Column{};
    }

    if (!sheet.cells.contains(position)) {
        for (sheet.cells.keys(), 0..) |key, i| {
            if (key.hash() > position.hash()) {
                try sheet.cells.entries.insert(sheet.allocator, i, .{
                    .hash = {},
                    .key = position,
                    .value = .{
                        .ast = ast,
                    },
                });
                errdefer sheet.cells.entries.orderedRemove(i);

                // If this fails with OOM we could potentially end up with the map in an invalid
                // state. All instances of OOM must be recoverable. If we error here we remove the
                // newly inserted entry so that the old index remains correct.
                try sheet.cells.reIndex(sheet.allocator);

                try sheet.pushUndo(.{ .delete_cell = position }, undo_opts);

                sheet.has_changes = true;
                return;
            }
        }

        // Found no entries
        try sheet.cells.put(sheet.allocator, position, .{ .ast = ast });
        errdefer _ = sheet.cells.orderedRemove(position);

        try sheet.pushUndo(.{ .delete_cell = position }, undo_opts);
        sheet.has_changes = true;
        return;
    }

    const ptr = sheet.cells.getPtr(position).?;
    var old_ast = ptr.ast;

    ptr.ast = ast;
    ptr.num = std.math.nan(f64);
    sheet.has_changes = true;

    const index = sheet.createUndoAst(old_ast) catch |err| {
        old_ast.deinit(sheet.allocator);
        return err;
    };
    errdefer sheet.freeUndoAst(index);

    try sheet.pushUndo(
        .{
            .set_cell = .{
                .pos = position,
                .index = index,
            },
        },
        undo_opts,
    );
}

pub fn deleteCell(sheet: *Sheet, pos: Position, undo_opts: UndoOpts) Allocator.Error!void {
    var cell = sheet.cells.get(pos) orelse return;
    _ = sheet.cells.orderedRemove(pos);

    const index = sheet.createUndoAst(cell.ast) catch |err| {
        cell.ast.deinit(sheet.allocator);
        return err;
    };
    errdefer sheet.freeUndoAst(index);

    try sheet.pushUndo(
        .{
            .set_cell = .{
                .pos = pos,
                .index = index,
            },
        },
        undo_opts,
    );

    sheet.needs_update = true;
    sheet.has_changes = true;
}

pub fn deleteCellsInRange(sheet: *Sheet, p1: Position, p2: Position) Allocator.Error!void {
    var i: usize = 0;
    const positions = sheet.cells.keys();
    const tl = Position.topLeft(p1, p2);
    const br = Position.bottomRight(p1, p2);

    defer sheet.endUndoGroup();

    while (i < positions.len) {
        const pos = positions[i];
        if (pos.y > br.y) break;
        if (pos.y >= tl.y and pos.x >= tl.x and pos.x <= br.x) {
            try sheet.deleteCell(pos, .{});
        } else {
            i += 1;
        }
    }
}

pub fn getCell(sheet: Sheet, pos: Position) ?Cell {
    return sheet.cells.get(pos);
}

pub fn getCellPtr(sheet: *Sheet, pos: Position) ?*Cell {
    return sheet.cells.getPtr(pos);
}

/// Re-evaluates all cells in the sheet. Evaluates cells in reverse topological order to ensure
/// that each cell is only evaluated once. Cell results are cached after they are evaluted
/// (see Cell.eval)
pub fn update(sheet: *Sheet) Allocator.Error!void {
    if (!sheet.needs_update) return;

    log.debug("Updating...", .{});

    // Is void unless in debug build
    const begin = (if (builtin.mode == .Debug) std.time.Instant.now() catch unreachable else {});

    try sheet.rebuildSortedNodeList();

    for (sheet.sorted_nodes.items) |pos| {
        const cell = sheet.getCellPtr(pos).?;
        _ = try cell.eval(sheet);
    }

    sheet.needs_update = false;
    if (builtin.mode == .Debug) {
        log.debug("Finished update in {d} seconds", .{
            blk: {
                const now = std.time.Instant.now() catch unreachable;
                const elapsed = now.since(begin);
                break :blk @intToFloat(f64, elapsed) / std.time.ns_per_s;
            },
        });
    }
}

fn rebuildSortedNodeList(sheet: *Sheet) Allocator.Error!void {
    const node_count = @intCast(u32, sheet.cells.entries.len);

    // Topologically sorted set of cell positions
    sheet.visited_nodes.clearRetainingCapacity();
    sheet.sorted_nodes.clearRetainingCapacity();
    try sheet.visited_nodes.ensureTotalCapacity(sheet.allocator, node_count + 1);
    try sheet.sorted_nodes.ensureTotalCapacity(sheet.allocator, node_count + 1);

    for (sheet.cells.keys()) |pos| {
        if (!sheet.visited_nodes.contains(pos))
            visit(sheet, pos, &sheet.visited_nodes, &sheet.sorted_nodes);
    }
}

fn visit(
    sheet: *const Sheet,
    node: Position,
    nodes: *NodeMap,
    sorted_nodes: *NodeListUnmanaged,
) void {
    if (nodes.get(node)) |mark| {
        switch (mark) {
            .permanent => return,
            .temporary => unreachable,
        }
    }

    var cell = sheet.getCell(node) orelse return;

    if (cell.isEmpty()) return;

    nodes.putAssumeCapacity(node, .temporary);

    const Context = struct {
        sheet: *const Sheet,
        cell: *Cell,
        nodes: *NodeMap,
        sorted_nodes: *NodeListUnmanaged,

        pub fn evalCell(context: @This(), index: u32) !bool {
            const ast_node = context.cell.ast.nodes.get(index);
            if (ast_node == .cell and !context.nodes.contains(ast_node.cell)) {
                visit(context.sheet, ast_node.cell, context.nodes, context.sorted_nodes);
            }
            return true;
        }
    };

    _ = try cell.ast.traverse(.middle, Context{
        .sheet = sheet,
        .cell = &cell,
        .nodes = nodes,
        .sorted_nodes = sorted_nodes,
    });

    nodes.putAssumeCapacity(node, .permanent);
    sorted_nodes.appendAssumeCapacity(node);
}

pub fn getFilePath(sheet: Sheet) []const u8 {
    return sheet.filepath.slice();
}

pub fn setFilePath(sheet: *Sheet, filepath: []const u8) void {
    sheet.filepath.len = 0;
    sheet.filepath.appendSliceAssumeCapacity(filepath);
}

pub const Position = struct {
    x: u16 = 0,
    y: u16 = 0,

    pub fn format(
        pos: Position,
        comptime _: []const u8,
        _: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        try pos.writeCellAddress(writer);
    }

    pub fn hash(position: Position) u32 {
        return @as(u32, position.y) * (MAX + 1) + position.x;
    }

    pub fn topLeft(pos1: Position, pos2: Position) Position {
        return .{
            .x = @min(pos1.x, pos2.x),
            .y = @min(pos1.y, pos2.y),
        };
    }

    pub fn bottomRight(pos1: Position, pos2: Position) Position {
        return .{
            .x = @max(pos1.x, pos2.x),
            .y = @max(pos1.y, pos2.y),
        };
    }

    pub fn area(pos1: Position, pos2: Position) u32 {
        const start = topLeft(pos1, pos2);
        const end = bottomRight(pos1, pos2);

        return (@as(u32, end.x) + 1 - start.x) * (@as(u32, end.y) + 1 - start.y);
    }

    pub fn intersects(pos: Position, corner1: Position, corner2: Position) bool {
        const tl = topLeft(corner1, corner2);
        const br = bottomRight(corner1, corner2);

        return pos.y >= tl.y and pos.y <= br.y and pos.x >= tl.x and pos.x <= br.x;
    }

    /// Writes the cell address of this position to the given writer.
    pub fn writeCellAddress(pos: Position, writer: anytype) @TypeOf(writer).Error!void {
        try writeColumnAddress(pos.x, writer);
        try writer.print("{d}", .{pos.y});
    }

    /// Writes the alphabetic bijective base-26 representation of the given number to the passed
    /// writer.
    pub fn writeColumnAddress(index: u16, writer: anytype) @TypeOf(writer).Error!void {
        if (index < 26) {
            try writer.writeByte('A' + @intCast(u8, index));
            return;
        }

        // Max value is 'CRXP'
        var buf: [4]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const bufwriter = stream.writer();

        var i = @as(u32, index) + 1;
        while (i > 0) : (i /= 26) {
            i -= 1;
            const r = @intCast(u8, i % 26);
            bufwriter.writeByte('A' + r) catch unreachable;
        }

        const slice = stream.getWritten();
        std.mem.reverse(u8, slice);
        _ = try writer.writeAll(slice);
    }

    pub fn columnAddressBuf(index: u16, buf: []u8) []u8 {
        if (index < 26) {
            std.debug.assert(buf.len >= 1);
            buf[0] = 'A' + @intCast(u8, index);
            return buf[0..1];
        }

        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();

        var i = @as(u32, index) + 1;
        while (i > 0) : (i /= 26) {
            i -= 1;
            const r = @intCast(u8, i % 26);
            writer.writeByte('A' + r) catch break;
        }

        const slice = stream.getWritten();
        std.mem.reverse(u8, slice);
        return slice;
    }

    pub const FromAddressError = error{
        Overflow,
        InvalidCellAddress,
    };

    pub fn columnFromAddress(address: []const u8) FromAddressError!u16 {
        assert(address.len > 0);

        var ret: u32 = 0;
        for (address) |c| {
            if (!std.ascii.isAlphabetic(c))
                break;
            ret = ret *| 26 +| (std.ascii.toUpper(c) - 'A' + 1);
        }

        return if (ret > @as(u32, MAX) + 1) error.Overflow else @intCast(u16, ret - 1);
    }

    pub fn fromAddress(address: []const u8) FromAddressError!Position {
        const letters_end = for (address, 0..) |c, i| {
            if (!std.ascii.isAlphabetic(c))
                break i;
        } else unreachable;

        if (letters_end == 0) return error.InvalidCellAddress;

        return .{
            .x = try columnFromAddress(address[0..letters_end]),
            .y = std.fmt.parseInt(u16, address[letters_end..], 0) catch |err| switch (err) {
                error.Overflow => return error.Overflow,
                error.InvalidCharacter => return error.InvalidCellAddress,
            },
        };
    }

    test hash {
        const tuples = [_]struct { Position, u32 }{
            .{ Position{ .x = 0, .y = 0 }, 0 },
            .{ Position{ .x = 1, .y = 0 }, 1 },
            .{ Position{ .x = 1, .y = 1 }, MAX + 2 },
            .{ Position{ .x = 500, .y = 300 }, (MAX + 1) * 300 + 500 },
            .{ Position{ .x = 0, .y = 300 }, (MAX + 1) * 300 },
            .{ Position{ .x = MAX, .y = 0 }, MAX },
            .{ Position{ .x = 0, .y = MAX }, (MAX + 1) * MAX },
            .{ Position{ .x = MAX, .y = MAX }, std.math.maxInt(u32) },
        };

        for (tuples) |tuple| {
            try std.testing.expectEqual(tuple[1], tuple[0].hash());
        }
    }

    test fromAddress {
        const tuples = .{
            .{ "A1", Position{ .y = 1, .x = 0 } },
            .{ "AA7865", Position{ .y = 7865, .x = 26 } },
            .{ "AAA1000", Position{ .y = 1000, .x = 702 } },
            .{ "MM50000", Position{ .y = 50000, .x = 350 } },
            .{ "ZZ0", Position{ .y = 0, .x = 701 } },
            .{ "AAAA0", Position{ .y = 0, .x = 18278 } },
            .{ "CRXO0", Position{ .y = 0, .x = 65534 } },
            .{ "CRXP0", Position{ .y = 0, .x = 65535 } },
        };

        inline for (tuples) |tuple| {
            try std.testing.expectEqual(tuple[1], try Position.fromAddress(tuple[0]));
        }
    }
};

pub const Cell = struct {
    num: f64 = std.math.nan(f64),
    ast: Ast = .{},

    comptime {
        assert(@sizeOf(Cell) <= 40);
    }

    pub fn fromExpression(allocator: Allocator, expr: []const u8) !Cell {
        return .{
            .ast = try Ast.parseExpression(allocator, expr),
        };
    }

    pub fn deinit(cell: *Cell, allocator: Allocator) void {
        cell.ast.deinit(allocator);
        cell.* = undefined;
    }

    pub inline fn isEmpty(cell: Cell) bool {
        return cell.ast.nodes.len == 0;
    }

    pub fn eval(cell: *Cell, sheet: *Sheet) Allocator.Error!f64 {
        const Context = struct {
            sheet: *const Sheet,
            visited_cells: Map,

            const Map = std.HashMap(Position, void, PositionContext, 80);
            const EvalError = error{CyclicalReference} || Ast.EvalError || Allocator.Error;

            pub fn evalCell(context: *@This(), pos: Position) EvalError!?f64 {
                // Check for cyclical references
                const res = try context.visited_cells.getOrPut(pos);
                if (res.found_existing) {
                    log.debug("CYCLICAL REFERENCE at {}", .{pos});
                    return error.CyclicalReference;
                }

                const _cell = context.sheet.getCell(pos) orelse return null;
                switch (_cell.getValue()) {
                    .num => |num| return num,
                    else => {},
                }

                const ret = try _cell.ast.eval(context);
                _ = context.visited_cells.remove(pos);
                return ret;
            }
        };

        // Only heavily nested cell references will heap allocate
        var sfa = std.heap.stackFallback(4096, sheet.allocator);
        var context = Context{
            .sheet = sheet,
            .visited_cells = Context.Map.init(sfa.get()),
        };
        defer context.visited_cells.deinit();

        cell.num = cell.ast.eval(&context) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotEvaluable, error.CyclicalReference => {
                cell.num = std.math.nan(f64);
                return 0;
            },
        };

        return cell.num;
    }

    pub const Value = union(enum) {
        none,
        err,
        num: f64,
    };

    pub inline fn getValue(cell: Cell) Value {
        if (cell.isEmpty()) return .none;
        if (std.math.isNan(cell.num)) return .err;
        return .{ .num = cell.num };
    }

    pub fn format(
        cell: Cell,
        comptime _: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (cell.getValue()) {
            .none => {},
            .err => {
                try writer.writeAll("ERROR");
            },
            .num => |num| {
                try std.fmt.formatFloatDecimal(num, options, writer);
            },
        }
    }
};

pub const Column = struct {
    const CellMap = std.AutoArrayHashMapUnmanaged(u16, Cell);

    pub const default_width = 10;

    width: u16 = default_width,
    precision: u8 = 2,
};

pub fn getColumn(sheet: Sheet, index: u16) Column {
    return sheet.columns.get(index) orelse Column{};
}

test "Sheet basics" {
    const t = std.testing;

    var sheet = Sheet.init(t.allocator);
    defer sheet.deinit();

    try t.expectEqual(@as(u32, 0), sheet.cellCount());
    try t.expectEqual(@as(u32, 0), sheet.colCount());
    try t.expectEqualStrings("", sheet.filepath.slice());

    const ast1 = try Ast.parseExpression(t.allocator, "50 + 5");
    const ast2 = try Ast.parseExpression(t.allocator, "500 * 2 / 34 + 1");
    const ast3 = try Ast.parseExpression(t.allocator, "a0");
    const ast4 = try Ast.parseExpression(t.allocator, "a2 * a1");
    try sheet.setCellAst(.{ .x = 0, .y = 0 }, ast1, .{});
    try sheet.setCellAst(.{ .x = 0, .y = 1 }, ast2, .{});
    try sheet.setCellAst(.{ .x = 0, .y = 2 }, ast3, .{});
    try sheet.setCellAst(.{ .x = 0, .y = 3 }, ast4, .{});

    try t.expectEqual(@as(u32, 4), sheet.cellCount());
    try t.expectEqual(@as(u32, 1), sheet.colCount());
    try t.expectEqual(ast1, sheet.getCell(.{ .x = 0, .y = 0 }).?.ast);
    try t.expectEqual(ast2, sheet.getCell(.{ .x = 0, .y = 1 }).?.ast);
    try t.expectEqual(ast3, sheet.getCell(.{ .x = 0, .y = 2 }).?.ast);
    try t.expectEqual(ast4, sheet.getCell(.{ .x = 0, .y = 3 }).?.ast);

    // for (0..4) |y| {
    //const pos = .{ .x = 0, .y = @intCast(u16, y) };
    //try t.expectEqual(@as(?f64, null), sheet.cells.get(pos).?.getValue());
    // }
    try sheet.update();
    // for (0..4) |y| {
    // const pos = .{ .x = 0, .y = @intCast(u16, y) };
    // try t.expect(sheet.cells.get(pos).?.getValue() != null);
    // }

    try sheet.deleteCell(.{ .x = 0, .y = 0 }, .{});

    try t.expectEqual(@as(u32, 3), sheet.cellCount());
}

test "setCell allocations" {
    const t = std.testing;
    const Test = struct {
        fn testSetCellAllocs(allocator: Allocator) !void {
            var sheet = Sheet.init(allocator);
            defer sheet.deinit();

            {
                var ast = try Ast.parseExpression(allocator, "a4 * a1 * a3");
                errdefer ast.deinit(allocator);
                try sheet.setCellAst(.{ .x = 0, .y = 0 }, ast, .{});
            }

            {
                var ast = try Ast.parseExpression(allocator, "a2 * a1 * a3");
                errdefer ast.deinit(allocator);
                try sheet.setCellAst(.{ .x = 1, .y = 0 }, ast, .{});
            }

            try sheet.deleteCell(.{ .x = 0, .y = 0 }, .{});

            try sheet.update();
        }
    };

    try t.checkAllAllocationFailures(t.allocator, Test.testSetCellAllocs, .{});
}

test "Position.columnAddressBuf" {
    const t = std.testing;
    var buf: [4]u8 = undefined;

    try t.expectEqualStrings("A", Position.columnAddressBuf(0, &buf));
    try t.expectEqualStrings("AA", Position.columnAddressBuf(26, &buf));
    try t.expectEqualStrings("AAA", Position.columnAddressBuf(702, &buf));
    try t.expectEqualStrings("AAAA", Position.columnAddressBuf(18278, &buf));
    try t.expectEqualStrings("CRXP", Position.columnAddressBuf(MAX, &buf));
}

/// Tests setting cell values, updating cells, update time, and cell evaluation. Is
/// a function rather than a test so that we can check allocations with
/// `std.testing.checkAllAllocationFailures`
fn testCellEvaluation(allocator: Allocator) !void {
    const t = std.testing;
    var sheet = Sheet.init(allocator);
    defer sheet.deinit();

    const _setCell = struct {
        fn _setCell(
            _allocator: Allocator,
            _sheet: *Sheet,
            pos: Position,
            ast: Ast,
        ) Allocator.Error!void {
            var c = ast;
            defer _sheet.endUndoGroup();
            _sheet.setCellAst(pos, c, .{}) catch |err| {
                c.deinit(_allocator);
                return err;
            };
        }
    }._setCell;

    // Set cell values in random order
    try _setCell(allocator, &sheet, try Position.fromAddress("B17"), try Ast.parseExpression(allocator, "A17+B16"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G8"), try Ast.parseExpression(allocator, "G7+F8"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A9"), try Ast.parseExpression(allocator, "A8+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G11"), try Ast.parseExpression(allocator, "G10+F11"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E16"), try Ast.parseExpression(allocator, "E15+D16"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G10"), try Ast.parseExpression(allocator, "G9+F10"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D2"), try Ast.parseExpression(allocator, "D1+C2"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F2"), try Ast.parseExpression(allocator, "F1+E2"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B18"), try Ast.parseExpression(allocator, "A18+B17"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D15"), try Ast.parseExpression(allocator, "D14+C15"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D20"), try Ast.parseExpression(allocator, "D19+C20"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E13"), try Ast.parseExpression(allocator, "E12+D13"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C12"), try Ast.parseExpression(allocator, "C11+B12"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A16"), try Ast.parseExpression(allocator, "A15+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A10"), try Ast.parseExpression(allocator, "A9+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C19"), try Ast.parseExpression(allocator, "C18+B19"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F0"), try Ast.parseExpression(allocator, "E0+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B4"), try Ast.parseExpression(allocator, "A4+B3"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C11"), try Ast.parseExpression(allocator, "C10+B11"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B6"), try Ast.parseExpression(allocator, "A6+B5"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G5"), try Ast.parseExpression(allocator, "G4+F5"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A18"), try Ast.parseExpression(allocator, "A17+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D1"), try Ast.parseExpression(allocator, "D0+C1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G12"), try Ast.parseExpression(allocator, "G11+F12"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B5"), try Ast.parseExpression(allocator, "A5+B4"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D4"), try Ast.parseExpression(allocator, "D3+C4"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A5"), try Ast.parseExpression(allocator, "A4+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A0"), try Ast.parseExpression(allocator, "1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D13"), try Ast.parseExpression(allocator, "D12+C13"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A15"), try Ast.parseExpression(allocator, "A14+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A20"), try Ast.parseExpression(allocator, "A19+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G19"), try Ast.parseExpression(allocator, "G18+F19"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G13"), try Ast.parseExpression(allocator, "G12+F13"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G17"), try Ast.parseExpression(allocator, "G16+F17"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C14"), try Ast.parseExpression(allocator, "C13+B14"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B8"), try Ast.parseExpression(allocator, "A8+B7"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D10"), try Ast.parseExpression(allocator, "D9+C10"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F19"), try Ast.parseExpression(allocator, "F18+E19"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B11"), try Ast.parseExpression(allocator, "A11+B10"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F9"), try Ast.parseExpression(allocator, "F8+E9"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G7"), try Ast.parseExpression(allocator, "G6+F7"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C10"), try Ast.parseExpression(allocator, "C9+B10"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C2"), try Ast.parseExpression(allocator, "C1+B2"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D0"), try Ast.parseExpression(allocator, "C0+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C18"), try Ast.parseExpression(allocator, "C17+B18"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D6"), try Ast.parseExpression(allocator, "D5+C6"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C0"), try Ast.parseExpression(allocator, "B0+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B14"), try Ast.parseExpression(allocator, "A14+B13"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B19"), try Ast.parseExpression(allocator, "A19+B18"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G16"), try Ast.parseExpression(allocator, "G15+F16"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C8"), try Ast.parseExpression(allocator, "C7+B8"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G4"), try Ast.parseExpression(allocator, "G3+F4"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D18"), try Ast.parseExpression(allocator, "D17+C18"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E17"), try Ast.parseExpression(allocator, "E16+D17"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D3"), try Ast.parseExpression(allocator, "D2+C3"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E20"), try Ast.parseExpression(allocator, "E19+D20"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C6"), try Ast.parseExpression(allocator, "C5+B6"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E2"), try Ast.parseExpression(allocator, "E1+D2"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C1"), try Ast.parseExpression(allocator, "C0+B1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D17"), try Ast.parseExpression(allocator, "D16+C17"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C9"), try Ast.parseExpression(allocator, "C8+B9"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D12"), try Ast.parseExpression(allocator, "D11+C12"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F18"), try Ast.parseExpression(allocator, "F17+E18"));
    try _setCell(allocator, &sheet, try Position.fromAddress("H0"), try Ast.parseExpression(allocator, "G0+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D8"), try Ast.parseExpression(allocator, "D7+C8"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B12"), try Ast.parseExpression(allocator, "A12+B11"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E19"), try Ast.parseExpression(allocator, "E18+D19"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A14"), try Ast.parseExpression(allocator, "A13+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E14"), try Ast.parseExpression(allocator, "E13+D14"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F14"), try Ast.parseExpression(allocator, "F13+E14"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A13"), try Ast.parseExpression(allocator, "A12+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A19"), try Ast.parseExpression(allocator, "A18+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A4"), try Ast.parseExpression(allocator, "A3+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F7"), try Ast.parseExpression(allocator, "F6+E7"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A7"), try Ast.parseExpression(allocator, "A6+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E11"), try Ast.parseExpression(allocator, "E10+D11"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B1"), try Ast.parseExpression(allocator, "A1+B0"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A11"), try Ast.parseExpression(allocator, "A10+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B16"), try Ast.parseExpression(allocator, "A16+B15"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E12"), try Ast.parseExpression(allocator, "E11+D12"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F11"), try Ast.parseExpression(allocator, "F10+E11"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F1"), try Ast.parseExpression(allocator, "F0+E1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C4"), try Ast.parseExpression(allocator, "C3+B4"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G20"), try Ast.parseExpression(allocator, "G19+F20"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F16"), try Ast.parseExpression(allocator, "F15+E16"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D5"), try Ast.parseExpression(allocator, "D4+C5"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A17"), try Ast.parseExpression(allocator, "A16+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A22"), try Ast.parseExpression(allocator, "@sum(a0:g20)"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F4"), try Ast.parseExpression(allocator, "F3+E4"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B9"), try Ast.parseExpression(allocator, "A9+B8"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E4"), try Ast.parseExpression(allocator, "E3+D4"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F13"), try Ast.parseExpression(allocator, "F12+E13"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A1"), try Ast.parseExpression(allocator, "A0+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F3"), try Ast.parseExpression(allocator, "F2+E3"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F17"), try Ast.parseExpression(allocator, "F16+E17"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G14"), try Ast.parseExpression(allocator, "G13+F14"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D11"), try Ast.parseExpression(allocator, "D10+C11"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A2"), try Ast.parseExpression(allocator, "A1+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E9"), try Ast.parseExpression(allocator, "E8+D9"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B15"), try Ast.parseExpression(allocator, "A15+B14"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E18"), try Ast.parseExpression(allocator, "E17+D18"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E8"), try Ast.parseExpression(allocator, "E7+D8"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G18"), try Ast.parseExpression(allocator, "G17+F18"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A6"), try Ast.parseExpression(allocator, "A5+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C3"), try Ast.parseExpression(allocator, "C2+B3"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B0"), try Ast.parseExpression(allocator, "A0+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E10"), try Ast.parseExpression(allocator, "E9+D10"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B7"), try Ast.parseExpression(allocator, "A7+B6"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C7"), try Ast.parseExpression(allocator, "C6+B7"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D9"), try Ast.parseExpression(allocator, "D8+C9"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D14"), try Ast.parseExpression(allocator, "D13+C14"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B20"), try Ast.parseExpression(allocator, "A20+B19"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E7"), try Ast.parseExpression(allocator, "E6+D7"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E0"), try Ast.parseExpression(allocator, "D0+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A3"), try Ast.parseExpression(allocator, "A2+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G9"), try Ast.parseExpression(allocator, "G8+F9"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C17"), try Ast.parseExpression(allocator, "C16+B17"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F5"), try Ast.parseExpression(allocator, "F4+E5"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F6"), try Ast.parseExpression(allocator, "F5+E6"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G3"), try Ast.parseExpression(allocator, "G2+F3"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E5"), try Ast.parseExpression(allocator, "E4+D5"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A8"), try Ast.parseExpression(allocator, "A7+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B13"), try Ast.parseExpression(allocator, "A13+B12"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B3"), try Ast.parseExpression(allocator, "A3+B2"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D19"), try Ast.parseExpression(allocator, "D18+C19"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B2"), try Ast.parseExpression(allocator, "A2+B1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C5"), try Ast.parseExpression(allocator, "C4+B5"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G6"), try Ast.parseExpression(allocator, "G5+F6"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F12"), try Ast.parseExpression(allocator, "F11+E12"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E1"), try Ast.parseExpression(allocator, "E0+D1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C15"), try Ast.parseExpression(allocator, "C14+B15"));
    try _setCell(allocator, &sheet, try Position.fromAddress("A12"), try Ast.parseExpression(allocator, "A11+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G1"), try Ast.parseExpression(allocator, "G0+F1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D16"), try Ast.parseExpression(allocator, "D15+C16"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F20"), try Ast.parseExpression(allocator, "F19+E20"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E6"), try Ast.parseExpression(allocator, "E5+D6"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E15"), try Ast.parseExpression(allocator, "E14+D15"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F8"), try Ast.parseExpression(allocator, "F7+E8"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F10"), try Ast.parseExpression(allocator, "F9+E10"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C16"), try Ast.parseExpression(allocator, "C15+B16"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C20"), try Ast.parseExpression(allocator, "C19+B20"));
    try _setCell(allocator, &sheet, try Position.fromAddress("E3"), try Ast.parseExpression(allocator, "E2+D3"));
    try _setCell(allocator, &sheet, try Position.fromAddress("B10"), try Ast.parseExpression(allocator, "A10+B9"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G2"), try Ast.parseExpression(allocator, "G1+F2"));
    try _setCell(allocator, &sheet, try Position.fromAddress("D7"), try Ast.parseExpression(allocator, "D6+C7"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G15"), try Ast.parseExpression(allocator, "G14+F15"));
    try _setCell(allocator, &sheet, try Position.fromAddress("G0"), try Ast.parseExpression(allocator, "F0+1"));
    try _setCell(allocator, &sheet, try Position.fromAddress("F15"), try Ast.parseExpression(allocator, "F14+E15"));
    try _setCell(allocator, &sheet, try Position.fromAddress("C13"), try Ast.parseExpression(allocator, "C12+B13"));

    // Test that updating this takes less than 10 ms
    const begin = try std.time.Instant.now();
    try sheet.update();
    const elapsed_time = (try std.time.Instant.now()).since(begin);
    try t.expect(@intToFloat(f64, elapsed_time) / std.time.ns_per_ms < 10);

    // Test values of cells
    const testCell = struct {
        pub fn testCell(_sheet: *Sheet, pos: []const u8, expected: f64) !void {
            const cell = _sheet.getCell(try Position.fromAddress(pos)) orelse return error.CellNotFound;
            try t.expectApproxEqRel(expected, cell.num, 0.001);
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

    // Check that cells are ordered correctly
    const positions = sheet.cells.keys();
    var last_pos = positions[0];
    for (positions[1..]) |pos| {
        try t.expect(pos.hash() > last_pos.hash());
        last_pos = pos;
    }

    // Check undos
    try t.expectEqual(@as(usize, 298), sheet.undos.len);
    try t.expectEqual(@as(usize, 0), sheet.redos.len);

    try sheet.undo();
    try t.expectEqual(@as(usize, 296), sheet.undos.len);
    try t.expectEqual(@as(usize, 2), sheet.redos.len);

    try sheet.redo();
    try t.expectEqual(@as(usize, 298), sheet.undos.len);
    try t.expectEqual(@as(usize, 0), sheet.redos.len);

    try sheet.deleteCell(try Position.fromAddress("A22"), .{});
    try sheet.deleteCell(try Position.fromAddress("G20"), .{});
    sheet.endUndoGroup();

    try t.expectEqual(@as(usize, 301), sheet.undos.len);
    try t.expectEqual(@as(usize, 0), sheet.redos.len);

    try sheet.undo();
    try t.expectEqual(@as(usize, 298), sheet.undos.len);
    try t.expectEqual(@as(usize, 3), sheet.redos.len);
    try sheet.undo();
    try t.expectEqual(@as(usize, 296), sheet.undos.len);
    try t.expectEqual(@as(usize, 5), sheet.redos.len);
    try sheet.undo();
    try t.expectEqual(@as(usize, 294), sheet.undos.len);
    try t.expectEqual(@as(usize, 7), sheet.redos.len);

    try sheet.redo();
    try t.expectEqual(@as(usize, 296), sheet.undos.len);
    try t.expectEqual(@as(usize, 5), sheet.redos.len);
    try sheet.redo();
    try t.expectEqual(@as(usize, 298), sheet.undos.len);
    try t.expectEqual(@as(usize, 3), sheet.redos.len);
    try sheet.redo();
    try t.expectEqual(@as(usize, 301), sheet.undos.len);
    try t.expectEqual(@as(usize, 0), sheet.redos.len);
    try sheet.redo();
    try t.expectEqual(@as(usize, 301), sheet.undos.len);
    try t.expectEqual(@as(usize, 0), sheet.redos.len);
}

test "Cell assignment, updating, evaluation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testCellEvaluation, .{});
}
