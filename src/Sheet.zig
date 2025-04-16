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
const FlatListPool = @import("flat_list_pool.zig").FlatListPool;
const PhTree = @import("phtree.zig").PhTree;

const Sheet = @This();

allocator: Allocator,

/// True if there have been any changes since the last save
has_changes: bool,

/// List of cells that need to be re-evaluated.
queued_cells: std.ArrayListUnmanaged(struct { Cell.Handle, Cell.Handle.Int }),

/// Stores the null terminated text of string literals. Cells contain an index into this buffer.
strings_buf: std.ArrayListUnmanaged(u8),

/// Maps ranges to a list of cell handles that depend on them.
/// Used to query whether a cell belongs to a range and then update the cells
/// that depend on that range.
dependents: Dependents,
deps: std.ArrayListUnmanaged(Dep) = .empty,
free_deps: DepIndex = .none,

/// Range tree containing just the positions of extant cells.
/// Used for quick lookup of all extant cells in a range.
cell_tree: CellTree,

ast_nodes: std.MultiArrayList(ast.Node).Slice,

string_values: FlatListPool(u8),

// TODO: Only create columns for columns whose width/precision/whatever actually changes.
cols: Columns,

undos: UndoList,
redos: UndoList,

cell_buffer: std.ArrayListUnmanaged(Cell.Handle) = .empty,

search_buffer: std.ArrayListUnmanaged(Dependents.ValueHandle),

filepath: std.BoundedArray(u8, std.fs.max_path_bytes),

/// Used for temporary allocations
arena: std.heap.ArenaAllocator,

text_attrs: PhTree(TextAttrs, 2, Cell.Handle.Int),

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

    pub const Handle = @FieldType(Sheet, "text_attrs").ValueHandle;
};

pub fn setTextAlignment(
    sheet: *Sheet,
    cell: Cell.Handle,
    new_alignment: TextAttrs.Alignment,
) !void {
    const res = try sheet.text_attrs.getOrPut(sheet.allocator, sheet.cell_tree.getPoint(cell));
    if (!res.found_existing)
        res.value_ptr.* = .default;
    res.value_ptr.alignment = new_alignment;
}

pub fn clearTextAttrs(sheet: *Sheet, cell: Cell.Handle) void {
    _ = sheet.text_attrs.remove(cell);
}

const arena_retain_size = std.math.pow(usize, 2, 20);

pub const Dep = extern struct {
    handle: Cell.Handle,
    next: DepIndex,
};

pub const Columns = PhTree(Column, 1, u32);
pub const Dependents = PhTree(DepIndex, 4, usize);
pub const CellTree = @import("phtree.zig").PhTree(Cell, 2, usize);

fn createDep(sheet: *Sheet, dep: Dep) !DepIndex {
    if (sheet.free_deps.isValid()) {
        const ret = sheet.free_deps;
        sheet.free_deps = sheet.deps.items[ret.n].next;
        sheet.deps.items[ret.n] = dep;
        return ret;
    }

    const ret: DepIndex = .from(@intCast(sheet.deps.items.len));
    try sheet.deps.append(sheet.allocator, dep);
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

fn getStringSlice(sheet: *Sheet, index: StringIndex) [:0]const u8 {
    if (!index.isValid()) return "";
    const ptr: [*:0]const u8 = @ptrCast(sheet.strings_buf.items[index.n..].ptr);
    return std.mem.span(ptr);
}

pub fn posFromCellHandle(sheet: *Sheet, handle: Cell.Handle) Position {
    const point = sheet.cell_tree.getPoint(handle).*;
    return .init(point[0], point[1]);
}

pub fn rectFromCellHandle(sheet: *Sheet, handle: Cell.Handle) Rect {
    const point = sheet.cell_tree.getPoint(handle).*;
    const pos: Position = .init(point[0], point[1]);
    return .initSinglePos(pos);
}

pub fn init(allocator: Allocator) !Sheet {
    var sheet: Sheet = .{
        .allocator = allocator,
        .has_changes = false,

        .queued_cells = .empty,
        .strings_buf = .empty,

        .undos = .empty,
        .redos = .empty,

        .cell_tree = .empty,
        .dependents = .empty,
        .ast_nodes = .empty,
        .string_values = .empty,

        .cols = .empty,

        .search_buffer = .empty,

        .arena = .init(allocator),
        .filepath = .{},

        .text_attrs = .empty,
    };

    try sheet.undos.ensureTotalCapacity(allocator, 1);
    errdefer sheet.undos.deinit(allocator);
    try sheet.redos.ensureTotalCapacity(allocator, 1);

    return sheet;
}

pub fn deinit(sheet: *Sheet) void {
    sheet.strings_buf.deinit(sheet.allocator);
    sheet.search_buffer.deinit(sheet.allocator);

    sheet.clearUndos(.undo);
    sheet.clearUndos(.redo);
    sheet.dependents.deinit(sheet.allocator);
    sheet.cell_tree.deinit(sheet.allocator);

    sheet.queued_cells.deinit(sheet.allocator);
    sheet.undos.deinit(sheet.allocator);
    sheet.redos.deinit(sheet.allocator);

    sheet.cols.deinit(sheet.allocator);
    sheet.ast_nodes.deinit(sheet.allocator);
    sheet.string_values.deinit(sheet.allocator);
    sheet.deps.deinit(sheet.allocator);
    sheet.cell_buffer.deinit(sheet.allocator);
    sheet.text_attrs.deinit(sheet.allocator);
    sheet.arena.deinit();
}

pub fn getCellFromHandle(sheet: *Sheet, handle: Cell.Handle) *Cell {
    return sheet.cell_tree.getValue(handle);
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
        sentinel,
        delete_columns,
        insert_columns,
        delete_rows,
        insert_rows,
        update_range,
        update_pos,
        insert_dep,
        update_dep,
        insert_cell,
        bulk_cell_delete,
        bulk_cell_insert,
        bulk_cell_delete_contiguous,
        bulk_cell_insert_contiguous,
    };

    pub const Payload = extern union {
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
            ast_node: ast.Index,
            range: Rect,
        },
        update_pos: extern struct {
            ast_node: ast.Index,
            pos: Position,
        },
        insert_dep: Dependents.ValueHandle,
        update_dep: extern struct {
            handle: Dependents.ValueHandle,
            point: Dependents.Point,
        },
        bulk_cell_delete: u32,
        bulk_cell_insert: u32,
        bulk_cell_delete_contiguous: CellHandleInterval,
        bulk_cell_insert_contiguous: CellHandleInterval,

        const CellHandleInterval = extern struct {
            start: Cell.Handle.Int,
            end: Cell.Handle.Int,
        };
    };
};

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
    const binary_version = 8;
};

pub fn serialize(sheet: *Sheet, file: std.fs.File) !void {
    assert(sheet.queued_cells.items.len == 0);

    const header: SerializeHeader = .{
        .strings_buf_len = @intCast(sheet.strings_buf.items.len),
        .dependents = sheet.dependents.getHeader(),
        .deps_len = @intCast(sheet.deps.items.len),
        .deps_free = sheet.free_deps,
        .cell_tree = sheet.cell_tree.getHeader(),
        .ast_nodes_len = @intCast(sheet.ast_nodes.len),
        .ast_nodes_cap = @intCast(sheet.ast_nodes.capacity),
        .string_values = sheet.string_values.getHeader(),
        .cols = sheet.cols.getHeader(),
        .cells_buffer_len = @intCast(sheet.cell_buffer.items.len),
        .undos_len = @intCast(sheet.undos.len),
        .undos_cap = @intCast(sheet.undos.capacity),
        .redos_len = @intCast(sheet.redos.len),
        .redos_cap = @intCast(sheet.redos.capacity),
    };

    var iovecs = .{
        utils.ptrToIoVec(&header),
        utils.arrayListIoVec(&sheet.strings_buf),
    } ++ sheet.dependents.iovecs() ++ .{
        utils.arrayListIoVec(&sheet.deps),
    } ++ sheet.cell_tree.iovecs() ++
        utils.multiArrayListSliceIoVec(ast.Node, &sheet.ast_nodes) ++
        sheet.string_values.iovecs() ++
        sheet.cols.iovecs() ++
        .{utils.arrayListIoVec(&sheet.cell_buffer)} ++
        utils.multiArrayListIoVec(Undo, &sheet.undos) ++
        utils.multiArrayListIoVec(Undo, &sheet.redos);

    try file.writevAll(&iovecs);
}

pub fn deserialize(allocator: Allocator, file: std.fs.File) !Sheet {
    const header = try file.reader().readStruct(SerializeHeader);

    if (header.magic != SerializeHeader.magic_number) return error.InvalidFile;
    if (header.version != SerializeHeader.binary_version) return error.InvalidVersion;

    var sheet = try Sheet.init(allocator);
    errdefer sheet.deinit();

    sheet.free_deps = header.deps_free;

    var iovecs = [_]std.posix.iovec{
        try utils.prepArrayList(&sheet.strings_buf, allocator, header.strings_buf_len),
    } ++ try sheet.dependents.fromHeader(allocator, header.dependents) ++ .{
        try utils.prepArrayList(&sheet.deps, sheet.allocator, header.deps_len),
    } ++ try sheet.cell_tree.fromHeader(allocator, header.cell_tree) ++
        try utils.prepMultiArrayListSlice(ast.Node, &sheet.ast_nodes, allocator, header.ast_nodes_len, header.ast_nodes_cap) ++
        try sheet.string_values.fromHeader(sheet.allocator, header.string_values) ++
        try sheet.cols.fromHeader(allocator, header.cols) ++
        .{try utils.prepArrayList(&sheet.cell_buffer, sheet.allocator, header.cells_buffer_len)} ++
        try utils.prepMultiArrayList(Undo, &sheet.undos, allocator, header.undos_len, header.undos_cap) ++
        try utils.prepMultiArrayList(Undo, &sheet.redos, allocator, header.redos_len, header.redos_cap);

    _ = try file.readvAll(&iovecs);

    return sheet;
}

pub fn clearRetainingCapacity(sheet: *Sheet) void {
    sheet.cols.root = .invalid;

    sheet.queued_cells.clearRetainingCapacity();

    sheet.cell_tree.clearRetainingCapacity();

    sheet.dependents.clearRetainingCapacity();
    sheet.string_values.clearRetainingCapacity();
    sheet.ast_nodes.len = 0;

    sheet.undos.len = 0;
    sheet.redos.len = 0;
    sheet.strings_buf.clearRetainingCapacity();
    sheet.cols.clearRetainingCapacity();
    _ = sheet.arena.reset(.{ .retain_with_limit = arena_retain_size });
}

const Tokenizer = @import("Tokenizer.zig");

const Assignment = struct {
    root: ast.Index,
    pos: Position,
    strings: StringIndex,
};

