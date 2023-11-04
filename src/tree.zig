// TODO:
// Instead of ArrayLists use *BoundedArray
//   Makes OOM easier to handle via less allocations
//   Can write `ensureUnusedCapacity(n)` by pre-allocating root.level + n BoundedArrays
// Use MultiArrayLists for faster iteration of Node.range/KV.key
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Position = @import("Position.zig").Position;
const Range = Position.Range;
const PosInt = Position.Int;
const MultiArrayList = @import("multi_array_list.zig").MultiArrayList;

pub fn RTree(comptime V: type, comptime min_children: usize) type {
    return struct {
        const max_children = min_children * 2;

        comptime {
            assert(min_children > 2);
        }

        root: Node = .{
            .level = 0,
            .range = .{
                .tl = .{ .x = 0, .y = 0 },
                .br = .{ .x = 0, .y = 0 },
            },
            .data = .{ .values = .{} },
        },

        const Self = @This();

        pub const KV = struct {
            key: Range,
            /// List of cells that depend on the cells in `key`
            value: V,
        };

        const Node = struct {
            const ChildList = std.ArrayListUnmanaged(Node);
            const ValueList = std.ArrayListUnmanaged(KV);

            level: usize,
            range: Range,
            data: union {
                children: ChildList,
                values: ValueList,

                pub fn print(
                    self: *const @This(),
                    writer: anytype,
                ) !void {
                    const node: *const Node = @fieldParentPtr(Node, "data", self);
                    if (node.isLeaf()) {
                        try writer.print("{d} value{s}", .{
                            self.values.items.len,
                            if (self.values.items.len == 1) "" else "s",
                        });
                    } else {
                        try writer.print("{d} {s}", .{
                            self.children.items.len,
                            if (self.children.items.len == 1) "child" else "children",
                        });
                    }
                }
            },

            pub fn format(
                node: *const Node,
                comptime _: []const u8,
                _: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                try writer.print("{{ level = {d}, range = {d}, ", .{
                    node.level,
                    node.range,
                });
                try node.data.print(writer);
                try writer.writeAll(" }}\n");
                if (!node.isLeaf()) {
                    for (node.data.children.items) |child| {
                        try child.data.print(writer);
                    }
                }
            }

            /// Frees all memory associated with `node` and its children.
            fn deinit(node: *Node, allocator: Allocator) void {
                return node.deinitContext(allocator, {});
            }

            /// Frees all memory associated with `node` and its children, and calls
            /// `context.deinitValue` on every instance of `V` in the tree.
            fn deinitContext(node: *Node, allocator: Allocator, context: anytype) void {
                if (node.isLeaf()) {
                    if (@TypeOf(context) != void) {
                        for (node.data.values.items) |*kv| {
                            context.deinit(allocator, &kv.value);
                        }
                    }
                    // assert(@intFromPtr(node.data.values.items.ptr) != 0xaaaaaaaaaaaaaaaa);
                    node.data.values.deinit(allocator);
                } else {
                    for (node.data.children.items) |*n| n.deinitContext(allocator, context);
                    node.data.children.deinit(allocator);
                }
                node.* = undefined;
            }

            fn isLeaf(node: Node) bool {
                return node.level == 0;
            }

            fn search(
                node: Node,
                range: Range,
                list: *std.ArrayList(*KV),
            ) Allocator.Error!void {
                if (node.isLeaf()) {
                    for (node.data.values.items) |*kv| {
                        if (range.intersects(kv.key)) {
                            try list.append(kv);
                        }
                    }
                } else {
                    for (node.data.children.items) |n| {
                        if (range.intersects(n.range)) {
                            try n.search(range, list);
                        }
                    }
                }
            }

            /// Returns the first kv pair whose key is exactly equal to `key`
            pub fn get(node: *Node, key: Range) ?struct { *Node, usize } {
                if (node.isLeaf()) {
                    for (node.data.values.items, 0..) |*kv, i| {
                        if (Range.eql(key, kv.key)) return .{ node, i };
                    }
                } else {
                    for (node.data.children.items) |*n| {
                        if (key.intersects(n.range)) {
                            if (n.get(key)) |kv| return kv;
                        }
                    }
                }

                return null;
            }

            const GetOrPutResultInternal = struct {
                ?Node,
                GetOrPutResult,
            };

            fn getOrPut(
                node: *Node,
                allocator: Allocator,
                key: Range,
                /// Context that has the method `fn init(@This()) !V` This allows errors resulting
                /// from init to be caught before inserting, which means OOM from initialising a
                /// value doesn't require a remove (which may fail due to OOM and leave the tree in
                /// an invalid state).
                context: anytype,
            ) !GetOrPutResultInternal {
                var ok = true;
                defer if (ok) {
                    // Update the node's range if there are no errors
                    node.range = node.range.merge(key);
                };
                errdefer ok = false;

                if (node.isLeaf()) {
                    for (node.data.values.items) |*kv| {
                        if (Range.eql(kv.key, key)) {
                            // Already exists
                            return .{ null, .{ .found_existing = true, .kv = kv } };
                        }
                    }

                    // `key` doesn't already exist
                    try node.data.values.ensureUnusedCapacity(allocator, 1);
                    var new_kv = KV{
                        .key = key,
                        .value = if (@TypeOf(context) != void)
                            try context.init(allocator)
                        else
                            undefined,
                    };
                    errdefer if (@TypeOf(context) != void) context.deinit(allocator, &new_kv.value);
                    node.data.values.appendAssumeCapacity(new_kv);
                    errdefer _ = node.data.values.pop();

                    if (node.data.values.items.len >= max_children) {
                        // Don't merge ranges in this branch, split does that
                        ok = false;
                        // Too many kvs, need to split this node
                        const new_node = try node.split(allocator);

                        const ret = .{
                            // Return the new node up the call stack so the parent
                            // can add it to their child list
                            new_node,
                            .{
                                .found_existing = false,
                                .kv = if (new_node.data.values.items[0].key.eql(key))
                                    &new_node.data.values.items[0]
                                else
                                    &new_node.data.values.items[1],
                            },
                        };

                        assert(ret[1].kv.key.eql(key));
                        return ret;
                    }

                    return .{
                        null,
                        .{
                            .found_existing = false,
                            .kv = &node.data.values.items[node.data.values.items.len - 1],
                        },
                    };
                }

                // Branch node
                const list = &node.data.children;
                try list.ensureUnusedCapacity(allocator, 1);

                const best = node.bestChild(key);
                const maybe_new_node, const res = try best.getOrPut(allocator, key, context);

                if (maybe_new_node) |split_node| {
                    // Child node was split, need to add new node to child list
                    list.appendAssumeCapacity(split_node);

                    if (list.items.len >= max_children) {
                        ok = false;
                        const new_node = try node.split(allocator);
                        return .{ new_node, res };
                    }
                }

                return .{ null, res };
            }

            fn getSingle(node: *Node, key: Range) ?*KV {
                if (!node.range.contains(key)) return null;

                if (node.isLeaf()) {
                    return for (node.data.values.items) |*kv| {
                        if (kv.key.eql(key)) break kv;
                    } else null;
                }

                return for (node.data.children.items) |*n| {
                    break n.getSingle(key) orelse continue;
                } else null;
            }

            /// Find best child to insert into.
            /// Gets the child with the smallest area increase to store `key`
            fn bestChild(node: *Node, key: Range) *Node {
                assert(!node.isLeaf());

                const slice = node.data.children.items;
                assert(slice.len > 0);

                var min_index: usize = 0;
                var min_diff = blk: {
                    const rect = Range.merge(slice[0].range, key);
                    break :blk rect.area() - slice[0].range.area();
                };

                for (slice[1..], 1..) |n, i| {
                    const rect = Range.merge(n.range, key);
                    const diff = rect.area() - n.range.area();
                    if (diff < min_diff) {
                        min_index = i;
                        min_diff = diff;
                    }
                }

                return &node.data.children.items[min_index];
            }

            fn recalcBoundingRange(node: Node) Range {
                if (node.isLeaf()) {
                    const slice: []const KV = node.data.values.items;
                    assert(slice.len > 0);

                    var range = slice[0].key;
                    for (slice[1..]) |kv| {
                        range = range.merge(kv.key);
                    }
                    return range;
                }

                const slice: []const Node = node.data.children.items;
                assert(slice.len > 0);
                var range = slice[0].range;
                for (slice[1..]) |n| {
                    range = range.merge(n.range);
                }
                return range;
            }

            /// Removes `key` and its associated value from the tree.
            fn remove(
                node: *Node,
                key: Range,
            ) struct {
                /// Removed kv pair (if any)
                ?KV,
                /// Whether `node` needs to be merged with another one
                bool,
                /// Whether the node's range needs to be recalculated
                bool,

                /// Index of node needing to be merged in parent
                ?usize,
                /// Parent of node needing to be merged
                ?*Node,
            } {
                if (node.isLeaf()) {
                    const list = &node.data.values;
                    const ret = for (list.items, 0..) |kv, i| {
                        if (!Range.eql(kv.key, key)) continue;
                        _ = list.swapRemove(i);
                        break .{
                            kv,
                            list.items.len < min_children,
                            key.tl.anyMatch(node.range.tl) or key.br.anyMatch(node.range.br),
                            null,
                            null,
                        };
                    } else .{ null, false, false, null, null };

                    if (list.items.len > 0 and ret[2])
                        node.range = node.recalcBoundingRange();
                    return ret;
                }

                const list = &node.data.children;
                for (list.items, 0..) |*n, i| {
                    if (!n.range.contains(key)) continue;
                    const res = n.remove(key);
                    const kv, const merge_node, const recalc, var index, var parent = res;
                    if (kv == null) continue; // Didn't find a value

                    if (merge_node and list.items.len > 1) {
                        parent = node;
                        index = i;

                        if (recalc) {
                            const start = @intFromBool(i == 0);
                            var range = list.items[start].range;
                            for (list.items[0..i]) |c| range = range.merge(c.range);
                            for (list.items[i + 1 ..]) |c| range = range.merge(c.range);
                            node.range = range;
                        }
                    } else if (recalc) {
                        node.range = node.recalcBoundingRange();
                    }

                    const len = list.items.len - @intFromBool(parent == node);
                    return .{ kv, len < min_children, recalc, index, parent };
                } else return .{ null, false, false, null, null };
                unreachable;
            }

            fn getRange(a: anytype) Range {
                return switch (@TypeOf(a)) {
                    Node => a.range,
                    KV => a.key,
                    else => @compileError("Invalid type"),
                };
            }

            fn split(node: *Node, allocator: Allocator) Allocator.Error!Node {
                if (node.isLeaf()) {
                    return node.splitNode(.leaf, allocator);
                } else {
                    return node.splitNode(.branch, allocator);
                }
            }

            /// Splits a node in place, returning the other half as a new node.
            fn splitNode(
                node: *Node,
                comptime node_type: enum { branch, leaf },
                allocator: Allocator,
            ) !Node {
                const entries = switch (node_type) {
                    .leaf => &node.data.values,
                    .branch => &node.data.children,
                };

                var new_entries = switch (node_type) {
                    .leaf => ValueList{},
                    .branch => ChildList{},
                };

                try new_entries.ensureTotalCapacity(allocator, max_children);
                errdefer new_entries.deinit(allocator);

                const seed2, const seed1 = blk: {
                    const i_1, const i_2 = linearSplit(entries.items);
                    assert(i_1 < i_2);
                    break :blk .{ entries.orderedRemove(i_2), entries.orderedRemove(i_1) };
                };

                var bound2 = getRange(seed2);
                new_entries.appendAssumeCapacity(seed2);

                for (0..min_children - 1) |_| {
                    const e = entries.pop();
                    bound2 = bound2.merge(getRange(e));
                    new_entries.appendAssumeCapacity(e);
                }

                entries.appendAssumeCapacity(seed1);
                node.range = node.recalcBoundingRange();

                return .{
                    .level = node.level,
                    .range = bound2,
                    .data = switch (node_type) {
                        .leaf => .{ .values = new_entries },
                        .branch => .{ .children = new_entries },
                    },
                };
            }

            const DimStats = struct {
                const maxInt = std.math.maxInt;
                const minInt = std.math.minInt;

                min_tl: PosInt = maxInt(PosInt),
                max_tl: PosInt = minInt(PosInt),

                max_br: PosInt = minInt(PosInt),
                min_br: PosInt = maxInt(PosInt),

                tl_index: usize = 0,
                br_index: usize = 0,

                fn farthest(s: DimStats) PosInt {
                    return if (s.max_br > s.min_tl)
                        s.max_br - s.min_tl
                    else
                        s.min_tl - s.max_br;
                }

                fn nearest(s: DimStats) PosInt {
                    return if (s.min_br > s.max_tl)
                        s.min_br - s.max_tl
                    else
                        s.max_tl - s.min_br;
                }

                fn computeDim(s: *DimStats, lo: PosInt, hi: PosInt, i: usize) void {
                    s.min_tl = @min(s.min_tl, lo);
                    s.max_br = @max(s.max_br, hi);

                    if (lo > s.max_tl) {
                        s.max_tl = lo;
                        s.tl_index = i;
                    }

                    if (hi < s.min_br) {
                        s.min_br = hi;
                        s.br_index = i;
                    }
                }
            };

            fn linearSplit(entries: anytype) struct { usize, usize } {
                var dx = DimStats{};
                var dy = DimStats{};

                if (entries.len > 2) {
                    for (entries, 0..) |e, i| {
                        const rect = getRange(e);
                        dx.computeDim(rect.tl.x, rect.br.x, i);
                        dy.computeDim(rect.tl.y, rect.br.y, i);
                    }
                }

                const max = std.math.maxInt(PosInt);
                const norm_x = std.math.divTrunc(PosInt, dx.nearest(), dx.farthest()) catch max;
                const norm_y = std.math.divTrunc(PosInt, dy.nearest(), dy.farthest()) catch max;
                const x, const y = if (norm_x > norm_y)
                    .{ dx.tl_index, dx.br_index }
                else
                    .{ dy.tl_index, dy.br_index };

                return if (x < y)
                    .{ x, y }
                else if (x > y)
                    .{ y, x }
                else if (x == 0)
                    .{ 0, 1 }
                else
                    .{ 0, y };
            }
        };

        /// Returns an unorded list of key-value pairs whose keys intersect `range`
        pub fn search(
            tree: Self,
            allocator: Allocator,
            range: Range,
        ) Allocator.Error![]*KV {
            var list = std.ArrayList(*KV).init(allocator);
            errdefer list.deinit();

            try tree.root.search(range, &list);
            return list.toOwnedSlice();
        }

        fn mergeRoots(tree: *Self, allocator: Allocator, new_node: Node) Allocator.Error!void {
            // Root node got split, need to create a new root
            var new_root = Node{
                .level = new_node.level + 1,
                .range = Range.merge(tree.root.range, new_node.range),
                .data = .{ .children = .{} },
            };

            try new_root.data.children.appendSlice(allocator, &.{ tree.root, new_node });
            tree.root = new_root;
        }

        pub fn put(
            tree: *Self,
            allocator: Allocator,
            key: Range,
            value: V,
        ) Allocator.Error!void {
            const res = try tree.getOrPut(allocator, key);
            res.kv.value = value;
        }

        // pub fn putContext(
        //     tree: *Self,
        //     allocator: Allocator,
        //     key: Range,
        //     value: V,
        //     context: anytype,
        // ) !void {
        //     const res = try tree.getOrPutContext(allocator, key, context);
        //     context.deinit(allocator, &res.kv.value);
        //     res.kv.value = value;
        // }

        pub fn putNoClobber(
            tree: *Self,
            allocator: Allocator,
            key: Range,
            value: V,
        ) !void {
            const res = try tree.getOrPut(allocator, key);
            assert(!res.found_existing);
            res.kv.value = value;
        }

        pub fn putNoClobberContext(
            tree: *Self,
            allocator: Allocator,
            key: Range,
            value: V,
            context: anytype,
        ) !void {
            const res = try tree.getOrPutContext(allocator, key, context);
            assert(!res.found_existing);
            res.kv.value = value;
        }

        pub const GetOrPutResult = struct {
            kv: *KV,
            found_existing: bool,
        };

        pub fn getOrPut(
            tree: *Self,
            allocator: Allocator,
            key: Range,
        ) !GetOrPutResult {
            if (tree.root.getSingle(key)) |kv| return .{ .found_existing = true, .kv = kv };
            var maybe_new_node, const res = try tree.root.getOrPut(allocator, key, {});
            if (maybe_new_node) |*new_node| {
                errdefer new_node.deinit(allocator);
                try tree.mergeRoots(allocator, new_node.*);
            }
            return res;
        }

        pub fn getOrPutContext(
            tree: *Self,
            allocator: Allocator,
            key: Range,
            context: anytype,
        ) !GetOrPutResult {
            var maybe_new_node, const res = try tree.root.getOrPut(allocator, key, context);
            if (maybe_new_node) |*new_node| {
                errdefer new_node.deinitContext(allocator, context);
                try tree.mergeRoots(allocator, new_node.*);
            }
            return res;
        }

        /// Adds all keys contained in the tree belonging to `root` into `tree`
        fn reAddRecursive(
            tree: *Self,
            allocator: Allocator,
            root: *Node,
            context: anytype,
        ) Allocator.Error!void {
            var maybe_err: Allocator.Error!void = {};
            if (root.isLeaf()) {
                defer root.data.values.deinit(allocator);
                while (root.data.values.popOrNull()) |temp| {
                    var kv = temp;
                    tree.put(allocator, kv.key, kv.value) catch |err| {
                        if (@TypeOf(context) != void)
                            context.deinit(allocator, &kv.value);
                        maybe_err = err;
                    };
                }
            } else {
                defer root.data.children.deinit(allocator);
                while (root.data.children.popOrNull()) |temp| {
                    var child = temp;
                    tree.reAddRecursive(allocator, &child, context) catch |err| {
                        maybe_err = err;
                    };
                }
            }
            return maybe_err;
        }

        /// Removes `key` and its associated value from the true.
        pub fn remove(
            tree: *Self,
            allocator: Allocator,
            key: Range,
        ) Allocator.Error!void {
            return tree.removeContext(allocator, key, {});
        }

        /// Removes `key` and its associated value from the true.
        pub fn removeContext(
            tree: *Self,
            allocator: Allocator,
            key: Range,
            context: anytype,
        ) Allocator.Error!void {
            const res = tree.root.remove(key);

            if (@TypeOf(context) != void) {
                if (res[0]) |kv| {
                    var temp = kv;
                    context.deinit(&temp.value);
                }
            }
            const parent = res[4] orelse return;
            const index = res[3].?;
            var child: Node = parent.data.children.swapRemove(index);
            defer child.deinitContext(allocator, context);

            // try tree.reAddRecursive(allocator, &child, context);
        }

        pub fn deinit(tree: *Self, allocator: Allocator) void {
            return tree.deinitContext(allocator, {});
        }

        pub fn deinitContext(
            tree: *Self,
            allocator: Allocator,
            context: anytype,
        ) void {
            tree.root.deinitContext(allocator, context);
            tree.* = undefined;
        }
    };
}

