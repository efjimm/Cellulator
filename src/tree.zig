const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Position = @import("Position.zig").Position;
const Rect = Position.Rect;
const PosInt = Position.Int;
const MultiArrayList = @import("multi_array_list.zig").MultiArrayList;
const Sheet = @import("Sheet.zig");
const Range = Sheet.Range;
const Cell = Sheet.Cell;

// TODO: Keep all nodes in a single array and use indices instead of pointers.

pub fn RTree(comptime K: type, comptime V: type, comptime min_children: usize) type {
    assert(min_children >= 2);
    return struct {
        const max_children: comptime_int = min_children * 2;
        const ListPool = @import("pool.zig").MemoryPool(std.BoundedArray(Node, max_children), .{});

        root: Node = .{
            .level = 0,
            .range = undefined,
            .data = .{ .values = .{} },
        },
        pool: ListPool = .{},
        sheet: *Sheet,

        const Self = @This();

        const KV = struct {
            key: K,
            /// List of cells that depend on the cells in `key`
            value: V,
        };

        pub const SearchItem = struct {
            key: K,
            value_ptr: *V,
        };

        const Node = struct {
            const ValueList = std.MultiArrayList(KV);

            const Data = union {
                children: *std.BoundedArray(Node, max_children),
                values: ValueList,
            };

            level: u32,
            range: Range,
            data: Data,

            fn isLeaf(node: *const Node) bool {
                return node.level == 0;
            }
        };

        /// Finds the key/value pair whose key matches `key` and returns pointers
        /// to the key and value, or `null` if not found.
        pub fn get(tree: *Self, key: K) ?struct { *K, *V } {
            if (tree.root.isLeaf()) {
                if (tree.root.data.values.len == 0)
                    return null;
            } else if (tree.root.data.children.len == 0) {
                return null;
            }

            return getSingle(tree, &tree.root, key);
        }

        pub fn put(
            tree: *Self,
            key: K,
            value: V,
        ) Allocator.Error!void {
            return tree.putContext(key, value, {});
        }

        pub fn putContext(
            tree: *Self,
            key: K,
            value: V,
            context: anytype,
        ) Allocator.Error!void {
            var maybe_new_node = tree.putNode(&tree.root, key, value) catch
                return error.OutOfMemory;

            if (maybe_new_node) |*new_node| {
                errdefer deinitNodeContext(tree, new_node, tree.sheet.allocator, context);
                try tree.mergeRoots(new_node.*);
            }
        }

        /// Removes `key` and its associated value from the tree.
        pub fn remove(
            tree: *Self,
            key: K,
        ) Allocator.Error!void {
            return tree.removeContext(key, {});
        }

        /// Removes `key` and its associated value from the tree.
        pub fn removeContext(
            tree: *Self,
            key: K,
            context: anytype,
        ) Allocator.Error!void {
            var res = removeNode(tree, &tree.root, key) orelse return;

            if (@TypeOf(context) != void)
                context.deinit(tree.sheet.allocator, &res.kv.value);

            var node_to_merge = blk: {
                if (!tree.root.isLeaf()) {
                    // Remove the root node if it goes under `min_children`, so all of its leaves
                    // can be re-added
                    const root_len = tree.root.data.children.len -
                        @intFromBool(res.merge.parent == &tree.root);
                    if (root_len < min_children) {
                        const ret = tree.root;
                        tree.root = .{
                            .level = 0,
                            .range = undefined,
                            .data = .{ .values = .{} },
                        };
                        break :blk ret;
                    }
                }
                const parent = res.merge.parent orelse return;
                const child_index = res.merge.child_index;
                break :blk parent.data.children.swapRemove(child_index);
            };

            try tree.reAddRecursive(&node_to_merge, context);
        }

        pub fn deinit(tree: *Self, allocator: Allocator) void {
            return tree.deinitContext(allocator, {});
        }

        pub fn deinitContext(
            tree: *Self,
            allocator: Allocator,
            context: anytype,
        ) void {
            tree.deinitNodeContext(&tree.root, allocator, context);
            tree.pool.deinit(allocator);
            tree.* = undefined;
        }

        /// Returns an unorded list of key-value pairs whose keys intersect `range`
        pub fn search(
            tree: *Self,
            allocator: Allocator,
            range: Rect,
        ) Allocator.Error![]SearchItem {
            var list = std.ArrayList(SearchItem).init(allocator);
            errdefer list.deinit();

            try searchNode(tree, &tree.root, range, &list);
            return list.toOwnedSlice();
        }

        pub fn searchIterator(
            tree: *Self,
            allocator: Allocator,
            rect: Rect,
        ) Allocator.Error!SearchIterator {
            var ret: SearchIterator = .{
                .rect = rect,
                .allocator = allocator,
                .tree = tree,
                .index = 0,
                .stack = .empty,
            };
            try ret.stack.append(allocator, &tree.root);
            return ret;
        }

        pub const SearchIterator = struct {
            tree: *Self,
            stack: std.ArrayListUnmanaged(*Node),
            index: usize,
            rect: Rect,
            allocator: Allocator,

            /// Resets the iterator, retaining any memory allocated for the stack
            pub fn reset(
                iter: *SearchIterator,
                new_range: Rect,
                tree: *Self,
            ) Allocator.Error!void {
                iter.rect = new_range;
                iter.index = 0;
                iter.stack.clearRetainingCapacity();
                try iter.stack.append(iter.allocator, &tree.root);
            }

            pub fn deinit(iter: *SearchIterator) void {
                iter.stack.deinit(iter.allocator);
            }

            pub fn next(iter: *SearchIterator) !?SearchItem {
                const node = iter.stack.popOrNull() orelse return null;

                if (node.isLeaf()) {
                    if (iter.index >= node.data.values.len) {
                        iter.index = 0;
                        return iter.next();
                    }

                    const values = node.data.values.items(.value);
                    const keys = node.data.values.items(.key);

                    for (keys[iter.index..], iter.index..) |k, i| {
                        if (iter.rect.intersects(k.rect(iter.tree.sheet))) {
                            // We might have more matches in this leaf node, put it back on the
                            // stack
                            try iter.stack.append(iter.allocator, node);
                            iter.index = i + 1;
                            return .{
                                .key = k,
                                .value_ptr = &values[i],
                            };
                        }
                    }
                } else {
                    for (node.data.children.slice()) |*child| {
                        const child_rect = child.range.rect(iter.tree.sheet);
                        if (iter.rect.intersects(child_rect)) {
                            try iter.stack.append(iter.allocator, child);
                        }
                    }
                }

                iter.index = 0;
                return iter.next();
            }
        };

        pub fn searchBuffer(
            tree: *Self,
            allocator: Allocator,
            list: *std.ArrayListUnmanaged(V),
            range: Rect,
        ) Allocator.Error!void {
            try searchValues(tree, &tree.root, allocator, range, list);
        }

        /// Frees all memory associated with `node` and its children, and calls
        /// `context.deinitValue` on every instance of `V` in the tree.
        fn deinitNodeContext(
            tree: *Self,
            node: *Node,
            allocator: Allocator,
            context: anytype,
        ) void {
            if (node.isLeaf()) {
                if (@TypeOf(context) != void) {
                    for (node.data.values.items(.value)) |*v| {
                        context.deinit(allocator, v);
                    }
                }
                node.data.values.deinit(allocator);
            } else {
                for (node.data.children.slice()) |*n|
                    tree.deinitNodeContext(n, allocator, context);
            }
            node.* = undefined;
        }

        fn searchValues(
            tree: *Self,
            node: *const Node,
            allocator: Allocator,
            rect: Rect,
            list: *std.ArrayListUnmanaged(V),
        ) Allocator.Error!void {
            if (node.isLeaf()) {
                const values = node.data.values.items(.value);
                for (node.data.values.items(.key), 0..) |*k, i| {
                    if (rect.intersects(k.rect(tree.sheet))) {
                        try list.append(allocator, values[i]);
                    }
                }
            } else {
                for (node.data.children.constSlice()) |*n| {
                    if (rect.intersects(n.range.rect(tree.sheet))) {
                        try searchValues(tree, n, allocator, rect, list);
                    }
                }
            }
        }

        fn searchNode(
            tree: *Self,
            node: *const Node,
            rect: Rect,
            list: *std.ArrayList(SearchItem),
        ) Allocator.Error!void {
            if (node.isLeaf()) {
                const values = node.data.values.items(.value);
                for (node.data.values.items(.key), 0..) |k, i| {
                    if (rect.intersects(k.rect(tree.sheet))) {
                        try list.append(.{
                            .key = k,
                            .value_ptr = &values[i],
                        });
                    }
                }
            } else {
                for (node.data.children.constSlice()) |*n| {
                    if (rect.intersects(n.range.rect(tree.sheet))) {
                        try searchNode(tree, n, rect, list);
                    }
                }
            }
        }

        fn getSingleRecursive(tree: *Self, node: *Node, key: K) ?struct { *K, *V } {
            if (node.isLeaf()) {
                for (node.data.values.items(.key), 0..) |*k, i| {
                    if (k.eql(key))
                        return .{ k, &node.data.values.items(.value)[i] };
                }
                return null;
            }

            for (node.data.children.slice()) |*n| {
                if (n.range.rect(tree.sheet).contains(key.rect(tree.sheet))) {
                    if (getSingleRecursive(tree, n, key)) |res|
                        return res;
                }
            }
            return null;
        }

        fn getSingle(tree: *Self, node: *Node, key: K) ?struct { *K, *V } {
            return if (node.range.rect(tree.sheet).contains(key.rect(tree.sheet)))
                getSingleRecursive(tree, node, key)
            else
                null;
        }

        fn bestLeaf(tree: *Self, node: *Node, key: K) *Node {
            assert(node.level == 1);
            const children = node.data.children.constSlice();
            assert(children.len > 0);

            // Minimize overlap
            var min_index: usize = 0;
            var min_enlargement: u64 = 0;
            var min_overlap: u64 = std.math.maxInt(u64);

            for (children, 0..) |n1, i| {
                const rect = n1.range.rect(tree.sheet);
                const r = rect.merge(key.rect(tree.sheet));
                const enlargement = r.area() - rect.area();

                const total_overlap = totalOverlap(tree, children, r);

                if (total_overlap <= min_overlap) {
                    if (total_overlap != min_overlap or min_enlargement < enlargement) {
                        min_index = i;
                        min_enlargement = enlargement;
                        min_overlap = total_overlap;
                    }
                }
            }
            return &node.data.children.slice()[min_index];
        }

        fn totalOverlap(tree: *Self, nodes: []const Node, range: Rect) u64 {
            var total: u64 = 0;
            for (nodes) |*n| {
                total += range.overlapArea(n.range.rect(tree.sheet));
            }
            return total;
        }

        /// Find best child to insert into.
        /// Gets the child with the smallest area increase to store `key`
        fn bestChild(tree: *Self, node: *Node, key: K) *Node {
            assert(!node.isLeaf());

            if (node.level == 1) return bestLeaf(tree, node, key);

            // Minimize area enlargement

            const key_rect = key.rect(tree.sheet);

            const children = node.data.children.constSlice();
            assert(children.len > 0);

            var min_index: usize = 0;
            var min_area_diff, var min_area = blk: {
                const child_rect = children[0].range.rect(tree.sheet);
                const merged_rect = Rect.merge(child_rect, key_rect);

                break :blk .{
                    merged_rect.area() - child_rect.area(),
                    child_rect.area(),
                };
            };

            for (children[1..], 1..) |child, i| {
                const child_rect = child.range.rect(tree.sheet);
                const merged_rect = Rect.merge(child_rect, key_rect);
                const area = child_rect.area();
                const area_diff = merged_rect.area() - area;

                if (area_diff <= min_area_diff) {
                    if (area_diff != min_area_diff or area < min_area) {
                        min_index = i;
                        min_area = area;
                        min_area_diff = area_diff;
                    }
                }
            }

            return &node.data.children.slice()[min_index];
        }

        fn recalcBoundingRange(tree: *Self, node: *Node) void {
            if (node.isLeaf()) {
                const keys: []const K = node.data.values.items(.key);
                var rect = keys[0].rect(tree.sheet);

                for (keys[1..]) |k|
                    rect = rect.merge(k.rect(tree.sheet));

                node.range = Range.fromRect(tree.sheet, rect);
                return;
            }

            const children = node.data.children.constSlice();
            var rect = children[0].range.rect(tree.sheet);

            for (children[1..]) |n|
                rect = rect.merge(n.range.rect(tree.sheet));

            node.range = Range.fromRect(tree.sheet, rect);
        }

        const RemoveResult = struct {
            /// Removed kv pair.
            kv: KV,
            merge: struct {
                /// Pointer to the parent of the node that needs to be merged.
                /// Null if no node needs to be merged.
                parent: ?*Node,
                /// Index of the node to be merged inside of the parent.
                child_index: usize,

                const none: @This() = .{ .parent = null, .child_index = undefined };
            },
        };

        /// Attempt to remove `key` from the given leaf node.
        fn removeFromLeaf(tree: *Self, node: *Node, key: K) ?RemoveResult {
            const key_rect = key.rect(tree.sheet);
            const node_rect = node.range.rect(tree.sheet);
            const kvs = &node.data.values;
            for (kvs.items(.key), 0..) |k, i| {
                if (!k.eql(key)) continue;
                const value = kvs.items(.value)[i];
                kvs.swapRemove(i);

                if (kvs.len > 0 and key_rect.anyMatch(node_rect))
                    recalcBoundingRange(tree, node);
                return .{ .kv = .{ .key = k, .value = value }, .merge = .none };
            }

            return null;
        }

        /// Attempt to remove `key` from the given branch node.
        fn removeFromBranch(tree: *Self, node: *Node, key: K) ?RemoveResult {
            const key_rect = key.rect(tree.sheet);
            const node_rect = node.range.rect(tree.sheet);

            const children = node.data.children;
            for (children.slice(), 0..) |*child, i| {
                const child_rect = child.range.rect(tree.sheet);
                if (!child_rect.contains(key_rect))
                    continue;

                const res = removeNode(tree, child, key) orelse continue;

                const merge_node = blk: {
                    if (child.isLeaf())
                        break :blk child.data.values.len < min_children;

                    const child_len = child.data.children.len;
                    const child_mod = @intFromBool(res.merge.parent == child);
                    break :blk child_len - child_mod < min_children;
                };

                const recalc = key_rect.anyMatch(node_rect);

                assert(children.len > 1);
                if (merge_node) {
                    if (recalc) {
                        // Recalculate range excluding the child to be removed
                        const start = @intFromBool(i == 0);
                        var rect = children.constSlice()[start].range.rect(tree.sheet);

                        for (children.constSlice()[0..i]) |c|
                            rect = rect.merge(c.range.rect(tree.sheet));

                        for (children.constSlice()[i + 1 ..]) |c|
                            rect = rect.merge(c.range.rect(tree.sheet));

                        node.range = Range.fromRect(tree.sheet, rect);
                    }

                    return .{
                        .kv = res.kv,
                        .merge = .{
                            .parent = node,
                            .child_index = i,
                        },
                    };
                }

                if (recalc)
                    recalcBoundingRange(tree, node);

                return .{ .kv = res.kv, .merge = res.merge };
            }

            return null;
        }

        /// Removes `key` and its associated value from the tree.
        fn removeNode(
            tree: *Self,
            node: *Node,
            key: K,
        ) ?RemoveResult {
            if (node.isLeaf()) {
                return removeFromLeaf(tree, node, key);
            } else {
                return removeFromBranch(tree, node, key);
            }
        }

        fn getRect(tree: *Self, a: anytype) Rect {
            return switch (@TypeOf(a)) {
                Node, *Node, *const Node => a.range.rect(tree.sheet),
                KV, *KV, *const KV => a.key.rect(tree.sheet),
                else => a.rect(tree.sheet),
            };
        }

        fn DistributionGroup(comptime T: type) type {
            return struct {
                entries: std.BoundedArray(T, max_children),
                range: Rect,
            };
        }
        fn Distribution(comptime T: type) type {
            return [2]DistributionGroup(T);
        }

        fn Distributions(comptime T: type) type {
            return std.BoundedArray(Distribution(T), 4);
        }

        fn chooseSplitAxis(tree: *Self, node: *const Node, comptime T: type) Distributions(T) {
            var min_perimeter: u64 = std.math.maxInt(u64);
            var ret: Distributions(T) = .{};

            inline for (.{ .x, .y }) |d| {
                var sorted_lower: std.BoundedArray(T, max_children) = .{};
                var sorted_upper: std.BoundedArray(T, max_children) = .{};

                // TODO: Elide copies (sort out of place)
                if (T == Node) {
                    sorted_lower.appendSliceAssumeCapacity(node.data.children.constSlice());
                    sorted_upper.appendSliceAssumeCapacity(node.data.children.constSlice());
                } else {
                    const s = node.data.values.slice();
                    for (s.items(.key), s.items(.value)) |k, v| {
                        sorted_lower.appendAssumeCapacity(.{ .key = k, .value = v });
                        sorted_upper.appendAssumeCapacity(.{ .key = k, .value = v });
                    }
                }

                const LowerContext = struct {
                    fn compare(t: *Self, lhs: T, rhs: T) bool {
                        return switch (d) {
                            .x => getRect(t, lhs).tl.x < getRect(t, rhs).tl.x,
                            .y => getRect(t, lhs).tl.y < getRect(t, rhs).tl.y,
                            else => unreachable,
                        };
                    }
                };

                const UpperContext = struct {
                    fn compare(t: *Self, lhs: T, rhs: T) bool {
                        return switch (d) {
                            .x => getRect(t, lhs).br.x < getRect(t, rhs).br.x,
                            .y => getRect(t, lhs).br.y < getRect(t, rhs).br.y,
                            else => unreachable,
                        };
                    }
                };

                std.sort.heap(T, sorted_lower.slice(), tree, LowerContext.compare);
                std.sort.heap(T, sorted_upper.slice(), tree, UpperContext.compare);

                var sum: u64 = 0;
                var temp: Distributions(T) = .{};
                temp.len = 0;
                inline for (.{
                    sorted_lower.constSlice(),
                    sorted_upper.constSlice(),
                }) |entries| {
                    for (0..max_children - 2 * min_children + 2) |k| {
                        var r1: Rect = getRect(tree, entries[0]);
                        var r2: Rect = getRect(tree, entries[min_children + k]);
                        for (entries[1 .. min_children + k]) |e| r1 = r1.merge(getRect(tree, e));
                        for (entries[min_children + k + 1 ..]) |e| r2 = r2.merge(getRect(tree, e));

                        temp.appendAssumeCapacity(.{
                            .{ .range = r1, .entries = .{} },
                            .{ .range = r2, .entries = .{} },
                        });
                        const g1 = &temp.slice()[temp.len - 1][0].entries;
                        const g2 = &temp.slice()[temp.len - 1][1].entries;
                        g1.appendSliceAssumeCapacity(entries[0 .. min_children + k]);
                        g2.appendSliceAssumeCapacity(entries[min_children + k ..]);
                        sum += r1.perimeter() + r2.perimeter();
                    }
                }

                if (sum < min_perimeter) {
                    min_perimeter = sum;
                    ret = temp;
                }
            }

            return ret;
        }

        fn chooseSplitIndex(comptime T: type, dists: *const Distributions(T)) usize {
            assert(dists.len > 0);

            var min_overlap: u64 = comptime std.math.maxInt(u64);
            var min_area: u64 = comptime std.math.maxInt(u64);
            var best_index: usize = 0;

            for (dists.constSlice(), 0..) |*dist, i| {
                const first, const second = .{ &dist[0], &dist[1] };
                const overlap = first.range.overlapArea(second.range);

                if (overlap < min_overlap) {
                    min_overlap = overlap;
                    min_area = first.range.area() + second.range.area();
                    best_index = i;
                } else if (overlap == min_overlap) {
                    const a = first.range.area() + second.range.area();
                    if (a < min_area) {
                        min_area = a;
                        best_index = i;
                    }
                }
            }
            return best_index;
        }

        fn splitLeafNode(
            tree: *Self,
            node: *Node,
        ) Allocator.Error!Node {
            const dists: Distributions(KV) = chooseSplitAxis(tree, node, KV);
            const index = chooseSplitIndex(KV, &dists);
            const d = &dists.constSlice()[index];

            var new_entries: Node.ValueList = .{};
            try new_entries.ensureUnusedCapacity(tree.sheet.allocator, d[1].entries.len);
            for (d[1].entries.constSlice()) |e| {
                new_entries.appendAssumeCapacity(e);
            }

            node.data.values.len = 0;
            for (d[0].entries.constSlice()) |e| {
                node.data.values.appendAssumeCapacity(e);
            }
            node.range = Range.fromRect(tree.sheet, d[0].range);
            return .{
                .level = node.level,
                .range = Range.fromRect(tree.sheet, d[1].range),
                .data = .{ .values = new_entries },
            };
        }

        fn splitBranchNode(
            tree: *Self,
            node: *Node,
        ) Allocator.Error!Node {
            assert(!node.isLeaf());

            const dists: Distributions(Node) = chooseSplitAxis(tree, node, Node);
            const index = chooseSplitIndex(Node, &dists);
            const d = &dists.constSlice()[index];

            const new_entries = try tree.pool.create(tree.sheet.allocator);
            new_entries.* = d[1].entries;

            node.data.children.* = d[0].entries;
            node.range = Range.fromRect(tree.sheet, d[0].range);
            return .{
                .level = node.level,
                .range = Range.fromRect(tree.sheet, d[1].range),
                .data = .{ .children = new_entries },
            };
        }

        fn mergeRoots(
            tree: *Self,
            new_node: Node,
        ) Allocator.Error!void {
            // Root node got split, need to create a new root
            const children = try tree.pool.create(tree.sheet.allocator);
            children.* = .{};

            var new_root = Node{
                .level = new_node.level + 1,
                .range = Range.fromRect(tree.sheet, Rect.merge(
                    tree.root.range.rect(tree.sheet),
                    new_node.range.rect(tree.sheet),
                )),
                .data = .{ .children = children },
            };

            new_root.data.children.appendSliceAssumeCapacity(&.{ tree.root, new_node });
            tree.root = new_root;
        }

        const PutError = error{ OutOfMemory, NotAdded };

        // TODO: Make put operations atomic
        //
        //       Inserting has an upper bound of `n` node allocations, where `n` is the height of
        //       the tree. Or maybe it's `n+1`, who knows.
        //
        //       This will be trivial to do once we switch to a DOD memory layout, where all nodes
        //       are stored in an array.

        fn putLeafNode(tree: *Self, node: *Node, key: K, value: V) PutError!?Node {
            for (node.data.values.items(.key)) |*k| {
                // Key already exists in tree
                if (key.eql(k.*)) {
                    k.* = key; // TODO: This is kind of a hack, but it works
                    return null;
                }
            }

            node.data.values.append(tree.sheet.allocator, .{ .key = key, .value = value }) catch
                return error.NotAdded;
            errdefer _ = node.data.values.pop();

            if (node.data.values.len >= max_children) {
                // Too many kvs, need to split this node
                const new_node = tree.splitNode(node) catch return error.NotAdded;
                return new_node;
            } else if (node.data.values.len == 1) {
                // This was the first node added to this leaf
                node.range = key.range();
            } else {
                const key_rect = key.rect(tree.sheet);
                const node_rect = node.range.rect(tree.sheet);
                node.range = Range.fromRect(tree.sheet, node_rect.merge(key_rect));
            }
            return null;
        }

        fn putBranchNode(tree: *Self, node: *Node, key: K, value: V) PutError!?Node {
            const key_rect = key.rect(tree.sheet);
            const node_rect = node.range.rect(tree.sheet);
            const new_node_range = Range.fromRect(tree.sheet, node_rect.merge(key_rect));

            // Branch node
            const children = node.data.children;

            const best = bestChild(tree, node, key);
            const maybe_new_node = try tree.putNode(best, key, value);

            if (maybe_new_node) |split_node| {
                // Child node was split, need to add new node to child list
                children.appendAssumeCapacity(split_node);

                if (children.len >= max_children) {
                    const new_node = try tree.splitNode(node);
                    return new_node;
                }
            }

            node.range = new_node_range;
            return null;
        }

        fn putNode(tree: *Self, node: *Node, key: K, value: V) PutError!?Node {
            if (node.isLeaf()) {
                return tree.putLeafNode(node, key, value);
            } else {
                return tree.putBranchNode(node, key, value);
            }
        }

        fn splitNode(tree: *Self, node: *Node) Allocator.Error!Node {
            return if (node.isLeaf())
                splitLeafNode(tree, node)
            else
                splitBranchNode(tree, node);
        }

        /// Adds all keys contained in the tree belonging to `root` into `tree`
        fn reAddRecursive(
            tree: *Self,
            root: *Node,
            context: anytype,
        ) Allocator.Error!void {
            var maybe_err: Allocator.Error!void = {};
            if (root.isLeaf()) {
                defer root.data.values.deinit(tree.sheet.allocator);
                while (root.data.values.popOrNull()) |temp| {
                    var kv = temp;
                    tree.put(kv.key, kv.value) catch |err| {
                        if (@TypeOf(context) != void)
                            context.deinit(tree.sheet.allocator, &kv.value);
                        maybe_err = err;
                    };
                }
            } else {
                while (root.data.children.popOrNull()) |temp| {
                    var child = temp;
                    tree.reAddRecursive(&child, context) catch |err| {
                        maybe_err = err;
                    };
                }
            }
            return maybe_err;
        }

        // test "RTree1" {
        //     const t = std.testing;

        //     var r: RTree(Rect, void, min_children) = .{};
        //     defer r.deinit(t.allocator);

        //     for (100..100 + max_children) |i| {
        //         try r.put(t.allocator, Rect.initSingle(@intCast(i), 0), {});
        //     }
        //     const range1 = Rect.init(100, 0, 100 + max_children - 1, 0);
        //     const range2 = Rect.init(101, 0, 100 + max_children - 1, 0);

        //     try t.expectEqual(@as(usize, 1), r.root.level);
        //     try t.expect(r.root.data.children.len == 2);
        //     for (r.root.data.children.constSlice()) |c| {
        //         try t.expectEqual(@as(usize, 0), c.level);
        //         try t.expectEqual(@as(usize, min_children), c.data.values.len);
        //         try t.expect(range1.contains(c.range));
        //     }
        //     try t.expect(r.root.data.children.len == 2);
        //     try t.expectEqual(range1, r.root.range);

        //     try r.remove(t.allocator, Rect.initSingle(100, 0));

        //     try t.expectEqual(@as(usize, 0), r.root.level);
        //     try t.expectEqual(@as(usize, max_children - 1), r.root.data.values.len);
        //     try t.expectEqual(range2, r.root.range);
        // }
    };
}