/// Parses many cell assignments in bulk, appending their AST nodes to `Sheet.ast_nodes`.
/// Returns the total byte length of all parsed string literals
pub fn bulkParse(
    sheet: *Sheet,
    src: [:0]const u8,
    tokens_allocator: std.mem.Allocator,
    tokens: *std.MultiArrayList(Tokenizer.Token),
    cells_allocator: std.mem.Allocator,
    cells: *std.MultiArrayList(Assignment),
) !u32 {
    const line_count = blk: {
        var line_count: u32 = 1;
        for (src) |c| {
            if (c == '\n') line_count += 1;
        }
        break :blk line_count;
    };

    {
        var m = sheet.ast_nodes.toMultiArrayList();
        defer sheet.ast_nodes = m.slice();

        try m.ensureUnusedCapacity(sheet.allocator, line_count * 2);
    }

    try cells.ensureTotalCapacity(cells_allocator, line_count + 1);
    try tokens.ensureTotalCapacity(tokens_allocator, src.len / 2);

    // Parse each line
    var total_strings_len: u32 = 0;
    var lines = std.mem.tokenizeScalar(u8, src, '\n');

    tokens.clearRetainingCapacity();
    var t: Tokenizer = .init(src);
    while (true) {
        const token = t.next();
        try tokens.append(tokens_allocator, token);
        if (token.tag == .eof) break;
    }

    const token_tags = tokens.items(.tag);
    const token_starts = tokens.items(.start);

    var cells_slice = cells.slice();
    defer cells.* = cells_slice.toMultiArrayList();

    var token_index: u32 = 0;
    while (lines.next()) |_| {
        const strings_len, const token_sub_index = ast.fromSource2(
            sheet,
            src,
            token_tags[token_index..],
            token_starts[token_index..],
        ) catch |err| switch (err) {
            error.UnexpectedToken, error.InvalidCellAddress => continue,
            else => |e| return e,
        };
        token_index += token_sub_index;
        const expr_root: ast.Index = .from(@intCast(sheet.ast_nodes.len - 1));

        total_strings_len += strings_len + 1;

        const data = sheet.ast_nodes.items(.data);
        assert(sheet.ast_nodes.items(.tag)[expr_root.n] == .assignment);
        const pos = data[expr_root.n].assignment;
        sheet.ast_nodes.len -= 1;
        const spliced_root: ast.Index = .from(expr_root.n - 1);

        const index = cells_slice.len;
        cells_slice.len += 1;
        cells_slice.items(.root)[index] = spliced_root;
        cells_slice.items(.pos)[index] = pos;
    }

    return total_strings_len;
}

fn resetArena(sheet: *Sheet) void {
    _ = sheet.arena.reset(.{ .retain_with_limit = arena_retain_size });
}

// Optimized for bulk loading
pub fn interpretSource(sheet: *Sheet, reader: anytype) !void {
    errdefer sheet.clearRetainingCapacity();

    const arena = sheet.arena.allocator();
    defer sheet.resetArena();

    var cells: std.MultiArrayList(Assignment) = .empty;
    var tokens: std.MultiArrayList(Tokenizer.Token) = .empty;

    const buf_size = comptime std.math.pow(usize, 2, 22);
    var buf = try arena.alloc(u8, buf_size);
    buf[buf_size - 1] = 0;
    buf.len = 0;

    while (true) {
        buf.len += try reader.readAll(buf.ptr[buf.len .. buf_size - 1]);
        if (buf.len == 0) break;

        const end = std.mem.lastIndexOfScalar(u8, buf, '\n') orelse buf.len;
        buf.ptr[end] = 0;
        const src = buf.ptr[0..end :0];

        cells.clearRetainingCapacity();
        tokens.clearRetainingCapacity();
        const ast_nodes_start: u32 = @intCast(sheet.ast_nodes.len);
        const total_strings_len = try sheet.bulkParse(src, arena, &tokens, arena, &cells);
        assert(cells.len > 0);

        const dependent_count = blk: {
            var dependent_count: Cell.Handle.Int = 0;
            for (sheet.ast_nodes.items(.tag)[ast_nodes_start..]) |tag| {
                if (tag == .pos) dependent_count += 1;
            }
            break :blk dependent_count;
        };

        try sheet.cell_tree.ensureUnusedCapacity(sheet.allocator, @intCast(cells.len));
        try sheet.dependents.ensureUnusedCapacity(sheet.allocator, @intCast(dependent_count));
        try sheet.deps.ensureUnusedCapacity(sheet.allocator, dependent_count);
        try sheet.undos.ensureUnusedCapacity(sheet.allocator, cells.len);

        try sheet.strings_buf.ensureUnusedCapacity(sheet.allocator, total_strings_len);
        try sheet.cols.ensureUnusedCapacity(sheet.allocator, @intCast(cells.len));
        try sheet.queued_cells.ensureUnusedCapacity(sheet.allocator, 1);
        errdefer comptime unreachable;

        const cells_slice = cells.slice();

        // Copy the string values from every cell into the string table
        var start: u32 = ast_nodes_start;
        for (cells_slice.items(.root), cells_slice.items(.strings)) |root, *string_index| {
            string_index.* = sheet.dupeAstStrings(src, .from(start), root);
            start = root.n + 1;
        }

        // TODO: Should we even create undos for loading a sheet?
        // Create all undos
        for (cells_slice.items(.pos)) |pos| {
            sheet.undos.appendAssumeCapacity(.init(.delete_cell, pos));
        }

        // Queue up all the to-be-inserted cells for update
        const start_node_index = sheet.cell_tree.values.len;
        sheet.cell_tree.values.len += cells.len;
        assert(sheet.cell_tree.values.len <= sheet.cell_tree.values.capacity);

        sheet.queued_cells.appendAssumeCapacity(.{
            .from(@intCast(start_node_index)),
            @intCast(cells.len),
        });

        sheet.has_changes = true;

        for (
            cells_slice.items(.root),
            cells_slice.items(.pos),
            cells_slice.items(.strings),
            start_node_index..,
        ) |root, pos, strings, i| {
            const handle: Cell.Handle = .from(@intCast(i));
            sheet.setCell2(pos, handle, root, strings);
        }

        if (end + 1 < buf.len) {
            std.mem.copyForwards(u8, buf, buf[end + 1 ..]);
            buf.len -= end + 1;
        } else {
            buf.len = 0;
        }
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

    log.debug("Loading file {s}", .{filepath});

    sheet.clearRetainingCapacity();
    try sheet.interpretSource(file.reader());
}

pub fn writeFile(
    sheet: *Sheet,
    opts: struct {
        filepath: ?[]const u8 = null,
    },
) !void {
    const filepath = opts.filepath orelse sheet.filepath.slice();
    if (filepath.len == 0)
        return error.EmptyFileName;

    var atomic_file = try std.fs.cwd().atomicFile(filepath, .{});
    defer atomic_file.deinit();

    try sheet.writeContents(atomic_file.file.writer());
    try atomic_file.finish();

    if (opts.filepath) |path|
        sheet.setFilePath(path);
}

pub fn writeContents(sheet: *Sheet, writer: anytype) !void {
    var buf = std.io.bufferedWriter(writer);
    const buf_writer = buf.writer();

    var iter = sheet.cell_tree.iterator();
    while (iter.next()) |handle| {
        const p = sheet.cell_tree.getPoint(handle).*;
        const pos: Position = .init(p[0], p[1]);
        try buf_writer.print("let {}=", .{pos});
        try sheet.printCellExpression(pos, buf_writer);
        try buf_writer.writeByte('\n');
    }

    try buf.flush();
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

    fn next(it: *ExprRangeIterator) ?Rect {
        if (it.i == it.start) return null;

        const data = it.sheet.ast_nodes.items(.data);

        var iter = std.mem.reverseIterator(it.sheet.ast_nodes.items(.tag)[it.start.n..it.i.n]);
        defer it.i = .from(@intCast(it.start.n + iter.index));

        while (iter.next()) |tag| switch (tag) {
            .pos => {
                return .initSinglePos(data[it.start.n + iter.index].pos);
            },
            .range => {
                const r = data[it.start.n + iter.index].range;
                const p1 = data[r.lhs.n].pos;
                const p2 = data[r.rhs.n].pos;
                _ = iter.next().?;
                _ = iter.next().?;
                return .{ .tl = p1, .br = p2 };
            },
            else => {},
        };

        return null;
    }
};

/// Adds `dependent_range` as a dependent of all cells in `range`.
fn addRangeDependents(
    sheet: *Sheet,
    dependent: Cell.Handle,
    range: Rect,
) void {
    // log.debug("Adding {} as a dependent of {}", .{
    //     sheet.rectFromCellHandle(dependent).tl,
    //     range,
    // });

    const p: Dependents.Point = .{
        range.tl.x, range.tl.y,
        range.br.x, range.br.y,
    };
    const res = sheet.dependents.getOrPutAssumeCapacity(&p);
    const head_ptr = res.value_ptr;
    if (!res.found_existing) {
        head_ptr.* = .none;
    }

    const index = sheet.createDepAssumeCapacity(.{
        .handle = dependent,
        .next = head_ptr.*,
    });
    head_ptr.* = index;
}

fn addExpressionDependents(
    sheet: *Sheet,
    dependent: Cell.Handle,
    expr_root: ast.Index,
) void {
    var iter: ExprRangeIterator = .init(sheet, expr_root);
    while (iter.next()) |range| {
        sheet.addRangeDependents(dependent, range);
    }
}

fn ensureExpressionDependentsCapacity(sheet: *Sheet, expr_root: ast.Index) Allocator.Error!void {
    const left = ast.leftMostChild(sheet.ast_nodes, expr_root);
    var dependent_count: u32 = 0;
    for (sheet.ast_nodes.items(.tag)[left.n .. expr_root.n + 1]) |tag| {
        if (tag == .pos)
            dependent_count += 1;
    }

    try sheet.dependents.ensureUnusedCapacity(sheet.allocator, dependent_count);
    try sheet.deps.ensureUnusedCapacity(sheet.allocator, dependent_count);
}

/// Removes `cell` as a dependent of all cells in `rect`
fn removeRangeDependents(
    sheet: *Sheet,
    dependent: Cell.Handle,
    range: Rect,
) void {
    // log.debug("Removing {} as a dependent of {}", .{
    //     sheet.rectFromCellHandle(dependent),
    //     range,
    // });
    const p: Dependents.Point = .{
        range.tl.x, range.tl.y,
        range.br.x, range.br.y,
    };
    const head = (sheet.dependents.find(&p) orelse return);

    while (head.isValid() and sheet.deps.items[head.n].handle == dependent) {
        const old_head = head.*;
        head.* = sheet.deps.items[head.n].next;
        sheet.destroyDep(old_head);
    }

    if (!head.isValid()) {
        if (sheet.dependents.remove(&p)) |kv_handle|
            sheet.dependents.destroyValue(kv_handle);
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
            sheet.dependents.destroyValue(kv_handle);
    }
}

/// Removes `cell` as a dependent of all ranges referenced by `expr`.
fn removeExprDependents(
    sheet: *Sheet,
    dependent: Cell.Handle,
    expr_root: ast.Index,
) void {
    var iter = ExprRangeIterator.init(sheet, expr_root);
    while (iter.next()) |range| {
        sheet.removeRangeDependents(dependent, range);
    }
}

pub fn firstCellInRow(sheet: *Sheet, row: Position.Int) !?Position {
    var results: std.ArrayList(Cell.Handle) = .init(sheet.allocator);
    defer results.deinit();

    try sheet.cell_tree.queryWindow(&.{ 0, row }, &.{ std.math.maxInt(u32), row }, &results);

    var min: ?PosInt = null;
    for (results.items) |handle| {
        const x = sheet.cell_tree.getPoint(handle).*[0];
        if (min == null or x < min.?) min = x;
    }

    return if (min) |x| .{ .x = x, .y = row } else null;
}

pub fn lastCellInRow(sheet: *Sheet, row: Position.Int) !?Position {
    var results: std.ArrayList(Cell.Handle) = .init(sheet.allocator);
    defer results.deinit();

    try sheet.cell_tree.queryWindow(&.{ 0, row }, &.{ std.math.maxInt(u32), row }, &results);

    var max: ?PosInt = null;
    for (results.items) |handle| {
        const x = sheet.cell_tree.getPoint(handle).*[0];
        if (max == null or x > max.?) max = x;
    }

    return if (max) |x| .{ .x = x, .y = row } else null;
}

// TODO: Optimize these

pub fn firstCellInColumn(sheet: *Sheet, col: Position.Int) !?Position {
    var results: std.ArrayList(Cell.Handle) = .init(sheet.allocator);
    defer results.deinit();

    try sheet.cell_tree.queryWindow(&.{ col, 0 }, &.{ col, std.math.maxInt(u32) }, &results);

    var min: ?PosInt = null;
    for (results.items) |handle| {
        const y = sheet.cell_tree.getPoint(handle).*[1];
        if (min == null or y < min.?) min = y;
    }

    return if (min) |y| .{ .x = col, .y = y } else null;
}

pub fn lastCellInColumn(sheet: *Sheet, col: Position.Int) !?Position {
    var results: std.ArrayList(Cell.Handle) = .init(sheet.allocator);
    defer results.deinit();

    try sheet.cell_tree.queryWindow(&.{ col, 0 }, &.{ col, std.math.maxInt(u32) }, &results);

    var max: ?PosInt = null;
    for (results.items) |handle| {
        const y = sheet.cell_tree.getPoint(handle).*[1];
        if (max == null or y > max.?) max = y;
    }

    return if (max) |y| .{ .x = col, .y = y } else null;
}

/// Given a range, find the first or last row that contains a cell
fn findExtantRow(sheet: *Sheet, r: Rect, comptime p: enum { first, last }) !?PosInt {
    var sfa = std.heap.stackFallback(1024, sheet.allocator);
    const allocator = sfa.get();

    var results: std.ArrayList(Cell.Handle) = .init(allocator);
    defer results.deinit();

    try sheet.cell_tree.queryWindow(&.{ r.tl.x, r.tl.y }, &.{ r.br.x, r.br.y }, &results);

    if (results.items.len == 0) return null; // Range does not contain any cells

    var result_y: u32 = sheet.cell_tree.getPoint(results.items[0]).*[1];
    for (results.items[1..]) |handle| {
        const y = sheet.cell_tree.getPoint(handle).*[1];
        switch (p) {
            .first => if (y < result_y) {
                result_y = y;
            },
            .last => if (y > result_y) {
                result_y = y;
            },
        }
    }
    return result_y;
}

/// Given a range, find the first or last column that contains a cell
fn findExtantCol(sheet: *Sheet, r: Rect, comptime p: enum { first, last }) !?PosInt {
    var sfa = std.heap.stackFallback(1024, sheet.allocator);
    const allocator = sfa.get();

    var results: std.ArrayList(Cell.Handle) = .init(allocator);
    defer results.deinit();

    try sheet.cell_tree.queryWindow(&.{ r.tl.x, r.tl.y }, &.{ r.br.x, r.br.y }, &results);

    if (results.items.len == 0) return null; // Range does not contain any cells

    var result_x: u32 = sheet.cell_tree.getPoint(results.items[0]).*[0];
    for (results.items[1..]) |handle| {
        const x = sheet.cell_tree.getPoint(handle).*[0];
        switch (p) {
            .first => if (x < result_x) {
                result_x = x;
            },
            .last => if (x > result_x) {
                result_x = x;
            },
        }
    }
    return result_x;
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
    undo_type: UndoType = .undo,
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
    if (sheet.undos.len == 0 or sheet.undos.items(.tag)[sheet.undos.len - 1] == .sentinel)
        return;
    sheet.undos.appendAssumeCapacity(.sentinel);
}

fn endRedoGroup(sheet: *Sheet) void {
    if (sheet.redos.len == 0) return;
    sheet.redos.appendAssumeCapacity(.sentinel);
}

pub fn ensureUnusedUndoCapacity(sheet: *Sheet, n: u32) Allocator.Error!void {
    try sheet.undos.ensureUnusedCapacity(sheet.allocator, n + 1);
    try sheet.redos.ensureUnusedCapacity(sheet.allocator, n + 1);
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
            _ = try sheet.cell_tree.insert(sheet.allocator, &p, handle);
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
            try sheet.deleteColumnRange(p.start, p.end, opts);
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
            try sheet.deleteRowRange(p.start, p.end, opts);
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
            try sheet.updateRange(p.ast_node, p.range, opts);
        },
        .update_pos => {
            const pos = u.payload.update_pos.pos;
            const i = u.payload.update_pos.ast_node;
            try sheet.updatePos(i, pos, opts);
        },
        .insert_dep => {
            const handle = u.payload.insert_dep;
            const p = sheet.dependents.getPoint(handle).*;
            _ = try sheet.dependents.insert(sheet.allocator, &p, handle);
        },
        .update_dep => {
            const handle = u.payload.update_dep.handle;
            const new_point = u.payload.update_dep.point;
            assert(handle.isValid());

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
        sheet.removeExprDependents(handle, cell.expr_root);
        sheet.setCellError(cell);
        sheet.cell_tree.removeHandle(handle);
    }
}

