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
        const ListPool = @import("pool.zig").MemoryPool(std.BoundedArray(Entry, max_children), .{});

        root: Node = .{
            .level = 0,
            .range = undefined,
            .entries = null,
        },
        pool: ListPool = .{},
        sheet: *Sheet,

        const Self = @This();

        pub const Entry = union {
            kv: KV,
            node: Node,

            fn getRectMode(tree: *Self, entry: Entry, comptime mode: Node.Mode) Rect {
                return switch (mode) {
                    .kv => entry.kv.key.rect(tree.sheet),
                    .node => entry.node.range.rect(tree.sheet),
                };
            }
        };

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
            level: u32,
            range: Range,
            entries: ?*std.BoundedArray(Entry, max_children),

            fn isLeaf(node: *const Node) bool {
                return node.level == 0;
            }

            pub const Mode = enum { kv, node };
        };

        // These functions are trivial now but will make our life easier when we change the data layout.
        fn nodeEntries(_: *Self, node: *const Node) []Entry {
            if (node.entries) |entries| return entries.slice();
            return &.{};
        }

        fn setNodeEntriesLen(node: *Node, new_len: usize) void {
            node.entries.?.len = new_len;
        }

        fn appendNodeEntry(_: *Self, node: *Node, entry: Entry) void {
            assert(node.entries != null);
            node.entries.?.appendAssumeCapacity(entry);
        }

        fn nodeEntriesSwapRemove(_: *Self, node: *Node, index: usize) Entry {
            return node.entries.?.swapRemove(index);
        }

        fn nodeEntriesPopOrNull(tree: *Self, node: *Node) ?Entry {
            const entries = tree.nodeEntries(node);
            if (entries.len == 0) return null;
            const ret = entries[entries.len - 1];
            setNodeEntriesLen(node, entries.len - 1);
            return ret;
        }

        /// Finds the key/value pair whose key matches `key` and returns pointers
        /// to the key and value, or `null` if not found.
        pub fn get(tree: *Self, key: K) ?struct { *K, *V } {
            if (tree.nodeEntries(&tree.root).len == 0)
                return null;

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
            if (tree.root.entries == null) {
                tree.root.entries = try tree.pool.create(tree.sheet.allocator);
                tree.root.entries.?.* = .{};
                tree.appendNodeEntry(&tree.root, .{ .kv = .{ .key = key, .value = value } });
                return;
            }

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
                    const root_len = tree.nodeEntries(&tree.root).len -
                        @intFromBool(res.merge.parent == &tree.root);
                    if (root_len < min_children) {
                        const ret = tree.root;
                        tree.root = .{
                            .level = 0,
                            .range = undefined,
                            .entries = null,
                        };
                        break :blk ret;
                    }
                }
                const parent = res.merge.parent orelse return;
                const child_index = res.merge.child_index;
                break :blk tree.nodeEntriesSwapRemove(parent, child_index).node;
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
                    if (iter.index >= iter.tree.nodeEntries(node).len) {
                        iter.index = 0;
                        return iter.next();
                    }

                    for (iter.tree.nodeEntries(node)[iter.index..], iter.index..) |*entry, i| {
                        if (iter.rect.intersects(entry.kv.key.rect(iter.tree.sheet))) {
                            // We might have more matches in this leaf node, put it back on the
                            // stack
                            try iter.stack.append(iter.allocator, node);
                            iter.index = i + 1;
                            return .{
                                .key = entry.kv.key,
                                .value_ptr = &entry.kv.value,
                            };
                        }
                    }
                } else {
                    for (iter.tree.nodeEntries(node)) |*entry| {
                        const child_rect = entry.node.range.rect(iter.tree.sheet);
                        if (iter.rect.intersects(child_rect)) {
                            try iter.stack.append(iter.allocator, &entry.node);
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
            if (@TypeOf(context) == void) return;

            if (node.isLeaf()) {
                for (tree.nodeEntries(node)) |*entry| {
                    context.deinit(allocator, &entry.kv.value);
                }
            } else {
                for (tree.nodeEntries(node)) |*entry|
                    tree.deinitNodeContext(&entry.node, allocator, context);
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
                for (tree.nodeEntries(node)) |*entry| {
                    if (rect.intersects(entry.kv.key.rect(tree.sheet))) {
                        try list.append(allocator, entry.kv.value);
                    }
                }
            } else {
                for (tree.nodeEntries(node)) |*entry| {
                    if (rect.intersects(entry.node.range.rect(tree.sheet))) {
                        try searchValues(tree, &entry.node, allocator, rect, list);
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
                for (tree.nodeEntries(node)) |*entry| {
                    if (rect.intersects(entry.kv.key.rect(tree.sheet))) {
                        try list.append(.{
                            .key = entry.kv.key,
                            .value_ptr = &entry.kv.value,
                        });
                    }
                }
            } else {
                for (tree.nodeEntries(node)) |*entry| {
                    if (rect.intersects(entry.node.range.rect(tree.sheet))) {
                        try searchNode(tree, &entry.node, rect, list);
                    }
                }
            }
        }

        // TODO: Change return type to ?*KV
        fn getSingleRecursive(tree: *Self, node: *Node, key: K) ?struct { *K, *V } {
            if (node.isLeaf()) {
                for (tree.nodeEntries(node)) |*entry| {
                    if (entry.kv.key.eql(key))
                        return .{ &entry.kv.key, &entry.kv.value };
                }
                return null;
            }

            const key_rect = key.rect(tree.sheet);
            for (tree.nodeEntries(node)) |*entry| {
                const child_rect = entry.node.range.rect(tree.sheet);
                if (child_rect.contains(key_rect)) {
                    if (getSingleRecursive(tree, &entry.node, key)) |res|
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

            // Minimize overlap
            var min_index: usize = 0;
            var min_enlargement: u64 = 0;
            var min_overlap: u64 = std.math.maxInt(u64);

            const entries = tree.nodeEntries(node);
            for (entries, 0..) |*entry, i| {
                const rect = entry.node.range.rect(tree.sheet);
                const r = rect.merge(key.rect(tree.sheet));
                const enlargement = r.area() - rect.area();

                const total_overlap = totalOverlap(tree, entries, r);

                if (total_overlap <= min_overlap) {
                    if (total_overlap != min_overlap or min_enlargement < enlargement) {
                        min_index = i;
                        min_enlargement = enlargement;
                        min_overlap = total_overlap;
                    }
                }
            }
            return &entries[min_index].node;
        }

        fn totalOverlap(tree: *Self, entries: []const Entry, range: Rect) u64 {
            var total: u64 = 0;
            for (entries) |*entry| {
                total += range.overlapArea(entry.node.range.rect(tree.sheet));
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

            const entries = tree.nodeEntries(node);
            assert(entries.len > 0);

            var min_index: usize = 0;
            var min_area_diff, var min_area = blk: {
                const child_rect = entries[0].node.range.rect(tree.sheet);
                const merged_rect = Rect.merge(child_rect, key_rect);

                break :blk .{
                    merged_rect.area() - child_rect.area(),
                    child_rect.area(),
                };
            };

            for (entries[1..], 1..) |entry, i| {
                const child_rect = entry.node.range.rect(tree.sheet);
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

            return &entries[min_index].node;
        }

        fn recalcBoundingRange(tree: *Self, node: *Node) void {
            if (node.isLeaf()) {
                const entries = tree.nodeEntries(node);
                var rect = entries[0].kv.key.rect(tree.sheet);
                for (entries[1..]) |entry|
                    rect = rect.merge(entry.kv.key.rect(tree.sheet));

                node.range = Range.fromRect(tree.sheet, rect);
                return;
            }

            const entries = tree.nodeEntries(node);
            var rect = entries[0].node.range.rect(tree.sheet);
            for (entries[1..]) |entry|
                rect = rect.merge(entry.node.range.rect(tree.sheet));

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
            const entries = tree.nodeEntries(node);
            for (entries, 0..) |entry, i| {
                if (!entry.kv.key.eql(key)) continue;
                _ = tree.nodeEntriesSwapRemove(node, i);

                if (tree.nodeEntries(node).len > 0 and key_rect.anyMatch(node_rect))
                    recalcBoundingRange(tree, node);
                return .{ .kv = entry.kv, .merge = .none };
            }

            return null;
        }

        /// Attempt to remove `key` from the given branch node.
        fn removeFromBranch(tree: *Self, node: *Node, key: K) ?RemoveResult {
            const key_rect = key.rect(tree.sheet);
            const node_rect = node.range.rect(tree.sheet);

            const entries = tree.nodeEntries(node);
            for (entries, 0..) |*entry, i| {
                const child_rect = entry.node.range.rect(tree.sheet);
                if (!child_rect.contains(key_rect))
                    continue;

                const res = removeNode(tree, &entry.node, key) orelse continue;

                const merge_node = blk: {
                    const child_entries = tree.nodeEntries(&entry.node);
                    if (entry.node.isLeaf())
                        break :blk child_entries.len < min_children;

                    const child_len = child_entries.len;
                    const child_mod = @intFromBool(res.merge.parent == &entry.node);
                    break :blk child_len - child_mod < min_children;
                };

                const recalc = key_rect.anyMatch(node_rect);

                assert(entries.len > 1);
                if (merge_node) {
                    if (recalc) {
                        // Recalculate range excluding the child to be removed
                        const start = @intFromBool(i == 0);
                        var rect = entries[start].node.range.rect(tree.sheet);

                        for (entries[0..i]) |e|
                            rect = rect.merge(e.node.range.rect(tree.sheet));

                        for (entries[i + 1 ..]) |e|
                            rect = rect.merge(e.node.range.rect(tree.sheet));

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

        const DistributionGroup = struct {
            entries: std.BoundedArray(Entry, max_children),
            range: Rect,
        };
        const Distribution = [2]DistributionGroup;
        const Distributions = std.BoundedArray(Distribution, 4);

        fn chooseSplitAxis(tree: *Self, node: *const Node, comptime mode: Node.Mode) Distributions {
            var min_perimeter: u64 = std.math.maxInt(u64);
            var ret: Distributions = .{};

            const entries = tree.nodeEntries(node);
            inline for (.{ .x, .y }) |d| {
                var sorted_lower: std.BoundedArray(Entry, max_children) = .{};
                var sorted_upper: std.BoundedArray(Entry, max_children) = .{};

                // TODO: Elide copies (sort out of place)
                sorted_lower.appendSliceAssumeCapacity(entries);
                sorted_upper.appendSliceAssumeCapacity(entries);

                const LowerContext = struct {
                    fn compare(t: *Self, lhs: Entry, rhs: Entry) bool {
                        const field = @tagName(mode);
                        return switch (d) {
                            .x => getRect(t, @field(lhs, field)).tl.x < getRect(t, @field(rhs, field)).tl.x,
                            .y => getRect(t, @field(lhs, field)).tl.y < getRect(t, @field(rhs, field)).tl.y,
                            else => unreachable,
                        };
                    }
                };

                const UpperContext = struct {
                    fn compare(t: *Self, lhs: Entry, rhs: Entry) bool {
                        const field = @tagName(mode);
                        return switch (d) {
                            .x => getRect(t, @field(lhs, field)).br.x < getRect(t, @field(rhs, field)).br.x,
                            .y => getRect(t, @field(lhs, field)).br.y < getRect(t, @field(rhs, field)).br.y,
                            else => unreachable,
                        };
                    }
                };

                std.sort.heap(Entry, sorted_lower.slice(), tree, LowerContext.compare);
                std.sort.heap(Entry, sorted_upper.slice(), tree, UpperContext.compare);

                var sum: u64 = 0;
                var temp: Distributions = .{};
                temp.len = 0;
                inline for (.{
                    sorted_lower.constSlice(),
                    sorted_upper.constSlice(),
                }) |sorted| {
                    for (0..max_children - 2 * min_children + 2) |k| {
                        var r1: Rect = Entry.getRectMode(tree, sorted[0], mode);
                        var r2: Rect = Entry.getRectMode(tree, sorted[min_children + k], mode);

                        for (sorted[1 .. min_children + k]) |e|
                            r1 = r1.merge(Entry.getRectMode(tree, e, mode));
                        for (sorted[min_children + k + 1 ..]) |e|
                            r2 = r2.merge(Entry.getRectMode(tree, e, mode));

                        temp.appendAssumeCapacity(.{
                            .{ .range = r1, .entries = .{} },
                            .{ .range = r2, .entries = .{} },
                        });
                        const g1 = &temp.slice()[temp.len - 1][0].entries;
                        const g2 = &temp.slice()[temp.len - 1][1].entries;
                        g1.appendSliceAssumeCapacity(sorted[0 .. min_children + k]);
                        g2.appendSliceAssumeCapacity(sorted[min_children + k ..]);
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

        fn chooseSplitIndex(dists: *const Distributions) usize {
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
            const dists: Distributions = chooseSplitAxis(tree, node, .kv);
            const index = chooseSplitIndex(&dists);
            const d = &dists.constSlice()[index];

            const new_entries = try tree.pool.create(tree.sheet.allocator);
            new_entries.* = d[1].entries;

            setNodeEntriesLen(node, 0);
            for (d[0].entries.constSlice()) |entry| {
                tree.appendNodeEntry(node, entry);
            }
            node.range = Range.fromRect(tree.sheet, d[0].range);
            return .{
                .level = node.level,
                .range = Range.fromRect(tree.sheet, d[1].range),
                .entries = new_entries,
            };
        }

        fn splitBranchNode(
            tree: *Self,
            node: *Node,
        ) Allocator.Error!Node {
            assert(!node.isLeaf());

            const dists: Distributions = chooseSplitAxis(tree, node, .node);
            const index = chooseSplitIndex(&dists);
            const d = &dists.constSlice()[index];

            const new_entries = try tree.pool.create(tree.sheet.allocator);
            new_entries.* = d[1].entries;

            setNodeEntriesLen(node, 0);
            for (d[0].entries.constSlice()) |entry| {
                tree.appendNodeEntry(node, entry);
            }
            return .{
                .level = node.level,
                .range = Range.fromRect(tree.sheet, d[1].range),
                .entries = new_entries,
            };
        }

        fn mergeRoots(
            tree: *Self,
            new_node: Node,
        ) Allocator.Error!void {
            // Root node got split, need to create a new root
            const entries = try tree.pool.create(tree.sheet.allocator);
            entries.* = .{};

            var new_root = Node{
                .level = new_node.level + 1,
                .range = Range.fromRect(tree.sheet, Rect.merge(
                    tree.root.range.rect(tree.sheet),
                    new_node.range.rect(tree.sheet),
                )),
                .entries = entries,
            };

            tree.appendNodeEntry(&new_root, .{ .node = tree.root });
            tree.appendNodeEntry(&new_root, .{ .node = new_node });
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
            for (tree.nodeEntries(node)) |*entry| {
                // Key already exists in tree
                if (entry.kv.key.eql(key)) {
                    entry.kv.key = key; // TODO: This is kind of a hack, but it works
                    return null;
                }
            }

            tree.appendNodeEntry(node, .{ .kv = .{ .key = key, .value = value } });
            errdefer _ = node.entries.?.pop();

            if (tree.nodeEntries(node).len >= max_children) {
                // Too many kvs, need to split this node
                const new_node = tree.splitNode(node) catch return error.NotAdded;
                return new_node;
            } else if (tree.nodeEntries(node).len == 1) {
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

            const best = bestChild(tree, node, key);
            const maybe_new_node = try tree.putNode(best, key, value);

            if (maybe_new_node) |split_node| {
                // Child node was split, need to add new node to child list
                tree.appendNodeEntry(node, .{ .node = split_node });

                if (tree.nodeEntries(node).len >= max_children) {
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
                //defer root.data.values.deinit(tree.sheet.allocator); // TODO
                while (tree.nodeEntriesPopOrNull(root)) |entry| {
                    var kv = entry.kv;
                    tree.put(kv.key, kv.value) catch |err| {
                        if (@TypeOf(context) != void)
                            context.deinit(tree.sheet.allocator, &kv.value);
                        maybe_err = err;
                    };
                }
            } else {
                while (tree.nodeEntriesPopOrNull(root)) |entry| {
                    var child = entry.node;
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

            if (self.rtree.root.entries == null) {
                self.rtree.root.entries = try self.rtree.pool.create(self.rtree.sheet.allocator);
                self.rtree.root.entries.?.* = .{};

                var list = try ValueList.initCapacity(sheet.allocator, values.len);
                list.appendSliceAssumeCapacity(values);

                self.rtree.appendNodeEntry(&self.rtree.root, .{ .kv = .{ .key = key, .value = list } });
                return;
            }

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
                    const root_len = self.rtree.nodeEntries(&self.rtree.root).len -
                        @intFromBool(res == .merge and res.merge.parent == &self.rtree.root);

                    if (root_len < min_children) {
                        const ret = self.rtree.root;
                        self.rtree.root = .{
                            .level = 0,
                            .range = undefined,
                            .entries = null,
                        };
                        break :blk ret;
                    }
                }

                const parent = res.merge.parent;
                const child_index = res.merge.child_index;
                break :blk self.rtree.nodeEntriesSwapRemove(parent, child_index).node;
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
                const entries = tree.nodeEntries(node);
                for (entries, 0..) |*entry, i| {
                    if (!entry.kv.key.eql(key)) continue;

                    const values = &entry.kv.value;
                    errdefer if (values.items.len == 0) {
                        var old_kv = tree.nodeEntriesSwapRemove(node, i);
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
                        var old_value = entry.kv.value;
                        _ = tree.nodeEntriesSwapRemove(node, i);
                        Context.deinit(.{}, sheet.allocator, &old_value);

                        if (tree.nodeEntries(node).len > 0 and key_rect.anyMatch(node.range.rect(sheet))) {
                            Tree.recalcBoundingRange(tree, node);
                        }

                        return .removed_value;
                    }

                    // Removed a value but not a key
                    return .removed_value;
                }

                return .none;
            }

            const entries = tree.nodeEntries(node);
            for (entries, 0..) |*entry, i| {
                const child_rect = entry.node.range.rect(tree.sheet);
                if (!child_rect.contains(key_rect))
                    continue;

                const res = removeNode(tree, &entry.node, key, value);
                if (res == .none) continue;

                // Determine if the child node now needs to be merged
                const merge_node = blk: {
                    const child_entries = tree.nodeEntries(&entry.node);
                    if (entry.node.isLeaf())
                        break :blk child_entries.len < min_children;

                    const child_len = child_entries.len;
                    const child_mod = @intFromBool(res == .merge and res.merge.parent == &entry.node);
                    break :blk child_len - child_mod < min_children;
                };

                const recalc_range = key_rect.anyMatch(child_rect);

                if (merge_node) {
                    if (recalc_range) {
                        // Recalculate range excluding the child to be removed
                        const start = @intFromBool(i == 0);
                        var rect = entries[start].node.range.rect(tree.sheet);

                        for (entries[0..i]) |e|
                            rect = rect.merge(e.node.range.rect(tree.sheet));

                        for (entries[i + 1 ..]) |e|
                            rect = rect.merge(e.node.range.rect(tree.sheet));

                        node.range = Range.fromRect(tree.sheet, rect);
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