// test "RTree2" {
//     const t = std.testing;

//     const T = struct {
//         r: Rect,

//         fn rect(self: @This()) Rect {
//             return self.r;
//         }

//         fn eql(a: @This(), b: @This()) bool {
//             return a.rect().eql(b.rect());
//         }
//     };

//     const Tree = RTree(T, void, 8);
//     const max_children = Tree.max_children;
//     const min_children = 8;
//     var r: Tree = .{};
//     defer r.deinit(t.allocator);

//     for (100..100 + max_children) |i| {
//         try r.put(t.allocator, .{ .r = Rect.initSingle(@intCast(i), 0) }, {});
//     }
//     const range1 = Rect.init(100, 0, 100 + max_children - 1, 0);
//     const range2 = Rect.init(101, 0, 100 + max_children - 1, 0);

//     try t.expectEqual(@as(usize, 1), r.root.level);
//     try t.expect(r.root.data.children.len == 2);
//     for (r.root.data.children.constSlice()) |c| {
//         try t.expectEqual(@as(usize, 0), c.level);
//         try t.expectEqual(@as(usize, min_children), c.data.values.len);
//         try t.expect(range1.contains(c.range));
//     }
//     try t.expect(r.root.data.children.len == 2);
//     try t.expectEqual(range1, r.root.range);