fn bulkDeleteCellHandlesContiguous(sheet: *Sheet, start: Cell.Handle.Int, end: Cell.Handle.Int) void {
    assert(start < sheet.cell_tree.values.len);
    assert(end <= sheet.cell_tree.values.len);

    for (start..end) |i| {
        const handle: Cell.Handle = .from(@intCast(i));
        const cell = sheet.getCellFromHandle(handle);
        // TODO: Doing this in a separate loop from removeHandle might be better
        sheet.removeExprDependents(handle, cell.expr_root);
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
        const removed = sheet.cell_tree.insertAssumeCapacity(&p, handle);
        assert(!removed.isValid());
        sheet.addExpressionDependents(handle, cell.expr_root);
        cell.state = .enqueued;
    }
}

fn bulkInsertCellHandlesContiguous(sheet: *Sheet, start: Cell.Handle.Int, end: Cell.Handle.Int) void {
    assert(start < sheet.cell_tree.values.len);
    assert(end <= sheet.cell_tree.values.len);

    sheet.queued_cells.appendAssumeCapacity(.{ .from(start), end - start });
    for (start..end) |i| {
        const handle: Cell.Handle = .from(@intCast(i));
        const cell = sheet.getCellFromHandle(handle);
        const p = sheet.cell_tree.getPoint(handle).*;
        const removed = sheet.cell_tree.insertAssumeCapacity(&p, handle);
        assert(!removed.isValid());
        sheet.addExpressionDependents(handle, cell.expr_root);
        cell.state = .enqueued;
    }
}

fn getUndoCellsSlice(sheet: *Sheet, index: u32) []Cell.Handle {
    for (sheet.cell_buffer.items[index..], index..) |handle, i| {
        if (!handle.isValid()) {
            assert(i > index);
            return sheet.cell_buffer.items[index..i];
        }
    }

    unreachable;
}

fn updatePos(sheet: *Sheet, index: ast.Index, new_pos: Position, _: UndoOpts) !void {
    const tag = sheet.ast_nodes.items(.tag)[index.n];
    assert(tag == .pos or tag == .invalidated_pos);
    try sheet.ensureUnusedUndoCapacity(1);

    const ptr = &sheet.ast_nodes.items(.data)[index.n];
    ptr.pos = new_pos;
    sheet.ast_nodes.items(.tag)[index.n] = .pos;
}

