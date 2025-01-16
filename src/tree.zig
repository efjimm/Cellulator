const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Position = @import("Position.zig").Position;
const Rect = Position.Rect;
const PosInt = Position.Int;
const Sheet = @import("Sheet.zig");
const Cell = Sheet.Cell;
const ast = @import("ast.zig");
const utils = @import("utils.zig");

pub fn RTree(
    comptime K: type,
    comptime V: type,
    comptime min_children: usize,
    comptime rectFromKey: fn (*Sheet, K) Rect,
    comptime eqlKeys: fn (*Sheet, K, K) bool,
) type {
    assert(min_children >= 2);
    return struct {
        const max_children: comptime_int = min_children * 2;

        entries: std.ArrayListUnmanaged(Entry),
        sheet: *Sheet,
        free: Handle,

        const Self = @This();

        pub const Handle = packed struct {
            n: u32,

            pub const invalid: Handle = .{ .n = std.math.maxInt(u32) };

            pub fn from(n: u32) Handle {
                assert(n < std.math.maxInt(u32));
                return .{ .n = n };
            }

            pub fn isValid(index: Handle) bool {
                return index != invalid;
            }
        };

        pub const Entry = extern union {
            kv: KV,
            node: Node,

            fn getRectMode(tree: *Self, entry: Entry, comptime mode: Node.Mode) Rect {
                return switch (mode) {
                    .kv => rectFromKey(tree.sheet, entry.kv.key),
                    .node => entry.node.rect,
                };
            }
        };

        const KV = extern struct {
            key: K,
            /// List of cells that depend on the cells in `key`
            value: V,
        };

        pub const SearchItem = struct {
            key: K,
            value_ptr: *V,
        };

        const Node = extern struct {
            level: u32,
            rect: Rect,
            children: Handle,
            children_len: u32,

            fn isLeaf(node: *const Node) bool {
                return node.level == 0;
            }

            pub const Mode = enum { kv, node };
        };

        fn entryPtr(tree: *Self, handle: Handle) *Entry {
            assert(handle.isValid());
            return &tree.entries.items[handle.n];
        }

        fn nodePtr(tree: *Self, handle: Handle) *Node {
            return &tree.entryPtr(handle).node;
        }

        fn nodeEntries(tree: *Self, node: *const Node) []Entry {
            assert(node.children.isValid());
            assert(node.children_len <= max_children);
            return tree.entries.items[node.children.n..][0..node.children_len];
        }

        fn handleEntries(tree: *Self, handle: Handle) []Entry {
            assert(handle.isValid());
            const node = &tree.entries.items[handle.n].node;
            return tree.nodeEntries(node);
        }

        fn setNodeEntriesLen(node: *Node, new_len: u32) void {
            assert(new_len <= max_children);
            node.children_len = new_len;
        }

        fn appendNodeEntry(tree: *Self, node: *Node, entry: Entry) void {
            // if (node.children_len == 7) std.debug.dumpCurrentStackTrace(null);
            // std.debug.print("Appended to {x}, new len {d}\n", .{ @intFromPtr(node), node.children_len + 1 });
            assert(node.children_len < max_children);
            node.children_len += 1;
            tree.nodeEntries(node)[node.children_len - 1] = entry;
        }

        fn appendHandleEntry(tree: *Self, handle: Handle, entry: Entry) void {
            assert(handle.isValid());
            const node = &tree.entries.items[handle.n].node;
            return tree.appendNodeEntry(node, entry);
        }

        fn nodeEntriesSwapRemove(tree: *Self, node: *Node, index: usize) Entry {
            const entries = tree.nodeEntries(node);
            const ret = entries[index];
            entries[index] = entries[entries.len - 1];
            entries[entries.len - 1] = undefined;
            node.children_len -= 1;
            return ret;
        }

        fn nodeEntriesPopOrNull(tree: *Self, node: *Node) ?Entry {
            const entries = tree.nodeEntries(node);
            if (entries.len == 0) return null;
            const ret = entries[entries.len - 1];
            setNodeEntriesLen(node, @intCast(entries.len - 1));
            return ret;
        }

        fn createNodeEntriesAssumeCapacity(tree: *Self) Handle {
            assert(tree.entries.items.len > 0);

            if (tree.free.isValid()) {
                return tree.popFree();
            }

            const handle: Handle = .from(@intCast(tree.entries.items.len));
            tree.entries.items.len += max_children;

            assert(tree.entries.items.len <= tree.entries.capacity);
            assert(handle.n != 0);

            return handle;
        }

        fn createNodeEntries(tree: *Self) Allocator.Error!Handle {
            if (tree.free.isValid()) {
                return tree.popFree();
            }

            try tree.entries.ensureUnusedCapacity(tree.sheet.allocator, max_children);
            return tree.createNodeEntriesAssumeCapacity();
        }

        fn popFree(tree: *Self) Handle {
            assert(tree.free.isValid());
            const ret = tree.free;
            tree.free = tree.entries.items[tree.free.n].node.children;
            assert(ret.n != 0);
            assert(!tree.free.isValid() or tree.free.n < tree.entries.items.len);
            return ret;
        }

        fn pushFree(tree: *Self, handle: Handle) void {
            assert(handle.isValid());
            assert(handle.n != 0);
            tree.entries.items[handle.n] = .{
                .node = .{
                    .level = undefined,
                    .rect = undefined,
                    .children = tree.free,
                    .children_len = undefined,
                },
            };
            tree.free = handle;
        }

        fn rootNode(tree: *Self) *Node {
            return &tree.entries.items[0].node;
        }

        pub fn init(sheet: *Sheet) Self {
            return .{
                .sheet = sheet,
                .entries = .empty,
                .free = .invalid,
            };
        }

        /// Finds the key/value pair whose key matches `key` and returns pointers
        /// to the key and value, or `null` if not found.
        pub fn get(tree: *Self, key: K) ?*KV {
            // if (tree.isEmpty())
            //     return null;
            assert(!tree.isEmpty());

            return getSingle(tree, tree.rootNode(), key);
        }

        pub fn put(
            tree: *Self,
            key: K,
            value: V,
        ) Allocator.Error!void {
            return tree.putContext(key, value, {});
        }

        fn putRoot(tree: *Self, key: K, value: V) Allocator.Error!void {
            try tree.entries.ensureUnusedCapacity(tree.sheet.allocator, max_children + 1);
            return tree.putRootAssumeCapacity(key, value);
        }

        fn putRootAssumeCapacity(tree: *Self, key: K, value: V) void {
            if (tree.entries.items.len == 0) {
                tree.entries.items.len += 1;
            } else {
                assert(tree.rootNode().children_len == 0);
            }
            assert(tree.entries.items.len <= tree.entries.capacity);

            const children = tree.createNodeEntriesAssumeCapacity();

            tree.entries.items[0] = .{ .node = .{
                .level = 0,
                .rect = rectFromKey(tree.sheet, key),
                .children = children,
                .children_len = 0,
            } };

            tree.appendNodeEntry(tree.rootNode(), .{ .kv = .{ .key = key, .value = value } });
        }

        /// Returns the number of entries that can be created without allocating.
        fn unusedCapacity(tree: *Self) usize {
            var free_count: usize = 0;
            var handle = tree.free;
            while (handle.isValid()) {
                free_count += 1;
                handle = tree.entries.items[handle.n].node.children;
            }

            return free_count * max_children + tree.entries.unusedCapacitySlice().len;
        }

        /// Allocates enough memory to ensure `n` put operations can be done without requiring more
        /// allocations. This requires allocating O(n^2) memory, so it's best not to do too much.
        pub fn ensureUnusedCapacity(tree: *Self, n: u32) Allocator.Error!void {
            const len = blk: {
                // Count the number of entries in the free list.
                var free_count: usize = 0;
                var handle = tree.free;
                while (handle.isValid()) {
                    free_count += 1;
                    handle = tree.entries.items[handle.n].node.children;
                }

                if (!tree.isEmpty()) {
                    // root.level + 1 is the height of the tree. Add one more for mergeRoots.
                    // In the worst case each `put` may increase the height of the tree by one.
                    const level = tree.rootNode().level;
                    // break :blk (level + 1 + (n * (n + 1) / 2) -| free_count) * max_children;
                    break :blk (level + 1 + (n * (n + 1) / 2)) * max_children;
                }

                break :blk 1 + max_children + (n * (n + 1) / 2) * max_children;
                // (free_count * max_children);
            };

            try tree.entries.ensureUnusedCapacity(tree.sheet.allocator, len);
        }

        pub fn putContext(
            tree: *Self,
            key: K,
            value: V,
            context: anytype,
        ) Allocator.Error!void {
            try tree.ensureUnusedCapacity(1);
            return tree.putContextAssumeCapacity(key, value, context);
        }

        pub fn isEmpty(tree: *Self) bool {
            return tree.entries.items.len == 0 or tree.rootNode().children_len == 0;
        }

        pub fn putContextAssumeCapacity(tree: *Self, key: K, value: V, context: anytype) void {
            if (tree.isEmpty()) {
                assert(tree.unusedCapacity() >= 1 + max_children);
                tree.putRootAssumeCapacity(key, value);
                return;
            }

            if (tree.get(key)) |kv| {
                kv.* = .{
                    .key = key,
                    .value = value,
                };
                return;
            }

            const required_capacity = (tree.rootNode().level + 2) * max_children;
            assert(tree.unusedCapacity() >= required_capacity);

            var maybe_new_node = tree.putNode(.from(0), key, value);

            if (maybe_new_node) |*new_node| {
                errdefer deinitNodeContext(tree, new_node, tree.sheet.allocator, context);
                tree.mergeRootsAssumeCapacity(new_node.*);
            }
        }

        // TODO: This function leaves the tree in an inconsistent state if `reAddRecursive` fails.
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
            const res = removeNode(tree, tree.rootNode(), key) orelse return;

            if (@TypeOf(context) != void)
                context.deinit(tree.sheet.allocator, res.kv.value);

            const node_to_merge = blk: {
                if (!tree.rootNode().isLeaf()) {
                    // Remove the root node if it goes under `min_children`, so all of its leaves
                    // can be re-added
                    const root_len = tree.nodeEntries(tree.rootNode()).len -
                        @intFromBool(res.merge.parent == tree.rootNode());
                    if (root_len < min_children) {
                        const ret = tree.rootNode().*;
                        tree.rootNode().* = .{
                            .level = 0,
                            .rect = undefined,
                            .children = .invalid,
                            .children_len = 0,
                        };
                        break :blk ret;
                    }
                }
                const parent = res.merge.parent orelse return;
                const child_index = res.merge.child_index;
                break :blk tree.nodeEntriesSwapRemove(parent, child_index).node;
            };

            try tree.reAddRecursive(node_to_merge, context);
        }

        pub fn deinit(tree: *Self, allocator: Allocator) void {
            return tree.deinitContext(allocator, {});
        }

        pub fn deinitContext(
            tree: *Self,
            allocator: Allocator,
            context: anytype,
        ) void {
            if (!tree.isEmpty())
                tree.deinitNodeContext(tree.rootNode(), allocator, context);
            tree.entries.deinit(allocator);
            tree.* = undefined;
        }

        /// Returns an unordered list of key-value pairs whose keys intersect `range`
        pub fn search(
            tree: *Self,
            allocator: Allocator,
            range: Rect,
        ) Allocator.Error![]SearchItem {
            var list = std.ArrayList(SearchItem).init(allocator);
            errdefer list.deinit();

            try searchNode(tree, tree.rootNode(), range, &list);
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
            if (!tree.isEmpty())
                try ret.stack.append(allocator, tree.rootNode());
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
                try iter.stack.append(iter.allocator, tree.rootNode());
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
                        if (iter.rect.intersects(rectFromKey(iter.tree.sheet, entry.kv.key))) {
                            // We might have more matches in this leaf node, put it back on the
                            // stack
                            iter.stack.appendAssumeCapacity(node);
                            iter.index = i + 1;
                            return .{
                                .key = entry.kv.key,
                                .value_ptr = &entry.kv.value,
                            };
                        }
                    }
                } else {
                    for (iter.tree.nodeEntries(node)) |*entry| {
                        const child_rect = entry.node.rect;
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
            if (tree.isEmpty()) return;
            try searchValues(tree, tree.rootNode(), allocator, range, list);
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
                for (tree.nodeEntries(node)) |entry| {
                    context.deinit(allocator, entry.kv.value);
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
                    if (rect.intersects(rectFromKey(tree.sheet, entry.kv.key))) {
                        try list.append(allocator, entry.kv.value);
                    }
                }
            } else {
                for (tree.nodeEntries(node)) |*entry| {
                    if (rect.intersects(entry.node.rect)) {
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
                    if (rect.intersects(rectFromKey(tree.sheet, entry.kv.key))) {
                        try list.append(.{
                            .key = entry.kv.key,
                            .value_ptr = &entry.kv.value,
                        });
                    }
                }
            } else {
                for (tree.nodeEntries(node)) |*entry| {
                    if (rect.intersects(entry.node.rect)) {
                        try searchNode(tree, &entry.node, rect, list);
                    }
                }
            }
        }

        // TODO: Change return type to ?*KV
        fn getSingleRecursive(tree: *Self, node: *Node, key: K) ?*KV {
            if (node.isLeaf()) {
                for (tree.nodeEntries(node)) |*entry| {
                    if (eqlKeys(tree.sheet, entry.kv.key, key))
                        return &entry.kv;
                }
                return null;
            }

            const key_rect = rectFromKey(tree.sheet, key);
            for (tree.nodeEntries(node)) |*entry| {
                const child_rect = entry.node.rect;
                if (child_rect.contains(key_rect)) {
                    if (getSingleRecursive(tree, &entry.node, key)) |res|
                        return res;
                }
            }
            return null;
        }

        fn getSingle(tree: *Self, node: *Node, key: K) ?*KV {
            return if (node.rect.contains(rectFromKey(tree.sheet, key)))
                getSingleRecursive(tree, node, key)
            else
                null;
        }

        fn bestLeaf(tree: *Self, node: *Node, key: K) Handle {
            assert(node.level == 1);

            // Minimize overlap
            var min_index: usize = 0;
            var min_enlargement: u64 = 0;
            var min_overlap: u64 = std.math.maxInt(u64);

            const entries = tree.nodeEntries(node);
            for (entries, 0..) |*entry, i| {
                const rect = entry.node.rect;
                const r = rect.merge(rectFromKey(tree.sheet, key));
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
            return .from(@intCast(node.children.n + min_index));
        }

        fn totalOverlap(_: *Self, entries: []const Entry, range: Rect) u64 {
            var total: u64 = 0;
            for (entries) |*entry| {
                total += range.overlapArea(entry.node.rect);
            }
            return total;
        }

        /// Find best child to insert into.
        /// Gets the child with the smallest area increase to store `key`
        fn bestChild(tree: *Self, node: *Node, key: K) Handle {
            assert(!node.isLeaf());

            if (node.level == 1) return bestLeaf(tree, node, key);

            // Minimize area enlargement

            const key_rect = rectFromKey(tree.sheet, key);

            const entries = tree.nodeEntries(node);
            assert(entries.len > 0);

            var min_index: usize = 0;
            var min_area_diff, var min_area = blk: {
                const child_rect = entries[0].node.rect;
                const merged_rect = Rect.merge(child_rect, key_rect);

                break :blk .{
                    merged_rect.area() - child_rect.area(),
                    child_rect.area(),
                };
            };

            for (entries[1..], 1..) |entry, i| {
                const child_rect = entry.node.rect;
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

            return .from(@intCast(node.children.n + min_index));
        }

        fn recalcBoundingRange(tree: *Self, node: *Node) void {
            if (node.isLeaf()) {
                const entries = tree.nodeEntries(node);
                var rect = rectFromKey(tree.sheet, entries[0].kv.key);
                for (entries[1..]) |entry|
                    rect = rect.merge(rectFromKey(tree.sheet, entry.kv.key));

                node.rect = rect;
                return;
            }

            const entries = tree.nodeEntries(node);
            var rect = entries[0].node.rect;
            for (entries[1..]) |entry|
                rect = rect.merge(entry.node.rect);

            node.rect = rect;
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
            const key_rect = rectFromKey(tree.sheet, key);
            const node_rect = node.rect;
            const entries = tree.nodeEntries(node);
            for (entries, 0..) |entry, i| {
                if (!eqlKeys(tree.sheet, entry.kv.key, key)) continue;
                _ = tree.nodeEntriesSwapRemove(node, i);

                if (tree.nodeEntries(node).len > 0 and key_rect.anyMatch(node_rect))
                    recalcBoundingRange(tree, node);
                return .{ .kv = entry.kv, .merge = .none };
            }

            return null;
        }

        /// Attempt to remove `key` from the given branch node.
        fn removeFromBranch(tree: *Self, node: *Node, key: K) ?RemoveResult {
            const key_rect = rectFromKey(tree.sheet, key);
            const node_rect = node.rect;

            const entries = tree.nodeEntries(node);
            for (entries, 0..) |*entry, i| {
                const child_rect = entry.node.rect;
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
                        var rect = entries[start].node.rect;

                        for (entries[0..i]) |e|
                            rect = rect.merge(e.node.rect);

                        for (entries[i + 1 ..]) |e|
                            rect = rect.merge(e.node.rect);

                        node.rect = rect;
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
                Node, *Node, *const Node => a.rect,
                KV, *KV, *const KV => rectFromKey(tree.sheet, a.key),
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
        ) Node {
            const dists: Distributions = chooseSplitAxis(tree, node, .kv);
            const index = chooseSplitIndex(&dists);
            const d = &dists.constSlice()[index];

            assert(d[0].entries.len < max_children);
            assert(d[1].entries.len < max_children);

            const new_entries_head = tree.createNodeEntriesAssumeCapacity();
            const new_entries = tree.entries.items[new_entries_head.n..][0..max_children];
            new_entries.* = d[1].entries.buffer;

            setNodeEntriesLen(node, 0);
            for (d[0].entries.constSlice()) |entry| {
                tree.appendNodeEntry(node, entry);
            }
            node.rect = d[0].range;
            return .{
                .level = node.level,
                .rect = d[1].range,
                .children = new_entries_head,
                .children_len = @intCast(d[1].entries.len),
            };
        }

        fn splitBranchNode(
            tree: *Self,
            node: *Node,
        ) Node {
            assert(!node.isLeaf());

            const dists: Distributions = chooseSplitAxis(tree, node, .node);
            const index = chooseSplitIndex(&dists);
            const d = &dists.constSlice()[index];

            assert(d[0].entries.len < max_children);
            assert(d[1].entries.len < max_children);

            const new_entries_head = tree.createNodeEntriesAssumeCapacity();
            const new_entries = tree.entries.items[new_entries_head.n..][0..max_children];
            new_entries.* = d[1].entries.buffer;

            setNodeEntriesLen(node, 0);
            for (d[0].entries.constSlice()) |entry| {
                tree.appendNodeEntry(node, entry);
            }
            return .{
                .level = node.level,
                .rect = d[1].range,
                .children = new_entries_head,
                .children_len = @intCast(d[1].entries.len),
            };
        }

        fn mergeRootsAssumeCapacity(tree: *Self, new_node: Node) void {
            // Root node got split, need to create a new root
            const entries_head = tree.createNodeEntriesAssumeCapacity();

            var new_root = Node{
                .level = new_node.level + 1,
                .rect = Rect.merge(tree.rootNode().rect, new_node.rect),
                .children = entries_head,
                .children_len = 0,
            };

            tree.appendNodeEntry(&new_root, .{ .node = tree.rootNode().* });
            tree.appendNodeEntry(&new_root, .{ .node = new_node });
            tree.rootNode().* = new_root;
        }

        fn mergeRoots(
            tree: *Self,
            new_node: Node,
        ) Allocator.Error!void {
            // Root node got split, need to create a new root
            try tree.entries.ensureUnusedCapacity(tree.sheet.allocator, max_children);
            return tree.mergeRootsAssumeCapacity(new_node);
        }

        const PutError = error{ OutOfMemory, NotAdded };

        fn putLeafNode(tree: *Self, handle: Handle, key: K, value: V) ?Node {
            for (tree.handleEntries(handle)) |*entry| {
                // Key already exists in tree
                if (eqlKeys(tree.sheet, entry.kv.key, key)) {
                    entry.kv.key = key; // TODO: This is kind of a hack, but it works
                    return null;
                }
            }

            tree.appendHandleEntry(handle, .{ .kv = .{ .key = key, .value = value } });

            if (tree.handleEntries(handle).len >= max_children) {
                // Too many kvs, need to split this node
                const new_node = tree.splitNode(handle);
                assert(tree.handleEntries(handle).len < max_children);
                return new_node;
            }

            const node = &tree.entryPtr(handle).node;
            if (tree.handleEntries(handle).len == 1) {
                // This was the first node added to this leaf
                node.rect = rectFromKey(tree.sheet, key);
            } else {
                const key_rect = rectFromKey(tree.sheet, key);
                const node_rect = node.rect;
                node.rect = node_rect.merge(key_rect);
            }
            return null;
        }

        fn putBranchNode(tree: *Self, handle: Handle, key: K, value: V) ?Node {
            const node = tree.nodePtr(handle);
            assert(!node.isLeaf());

            const key_rect = rectFromKey(tree.sheet, key);
            const node_rect = node.rect;
            const new_node_rect = node_rect.merge(key_rect);

            const best = bestChild(tree, node, key);
            const maybe_new_node = tree.putNode(best, key, value);

            if (maybe_new_node) |split_node| {
                // Child node was split, need to add new node to child list
                tree.appendHandleEntry(handle, .{ .node = split_node });

                if (tree.handleEntries(handle).len >= max_children) {
                    const new_node = tree.splitNode(handle);
                    return new_node;
                }
            }

            tree.nodePtr(handle).rect = new_node_rect;
            return null;
        }

        fn putNode(tree: *Self, handle: Handle, key: K, value: V) ?Node {
            const node = tree.nodePtr(handle);
            if (node.isLeaf()) {
                return tree.putLeafNode(handle, key, value);
            } else {
                return tree.putBranchNode(handle, key, value);
            }
        }

        fn splitNode(tree: *Self, handle: Handle) Node {
            const node = tree.nodePtr(handle);
            if (node.isLeaf()) {
                //     std.debug.print("split {x}\n", .{@intFromPtr(node)});
                return splitLeafNode(tree, node);
            } else {
                //     std.debug.print("split {x}\n", .{@intFromPtr(node)});
                return splitBranchNode(tree, node);
            }
        }

        /// Adds all keys contained in the tree belonging to `root` into `tree`
        fn reAddRecursive(
            tree: *Self,
            root: Node,
            context: anytype,
        ) Allocator.Error!void {
            assert(tree.entries.items.len > 0);

            var maybe_err: Allocator.Error!void = {};
            if (root.isLeaf()) {
                var i: usize = 0;
                while (i < tree.nodeEntries(&root).len) : (i += 1) {
                    const entry = tree.nodeEntries(&root)[i];
                    tree.put(entry.kv.key, entry.kv.value) catch |err| {
                        if (@TypeOf(context) != void)
                            context.deinit(tree.sheet.allocator, entry.kv.value);
                        maybe_err = err;
                    };
                }
            } else {
                var i: usize = 0;
                while (i < tree.nodeEntries(&root).len) : (i += 1) {
                    const entry = tree.nodeEntries(&root)[i];
                    tree.reAddRecursive(entry.node, context) catch |err| {
                        maybe_err = err;
                    };
                }
            }

            tree.pushFree(root.children);
            return maybe_err;
        }

        // For serialization.

        pub const Header = extern struct {
            entries_len: u32,
            free: Handle,
        };

        pub fn getHeader(tree: *const Self) Header {
            return .{ .entries_len = @intCast(tree.entries.items.len), .free = tree.free };
        }

        pub fn fromHeader(
            self: *Self,
            allocator: std.mem.Allocator,
            header: Header,
            sheet: *Sheet,
        ) !std.posix.iovec {
            self.* = .{
                .entries = .empty,
                .free = header.free,
                .sheet = sheet,
            };
            _ = try self.entries.addManyAt(allocator, 0, header.entries_len);
            return @bitCast(self.iovecs());
        }

        pub fn iovecs(tree: *Self) std.posix.iovec_const {
            return utils.ptrToIoVec(tree.entries.items);
        }
    };
}

const FlatListPool = @import("flat_list_pool.zig").FlatListPool;

pub fn DependentTree(comptime min_children: usize) type {
    return struct {
        rtree: Tree,
        flat: ListPool,

        pub const ListPool = FlatListPool(Sheet.CellHandle);
        pub const ListIndex = ListPool.List.Index;

        fn rectFromRect(_: *Sheet, r: Rect) Rect {
            return r;
        }

        const Self = @This();
        const Tree = RTree(Rect, ListIndex, min_children, rectFromRect, eqlKeys);
        pub const Handle = Tree.Handle;
        pub const Node = Tree.Node;
        pub const KV = Tree.KV;

        const Context = struct {
            self: *Self,

            fn deinit(ctx: Context, _: Allocator, list: ListIndex) void {
                ctx.self.flat.destroyList(list);
            }
        };

        pub fn init(sheet: *Sheet) @This() {
            return .{ .rtree = .init(sheet), .flat = .empty };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.rtree.deinitContext(allocator, Context{ .self = self });
            self.flat.deinit(allocator);
            self.* = undefined;
        }

        pub const SearchIterator = Tree.SearchIterator;

        pub fn searchIterator(tree: *Self, allocator: Allocator, rect: Rect) !SearchIterator {
            var ret: SearchIterator = .{
                .rect = rect,
                .allocator = allocator,
                .tree = &tree.rtree,
                .index = 0,
                .stack = .empty,
            };
            if (!tree.rtree.isEmpty())
                try ret.stack.append(allocator, tree.rtree.rootNode());
            return ret;
        }

        pub fn get(self: *Self, key: Rect) ?*KV {
            return self.rtree.get(key);
        }

        pub fn put(
            self: *Self,
            key: Rect,
            value: Sheet.CellHandle,
        ) Allocator.Error!void {
            return self.putSlice(key, &.{value});
        }

        pub fn putSlice(
            self: *Self,
            key: Rect,
            values: []const Sheet.CellHandle,
        ) Allocator.Error!void {
            const sheet = self.rtree.sheet;
            try self.rtree.ensureUnusedCapacity(1);

            if (self.rtree.isEmpty()) {
                const list = try self.flat.createList(sheet.allocator);
                errdefer self.flat.destroyList(list);
                try self.flat.ensureUnusedCapacity(sheet.allocator, list, values.len);
                errdefer comptime unreachable;

                self.flat.appendSliceAssumeCapacity(list, values);

                self.rtree.putRootAssumeCapacity(key, list);
                return;
            }

            if (self.get(key)) |kv| {
                const list = kv.value;
                try self.flat.appendSlice(sheet.allocator, list, values);
                return;
            }

            const list = try self.flat.createList(sheet.allocator);
            errdefer self.flat.destroyList(list);
            try self.flat.ensureUnusedCapacity(sheet.allocator, list, values.len);
            errdefer comptime unreachable;
            self.flat.appendSliceAssumeCapacity(list, values);

            var maybe_new_node = self.rtree.putNode(.from(0), key, list);

            if (maybe_new_node) |*new_node| {
                errdefer self.rtree.deinitNodeContext(new_node, sheet.allocator, Context{});
                self.rtree.mergeRootsAssumeCapacity(new_node.*);
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
            key: Rect,
        ) Allocator.Error!void {
            return self.rtree.removeContext(allocator, key, Context{});
        }

        /// Removes `value` from the list of values associated with `key`.
        /// Removes `key` if there are no values left after removal.
        pub fn removeValue(
            self: *Self,
            key: Rect,
            value: Sheet.CellHandle,
        ) Allocator.Error!void {
            if (self.rtree.isEmpty()) return;

            const res = self.removeNode(self.rtree.rootNode(), key, value);
            if (res != .merge) return;

            const node_to_merge = blk: {
                if (!self.rtree.rootNode().isLeaf()) {
                    // If the root node is a branch node and falls below `min_children` due to this
                    // operation, replace it with an empty leaf node and re-insert all values.
                    const root_len = self.rtree.nodeEntries(self.rtree.rootNode()).len -
                        @intFromBool(res == .merge and res.merge.parent == self.rtree.rootNode());

                    if (root_len < min_children) {
                        const ret = self.rtree.rootNode().*;
                        self.rtree.rootNode().* = .{
                            .level = 0,
                            .rect = undefined,
                            .children = .invalid,
                            .children_len = 0,
                        };
                        break :blk ret;
                    }
                }

                const parent = res.merge.parent;
                const child_index = res.merge.child_index;
                break :blk self.rtree.nodeEntriesSwapRemove(parent, child_index).node;
            };

            try self.reAddRecursive(node_to_merge);
        }

        /// Adds all keys contained in the tree belonging to `root` into `tree`
        fn reAddRecursive(
            self: *Self,
            root: Tree.Node,
        ) Allocator.Error!void {
            return self.rtree.reAddRecursive(root, Context{ .self = self });
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
            self: *Self,
            node: *Tree.Node,
            key: Rect,
            value: Sheet.CellHandle,
        ) RemoveNodeResult {
            const tree = &self.rtree;
            const sheet = tree.sheet;
            if (node.isLeaf()) {
                const entries = tree.nodeEntries(node);
                for (entries, 0..) |entry, i| {
                    if (!entry.kv.key.eql(key)) continue;

                    const list = entry.kv.value;
                    const values_slice = self.flat.items(list);

                    // Found matching key
                    // Now find the matching value
                    for (values_slice, 0..) |v, j| {
                        if (v == value) {
                            self.flat.swapRemove(list, j);
                            break;
                        }
                    }

                    if (self.flat.len(list) == 0) {
                        // This KV has no more values, so remove it entirely
                        _ = tree.nodeEntriesSwapRemove(node, i);
                        Context.deinit(.{ .self = self }, sheet.allocator, list);

                        if (tree.nodeEntries(node).len > 0 and key.anyMatch(node.rect)) {
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
                const child_rect = entry.node.rect;
                if (!child_rect.contains(key))
                    continue;

                const res = self.removeNode(&entry.node, key, value);
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

                const recalc_range = key.anyMatch(child_rect);

                if (merge_node) {
                    if (recalc_range) {
                        // Recalculate range excluding the child to be removed
                        const start = @intFromBool(i == 0);
                        var rect = entries[start].node.rect;

                        for (entries[0..i]) |e|
                            rect = rect.merge(e.node.rect);

                        for (entries[i + 1 ..]) |e|
                            rect = rect.merge(e.node.rect);

                        node.rect = rect;
                    }

                    return .{ .merge = .{ .parent = node, .child_index = i } };
                }

                if (recalc_range)
                    Tree.recalcBoundingRange(tree, node);

                return res;
            }

            return .none;
        }

        fn eqlKeys(_: *Sheet, a: Rect, b: Rect) bool {
            return a.eql(b);
        }

        // For serialization.

        pub const Header = extern struct {
            rtree: Tree.Header,
            flat: ListPool.Header,
        };

        pub fn getHeader(self: *const Self) Header {
            return .{ .rtree = self.rtree.getHeader(), .flat = self.flat.getHeader() };
        }

        pub fn fromHeader(
            self: *Self,
            allocator: Allocator,
            header: Header,
            sheet: *Sheet,
        ) ![3]std.posix.iovec {
            self.* = .init(sheet);
            errdefer self.deinit(allocator);

            _ = try self.rtree.fromHeader(allocator, header.rtree, sheet);
            _ = try self.flat.fromHeader(allocator, header.flat);
            return @bitCast(self.iovecs());
        }

        pub fn iovecs(self: *Self) [3]std.posix.iovec_const {
            return .{self.rtree.iovecs()} ++ self.flat.iovecs();
        }
    };
}
