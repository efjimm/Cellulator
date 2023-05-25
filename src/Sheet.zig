const std = @import("std");
const builtin = @import("builtin");
const utils = @import("utils.zig");
const Ast = @import("Parse.zig");

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

allocator: Allocator,

pub fn init(allocator: Allocator) Sheet {
    return .{
        .allocator = allocator,
    };
}

pub fn deinit(sheet: *Sheet) void {
    for (sheet.cells.values()) |*cell| {
        cell.deinit(sheet.allocator);
    }

    sheet.cells.deinit(sheet.allocator);
    sheet.visited_nodes.deinit(sheet.allocator);
    sheet.sorted_nodes.deinit(sheet.allocator);
    sheet.columns.deinit(sheet.allocator);
    sheet.* = undefined;
}

pub fn cellCount(sheet: *Sheet) u32 {
    return @intCast(u32, sheet.cells.entries.len);
}

pub fn colCount(sheet: *Sheet) u32 {
    return @intCast(u32, sheet.columns.entries.len);
}

pub fn setCell(
    sheet: *Sheet,
    position: Position,
    data: Cell,
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
                    .value = data,
                });

                // If this fails with OOM we could potentially end up with the map in an invalid
                // state. All instances of OOM must be recoverable. If we error here we remove the
                // newly inserted entry so that the old index remains correct.
                sheet.cells.reIndex(sheet.allocator) catch |err| switch (err) {
                    error.OutOfMemory => {
                        sheet.cells.entries.orderedRemove(i);
                        return err;
                    },
                };
                sheet.has_changes = true;
                return;
            }
        }

        // Found no entries
        try sheet.cells.put(sheet.allocator, position, data);
        sheet.has_changes = true;
        return;
    }

    const ptr = sheet.cells.getPtr(position).?;
    ptr.ast.deinit(sheet.allocator);
    ptr.* = data;
    sheet.has_changes = true;
}

pub fn deleteCell(sheet: *Sheet, pos: Position) ?Ast {
    const cell = sheet.cells.get(pos) orelse return null;
    _ = sheet.cells.orderedRemove(pos);
    sheet.needs_update = true;
    sheet.has_changes = true;

    return cell.ast;
}