fn updateRange(sheet: *Sheet, index: ast.Index, new_range: Rect, _: UndoOpts) !void {
    const tag = sheet.ast_nodes.items(.tag)[index.n];
    assert(tag == .range or tag == .invalidated_range);
    try sheet.ensureUnusedUndoCapacity(1);

    const ptr = &sheet.ast_nodes.items(.data)[index.n].range;
    const lhs = &sheet.ast_nodes.items(.data)[ptr.lhs.n].pos;
    const rhs = &sheet.ast_nodes.items(.data)[ptr.rhs.n].pos;

    lhs.* = new_range.tl;
    rhs.* = new_range.br;
    sheet.ast_nodes.items(.tag)[index.n] = .range;
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
    if (sheet.getColumnHandle(column_index)) |handle| {
        const col = sheet.cols.getValue(handle);
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
        const col = sheet.cols.getValue(handle);
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
    if (sheet.getColumnHandle(column_index)) |handle| {
        const col = sheet.cols.getValue(handle);
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
        const col = sheet.cols.getValue(handle);
        try sheet.setColPrecision(handle, column_index, col.precision -| n, opts);
    }
}

pub fn needsUpdate(sheet: *const Sheet) bool {
    return sheet.queued_cells.items.len > 0;
}

fn dupeAstStrings(
    sheet: *Sheet,
    source: []const u8,
    start: ast.Index,
    root_node: ast.Index,
) StringIndex {
    assert(root_node.n < sheet.ast_nodes.len);
    assert(start.n <= root_node.n);

    const tags = sheet.ast_nodes.items(.tag)[start.n .. root_node.n + 1];
    const data = sheet.ast_nodes.items(.data)[start.n .. root_node.n + 1];

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

fn ensureUnusedCellCapacity(sheet: *Sheet, n: u32) !void {
    try sheet.cell_tree.ensureUnusedCapacity(sheet.allocator, n);
}

fn ensureUnusedStringsCapacity(sheet: *Sheet, n: u32) !void {
    try sheet.strings_buf.ensureUnusedCapacity(sheet.allocator, n + 1);
}

fn ensureUnusedCellQueueCapacity(sheet: *Sheet, n: u32) !void {
    try sheet.queued_cells.ensureUnusedCapacity(sheet.allocator, n);
}

fn ensureUnusedColumnCapacity(sheet: *Sheet, n: u32) !void {
    try sheet.cols.ensureUnusedCapacity(sheet.allocator, n);
}

fn ensureUnusedAstNodeCapacity(sheet: *Sheet, n: u32) !void {
    var m = sheet.ast_nodes.toMultiArrayList();
    defer sheet.ast_nodes = m.slice();

    try m.ensureUnusedCapacity(sheet.allocator, n);
}

fn ensureUnusedCellBufferCapacity(sheet: *Sheet, n: u32) !void {
    try sheet.cell_buffer.ensureUnusedCapacity(sheet.allocator, n);
}

// TODO: This could be done without allocating by walking the ph-tree and removing as we go.
/// Deletes a cell range, pushing a `.bulk_cell_insert` undo. Asserts that `undo_cell_buffer` and the
/// respective undo stack has enough capacity.
fn deleteCellRangeAssumeCapacity(sheet: *Sheet, range: Rect, opts: UndoOpts) void {
    assert(sheet.cell_buffer.capacity - sheet.cell_buffer.items.len >= range.area() + 1);
    assert(opts.undo_type == .redo or sheet.undos.capacity - sheet.undos.len > 0);
    assert(opts.undo_type == .undo or sheet.redos.capacity - sheet.redos.len > 0);

    const existing_cells: []const Cell.Handle, const deleted_index: u32 = blk: {
        var buf = sheet.cell_buffer.toManaged(sheet.allocator);
        defer sheet.cell_buffer = buf.moveToUnmanaged();
        const start = buf.items.len;
        sheet.cell_tree.queryWindow(
            &.{ range.tl.x, range.tl.y },
            &.{ range.br.x, range.br.y },
            &buf,
        ) catch unreachable;

        if (buf.items.len == start) {
            break :blk .{ &.{}, std.math.maxInt(u32) };
        }

        buf.appendAssumeCapacity(.invalid);
        break :blk .{ buf.items[start .. buf.items.len - 1], @intCast(start) };
    };

    for (existing_cells) |cell_handle| {
        const old_cell = sheet.getCellFromHandle(cell_handle);
        sheet.removeExprDependents(cell_handle, old_cell.expr_root);
        sheet.cell_tree.removeHandle(cell_handle);
        sheet.setCellError(old_cell);
    }

    if (existing_cells.len > 0) {
        sheet.pushUndoAssumeCapacity(.init(.bulk_cell_insert, deleted_index), opts);
    }
}

pub fn insertIncrementingCellRange(sheet: *Sheet, range: Rect, start: f64, incr: f64, opts: UndoOpts) !void {
    const area: u32 = @intCast(range.area());
    try sheet.ensureUnusedCellCapacity(area);
    try sheet.ensureUnusedAstNodeCapacity(area);
    // One for deleting existing cells, one for inserting new cells
    try sheet.ensureUnusedUndoCapacity(2);
    try sheet.ensureUnusedCellQueueCapacity(1);
    try sheet.ensureUnusedCellBufferCapacity(area + 1);
    try sheet.ensureUnusedColumnCapacity(range.width());
    errdefer comptime unreachable;

    // These cells don't have any dependencies or strings that need to be stored.

    // Delete existing cells

    sheet.deleteCellRangeAssumeCapacity(range, opts);

    const ast_start = sheet.ast_nodes.len;
    sheet.ast_nodes.len += area;
    for (ast_start..sheet.ast_nodes.len, 0..) |i, j| {
        const f: f64 = @floatFromInt(j);
        sheet.ast_nodes.set(i, .{
            .tag = .number,
            .data = .{ .number = start + incr * f },
        });
    }

    sheet.createColumnRangeAssumeCapacity(range);

    const cells_start = sheet.bulkCreateCellRange(range);
    sheet.queued_cells.appendAssumeCapacity(.{ cells_start, area });
    for (0..area) |i| {
        const handle: Cell.Handle = .from(@intCast(i + cells_start.n));
        const expr: ast.Index = .from(@intCast(i + ast_start));
        sheet.cell_tree.getValue(handle).* = .{
            .state = .enqueued,
            .expr_root = expr,
            .strings = .invalid,
        };
    }

    sheet.bulkInsertContiguousCells(cells_start, opts);
}

/// Creates a new cell handle for every cell in `range`. Only sets the point field of each handle.
/// Only allocates memory for the cell tree.
pub fn bulkCreateCellRange(sheet: *Sheet, range: Rect) Cell.Handle {
    const area: u32 = @intCast(range.area());
    // assert(sheet.cell_tree.nodes.capacity - sheet.cell_tree.nodes.len >= area);
    const start: Cell.Handle = .from(@intCast(sheet.cell_tree.values.len));
    sheet.cell_tree.values.len += area;

    var i = start.n;
    var y: u64 = range.tl.y;
    while (y <= range.br.y) : (y += 1) {
        var x: u64 = range.tl.x;
        while (x <= range.br.x) : (x += 1) {
            sheet.cell_tree.getPoint(.from(i)).* = .{
                @intCast(x),
                @intCast(y),
            };
            i += 1;
        }
    }

    return start;
}

/// Inserts all the cells from `cells_start` to `sheet.cell_tree.entries.len` into the cell tree.
/// Also inserts dependency information. Asserts that the cell tree and undo cell buffer has enough
/// capacity to hold all the cells.
pub fn bulkInsertContiguousCells(
    sheet: *Sheet,
    cells_start: Cell.Handle,
    opts: UndoOpts,
) void {
    const cell_count = sheet.cell_tree.values.len - cells_start.n;
    assert(sheet.cell_tree.values.len <= sheet.cell_tree.values.capacity);
    assert(cell_count > 0);
    assert(sheet.cell_buffer.capacity - sheet.cell_buffer.items.len >= cell_count + 1);

    const end = sheet.cell_tree.values.len;
    for (cells_start.n..end) |i| {
        const handle: Cell.Handle = .from(@intCast(i));
        const p = sheet.cell_tree.getPoint(handle).*;
        const removed = sheet.cell_tree.insertAssumeCapacity(&p, handle);
        assert(!removed.isValid());
        sheet.addExpressionDependents(handle, sheet.getCellFromHandle(handle).expr_root);
        sheet.getCellFromHandle(handle).state = .enqueued;
    }

    sheet.pushUndoAssumeCapacity(.init(.bulk_cell_delete_contiguous, .{
        .start = cells_start.n,
        .end = @intCast(end),
    }), opts);
}

/// Creates all the columns required by range.
fn createColumnRangeAssumeCapacity(sheet: *Sheet, range: Rect) void {
    const width = range.width();
    const cols_start = sheet.cols.values.len;
    sheet.cols.values.len += width;
    @memset(sheet.cols.values.items(.value)[cols_start..], .{});

    for (sheet.cols.values.items(.point)[cols_start..], range.tl.x.., cols_start..) |*p, x, i| {
        p.* = .{@intCast(x)};
        const handle: Column.Handle = .from(@intCast(i));
        const res = sheet.cols.getOrPutAssumeCapacity(p);
        if (res.found_existing) {
            // Put the new column in the free list
            sheet.cols.destroyValue(handle);
        }

        res.value_ptr.* = .{};
    }
}

pub const BulkSetCellOptions = struct {
    value: Cell.Value = .{ .err = .fromError(error.NotEvaluable) },
    tag: Cell.Value.Tag = .err,
    undo_opts: UndoOpts = .{},
};

/// Sets all cells in `range` to `expr`.
pub fn bulkSetCellExpr(
    sheet: *Sheet,
    range: Rect,
    source: []const u8,
    expr: ast.Index,
    opts: BulkSetCellOptions,
) !void {
    const need_cell_eval = opts.tag != .err;
    // Pre-allocate memory
    const area: u32 = @intCast(range.area());
    const width = range.width();
    try sheet.ensureUnusedCellCapacity(area);
    try sheet.ensureUnusedStringsCapacity(@intCast(source.len));
    if (need_cell_eval)
        try sheet.ensureUnusedCellQueueCapacity(1);
    try sheet.ensureExpressionDependentsCapacity(expr);
    try sheet.ensureUnusedColumnCapacity(width);
    try sheet.ensureUnusedUndoCapacity(2);
    try sheet.ensureUnusedCellBufferCapacity(area + 1);

    const ref_count = blk: {
        var ref_count: u32 = 0;
        var iter: ExprRangeIterator = .init(sheet, expr);
        while (iter.next()) |_| ref_count += 1;
        break :blk ref_count;
    };
    try sheet.deps.ensureUnusedCapacity(sheet.allocator, area * ref_count);
    errdefer comptime unreachable;

    sheet.deleteCellRangeAssumeCapacity(range, opts.undo_opts);

    const ast_start_node = ast.leftMostChild(sheet.ast_nodes, expr);
    const strings = sheet.dupeAstStrings(source, ast_start_node, expr);

    const handles_start = sheet.cell_tree.values.len;

    // Create dependency information
    // For each range we depend on, prepend the cell handle of every cell we're creating
    var iter: ExprRangeIterator = .init(sheet, expr);
    while (iter.next()) |expr_range| {
        const p: Dependents.Point = .{
            expr_range.tl.x, expr_range.tl.y,
            expr_range.br.x, expr_range.br.y,
        };
        const res = sheet.dependents.getOrPutAssumeCapacity(&p);
        const head = res.value_ptr;
        if (!res.found_existing) head.* = .none;

        const start = sheet.deps.items.len;
        sheet.deps.items.len += area;
        const new_deps = sheet.deps.items[start..];
        // TODO: Make this suck less
        for (new_deps, 1.., handles_start..) |*dep, i, handle_index| {
            dep.* = .{
                .handle = .from(@intCast(handle_index)),
                .next = .from(@intCast(i)),
            };
        }
        new_deps[new_deps.len - 1].next = head.*;
        head.* = .from(@intCast(start));
    }

    if (need_cell_eval) {
        sheet.queued_cells.appendAssumeCapacity(.{ .from(@intCast(handles_start)), area });
    }

    sheet.createColumnRangeAssumeCapacity(range);

    const cell: Cell = .{
        .value = opts.value,
        .value_type = opts.tag,
        .state = if (opts.tag != .err) .enqueued else .up_to_date,
        .expr_root = expr,
        .strings = strings,
    };
    sheet.cell_tree.values.len += area;
    // All created cells share the same cell value
    @memset(sheet.cell_tree.values.items(.value)[handles_start..], cell);

    // TODO: These inserts get slow when we start inserting millions of cells at once.
    //       Each insert does a separate lookup. We should find some way to exploit the internal
    //       layout of the phtree to make inserting consecutive points faster.
    //       We could build the tree bottom-up?
    const end = sheet.cell_tree.values.len;
    const point_slice = sheet.cell_tree.values.items(.point);
    var y: u64 = range.tl.y;
    while (y <= range.br.y) : (y += 1) {
        var x: u64 = range.tl.x;
        while (x <= range.br.x) : (x += 1) {
            const y_off = (y - range.tl.y) * width;
            const x_off = x - range.tl.x;
            const off = y_off + x_off;
            const handle: Cell.Handle = .from(@intCast(handles_start + off));
            const p: CellTree.Point = .{ @intCast(x), @intCast(y) };
            point_slice[handle.n] = p;

            const removed = sheet.cell_tree.insertAssumeCapacity(&p, handle);
            assert(!removed.isValid());
        }
    }

    sheet.pushUndoAssumeCapacity(.init(.bulk_cell_delete_contiguous, .{
        .start = @intCast(handles_start),
        .end = @intCast(end),
    }), opts.undo_opts);
}

/// Creates the cell at `pos` using the given expression, duplicating its string literals.
pub fn setCell(
    sheet: *Sheet,
    pos: Position,
    source: []const u8,
    expr_root: ast.Index,
    undo_opts: UndoOpts,
) Allocator.Error!void {
    try sheet.ensureUnusedCellCapacity(1);
    try sheet.ensureUnusedStringsCapacity(@intCast(source.len));
    try sheet.ensureUnusedCellQueueCapacity(1);
    try sheet.ensureExpressionDependentsCapacity(expr_root);
    try sheet.ensureUnusedUndoCapacity(1);
    _ = try sheet.createColumn(pos.x);
    errdefer comptime unreachable;

    const ast_start_node = ast.leftMostChild(sheet.ast_nodes, expr_root);
    const strings = sheet.dupeAstStrings(source, ast_start_node, expr_root);

    const new_node = sheet.cell_tree.createValueAssumeCapacity(&.{ pos.x, pos.y }, .{
        .expr_root = expr_root,
        .strings = strings,
    });

    return sheet.insertCellNode(new_node, undo_opts);
}

pub fn setCell2(
    sheet: *Sheet,
    pos: Position,
    handle: Cell.Handle,
    root: ast.Index,
    strings: StringIndex,
) void {
    _ = sheet.createColumnAssumeCapacity(pos.x);

    sheet.cell_tree.values.set(handle.n, .{
        .point = .{ pos.x, pos.y },
        .parent = .invalid,
        .value = .{
            .expr_root = root,
            .strings = strings,
            .state = .enqueued,
        },
    });

    const removed = sheet.cell_tree.insertAssumeCapacity(&.{ pos.x, pos.y }, handle);
    assert(!removed.isValid());

    var iter: ExprRangeIterator = .init(sheet, root);
    while (iter.next()) |range| {
        const p: Dependents.Point = .{
            range.tl.x, range.tl.y,
            range.br.x, range.br.y,
        };
        const res = sheet.dependents.getOrPutAssumeCapacity(&p);
        const head_ptr = res.value_ptr;
        if (!res.found_existing) {
            head_ptr.* = .none;
        }

        const index = sheet.createDepAssumeCapacity(.{
            .handle = handle,
            .next = head_ptr.*,
        });
        head_ptr.* = index;
    }
}

/// Inserts a pre-allocated Cell node. Does not attempt to create any row/column anchors.
pub fn insertCellNode(
    sheet: *Sheet,
    handle: Cell.Handle,
    undo_opts: UndoOpts,
) void {
    const point = sheet.cell_tree.getPoint(handle).*;
    const pos: Position = .init(point[0], point[1]);
    const cell_ptr = sheet.getCellFromHandle(handle);

    const old_handle = sheet.cell_tree.insertAssumeCapacity(&point, handle);

    var u: Undo = undefined;
    if (!old_handle.isValid()) {
        // log.debug("Creating cell {}", .{pos});
        sheet.addExpressionDependents(handle, cell_ptr.expr_root);

        u = .init(.delete_cell, pos);
    } else {
        // log.debug("Overwriting cell {}", .{pos});

        const old_cell_ptr = sheet.getCellFromHandle(old_handle);
        sheet.removeExprDependents(handle, old_cell_ptr.expr_root);
        sheet.addExpressionDependents(handle, cell_ptr.expr_root);

        sheet.setCellError(old_cell_ptr);

        u = .init(.set_cell, old_handle);
    }

    sheet.pushUndo(u, undo_opts) catch unreachable;
    sheet.enqueueUpdate(handle) catch unreachable;
    sheet.has_changes = true;
}

pub fn deleteCellByHandle(
    sheet: *Sheet,
    handle: Cell.Handle,
    undo_opts: UndoOpts,
) Allocator.Error!void {
    const cell = sheet.getCellFromHandle(handle);

    try sheet.ensureUnusedUndoCapacity(1);

    try sheet.enqueueUpdate(handle);
    sheet.removeExprDependents(handle, cell.expr_root);

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
    const handle = sheet.cell_tree.findEntry(&.{ pos.x, pos.y });

    if (handle.isValid())
        return sheet.deleteCellByHandle(handle, undo_opts);
}

pub fn deleteCellRange(sheet: *Sheet, r: Rect, opts: UndoOpts) Allocator.Error!void {
    try sheet.ensureUnusedUndoCapacity(1);
    try sheet.cell_buffer.ensureUnusedCapacity(sheet.allocator, r.area() + 1);
    sheet.deleteCellRangeAssumeCapacity(r, opts);
}

pub fn getCell(sheet: *Sheet, pos: Position) ?Cell {
    return if (sheet.getCellPtr(pos)) |ptr| ptr.* else null;
}

pub fn getCellPtr(sheet: *Sheet, pos: Position) ?*Cell {
    return sheet.cell_tree.find(&.{ pos.x, pos.y });
}

pub fn getCellHandleByPos(sheet: *Sheet, pos: Position) Cell.Handle {
    return sheet.cell_tree.findEntry(&.{ pos.x, pos.y });
}

pub fn getCellHandleByPosOrNull(sheet: *Sheet, pos: Position) ?Cell.Handle {
    const handle = sheet.cell_tree.findEntry(&.{ pos.x, pos.y });
    if (handle.isValid()) return handle;
    return null;
}

// TODO: Investigate if just looping over every cell tree and dependent tree value is faster than
//       doing a window query.

// This naive implementation is shockingly fast with ph trees. R-trees could never!
pub fn deleteColumnRange(
    sheet: *Sheet,
    start: u32,
    /// Inclusive end index
    end: u32,
    undo_opts: UndoOpts,
) !void {
    assert(start <= end);
    const deleted_cols = end - start + 1;

    const arena = sheet.arena.allocator();
    defer sheet.resetArena();

    // List of cells that are affected
    var cells: std.ArrayList(Cell.Handle) = .init(arena);
    // List of dependency ranges that need to be updated
    var deps: std.ArrayList(Dependents.ValueHandle) = .init(arena);
    // List of dependency ranges whose depending cells will need to be re-calculated
    var intersecting_deps: std.ArrayList(Dependents.ValueHandle) = .init(arena);
    // List of columns whose position needs to be adjusted
    var cols: std.ArrayList(Column.Handle) = .init(arena);

    const max = std.math.maxInt(u32);

    try sheet.cell_tree.queryWindow(&.{ start, 0 }, &.{ max, max }, &cells);
    try sheet.dependents.queryWindowRect(.{ start, 0 }, .{ max, max }, &deps);
    try sheet.dependents.queryWindowRect(.{ start, 0 }, .{ start, max }, &intersecting_deps);
    try sheet.cols.queryWindow(&.{start}, &.{max}, &cols);

    const undo_count = blk: {
        var undo_count: u32 = 1;

        for (cells.items) |handle| {
            const p = sheet.cell_tree.getPoint(handle).*;
            undo_count += @intFromBool(p[0] >= start and p[0] <= end);
        }

        for (deps.items) |handle| {
            const p = sheet.dependents.getPoint(handle).*;
            const needs_resize_or_delete = !(p[0] > end or (p[0] < start and p[2] > end));
            undo_count += @intFromBool(needs_resize_or_delete);
        }

        const tags = sheet.ast_nodes.items(.tag);
        const data = sheet.ast_nodes.items(.data);
        var i: u32 = @intCast(sheet.ast_nodes.len);
        while (i > 0) {
            i -= 1;
            switch (tags[i]) {
                .pos => {
                    const pos = data[i].pos;
                    undo_count += @intFromBool(pos.x >= start);
                },
                .range => {
                    const range = data[i].range;
                    const tl: Position = data[range.lhs.n].pos;
                    const br: Position = data[range.rhs.n].pos;
                    const needs_resize_or_delete = !(tl.x > end or (tl.x < start and br.x > end));
                    undo_count += @intFromBool(needs_resize_or_delete);
                },
                else => {},
            }
        }

        break :blk undo_count;
    };

    // Count of the number of cells who depend on a range that intersects with
    var queue_count: u32 = 0;
    for (intersecting_deps.items) |handle| {
        const root = sheet.dependents.getValue(handle).*;
        var n = root;
        while (n.isValid()) : (n = sheet.deps.items[n.n].next) {
            queue_count += 1;
        }
    }

    try sheet.queued_cells.ensureUnusedCapacity(sheet.allocator, queue_count + cells.items.len);
    try sheet.ensureUnusedUndoCapacity(undo_count);
    errdefer comptime unreachable;

    for (intersecting_deps.items) |dep_handle| {
        const root = sheet.dependents.getValue(dep_handle).*;
        var n = root;
        assert(n.isValid());
        while (n.isValid()) : (n = sheet.deps.items[n.n].next) {
            const cell_handle = sheet.deps.items[n.n].handle;
            sheet.queued_cells.appendAssumeCapacity(.{ cell_handle, 1 });
            sheet.getCellFromHandle(cell_handle).state = .enqueued;
        }
    }
    for (cells.items) |handle| {
        sheet.queued_cells.appendAssumeCapacity(.{ handle, 1 });
    }

    for (cells.items) |handle| {
        const p = sheet.cell_tree.getPoint(handle);
        sheet.cell_tree.removeHandle(handle);

        if (p[0] >= start and p[0] <= end) {
            sheet.removeExprDependents(handle, sheet.getCellFromHandle(handle).expr_root);
        }
    }

    for (cells.items) |handle| {
        const p = sheet.cell_tree.getPoint(handle);

        if (p[0] >= start and p[0] <= end) {
            // TODO: batch these cell inserts
            sheet.pushUndoAssumeCapacity(.init(.set_cell, handle), undo_opts);
        } else {
            p[0] -= deleted_cols;
            _ = sheet.cell_tree.insertAssumeCapacity(p, handle);
        }
        sheet.getCellFromHandle(handle).state = .enqueued;
    }

    for (cols.items) |handle| {
        const p = sheet.cols.getPoint(handle);
        assert(p[0] >= start);

        sheet.cols.removeHandle(handle);

        if (p[0] > end) {
            p[0] -= end - start + 1;
            _ = sheet.cols.insertAssumeCapacity(p, handle);
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
        if (handle.n >= sheet.dependents.values.len)
            continue;

        const p = sheet.dependents.getPoint(handle);
        sheet.dependents.removeHandle(handle);
        if (p[0] >= start) {
            if (p[2] <= end) {
                // Deletion entirely contains range
                sheet.pushUndoAssumeCapacity(.init(.insert_dep, handle), undo_opts);
            } else if (p[0] <= end) {
                // Deletion contains range start
                sheet.pushUndoAssumeCapacity(.init(.update_dep, .{
                    .handle = handle,
                    .point = p.*,
                }), undo_opts);
                p[0] = start;
                p[2] -= deleted_cols;
                _ = sheet.dependents.insertAssumeCapacity(p, handle);
            } else {
                // Deletion does not intersect with range
                // This is undone by the .insert undo
                p[0] -= deleted_cols;
                p[2] -= deleted_cols;
                _ = sheet.dependents.insertAssumeCapacity(p, handle);
            }
        } else if (p[2] <= end) {
            // Deletion contains range end
            // Resizes the range, so a special undo is required
            sheet.pushUndoAssumeCapacity(.init(.update_dep, .{
                .handle = handle,
                .point = p.*,
            }), undo_opts);
            p[2] = start - 1;
            _ = sheet.dependents.insertAssumeCapacity(p, handle);
        } else {
            // Deletion is in the middle of the range
            // This is undone by the .insert undo
            p[2] -= deleted_cols;
            _ = sheet.dependents.insertAssumeCapacity(p, handle);
        }
    }

    const tags = sheet.ast_nodes.items(.tag);
    const data = sheet.ast_nodes.items(.data);
    var i: u32 = @intCast(sheet.ast_nodes.len);
    while (i > 0) {
        i -= 1;
        switch (tags[i]) {
            .pos => {
                const pos: *Position = &data[i].pos;
                if (pos.x >= start) {
                    sheet.pushUndoAssumeCapacity(.init(.update_pos, .{
                        .ast_node = .from(i),
                        .pos = pos.*,
                    }), undo_opts);

                    if (pos.x <= end) {
                        tags[i] = .invalidated_pos;
                    } else {
                        pos.x -= deleted_cols;
                    }
                }
            },
            .range => {
                const range = data[i].range;
                const tl: *Position = &data[range.lhs.n].pos;
                const br: *Position = &data[range.rhs.n].pos;
                const u: Undo = .init(.update_range, .{
                    .ast_node = .from(i),
                    .range = .{
                        .tl = tl.*,
                        .br = br.*,
                    },
                });

                if (tl.x >= start) {
                    if (br.x <= end) {
                        sheet.pushUndoAssumeCapacity(u, undo_opts);
                        // Lies entirely in the deleted range
                        tags[i] = .invalidated_range;
                    } else if (tl.x <= end) {
                        sheet.pushUndoAssumeCapacity(u, undo_opts);
                        tl.x = start;
                        br.x -= deleted_cols;
                    } else {
                        tl.x -= deleted_cols;
                        br.x -= deleted_cols;
                    }
                } else if (br.x >= start) {
                    if (br.x <= end) {
                        sheet.pushUndoAssumeCapacity(u, undo_opts);
                        br.x = start - 1;
                    } else {
                        br.x -= end - start + 1;
                    }
                }

                i -= 2;
            },
            else => {},
        }
    }

    sheet.pushUndoAssumeCapacity(.init(.insert_columns, .{
        .start = start,
        .len = deleted_cols,
    }), undo_opts);
}

pub fn deleteRowRange(
    sheet: *Sheet,
    start: u32,
    /// Inclusive end index
    end: u32,
    undo_opts: UndoOpts,
) !void {
    assert(start <= end);
    const deleted_rows = end - start + 1;

    const arena = sheet.arena.allocator();
    defer sheet.resetArena();

    // List of cells that are affected
    var cells: std.ArrayList(Cell.Handle) = .init(arena);
    // List of dependency ranges that need to be updated
    var deps: std.ArrayList(Dependents.ValueHandle) = .init(arena);
    // List of dependency ranges whose depending cells will need to be re-calculated
    var intersecting_deps: std.ArrayList(Dependents.ValueHandle) = .init(arena);

    const max = std.math.maxInt(u32);

    try sheet.cell_tree.queryWindow(&.{ 0, start }, &.{ max, max }, &cells);
    try sheet.dependents.queryWindowRect(.{ 0, start }, .{ max, max }, &deps);
    try sheet.dependents.queryWindowRect(.{ 0, start }, .{ max, start }, &intersecting_deps);

    const undo_count = blk: {
        var undo_count: u32 = 1;

        for (cells.items) |handle| {
            const p = sheet.cell_tree.getPoint(handle).*;
            undo_count += @intFromBool(p[1] >= start and p[1] <= end);
        }

        for (deps.items) |handle| {
            const p = sheet.dependents.getPoint(handle).*;
            const needs_resize_or_delete = !(p[1] > end or (p[1] < start and p[3] > end));
            undo_count += @intFromBool(needs_resize_or_delete);
        }

        const tags = sheet.ast_nodes.items(.tag);
        const data = sheet.ast_nodes.items(.data);
        var i: u32 = @intCast(sheet.ast_nodes.len);
        while (i > 0) {
            i -= 1;
            switch (tags[i]) {
                .pos => {
                    const pos = data[i].pos;
                    undo_count += @intFromBool(pos.y >= start);
                },
                .range => {
                    const range = data[i].range;
                    const tl: Position = data[range.lhs.n].pos;
                    const br: Position = data[range.rhs.n].pos;
                    const needs_resize_or_delete = !(tl.y > end or (tl.y < start and br.y > end));
                    undo_count += @intFromBool(needs_resize_or_delete);
                },
                else => {},
            }
        }

        break :blk undo_count;
    };

    // Count of the number of cells who depend on a range that intersects with
    var queue_count: u32 = 0;
    for (intersecting_deps.items) |handle| {
        const root = sheet.dependents.getValue(handle).*;
        var n = root;
        while (n.isValid()) : (n = sheet.deps.items[n.n].next) {
            queue_count += 1;
        }
    }

    try sheet.queued_cells.ensureUnusedCapacity(sheet.allocator, queue_count + cells.items.len);
    try sheet.ensureUnusedUndoCapacity(undo_count);
    errdefer comptime unreachable;

    for (intersecting_deps.items) |dep_handle| {
        const root = sheet.dependents.getValue(dep_handle).*;
        var n = root;
        assert(n.isValid());
        while (n.isValid()) : (n = sheet.deps.items[n.n].next) {
            const cell_handle = sheet.deps.items[n.n].handle;
            sheet.queued_cells.appendAssumeCapacity(.{ cell_handle, 1 });
            sheet.getCellFromHandle(cell_handle).state = .enqueued;
        }
    }
    for (cells.items) |handle| {
        sheet.queued_cells.appendAssumeCapacity(.{ handle, 1 });
    }

    for (cells.items) |handle| {
        const p = sheet.cell_tree.getPoint(handle);
        sheet.cell_tree.removeHandle(handle);

        if (p[1] >= start and p[1] <= end) {
            sheet.removeExprDependents(handle, sheet.getCellFromHandle(handle).expr_root);
        }
    }

    for (cells.items) |handle| {
        const p = sheet.cell_tree.getPoint(handle);
        if (p[1] >= start and p[1] <= end) {
            // TODO: Batch these inserts
            sheet.pushUndoAssumeCapacity(.init(.insert_cell, handle), undo_opts);
        } else {
            p[1] -= deleted_rows;
            _ = sheet.cell_tree.insertAssumeCapacity(p, handle);
        }
        sheet.getCellFromHandle(handle).state = .enqueued;
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
        if (handle.n >= sheet.dependents.values.len)
            continue;

        const p = sheet.dependents.getPoint(handle);
        sheet.dependents.removeHandle(handle);
        if (p[1] >= start) {
            if (p[3] <= end) {
                // Deletion entirely contains range
                sheet.pushUndoAssumeCapacity(.init(.insert_dep, handle), undo_opts);
            } else if (p[1] <= end) {
                // Deletion contains range start
                sheet.pushUndoAssumeCapacity(.init(.update_dep, .{
                    .handle = handle,
                    .point = p.*,
                }), undo_opts);
                p[1] = start;
                p[3] -= deleted_rows;
                _ = sheet.dependents.insertAssumeCapacity(p, handle);
            } else {
                // Deletion does not intersect with range
                // This is undone by the .insert undo
                p[1] -= deleted_rows;
                p[3] -= deleted_rows;
                _ = sheet.dependents.insertAssumeCapacity(p, handle);
            }
        } else if (p[3] <= end) {
            // Deletion contains range end
            // Resizes the range, so a special undo is required
            sheet.pushUndoAssumeCapacity(.init(.update_dep, .{
                .handle = handle,
                .point = p.*,
            }), undo_opts);
            p[3] = start - 1;
            _ = sheet.dependents.insertAssumeCapacity(p, handle);
        } else {
            // Deletion is in the middle of the range
            // This is undone by the .insert undo
            p[3] -= deleted_rows;
            _ = sheet.dependents.insertAssumeCapacity(p, handle);
        }
    }

    const tags = sheet.ast_nodes.items(.tag);
    const data = sheet.ast_nodes.items(.data);
    var i: u32 = @intCast(sheet.ast_nodes.len);
    while (i > 0) {
        i -= 1;
        switch (tags[i]) {
            .pos => {
                const pos: *Position = &data[i].pos;
                if (pos.y >= start) {
                    sheet.pushUndoAssumeCapacity(.init(.update_pos, .{
                        .ast_node = .from(i),
                        .pos = pos.*,
                    }), undo_opts);

                    if (pos.y <= end) {
                        tags[i] = .invalidated_pos;
                    } else {
                        pos.y -= deleted_rows;
                    }
                }
            },
            .range => {
                const range = data[i].range;
                const tl: *Position = &data[range.lhs.n].pos;
                const br: *Position = &data[range.rhs.n].pos;
                const u: Undo = .init(.update_range, .{
                    .ast_node = .from(i),
                    .range = .{
                        .tl = tl.*,
                        .br = br.*,
                    },
                });

                if (tl.y >= start) {
                    if (br.y <= end) {
                        sheet.pushUndoAssumeCapacity(u, undo_opts);
                        // Lies entirely in the deleted range
                        tags[i] = .invalidated_range;
                    } else if (tl.y <= end) {
                        sheet.pushUndoAssumeCapacity(u, undo_opts);
                        tl.y = start;
                        br.y -= deleted_rows;
                    } else {
                        tl.y -= deleted_rows;
                        br.y -= deleted_rows;
                    }
                } else if (br.y >= start) {
                    if (br.y <= end) {
                        sheet.pushUndoAssumeCapacity(u, undo_opts);
                        br.y = start - 1;
                    } else {
                        br.y -= end - start + 1;
                    }
                }

                i -= 2;
            },
            else => {},
        }
    }

    sheet.pushUndoAssumeCapacity(.init(.insert_rows, .{
        .start = start,
        .len = deleted_rows,
    }), undo_opts);
}

// When we insert n columns...
//
// Columns after index need to be incremented
//
// Cells after index need to be incremented
//
// Dependencies after index need to be incremented
// Dependencies containing index need to be adjusted specially
//
// AST references >= index need to be incremented
// AST ranges with at least one point >= index need to be incremented
//
// No cells need to be updated
pub fn insertColumns(sheet: *Sheet, index: u32, n: u32, undo_opts: UndoOpts) !void {
    assert(n > 0);

    // Check if columns would overflow
    const largest = sheet.cell_tree.largestDim(0);
    if (largest.isValid()) {
        const col = sheet.cell_tree.getPoint(largest).*[0];
        if (std.math.maxInt(u32) - col < n)
            return error.Overflow;
    }

    const arena = sheet.arena.allocator();
    defer sheet.resetArena();

    var cells: std.ArrayList(Cell.Handle) = .init(arena);
    var deps: std.ArrayList(Dependents.ValueHandle) = .init(arena);
    var cols: std.ArrayList(Column.Handle) = .init(arena);

    const undo_count = blk: {
        const tags = sheet.ast_nodes.items(.tag);
        const data = sheet.ast_nodes.items(.data);
        var i: u32 = @intCast(sheet.ast_nodes.len);
        var undo_count: u32 = 1;
        while (i > 0) {
            i -= 1;
            switch (tags[i]) {
                .pos => {
                    const pos = data[i].pos;
                    undo_count += @intFromBool(pos.x >= index);
                },
                .range => {
                    const range = data[i].range;
                    const tl: Position = data[range.lhs.n].pos;
                    const br: Position = data[range.rhs.n].pos;
                    undo_count += @intFromBool(tl.x >= index or br.x >= index);
                },
                else => {},
            }
        }

        break :blk undo_count;
    };

    try sheet.ensureUnusedUndoCapacity(undo_count);
    try sheet.cols.ensureUnusedCapacity(sheet.allocator, n);

    const max = std.math.maxInt(u32);

    try sheet.cell_tree.queryWindow(&.{ index, 0 }, &.{ max, max }, &cells);
    try sheet.dependents.queryWindowRect(.{ index, 0 }, .{ max, max }, &deps);
    try sheet.cols.queryWindow(&.{index}, &.{max}, &cols);
    errdefer comptime unreachable;

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

    // Create new columns
    for (index..index + n) |i|
        _ = sheet.createColumnAssumeCapacity(@intCast(i));

    // Remove affected cells
    for (cells.items) |handle| {
        const p = sheet.cell_tree.getPoint(handle);
        assert(p[0] >= index);
        sheet.cell_tree.removeHandle(handle);
    }

    // Re-insert affected cells with adjusted positions
    for (cells.items) |handle| {
        const p = sheet.cell_tree.getPoint(handle);
        p[0] += n;
        const removed = sheet.cell_tree.insertAssumeCapacity(p, handle);
        assert(!removed.isValid());
    }

    // Remove affected dependency ranges
    for (deps.items) |handle| {
        const p = sheet.dependents.getPoint(handle);
        assert(p[2] >= p[0]);
        sheet.dependents.removeHandle(handle);
    }

    // Re-insert affected dependency ranges with adjustments
    for (deps.items) |handle| {
        const p = sheet.dependents.getPoint(handle);
        if (p[0] >= index) {
            p[0] += n;
            p[2] += n;
            _ = sheet.dependents.insertAssumeCapacity(p, handle);
        } else {
            assert(p[2] >= index);
            p[2] += n;
            _ = sheet.dependents.insertAssumeCapacity(p, handle);
        }
    }

    // TODO: Could we store these in a ph-tree, and AST pos nodes store a handle into that tree.
    //       This would allow looking up all affected nodes in the AST easier. But is it even
    //       needed?
    // Adjust all affected position/range references in cell expressions
    const tags = sheet.ast_nodes.items(.tag);
    const data = sheet.ast_nodes.items(.data);
    var i: u32 = @intCast(sheet.ast_nodes.len);
    while (i > 0) {
        i -= 1;
        switch (tags[i]) {
            .pos => {
                const pos = &data[i].pos;
                if (pos.x >= index) {
                    sheet.pushUndoAssumeCapacity(.init(.update_pos, .{
                        .ast_node = .from(i),
                        .pos = pos.*,
                    }), undo_opts);
                    pos.x += n;
                }
            },
            .range => {
                const range = data[i].range;
                const tl = &data[range.lhs.n].pos;
                const br = &data[range.rhs.n].pos;
                assert(tl.x <= br.x);
                assert(tl.y <= br.y);

                const u: Undo = .init(.update_range, .{
                    .ast_node = .from(i),
                    .range = .{
                        .tl = tl.*,
                        .br = br.*,
                    },
                });

                if (tl.x >= index) {
                    sheet.pushUndoAssumeCapacity(u, undo_opts);
                    tl.x += n;
                    br.x += n;
                } else if (br.x >= index) {
                    sheet.pushUndoAssumeCapacity(u, undo_opts);
                    br.x += n;
                }

                i -= 2;
            },
            else => {},
        }
    }

    sheet.pushUndoAssumeCapacity(.init(.delete_columns, .{
        .start = index,
        .end = index + n - 1,
    }), undo_opts);
}

pub fn insertRows(sheet: *Sheet, index: u32, n: u32, undo_opts: UndoOpts) !void {
    assert(n > 0);

    // Check if this would cause rows to overflow
    const largest = sheet.cell_tree.largestDim(1);
    if (largest.isValid()) {
        const row = sheet.cell_tree.getPoint(largest).*[1];
        if (std.math.maxInt(u32) - row < n)
            return error.Overflow;
    }

    const arena = sheet.arena.allocator();
    defer sheet.resetArena();

    var cells: std.ArrayList(Cell.Handle) = .init(arena);
    var deps: std.ArrayList(Dependents.ValueHandle) = .init(arena);

    const undo_count = blk: {
        const tags = sheet.ast_nodes.items(.tag);
        const data = sheet.ast_nodes.items(.data);
        var i: u32 = @intCast(sheet.ast_nodes.len);
        var undo_count: u32 = 1;
        while (i > 0) {
            i -= 1;
            switch (tags[i]) {
                .pos => {
                    const pos = data[i].pos;
                    undo_count += @intFromBool(pos.y >= index);
                },
                .range => {
                    const range = data[i].range;
                    const tl: Position = data[range.lhs.n].pos;
                    const br: Position = data[range.rhs.n].pos;
                    undo_count += @intFromBool(tl.y >= index or br.y >= index);
                },
                else => {},
            }
        }

        break :blk undo_count;
    };

    try sheet.ensureUnusedUndoCapacity(undo_count);

    const max = std.math.maxInt(u32);

    try sheet.cell_tree.queryWindow(&.{ 0, index }, &.{ max, max }, &cells);
    try sheet.dependents.queryWindowRect(.{ 0, index }, .{ max, max }, &deps);
    errdefer comptime unreachable;

    // Remove affected cells
    for (cells.items) |handle| {
        const p = sheet.cell_tree.getPoint(handle);
        assert(p[1] >= index);
        sheet.cell_tree.removeHandle(handle);
    }

    // Re-insert affected cells with adjusted positions
    for (cells.items) |handle| {
        const p = sheet.cell_tree.getPoint(handle);
        p[1] += n;
        const removed = sheet.cell_tree.insertAssumeCapacity(p, handle);
        assert(!removed.isValid());
    }

    // Remove affected dependency ranges
    for (deps.items) |handle| {
        const p = sheet.dependents.getPoint(handle);
        assert(p[3] >= p[1]);
        sheet.dependents.removeHandle(handle);
    }

    // Re-insert affected dependency ranges with adjustments
    for (deps.items) |handle| {
        const p = sheet.dependents.getPoint(handle);
        if (p[1] >= index) {
            p[1] += n;
            p[3] += n;
            _ = sheet.dependents.insertAssumeCapacity(p, handle);
        } else {
            assert(p[3] >= index);
            p[3] += n;
            _ = sheet.dependents.insertAssumeCapacity(p, handle);
        }
    }

    // TODO: Could we store these in a ph-tree, and AST pos nodes store a handle into that tree.
    //       This would allow looking up all affected nodes in the AST easier. But is it even
    //       needed?
    // Adjust all affected position/range references in cell expressions
    const tags = sheet.ast_nodes.items(.tag);
    const data = sheet.ast_nodes.items(.data);
    var i: u32 = @intCast(sheet.ast_nodes.len);
    while (i > 0) {
        i -= 1;
        switch (tags[i]) {
            .pos => {
                const pos = &data[i].pos;
                if (pos.y >= index) {
                    sheet.pushUndoAssumeCapacity(.init(.update_pos, .{
                        .ast_node = .from(i),
                        .pos = pos.*,
                    }), undo_opts);
                    pos.y += n;
                }
            },
            .range => {
                const range = data[i].range;
                const tl = &data[range.lhs.n].pos;
                const br = &data[range.rhs.n].pos;
                assert(tl.y <= br.y);
                assert(tl.y <= br.y);

                const u: Undo = .init(.update_range, .{
                    .ast_node = .from(i),
                    .range = .{
                        .tl = tl.*,
                        .br = br.*,
                    },
                });

                if (tl.y >= index) {
                    sheet.pushUndoAssumeCapacity(u, undo_opts);
                    tl.y += n;
                    br.y += n;
                } else if (br.y >= index) {
                    sheet.pushUndoAssumeCapacity(u, undo_opts);
                    br.y += n;
                }

                i -= 2;
            },
            else => {},
        }
    }

    sheet.pushUndoAssumeCapacity(.init(.delete_rows, .{
        .start = index,
        .end = index + n - 1,
    }), undo_opts);
}

pub fn update(sheet: *Sheet) Allocator.Error!void {
    if (!sheet.needsUpdate()) return;

    // log.debug("Updating cells...", .{});
    var timer = if (builtin.mode == .Debug)
        std.time.Timer.start() catch unreachable
    else {};

    defer sheet.queued_cells.clearRetainingCapacity();

    // log.debug("Marking dirty cells", .{});

    var sfa = std.heap.stackFallback(16384, sheet.allocator);
    var dirty_cells: std.ArrayList(Cell.Handle) = .init(sfa.get());
    defer dirty_cells.deinit();

    for (sheet.queued_cells.items) |data| {
        const cell_start, const len = data;
        for (cell_start.n..cell_start.n + len) |i| {
            const handle: Cell.Handle = .from(@intCast(i));
            try sheet.markDirty(handle, &dirty_cells);
        }
    }

    while (dirty_cells.pop()) |cell| {
        try sheet.markDirty(cell, &dirty_cells);
    }
    // log.debug("Finished marking", .{});

    // All dirty cells are reachable from the cells in queued_cells
    while (sheet.queued_cells.pop()) |data| {
        const handle_start, const len = data;
        for (handle_start.n..handle_start.n + len) |i| {
            const handle: Cell.Handle = .from(@intCast(i));
            _ = sheet.evalCellByHandle(handle) catch |err| switch (err) {
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
}

pub fn enqueueUpdate(
    sheet: *Sheet,
    handle: Cell.Handle,
) Allocator.Error!void {
    try sheet.queued_cells.append(sheet.allocator, .{ handle, 1 });
    sheet.getCellFromHandle(handle).state = .enqueued;
}

/// Marks all of the dependents of `pos` as dirty. Any children that also need to be marked dirty
/// are appended to `dirty_cells`. This was previously done recursively which resulted in a stack
/// overflow on large sheets.
fn markDirty(
    sheet: *Sheet,
    handle: Cell.Handle,
    dirty_cells: *std.ArrayList(Cell.Handle),
) Allocator.Error!void {
    sheet.search_buffer.clearRetainingCapacity();

    var list = sheet.search_buffer.toManaged(sheet.allocator);
    defer sheet.search_buffer = list.moveToUnmanaged();

    const pos = sheet.posFromCellHandle(handle);
    try sheet.dependents.queryWindowRect(
        .{ pos.x, pos.y },
        .{ pos.x, pos.y },
        &list,
    );

    for (list.items) |dependent_handle| {
        const head = sheet.dependents.getValue(dependent_handle).*;
        var index = head;
        while (index.isValid()) : (index = sheet.deps.items[index.n].next) {
            const h = sheet.deps.items[index.n].handle;
            const c = sheet.getCellFromHandle(h);
            if (c.state != .dirty) {
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

    // TODO: We can encode this information in the string AST nodes themselves.
    strings: StringIndex = .invalid,

    pub const Handle = CellTree.ValueHandle;

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

    pub fn fromExpression(sheet: *Sheet, expr: []const u8) !Cell {
        return .{ .expr_root = try ast.fromExpression(&sheet, expr) };
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
fn queueDependents(sheet: *Sheet, rect: Rect) Allocator.Error!void {
    sheet.search_buffer.clearRetainingCapacity();
    var list = sheet.search_buffer.toManaged(sheet.allocator);
    defer sheet.search_buffer = list.moveToUnmanaged();

    try sheet.dependents.queryWindowRect(
        .{ rect.tl.x, rect.tl.y },
        .{ rect.br.x, rect.br.y },
        &list,
    );

    for (list.items) |dependent_handle| {
        const head = sheet.dependents.getValue(dependent_handle).*;
        var index = head;
        while (index.isValid()) : (index = sheet.deps.items[index.n].next) {
            const handle = sheet.deps.items[index.n].handle;
            const cell = sheet.getCellFromHandle(handle);
            if (cell.state == .dirty) {
                cell.state = .enqueued;
                try sheet.queued_cells.append(sheet.allocator, .{ handle, 1 });
            }
        }
    }
}

pub fn evalCellByHandle(sheet: *Sheet, handle: Cell.Handle) ast.EvalError!ast.EvalResult {
    const cell = sheet.getCellFromHandle(handle);
    switch (cell.state) {
        .up_to_date => {},
        .computing => return error.CyclicalReference,
        .enqueued, .dirty => {
            cell.state = .computing;

            const pos = sheet.posFromCellHandle(handle);
            log.debug("eval {}", .{pos});
            // Queue dependents before evaluating to ensure that errors are propagated to
            // dependents.
            try sheet.queueDependents(sheet.rectFromCellHandle(handle));

            const p = sheet.cell_tree.getPoint(handle).*;
            // Evaluate
            const res = ast.eval(
                sheet.ast_nodes,
                cell.expr_root,
                .init(p[0], p[1]),
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
                    const list = try sheet.string_values.createList(sheet.allocator);
                    errdefer sheet.string_values.destroyList(list);
                    try sheet.string_values.ensureUnusedCapacity(sheet.allocator, list, @intCast(str.len));

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

pub fn evalCellByPos(sheet: *Sheet, pos: Position) ast.EvalError!ast.EvalResult {
    if (sheet.getCellHandleByPosOrNull(pos)) |cell| {
        return sheet.evalCellByHandle(cell);
    }

    try sheet.queueDependents(.initSinglePos(pos));
    return .none;
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

pub const Column = extern struct {
    pub const default_width = 10;

    width: u16 = default_width,
    precision: u8 = 2,

    pub const Handle = Columns.ValueHandle;
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

pub fn createColumn(sheet: *Sheet, index: PosInt) !Column.Handle {
    const res = try sheet.cols.getOrPut(sheet.allocator, &.{index});
    if (!res.found_existing) {
        log.debug("Created column {}", .{index});
        res.value_ptr.* = .{};
    }
    return res.handle;
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
    return sheet.cols.getValueOrNull(handle) orelse .{};
}

pub inline fn getTextAttrs(sheet: *Sheet, handle: TextAttrs.Handle) TextAttrs {
    return sheet.text_attrs.getValueOrNull(handle) orelse .default;
}

pub fn getColumnHandle(sheet: *Sheet, index: PosInt) ?Column.Handle {
    const handle = sheet.cols.findEntry(&.{index});
    if (handle.isValid())
        return handle;
    return null;
}

pub fn widthNeededForColumn(
    sheet: *Sheet,
    column_index: PosInt,
    precision: u8,
    max_width: u16,
) !u16 {
    var width: u16 = Column.default_width;

    var results: std.ArrayList(Cell.Handle) = .init(sheet.allocator);
    defer results.deinit();

    try sheet.cell_tree.queryWindow(
        &.{ column_index, 0 },
        &.{ column_index, std.math.maxInt(u32) },
        &results,
    );

    var buf: std.BoundedArray(u8, 512) = .{};
    const writer = buf.writer();
    for (results.items) |handle| {
        const cell = sheet.getCellFromHandle(handle);
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

test "Sheet basics" {
    const t = std.testing;

    var sheet = try Sheet.init(t.allocator);
    defer sheet.deinit();

    const exprs: []const [:0]const u8 = &.{ "50 + 5", "500 * 2 / 34 + 1", "a0", "a2 * a1" };

    for (exprs, 0..) |expr, i| {
        const root = try ast.fromExpression(&sheet, expr);
        try sheet.setCell(.{ .x = 0, .y = @intCast(i) }, expr, root, .{});
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
                const expr = "a4 * a1 * a3";
                const expr_root = try ast.fromExpression(&sheet, expr);
                try sheet.setCell(.{ .x = 0, .y = 0 }, expr, expr_root, .{});
            }

            {
                const expr = "a2 * a1 * a3";
                const expr_root = try ast.fromExpression(&sheet, expr);
                try sheet.setCell(.{ .x = 1, .y = 0 }, expr, expr_root, .{});
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
        "@sum(A0:B0)",
        try ast.fromExpression(&sheet, "@sum(A0:B0)"),
        .{},
    );

    inline for (0..4) |i| {
        const str = std.fmt.comptimePrint("{d}", .{i});
        try sheet.setCell(
            try Position.fromAddress("A0"),
            str,
            try ast.fromExpression(&sheet, str),
            .{},
        );
        try sheet.setCell(
            try Position.fromAddress("B0"),
            "A0",
            try ast.fromExpression(&sheet, "A0"),
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
    var fbs = std.io.fixedBufferStream(set_cells);
    try sheet.interpretSource(fbs.reader().any());
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

    fbs = std.io.fixedBufferStream(commands);
    sheet.clearRetainingCapacity();
    try sheet.interpretSource(fbs.reader().any());
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
        std.debug.print("Expected cell {} to not exist\n", .{pos});
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

    var sfa = std.heap.stackFallback(4096, sheet.allocator);
    const a = sfa.get();

    var results: std.ArrayList(Cell.Handle) = .init(a);
    try sheet.cell_tree.queryWindow(&.{ r.tl.x, r.tl.y }, &.{ r.br.x, r.br.y }, &results);
    defer results.deinit();

    if (results.items.len != 0) {
        var bw = std.io.bufferedWriter(std.io.getStdErr().writer());
        const w = bw.writer();
        try w.print("Expected cells {} to not exist, found", .{r});
        for (results.items) |handle| {
            const p = sheet.cell_tree.getPoint(handle).*;
            const pos: Position = .init(p[0], p[1]);
            try w.print(" {}", .{pos});
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
    const cell = sheet.getCellPtr(pos) orelse {
        std.debug.print("Could not find cell '{s}'\n", .{address});
        return error.CellNotFound;
    };
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
    var sheet = try Sheet.init(std.testing.allocator);
    defer sheet.deinit();

    try sheet.setCell(
        .fromValidAddress("A0"),
        "10",
        try ast.fromExpression(&sheet, "10"),
        .{},
    );

    try sheet.update();
    try expectCellEquals(&sheet, "A0", 10);

    try sheet.setCell(
        .fromValidAddress("B0"),
        "A0",
        try ast.fromExpression(&sheet, "A0"),
        .{},
    );

    try sheet.update();
    try expectCellEquals(&sheet, "B0", 10);

    try sheet.setCell(
        .fromValidAddress("A0"),
        "A0",
        try ast.fromExpression(&sheet, "A0"),
        .{},
    );

    try sheet.update();
    try expectCellError(&sheet, "A0");
    try expectCellError(&sheet, "B0");
}

test "DupeStrings" {
    const t = std.testing;
    var sheet = try Sheet.init(t.allocator);
    defer sheet.deinit();

    {
        const source = "let a0 = 'this is epic' # 'nice' # 'string!'";
        const expr_root = try ast.fromSource(&sheet, source);

        try sheet.strings_buf.ensureUnusedCapacity(sheet.allocator, source.len);
        const strings = sheet.dupeAstStrings(
            source,
            ast.leftMostChild(sheet.ast_nodes, expr_root),
            expr_root,
        );

        try t.expectEqualStrings("this is epicnicestring!", sheet.getStringSlice(strings));
    }

    {
        const source = "let a0 = b0";
        const expr_root = try ast.fromSource(&sheet, source);

        try sheet.strings_buf.ensureUnusedCapacity(sheet.allocator, source.len);
        const strings = sheet.dupeAstStrings(
            source,
            ast.leftMostChild(sheet.ast_nodes, expr_root),
            expr_root,
        );
        try t.expectEqualStrings("", sheet.getStringSlice(strings));
    }
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
            source,
            try ast.fromExpression(&sheet, source),
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
            source,
            try ast.fromExpression(&sheet, source),
            .{},
        );

        try sheet.update();
    }
}

fn testSetCell(sheet: *Sheet, address: []const u8, expr: [:0]const u8) !void {
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
        \\
    ;

    var fbs = std.io.fixedBufferStream(bytes);

    var sheet = try init(std.testing.allocator);
    defer sheet.deinit();

    try sheet.interpretSource(fbs.reader().any());
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

fn fuzzNumbers(_: void, input: []const u8) !void {
    if (map) |m| {
        const len: *u64 = @ptrCast(m.ptr);
        len.* = input.len;
        @memcpy(m[8..][0..input.len], input);
    }

    var sheet = try init(std.testing.allocator);
    defer sheet.deinit();

    const Insert = extern struct {
        pos: Position,
        number_or_ref: extern union { f: u64, pos: Position },
        rand: bool,
    };

    const Operation = union(enum(u2)) {
        insert: Insert align(1),
        delete: Position align(1),
        delete_col: extern struct {
            start: u32,
            len: u32,
        } align(1),
        nothing: Insert align(1),
    };

    const slice: []align(1) const Operation = std.mem.bytesAsSlice(
        Operation,
        input[0 .. input.len - input.len % @sizeOf(Operation)],
    );

    for (slice) |t| {
        switch (t) {
            // Insert a random expression
            .insert, .nothing => |data| {
                const pos: Position = .init(data.pos.x % 10, data.pos.y % 10);

                var buf: std.BoundedArray(u8, 1024) = .{};
                if (data.rand) {
                    try buf.writer().print("{d}", .{data.number_or_ref.f});
                } else {
                    const p: Position = .init(
                        data.number_or_ref.pos.x % 10,
                        data.number_or_ref.pos.y % 10,
                    );
                    try buf.writer().print("{}", .{p});
                }
                try buf.append(0);
                const null_terminated_expr = buf.buffer[0 .. buf.len - 1 :0];

                const a = try ast.fromExpression(&sheet, null_terminated_expr);
                try sheet.setCell(pos, buf.constSlice(), a, .{});
            },
            .delete => |pos| {
                try sheet.deleteCell(pos, .{});
            },
            .delete_col => |col| {
                const start = col.start % 10;
                const end = (start + col.len % 10);
                try sheet.deleteColumnRange(start, end, .{});
            },
        }

        try sheet.update();
    }
}

var map: ?[]align(std.heap.page_size_min) u8 = null;

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
    try std.testing.fuzz({}, fuzzNumbers, .{});
}

test "insert column overflow" {
    var sheet = try init(std.testing.allocator);
    defer sheet.deinit();

    try sheet.setCell(.init(std.math.maxInt(u32) - 1, 0), "5", try ast.fromExpression(&sheet, "5"), .{});
    const res = sheet.insertColumns(0, 2, .{});
    try std.testing.expectError(error.Overflow, res);
}

test "insert row overflow" {
    var sheet = try init(std.testing.allocator);
    defer sheet.deinit();

    try sheet.setCell(.init(0, std.math.maxInt(u32) - 1), "5", try ast.fromExpression(&sheet, "5"), .{});
    try sheet.insertRows(0, 1, .{});
    try std.testing.expectError(error.Overflow, sheet.insertRows(0, 1, .{}));
}

test "delete col dependency data" {
    var sheet = try init(std.testing.allocator);
    defer sheet.deinit();

    try sheet.setCell(.init(0, 0), "b0", try ast.fromExpression(&sheet, "b0"), .{});
    try std.testing.expect(sheet.dependents.find(&.{ 1, 0, 1, 0 }) != null);
    try sheet.deleteColumnRange(0, 0, .{});
    try std.testing.expect(sheet.dependents.find(&.{ 1, 0, 1, 0 }) == null);
}

test "delete row dependency data" {
    var sheet = try init(std.testing.allocator);
    defer sheet.deinit();

    try sheet.setCell(.init(0, 0), "a1", try ast.fromExpression(&sheet, "a1"), .{});
    try std.testing.expect(sheet.dependents.find(&.{ 0, 1, 0, 1 }) != null);
    try sheet.deleteRowRange(0, 0, .{});
    try std.testing.expect(sheet.dependents.find(&.{ 0, 1, 0, 1 }) == null);
}