//     try r.remove(t.allocator, .{ .r = Rect.initSingle(100, 0) });

//     try t.expectEqual(@as(usize, 0), r.root.level);
//     try t.expectEqual(@as(usize, max_children - 1), r.root.data.values.len);
//     try t.expectEqual(range2, r.root.range);
// }

pub fn DependentTree(comptime min_children: usize) type {
    return struct {
        rtree: Tree,

        const Self = @This();
        const ValueList = std.ArrayListUnmanaged(*Cell);
        const Tree = RTree(Range, ValueList, min_children);
        pub const Node = Tree.Node;
        pub const KV = Tree.KV;
        const Context = struct {
            capacity: usize = 1,

            fn init(self: Context, allocator: Allocator) !ValueList {
                return ValueList.initCapacity(allocator, self.capacity);
            }

            fn deinit(_: Context, allocator: Allocator, value: *ValueList) void {
                value.deinit(allocator);
            }
        };

        pub fn init(sheet: *Sheet) @This() {
            return .{ .rtree = .{ .sheet = sheet } };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.rtree.deinitContext(allocator, Context{});
            self.* = undefined;
        }

        pub const SearchIterator = Tree.SearchIterator;

        pub fn searchIterator(tree: *Self, allocator: Allocator, rect: Rect) SearchIterator {
            var ret: SearchIterator = .{
                .range = rect,
                .allocator = allocator,
            };
            ret.stack.append(allocator, &tree.root) catch unreachable;
            return ret;
        }

        pub fn get(self: *Self, key: Range) ?struct { *Range, *ValueList } {
            return self.rtree.get(key);
        }

        pub fn put(
            self: *Self,
            key: Range,
            value: *Cell,
        ) Allocator.Error!void {
            return self.putSlice(key, &.{value});
        }

        pub fn putSlice(
            self: *Self,
            key: Range,
            values: []const *Cell,
        ) Allocator.Error!void {
            const sheet = self.rtree.sheet;
            if (self.get(key)) |kv| {
                try kv[1].appendSlice(sheet.allocator, values);
                return;
            }

            var list = try ValueList.initCapacity(sheet.allocator, values.len);
            list.appendSliceAssumeCapacity(values);

            var maybe_new_node = self.rtree.putNode(
                &self.rtree.root,
                key,
                list,
            ) catch |err| switch (err) {
                error.NotAdded => {
                    list.deinit(sheet.allocator);
                    return error.OutOfMemory;
                },
                else => |e| return e,
            };
            if (maybe_new_node) |*new_node| {
                errdefer self.rtree.deinitNodeContext(new_node, sheet.allocator, Context{});
                try self.rtree.mergeRoots(new_node.*);
            }
        }

        pub fn search(
            self: *Self,
            allocator: Allocator,
            key: Rect,
        ) Allocator.Error![]Tree.SearchItem {
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
            key: Range,
            value: *Cell,
        ) Allocator.Error!void {
            const res = removeNode(&self.rtree, &self.rtree.root, key, value);
            if (res != .merge) return;

            var node_to_merge = blk: {
                if (!self.rtree.root.isLeaf()) {
                    // If the root node is a branch node and falls below `min_children` due to this
                    // operation, replace it with an empty leaf node and re-insert all values.
                    const root_len = self.rtree.root.data.children.len -
                        @intFromBool(res == .merge and res.merge.parent == &self.rtree.root);

                    if (root_len < min_children) {
                        const ret = self.rtree.root;
                        self.rtree.root = .{
                            .level = 0,
                            .range = undefined,
                            .data = .{ .values = .{} },
                        };
                        break :blk ret;
                    }
                }

                const parent = res.merge.parent;
                const child_index = res.merge.child_index;
                break :blk parent.data.children.swapRemove(child_index);
            };

            try self.reAddRecursive(&node_to_merge);
        }

        /// Adds all keys contained in the tree belonging to `root` into `tree`
        fn reAddRecursive(
            self: *Self,
            root: *Tree.Node,
        ) Allocator.Error!void {
            return self.rtree.reAddRecursive(root, Context{});
        }

        const RemoveNodeResult = union(enum) {
            none,
            removed_value,
            merge: struct {
                parent: *Tree.Node,
                child_index: usize,
            },
        };

        /// Custom implementation of `remove` for the DependentTree
        /// Removes `value` from the entry with key `key`
        fn removeNode(
            tree: *Tree,
            node: *Tree.Node,
            key: Range,
            value: *Cell,
        ) RemoveNodeResult {
            const sheet = tree.sheet;
            const key_rect = key.rect(sheet);
            if (node.isLeaf()) {
                const list = &node.data.values;
                for (list.items(.key), 0..) |k, i| {
                    if (!k.eql(key)) continue;

                    const values = &list.items(.value)[i];
                    errdefer if (values.items.len == 0) {
                        var old_kv = list.swapRemove(i);
                        Context.deinit(.{}, sheet.allocator, &old_kv.value);
                    };

                    // Found matching key
                    // Now find the matching value
                    for (values.items, 0..) |v, j| {
                        if (v == value) {
                            _ = values.swapRemove(j);
                            break;
                        }
                    }

                    if (values.items.len == 0) {
                        // This KV has no more values, so remove it entirely
                        var old_value = list.items(.value)[i];
                        list.swapRemove(i);
                        Context.deinit(.{}, sheet.allocator, &old_value);

                        if (list.len > 0 and key_rect.anyMatch(node.range.rect(sheet))) {
                            Tree.recalcBoundingRange(tree, node);
                        }

                        return .removed_value;
                    }

                    // Removed a value but not a key
                    return .removed_value;
                }

                return .none;
            }

            const children = node.data.children;
            for (children.slice(), 0..) |*child, i| {
                const child_rect = child.range.rect(sheet);
                if (!child_rect.contains(key_rect)) continue;

                const res = removeNode(tree, child, key, value);
                if (res == .none) continue;

                // Determine if the child node now needs to be merged
                const merge_node = blk: {
                    if (child.isLeaf())
                        break :blk child.data.values.len < min_children;

                    // If the parent == child, then a child of child has to be merged (removed),
                    // so -1 from its length
                    const child_len_mod = @intFromBool(res == .merge and res.merge.parent == child);
                    break :blk child.data.children.len - child_len_mod < min_children;
                };

                const recalc_range = key_rect.anyMatch(child_rect);

                if (merge_node) {
                    if (recalc_range) {
                        // Recalculate range excluding the node to be merged
                        const start = @intFromBool(i == 0);
                        var rect = children.constSlice()[start].range.rect(sheet);

                        for (children.constSlice()[0..i]) |c|
                            rect = rect.merge(c.range.rect(sheet));

                        for (children.constSlice()[i + 1 ..]) |c|
                            rect = rect.merge(c.range.rect(sheet));

                        node.range = Range.fromRect(sheet, rect);
                    }

                    return .{ .merge = .{ .parent = node, .child_index = i } };
                }

                if (recalc_range)
                    Tree.recalcBoundingRange(tree, node);

                return res;
            }

            return .none;
        }

        test "DependentTree1" {
            if (true) return error.SkipZigTest;
            const t = std.testing;

            var tree = Self{};
            defer tree.deinit(t.allocator);

            try t.expectEqual(@as(usize, 0), tree.rtree.root.data.values.len);
            try t.expect(tree.rtree.root.isLeaf());

            const data = .{
                .{
                    // Key
                    Rect.init(11, 2, 11, 2),
                    .{ // Values
                        Rect.initSingle(0, 0),
                        Rect.initSingle(10, 10),
                    },
                },
                .{
                    Rect.init(0, 0, 2, 2),
                    .{
                        Rect.initSingle(500, 500),
                        Rect.initSingle(500, 501),
                        Rect.initSingle(500, 502),
                    },
                },
                .{
                    Rect.init(1, 1, 3, 3),
                    .{
                        Rect.initSingle(501, 500),
                        Rect.initSingle(501, 501),
                        Rect.initSingle(501, 502),
                    },
                },
                .{
                    Rect.init(1, 1, 10, 10),
                    .{
                        Rect.initSingle(502, 500),
                        Rect.initSingle(502, 501),
                        Rect.initSingle(502, 502),
                        Rect.initSingle(502, 503),
                        Rect.initSingle(502, 504),
                        Rect.initSingle(502, 505),
                    },
                },
                .{
                    Rect.init(5, 5, 10, 10),
                    .{
                        Rect.initSingle(503, 500),
                        Rect.initSingle(503, 501),
                    },
                },
                .{
                    Rect.init(3, 3, 4, 4),
                    .{
                        Rect.initSingle(503, 500),
                        Rect.initSingle(503, 501),
                    },
                },
                .{
                    Rect.init(3, 3, 4, 4),
                    .{
                        Rect.initSingle(503, 502),
                    },
                },
                .{
                    Rect.init(3, 3, 4, 4),
                    .{
                        Rect.initSingle(503, 502),
                    },
                },
                .{
                    Rect.init(3, 3, 4, 4),
                    .{
                        Rect.initSingle(503, 502),
                    },
                },
            };

            inline for (data) |d| {
                const key, const values = d;
                try tree.putSlice(t.allocator, key, &values);
            }

            try t.expectEqual(Rect.init(0, 0, 11, 10), tree.rtree.root.range);

            {
                const res = try tree.search(t.allocator, Rect.init(3, 3, 4, 4));
                defer t.allocator.free(res);

                const expected_results = .{
                    Rect.initSingle(501, 500),
                    Rect.initSingle(501, 501),
                    Rect.initSingle(501, 502),
                    Rect.initSingle(502, 500),
                    Rect.initSingle(502, 501),
                    Rect.initSingle(502, 502),
                    Rect.initSingle(502, 503),
                    Rect.initSingle(502, 504),
                    Rect.initSingle(502, 505),
                    Rect.initSingle(503, 500),
                    Rect.initSingle(503, 501),
                    Rect.initSingle(503, 502),
                };

                // Check that all ranges in `expected_results` are found in `res` in ANY order.
                for (res) |kv| {
                    for (kv.value_ptr.items) |r| {
                        inline for (expected_results) |e| {
                            if (Rect.eql(r, e)) break;
                        } else return error.SearchMismatch;
                    }
                }
            }
            {
                const res = try tree.search(t.allocator, Rect.initSingle(0, 0));
                defer t.allocator.free(res);

                const expected_results = .{
                    Rect.initSingle(500, 500),
                    Rect.initSingle(500, 501),
                    Rect.initSingle(500, 502),
                };

                for (res) |kv| {
                    for (kv.value_ptr.items) |r| {
                        inline for (expected_results) |e| {
                            if (Rect.eql(r, e)) break;
                        } else return error.SearchMismatch;
                    }
                }
            }
            {
                const res = try tree.search(t.allocator, Rect.initSingle(5, 5));
                defer t.allocator.free(res);

                const expected_results = .{
                    Rect.initSingle(502, 500),
                    Rect.initSingle(502, 501),
                    Rect.initSingle(502, 502),
                    Rect.initSingle(502, 503),
                    Rect.initSingle(502, 504),
                    Rect.initSingle(502, 505),
                    Rect.initSingle(503, 500),
                    Rect.initSingle(503, 501),
                };
                for (res) |kv| {
                    for (kv.value_ptr.items) |r| {
                        inline for (expected_results) |e| {
                            if (Rect.eql(r, e)) break;
                        } else return error.SearchMismatch;
                    }
                }
            }
            {
                const res = try tree.search(t.allocator, Rect.initSingle(11, 11));
                try t.expectEqualSlices(Tree.SearchItem, &.{}, res);
            }

            {
                // Check that it contains all ranges
                const res = try tree.search(t.allocator, Rect.init(0, 0, 500, 500));
                defer t.allocator.free(res);
                for (res) |kv| {
                    data_loop: inline for (data) |d| {
                        inline for (d[1]) |range| {
                            for (kv.value_ptr.items) |r|
                                if (range.eql(r)) break :data_loop;
                        }
                    } else return error.SearchMismatch;
                }
            }
        }

        test "DependentTree2" {
            if (true) return error.SkipZigTest;
            const t = std.testing;

            var r: Self = .{};
            defer r.deinit(t.allocator);

            const bound = 15;

            for (0..bound) |i| {
                for (0..bound) |j| {
                    const key = Rect.initSingle(@intCast(i), @intCast(j));
                    const value = Rect.initSingle(@intCast(bound - i - 1), @intCast(bound - j - 1));
                    try r.put(t.allocator, key, value);
                    std.testing.expect(r.rtree.root.getSingle(key) != null) catch |err| {
                        std.debug.print("{}\n", .{r.rtree.root});
                        std.debug.print("{}\n", .{key});
                        return err;
                    };
                    try r.put(t.allocator, key, value);
                    try std.testing.expect(r.rtree.root.getSingle(key) != null);
                }
            }

            for (0..bound) |i| {
                for (0..bound) |j| {
                    // Ensure no duplicate keys are present
                    const range = Rect.initSingle(@intCast(i), @intCast(j));
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
                        Rect.initSingle(@intCast(bound - i - 1), @intCast(bound - j - 1)),
                        Rect.initSingle(@intCast(i), @intCast(j)),
                    );
                    try r.removeValue(
                        t.allocator,
                        Rect.initSingle(@intCast(bound - i - 1), @intCast(bound - j - 1)),
                        Rect.initSingle(@intCast(i), @intCast(j)),
                    );
                }
            }
        }
    };
}