pub fn deleteCellsInRange(sheet: *Sheet, p1: Position, p2: Position) void {
    var i: usize = 0;
    const positions = sheet.cells.keys();
    const tl = Position.topLeft(p1, p2);
    const br = Position.bottomRight(p1, p2);

    while (i < positions.len) {
        const pos = positions[i];
        if (pos.y > br.y) break;
        if (pos.y >= tl.y and pos.x >= tl.x and pos.x <= br.x) {
            var ast = sheet.deleteCell(pos).?;
            ast.deinit(sheet.allocator);
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
        return @as(u32, position.y) * std.math.maxInt(u16) + position.x;
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

    pub const FromAddressError = error{Overflow};

    pub fn columnFromAddress(address: []const u8) FromAddressError!u16 {
        assert(address.len > 0);

        var ret: u32 = 0;
        for (address) |c| {
            if (!std.ascii.isAlphabetic(c))
                break;
            ret = ret *| 26 +| (std.ascii.toUpper(c) - 'A' + 1);
        }

        return if (ret > @as(u32, std.math.maxInt(u16)) + 1) error.Overflow else @intCast(u16, ret - 1);
    }

    pub fn fromCellAddress(address: []const u8) FromAddressError!Position {
        assert(address.len > 1);
        assert(std.ascii.isAlphabetic(address[0]));
        assert(std.ascii.isDigit(address[address.len - 1]));

        const letters_end = for (address, 0..) |c, i| {
            if (!std.ascii.isAlphabetic(c))
                break i;
        } else unreachable;

        return .{
            .x = try columnFromAddress(address[0..letters_end]),
            .y = std.fmt.parseInt(u16, address[letters_end..], 0) catch |err| switch (err) {
                error.Overflow => return error.Overflow,
                error.InvalidCharacter => unreachable, // Invalid data should not get to this function
            },
        };
    }
};

pub const Cell = struct {
    // TODO: reduce memory usage
    //         store optional bit somewhere where it won't waste 63 bits
    //         reduce Ast.NodeList to from 24 to 16 bytes
    num: ?f64 = null,
    ast: Ast = .{},

    pub fn deinit(cell: *Cell, allocator: Allocator) void {
        cell.ast.deinit(allocator);
        cell.* = undefined;
    }

    pub inline fn isEmpty(cell: Cell) bool {
        return cell.ast.nodes.len == 0;
    }

    pub inline fn getValue(cell: *Cell, sheet: *Sheet) f64 {
        return cell.num orelse cell.eval(sheet);
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
                if (_cell.num) |num| return num;

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
                cell.num = null;
                return 0;
            },
        };

        return cell.num.?;
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

test {
    const t = std.testing;

    {
        var sheet = Sheet.init(t.allocator);
        defer sheet.deinit();

        try t.expectEqual(@as(u32, 0), sheet.cellCount());
        try t.expectEqual(@as(u32, 0), sheet.colCount());
        try t.expectEqualStrings("", sheet.filepath.slice());
    }
    {
        var sheet = Sheet.init(t.allocator);
        defer sheet.deinit();

        const cell1 = Cell{ .ast = try Ast.parseExpression(t.allocator, "50 + 5") };
        const cell2 = Cell{ .ast = try Ast.parseExpression(t.allocator, "500 * 2 / 34 + 1") };
        const cell3 = Cell{ .ast = try Ast.parseExpression(t.allocator, "a0") };
        const cell4 = Cell{ .ast = try Ast.parseExpression(t.allocator, "a2 * a1") };
        try sheet.setCell(.{ .x = 0, .y = 0 }, cell1);
        try sheet.setCell(.{ .x = 0, .y = 1 }, cell2);
        try sheet.setCell(.{ .x = 0, .y = 2 }, cell3);
        try sheet.setCell(.{ .x = 0, .y = 3 }, cell4);

        try t.expectEqual(@as(u32, 4), sheet.cellCount());
        try t.expectEqual(@as(u32, 1), sheet.colCount());
        try t.expectEqual(cell1, sheet.getCell(.{ .x = 0, .y = 0 }).?);
        try t.expectEqual(cell2, sheet.getCell(.{ .x = 0, .y = 1 }).?);
        try t.expectEqual(cell3, sheet.getCell(.{ .x = 0, .y = 2 }).?);
        try t.expectEqual(cell4, sheet.getCell(.{ .x = 0, .y = 3 }).?);

        for (0..4) |y| {
            const pos = .{ .x = 0, .y = @intCast(u16, y) };
            try t.expectEqual(@as(?f64, null), sheet.cells.get(pos).?.num);
        }
        try sheet.update();
        for (0..4) |y| {
            const pos = .{ .x = 0, .y = @intCast(u16, y) };
            try t.expect(sheet.cells.get(pos).?.num != null);
        }

        var ast = sheet.deleteCell(.{ .x = 0, .y = 0 }).?;
        ast.deinit(t.allocator);

        try t.expectEqual(@as(u32, 3), sheet.cellCount());
        try t.expectEqual(@as(?Ast, null), sheet.deleteCell(.{ .x = 0, .y = 0 }));
        try t.expectEqual(@as(u32, 3), sheet.cellCount());
    }
}

test {
    const t = std.testing;
    const Test = struct {
        fn testSetCellAllocs(allocator: Allocator) !void {
            var sheet = Sheet.init(allocator);
            defer sheet.deinit();

            {
                var cell1 = Cell{ .ast = try Ast.parseExpression(allocator, "a4 * a1 * a3") };
                errdefer cell1.deinit(allocator);
                try sheet.setCell(.{ .x = 0, .y = 0 }, cell1);
            }

            {
                var cell2 = Cell{ .ast = try Ast.parseExpression(allocator, "a2 * a1 * a3") };
                errdefer cell2.deinit(allocator);
                try sheet.setCell(.{ .x = 1, .y = 0 }, cell2);
            }

            var ast = sheet.deleteCell(.{ .x = 0, .y = 0 }).?;
            ast.deinit(allocator);

            try sheet.update();
        }
    };

    try t.checkAllAllocationFailures(t.allocator, Test.testSetCellAllocs, .{});
}

test "Position.fromCellAddress" {
    const t = std.testing;

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
        try t.expectEqual(tuple[1], try Position.fromCellAddress(tuple[0]));
    }
}

test "Position.columnAddressBuf" {
    const t = std.testing;
    var buf: [4]u8 = undefined;

    try t.expectEqualStrings("A", Position.columnAddressBuf(0, &buf));
    try t.expectEqualStrings("AA", Position.columnAddressBuf(26, &buf));
    try t.expectEqualStrings("AAA", Position.columnAddressBuf(702, &buf));
    try t.expectEqualStrings("AAAA", Position.columnAddressBuf(18278, &buf));
}