// Dependent tree
pub fn DependentTree(comptime min_children: usize) type {
    return struct {
        rtree: Tree = .{},

        const Self = @This();
        const RangeList = std.ArrayListUnmanaged(Range);
        const Tree = RTree(RangeList, min_children);
        const Context = struct {
            capacity: usize = 1,

            fn init(self: Context, allocator: Allocator) !RangeList {
                return RangeList.initCapacity(allocator, self.capacity);
            }

            fn deinit(_: Context, allocator: Allocator, value: *RangeList) void {
                value.deinit(allocator);
            }
        };
        pub const GetOrPutResult = Tree.GetOrPutResult;

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.rtree.deinitContext(allocator, Context{});
            self.* = undefined;
        }

        pub fn put(
            self: *Self,
            allocator: Allocator,
            key: Range,
            value: Range,
        ) Allocator.Error!void {
            const res = try self.getOrPut(allocator, key, 1);
            try res.kv.value.append(allocator, value);
        }

        pub fn putSlice(
            self: *Self,
            allocator: Allocator,
            key: Range,
            values: []const Range,
        ) Allocator.Error!void {
            const res = try self.getOrPut(allocator, key, values.len);
            try res.kv.value.appendSlice(allocator, values);
        }

        pub fn getOrPut(
            self: *Self,
            allocator: Allocator,
            key: Range,
            init_capacity: usize,
        ) Allocator.Error!GetOrPutResult {
            if (self.rtree.root.getSingle(key)) |kv|
                return .{ .found_existing = true, .kv = kv };
            var maybe_new_node, const res = try self.rtree.root.getOrPut(
                allocator,
                key,
                Context{ .capacity = init_capacity },
            );
            if (maybe_new_node) |*new_node| {
                errdefer new_node.deinitContext(allocator, Context{});
                try self.rtree.mergeRoots(allocator, new_node.*);
            }
            return res;
        }

        pub fn search(
            self: *Self,
            allocator: Allocator,
            key: Range,
        ) Allocator.Error![]*Tree.KV {
            return self.rtree.search(allocator, key);
        }

        pub fn removeKey(
            self: *Self,
            allocator: Allocator,
            key: Range,
        ) Allocator.Error!void {
            return self.rtree.removeContext(allocator, key, Context{});
        }

        /// Removes `value` from the list of values associated with `key`.
        /// Removes `key` if there are no values left after removal.
        pub fn removeValue(
            self: *Self,
            allocator: Allocator,
            key: Range,
            value: Range,
        ) Allocator.Error!void {
            const res = removeNode(&self.rtree.root, allocator, key, value);

            const parent: *Tree.Node = res[4] orelse return;
            const index: usize = res[3].?;
            assert(parent.data.children.items.len > 1);
            var child = parent.data.children.swapRemove(index);
            assert(child.level < self.rtree.root.level);

            try self.reAddRecursive(allocator, &child);
        }

        /// Adds all keys contained in the tree belonging to `root` into `tree`
        fn reAddRecursive(
            self: *Self,
            allocator: Allocator,
            root: *Tree.Node,
        ) Allocator.Error!void {
            var maybe_err: Allocator.Error!void = {};
            if (root.isLeaf()) {
                defer root.data.values.deinit(allocator);
                while (root.data.values.popOrNull()) |temp| {
                    var kv = temp;
                    self.rtree.put(allocator, kv.key, kv.value) catch |err| {
                        kv.value.deinit(allocator);
                        maybe_err = err;
                    };
                }
            } else {
                defer root.data.children.deinit(allocator);
                while (root.data.children.popOrNull()) |temp| {
                    var child = temp;
                    self.reAddRecursive(allocator, &child) catch |err| {
                        maybe_err = err;
                    };
                }
            }
            return maybe_err;
        }

        /// Custom implementation of `remove` for the DependentTree
        /// Removes `value` from the entry with key `key`
        fn removeNode(
            node: *Tree.Node,
            allocator: Allocator,
            key: Range,
            value: Range,
        ) struct {
            /// Whether any item was removed
            bool,
            /// Whether `node` needs to be merged with another one
            bool,
            /// Whether the node's range needs to be recalculated
            bool,

            ?usize,
            ?*Tree.Node,
        } {
            if (node.isLeaf()) {
                const list = &node.data.values;
                return for (list.items, 0..) |*kv, i| {
                    if (!Range.eql(kv.key, key)) continue;
                    errdefer if (kv.value.items.len == 0) {
                        var old_kv = list.swapRemove(i);
                        Context.deinit(.{}, allocator, &old_kv.value);
                    };

                    // Found matching key
                    // Now find the matching value
                    for (kv.value.items, 0..) |v, j| {
                        if (!v.eql(value)) continue;
                        _ = kv.value.swapRemove(j);
                        break;
                    }

                    if (kv.value.items.len == 0) {
                        // This KV has no more values, so remove it entirely
                        var old_kv = list.swapRemove(i);
                        Context.deinit(.{}, allocator, &old_kv.value);

                        const recalc = key.tl.anyMatch(node.range.tl) or
                            key.br.anyMatch(node.range.br);
                        if (list.items.len > 0 and recalc)
                            node.range = node.recalcBoundingRange();

                        break .{
                            true,
                            list.items.len < min_children,
                            recalc,
                            null,
                            null,
                        };
                    }

                    // Didn't remove a kv, don't return a new node and don't recalculate
                    // minimum bounding rectangles
                    break .{ true, false, false, null, null };
                } else .{ false, false, false, null, null };
            }

            const list = &node.data.children;
            for (list.items, 0..) |*n, i| {
                if (!n.range.contains(key)) continue;
                const res = removeNode(n, allocator, key, value);
                const found, const merge_node, const recalc, var index, var parent = res;
                if (!found) continue;

                if (merge_node and list.items.len > 1) {
                    parent = node;
                    index = i;

                    if (recalc) {
                        const start = @intFromBool(i == 0);
                        var range = list.items[start].range;
                        for (list.items[0..i]) |c| range = range.merge(c.range);
                        for (list.items[i + 1 ..]) |c| range = range.merge(c.range);
                        node.range = range;
                    }
                } else if (recalc) {
                    node.range = node.recalcBoundingRange();
                }

                const len = list.items.len - @intFromBool(parent == node);
                return .{ true, len < min_children, recalc, index, parent };
            } else return .{ false, false, false, null, null };
            unreachable;
        }

        test "DependentTree1" {
            const t = std.testing;

            var tree = Self{};
            defer tree.deinit(t.allocator);

            try t.expectEqual(@as(usize, 0), tree.rtree.root.data.values.items.len);
            try t.expect(tree.rtree.root.isLeaf());

            const data = .{
                .{
                    // Key
                    Range.init(11, 2, 11, 2),
                    .{ // Values
                        Range.initSingle(0, 0),
                        Range.initSingle(10, 10),
                    },
                },
                .{
                    Range.init(0, 0, 2, 2),
                    .{
                        Range.initSingle(500, 500),
                        Range.initSingle(500, 501),
                        Range.initSingle(500, 502),
                    },
                },
                .{
                    Range.init(1, 1, 3, 3),
                    .{
                        Range.initSingle(501, 500),
                        Range.initSingle(501, 501),
                        Range.initSingle(501, 502),
                    },
                },
                .{
                    Range.init(1, 1, 10, 10),
                    .{
                        Range.initSingle(502, 500),
                        Range.initSingle(502, 501),
                        Range.initSingle(502, 502),
                        Range.initSingle(502, 503),
                        Range.initSingle(502, 504),
                        Range.initSingle(502, 505),
                    },
                },
                .{
                    Range.init(5, 5, 10, 10),
                    .{
                        Range.initSingle(503, 500),
                        Range.initSingle(503, 501),
                    },
                },
                .{
                    Range.init(3, 3, 4, 4),
                    .{
                        Range.initSingle(503, 500),
                        Range.initSingle(503, 501),
                    },
                },
                .{
                    Range.init(3, 3, 4, 4),
                    .{
                        Range.initSingle(503, 502),
                    },
                },
                .{
                    Range.init(3, 3, 4, 4),
                    .{
                        Range.initSingle(503, 502),
                    },
                },
                .{
                    Range.init(3, 3, 4, 4),
                    .{
                        Range.initSingle(503, 502),
                    },
                },
            };

            inline for (data) |d| {
                const key, const values = d;
                try tree.putSlice(t.allocator, key, &values);
            }

            try t.expectEqual(Range.init(0, 0, 11, 10), tree.rtree.root.range);

            {
                const res = try tree.search(t.allocator, Range.init(3, 3, 4, 4));
                defer t.allocator.free(res);

                const expected_results = .{
                    Range.initSingle(501, 500),
                    Range.initSingle(501, 501),
                    Range.initSingle(501, 502),
                    Range.initSingle(502, 500),
                    Range.initSingle(502, 501),
                    Range.initSingle(502, 502),
                    Range.initSingle(502, 503),
                    Range.initSingle(502, 504),
                    Range.initSingle(502, 505),
                    Range.initSingle(503, 500),
                    Range.initSingle(503, 501),
                    Range.initSingle(503, 502),
                };

                // Check that all ranges in `expected_results` are found in `res` in ANY order.
                for (res) |kv| {
                    for (kv.value.items) |r| {
                        inline for (expected_results) |e| {
                            if (Range.eql(r, e)) break;
                        } else return error.SearchMismatch;
                    }
                }
            }
            {
                const res = try tree.search(t.allocator, Range.initSingle(0, 0));
                defer t.allocator.free(res);

                const expected_results = .{
                    Range.initSingle(500, 500),
                    Range.initSingle(500, 501),
                    Range.initSingle(500, 502),
                };

                for (res) |kv| {
                    for (kv.value.items) |r| {
                        inline for (expected_results) |e| {
                            if (Range.eql(r, e)) break;
                        } else return error.SearchMismatch;
                    }
                }
            }
            {
                const res = try tree.search(t.allocator, Range.initSingle(5, 5));
                defer t.allocator.free(res);

                const expected_results = .{
                    Range.initSingle(502, 500),
                    Range.initSingle(502, 501),
                    Range.initSingle(502, 502),
                    Range.initSingle(502, 503),
                    Range.initSingle(502, 504),
                    Range.initSingle(502, 505),
                    Range.initSingle(503, 500),
                    Range.initSingle(503, 501),
                };
                for (res) |kv| {
                    for (kv.value.items) |r| {
                        inline for (expected_results) |e| {
                            if (Range.eql(r, e)) break;
                        } else return error.SearchMismatch;
                    }
                }
            }
            {
                const res = try tree.search(t.allocator, Range.initSingle(11, 11));
                try t.expectEqualSlices(*Tree.KV, &.{}, res);
            }

            {
                // Check that it contains all ranges
                const res = try tree.search(t.allocator, Range.init(0, 0, 500, 500));
                defer t.allocator.free(res);
                for (res) |kv| {
                    data_loop: inline for (data) |d| {
                        inline for (d[1]) |range| {
                            for (kv.value.items) |r|
                                if (range.eql(r)) break :data_loop;
                        }
                    } else return error.SearchMismatch;
                }
            }
        }

        test "DependentTree2" {
            const t = std.testing;

            var r: Self = .{};
            defer r.deinit(t.allocator);

            const bound = 15;

            for (0..bound) |i| {
                for (0..bound) |j| {
                    const key = Range.initSingle(@intCast(i), @intCast(j));
                    const value = Range.initSingle(@intCast(bound - i - 1), @intCast(bound - j - 1));
                    try r.put(t.allocator, key, value);
                    try std.testing.expect(r.rtree.root.getSingle(key) != null);
                    try r.put(t.allocator, key, value);
                    try std.testing.expect(r.rtree.root.getSingle(key) != null);
                }
            }

            for (0..bound) |i| {
                for (0..bound) |j| {
                    // Ensure no duplicate keys are present
                    const range = Range.initSingle(@intCast(i), @intCast(j));
                    const res = try r.search(t.allocator, range);
                    defer t.allocator.free(res);
                    std.testing.expectEqual(@as(usize, 1), res.len) catch |err| {
                        std.debug.print("Range: {}\n", .{range});
                        return err;
                    };
                }
            }

            for (0..bound) |i| {
                for (0..bound) |j| {
                    try r.removeValue(
                        t.allocator,
                        Range.initSingle(@intCast(bound - i - 1), @intCast(bound - j - 1)),
                        Range.initSingle(@intCast(i), @intCast(j)),
                    );
                    try r.removeValue(
                        t.allocator,
                        Range.initSingle(@intCast(bound - i - 1), @intCast(bound - j - 1)),
                        Range.initSingle(@intCast(i), @intCast(j)),
                    );
                }
            }
        }
    };
}
