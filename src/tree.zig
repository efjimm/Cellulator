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

            level: usize,
            range: Range,
            data: Data,

            /// Frees all memory associated with `node` and its children, and calls
            /// `context.deinitValue` on every instance of `V` in the tree.
            fn deinitContext(node: *Node, allocator: Allocator, context: anytype) void {
                if (node.isLeaf()) {
                    if (@TypeOf(context) != void) {
                        for (node.data.values.items(.value)) |*v| {
                            context.deinit(allocator, v);
                        }
                    }
                    node.data.values.deinit(allocator);
                } else {
                    for (node.data.children.slice()) |*n| n.deinitContext(allocator, context);
                }
                node.* = undefined;
            }

            fn isLeaf(node: *const Node) bool {
                return node.level == 0;
            }

            fn searchValues(
                node: *const Node,
                allocator: Allocator,
                range: Rect,
                list: *std.ArrayListUnmanaged(V),
            ) Allocator.Error!void {
                if (node.isLeaf()) {
                    const values = node.data.values.items(.value);
                    for (node.data.values.items(.key), 0..) |*k, i| {
                        if (range.intersects(k.rect())) {
                            try list.append(allocator, values[i]);
                        }
                    }
                } else {
                    for (node.data.children.constSlice()) |*n| {
                        if (range.intersects(n.range.rect())) {
                            try n.searchValues(allocator, range, list);
                        }
                    }
                }
            }

            fn search(
                node: *const Node,
                range: Rect,
                list: *std.ArrayList(SearchItem),
            ) Allocator.Error!void {
                if (node.isLeaf()) {
                    const values = node.data.values.items(.value);
                    for (node.data.values.items(.key), 0..) |k, i| {
                        if (range.intersects(k.rect())) {
                            try list.append(.{
                                .key = k,
                                .value_ptr = &values[i],
                            });
                        }
                    }
                } else {
                    for (node.data.children.constSlice()) |*n| {
                        if (range.intersects(n.range.rect())) {
                            try n.search(range, list);
                        }
                    }
                }
            }

            fn getSingleRecursive(node: *Node, key: K) ?struct { *K, *V } {
                if (node.isLeaf()) {
                    return for (node.data.values.items(.key), 0..) |*k, i| {
                        if (k.eql(key))
                            break .{ k, &node.data.values.items(.value)[i] };
                    } else null;
                }

                return for (node.data.children.slice()) |*n| {
                    if (n.range.rect().contains(key.rect())) {
                        if (n.getSingleRecursive(key)) |res| break res;
                    }
                } else null;
            }

            fn getSingle(node: *Node, key: K) ?struct { *K, *V } {
                return if (node.range.rect().contains(key.rect()))
                    getSingleRecursive(node, key)
                else
                    null;
            }

            fn bestLeaf(node: *Node, key: K) *Node {
                assert(node.level == 1);
                const slice = node.data.children.constSlice();
                assert(slice.len > 0);

                // Minimize overlap
                var min_index: usize = 0;
                var min_enlargement: u64 = 0;
                var min_overlap: u64 = std.math.maxInt(u64);

                for (slice, 0..) |n1, i| {
                    const rect = n1.range.rect();
                    const r = rect.merge(key.rect());
                    const enlargement = r.area() - rect.area();

                    const total_overlap = totalOverlap(slice, r);

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

            fn totalOverlap(nodes: []const Node, range: Rect) u64 {
                var total: u64 = 0;
                for (nodes) |*n| {
                    total += range.overlapArea(n.range.rect());
                }
                return total;
            }

            /// Find best child to insert into.
            /// Gets the child with the smallest area increase to store `key`
            fn bestChild(node: *Node, key: K) *Node {
                assert(!node.isLeaf());

                if (node.level == 1) return bestLeaf(node, key);

                // Minimize area enlargement

                const slice = node.data.children.constSlice();
                assert(slice.len > 0);

                var min_index: usize = 0;
                var min_diff, var min_area = blk: {
                    const rect = Rect.merge(slice[0].range.rect(), key.rect());
                    break :blk .{
                        rect.area() - slice[0].range.rect().area(),
                        slice[0].range.rect().area(),
                    };
                };

                for (slice[1..], 1..) |n, i| {
                    const r = n.range.rect();
                    const rect = Rect.merge(r, key.rect());
                    const a = r.area();
                    const diff = rect.area() - a;
                    if (diff <= min_diff) {
                        if (diff != min_diff or a < min_area) {
                            min_index = i;
                            min_area = a;
                            min_diff = diff;
                        }
                    }
                }

                return &node.data.children.slice()[min_index];
            }

            fn recalcBoundingRange(node: *Node, sheet: *Sheet) void {
                if (node.isLeaf()) {
                    const slice: []const K = node.data.values.items(.key);
                    assert(slice.len > 0);

                    var rect = slice[0].rect();
                    for (slice[1..]) |k| rect = rect.merge(k.rect());
                    node.range = Range.fromRect(sheet, rect);
                    return;
                }

                const slice = node.data.children.constSlice();
                assert(slice.len > 0);
                var rect = slice[0].range.rect();
                for (slice[1..]) |n| rect = rect.merge(n.range.rect());
                node.range = Range.fromRect(sheet, rect);
            }

            /// Removes `key` and its associated value from the tree.
            fn remove(
                node: *Node,
                sheet: *Sheet,
                key: K,
            ) ?struct {
                /// Removed kv pair (if any)
                KV,

                ?struct {
                    /// Pointer to the parent of the node that needs to be merged
                    *Node,
                    /// Index of the node to be merged inside of the parent
                    usize,
                },
            } {
                if (node.isLeaf()) {
                    const list = &node.data.values;
                    const ret = for (list.items(.key), 0..) |k, i| {
                        if (!k.eql(key)) continue;
                        _ = list.swapRemove(i);
                        break .{
                            KV{
                                .key = k,
                                .value = if (V == void) {} else list.items(.value)[i],
                            },
                            null,
                        };
                    } else return null;

                    // TODO: Use anymatch function on Range & K
                    if (list.len > 0 and
                        (key.rect().tl.anyMatch(node.range.rect().tl) or
                        key.rect().br.anyMatch(node.range.rect().br)))
                    {
                        node.recalcBoundingRange(sheet);
                    }
                    return ret;
                }

                const list = node.data.children;
                return for (list.slice(), 0..) |*n, i| {
                    if (!n.range.rect().contains(key.rect())) continue;

                    const res = n.remove(sheet, key) orelse continue;
                    const kv, var p = res;

                    const recalc = key.rect().tl.anyMatch(node.range.rect().tl) or
                        key.rect().br.anyMatch(node.range.rect().br);
                    const merge_node = if (n.isLeaf())
                        n.data.values.len < min_children
                    else
                        // If p[0] == n, then a child of n has to be merged (removed),
                        // so -1 from its length
                        n.data.children.len - @intFromBool(p != null and p.?[0] == n) < min_children;

                    assert(list.len > 1);
                    if (merge_node) {
                        p = .{ node, i };

                        if (recalc) {
                            // Recalculate range excluding the child to be removed
                            const start = @intFromBool(i == 0);
                            var rect = list.constSlice()[start].range.rect();
                            for (list.constSlice()[0..i]) |c| rect = rect.merge(c.range.rect());
                            for (list.constSlice()[i + 1 ..]) |c| rect = rect.merge(c.range.rect());
                            node.range = Range.fromRect(sheet, rect);
                        }
                    } else if (recalc) {
                        node.recalcBoundingRange(sheet);
                    }
                    break .{ kv, p };
                } else null;
            }

            fn getRect(a: anytype) Rect {
                return switch (@TypeOf(a)) {
                    Node, *Node, *const Node => a.range.rect(),
                    KV, *KV, *const KV => a.key.rect(),
                    else => a.rect(),
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
                return std.BoundedArray(Distribution(T), dist_count);
            }

            const dist_count = 2 * (max_children - 2 * min_children + 2);

            fn chooseSplitAxis(node: *const Node, comptime T: type) Distributions(T) {
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
                        pub fn compare(_: @This(), lhs: T, rhs: T) bool {
                            return switch (d) {
                                .x => getRect(lhs).tl.x < getRect(rhs).tl.x,
                                .y => getRect(lhs).tl.y < getRect(rhs).tl.y,
                                else => unreachable,
                            };
                        }
                    };

                    const UpperContext = struct {
                        pub fn compare(_: @This(), lhs: T, rhs: T) bool {
                            return switch (d) {
                                .x => getRect(lhs).br.x < getRect(rhs).br.x,
                                .y => getRect(lhs).br.y < getRect(rhs).br.y,
                                else => unreachable,
                            };
                        }
                    };

                    std.sort.heap(T, sorted_lower.slice(), LowerContext{}, LowerContext.compare);
                    std.sort.heap(T, sorted_upper.slice(), UpperContext{}, UpperContext.compare);

                    var sum: u64 = 0;
                    var temp: Distributions(T) = .{};
                    temp.len = 0;
                    inline for (.{
                        sorted_lower.constSlice(),
                        sorted_upper.constSlice(),
                    }) |entries| {
                        for (0..max_children - 2 * min_children + 2) |k| {
                            var r1: Rect = getRect(entries[0]);
                            var r2: Rect = getRect(entries[min_children + k]);
                            for (entries[1 .. min_children + k]) |e| r1 = r1.merge(getRect(e));
                            for (entries[min_children + k + 1 ..]) |e| r2 = r2.merge(getRect(e));

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

            pub fn chooseSplitIndex(comptime T: type, dists: *const Distributions(T)) usize {
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
        };

        fn splitLeafNode(
            sheet: *Sheet,
            node: *Node,
        ) Allocator.Error!Node {
            const dists: Node.Distributions(KV) = node.chooseSplitAxis(KV);
            const index = Node.chooseSplitIndex(KV, &dists);
            const d = &dists.constSlice()[index];

            var new_entries: Node.ValueList = .{};
            try new_entries.ensureUnusedCapacity(sheet.allocator, d[1].entries.len);
            for (d[1].entries.constSlice()) |e| {
                new_entries.appendAssumeCapacity(e);
            }

            node.data.values.len = 0;
            for (d[0].entries.constSlice()) |e| {
                node.data.values.appendAssumeCapacity(e);
            }
            node.range = Range.fromRect(sheet, d[0].range);
            return .{
                .level = node.level,
                .range = Range.fromRect(sheet, d[1].range),
                .data = .{ .values = new_entries },
            };
        }

        fn splitBranchNode(
            sheet: *Sheet,
            tree: *Self,
            node: *Node,
        ) Allocator.Error!Node {
            assert(!node.isLeaf());

            const dists: Node.Distributions(Node) = node.chooseSplitAxis(Node);
            const index = Node.chooseSplitIndex(Node, &dists);
            const d = &dists.constSlice()[index];

            const new_entries = try tree.pool.create(sheet.allocator);
            new_entries.* = d[1].entries;

            node.data.children.* = d[0].entries;
            node.range = Range.fromRect(sheet, d[0].range);
            return .{
                .level = node.level,
                .range = Range.fromRect(sheet, d[1].range),
                .data = .{ .children = new_entries },
            };
        }

        /// Returns an unorded list of key-value pairs whose keys intersect `range`
        pub fn search(
            tree: Self,
            allocator: Allocator,
            range: Rect,
        ) Allocator.Error![]SearchItem {
            var list = std.ArrayList(SearchItem).init(allocator);
            errdefer list.deinit();

            try tree.root.search(range, &list);
            return list.toOwnedSlice();
        }

        pub fn searchIterator(tree: *Self, allocator: Allocator, range: Rect) SearchIterator {
            var ret: SearchIterator = .{
                .range = range,
                .allocator = allocator,
            };
            ret.stack.append(allocator, &tree.root) catch unreachable;
            return ret;
        }

        pub const SearchIterator = struct {
            stack: std.SegmentedList(*Node, 256) = .{},
            index: usize = 0,
            range: Rect,
            allocator: Allocator,

            /// Resets the iterator, retaining any memory allocated for the stack
            pub fn reset(iter: *SearchIterator, new_range: Rect, tree: *Self) void {
                iter.range = new_range;
                iter.index = 0;
                iter.stack.clearRetainingCapacity();
                iter.stack.append(iter.allocator, &tree.root) catch unreachable;
            }

            pub fn deinit(iter: *SearchIterator) void {
                iter.stack.deinit(iter.allocator);
            }

            pub fn next(iter: *SearchIterator) !?SearchItem {
                const node = iter.stack.pop() orelse return null;

                if (node.isLeaf()) {
                    if (iter.index >= node.data.values.len) {
                        iter.index = 0;
                        return iter.next();
                    }

                    const values = node.data.values.items(.value);
                    const keys = node.data.values.items(.key);

                    for (keys[iter.index..], iter.index..) |k, i| {
                        if (iter.range.intersects(k.rect())) {
                            // We might have more matches in this leaf node, put it back on the
                            // stack
                            iter.stack.append(iter.allocator, node) catch unreachable;
                            iter.index = i + 1;
                            return .{
                                .key = k,
                                .value_ptr = &values[i],
                            };
                        }
                    }
                } else {
                    for (node.data.children.slice()) |*n| {
                        if (iter.range.intersects(n.range.rect())) {
                            try iter.stack.append(iter.allocator, n);
                        }
                    }
                }

                iter.index = 0;
                return iter.next();
            }
        };

        pub fn searchBuffer(
            tree: Self,
            allocator: Allocator,
            list: *std.ArrayListUnmanaged(V),
            range: Rect,
        ) Allocator.Error!void {
            try tree.root.searchValues(allocator, range, list);
        }

        fn mergeRoots(
            tree: *Self,
            sheet: *Sheet,
            new_node: Node,
        ) Allocator.Error!void {
            // Root node got split, need to create a new root
            var new_root = Node{
                .level = new_node.level + 1,
                .range = Range.fromRect(sheet, Rect.merge(
                    tree.root.range.rect(),
                    new_node.range.rect(),
                )),
                .data = .{
                    .children = blk: {
                        const mem = try tree.pool.create(sheet.allocator);
                        mem.* = .{};
                        break :blk mem;
                    },
                },
            };

            new_root.data.children.appendSliceAssumeCapacity(&.{ tree.root, new_node });
            tree.root = new_root;
        }

        fn putNode(
            tree: *Self,
            sheet: *Sheet,
            node: *Node,
            key: K,
            value: V,
        ) !?Node {
            var ok = true;
            defer if (ok) {
                // Update the node's range if there are no errors
                node.range = Range.fromRect(sheet, node.range.rect().merge(key.rect()));
            };
            errdefer ok = false;

            if (node.isLeaf()) {
                // TODO: Sort keys for faster search?
                for (node.data.values.items(.key)) |*k| {
                    // Key already exists in tree
                    if (key.eql(k.*)) {
                        k.* = key; // TODO: This is kind of a hack, but it works
                        return null;
                    }
                }

                node.data.values.ensureUnusedCapacity(sheet.allocator, 1) catch return error.NotAdded;
                node.data.values.appendAssumeCapacity(.{ .key = key, .value = value });
                errdefer _ = node.data.values.pop();

                if (node.data.values.len >= max_children) {
                    // Don't merge ranges in this branch, split does that
                    ok = false;
                    // Too many kvs, need to split this node
                    const new_node = tree.splitNode(sheet, node) catch return error.NotAdded;
                    return new_node;
                } else if (node.data.values.len == 1) {
                    // This was the first node added to this leaf
                    node.range = Range.fromRect(sheet, key.rect()); // TODO: use range method on K
                }
                return null;
            }

            // Branch node
            const list = node.data.children;

            const best = node.bestChild(key);
            const maybe_new_node = try tree.putNode(sheet, best, key, value);

            if (maybe_new_node) |split_node| {
                // Child node was split, need to add new node to child list
                list.appendAssumeCapacity(split_node);

                if (list.len >= max_children) {
                    ok = false;
                    const new_node = try tree.splitNode(sheet, node);
                    return new_node;
                }
            }

            return null;
        }

        fn splitNode(tree: *Self, sheet: *Sheet, node: *Node) Allocator.Error!Node {
            return if (node.isLeaf())
                splitLeafNode(sheet, node)
            else
                splitBranchNode(sheet, tree, node);
        }

        /// Finds the key/value pair whose key matches `key` and returns pointers
        /// to the key and value, or `null` if not found.
        pub fn get(tree: *Self, key: K) ?struct { *K, *V } {
            if (tree.root.isLeaf()) {
                if (tree.root.data.values.len == 0) return null;
            } else if (tree.root.data.children.len == 0) {
                return null;
            }

            return tree.root.getSingle(key);
        }

        pub fn put(
            tree: *Self,
            sheet: *Sheet,
            key: K,
            value: V,
        ) Allocator.Error!void {
            return tree.putContext(sheet, key, value, {});
        }

        pub fn putContext(
            tree: *Self,
            sheet: *Sheet,
            key: K,
            value: V,
            context: anytype,
        ) Allocator.Error!void {
            var maybe_new_node = tree.putNode(sheet, &tree.root, key, value) catch
                return error.OutOfMemory;
            if (maybe_new_node) |*new_node| {
                errdefer new_node.deinitContext(sheet.allocator, context);
                try tree.mergeRoots(sheet, new_node.*);
            }
        }

        /// Removes `key` and its associated value from the tree.
        pub fn remove(
            tree: *Self,
            sheet: *Sheet,
            key: K,
        ) Allocator.Error!void {
            return tree.removeContext(sheet, key, {});
        }

        /// Removes `key` and its associated value from the tree.
        pub fn removeContext(
            tree: *Self,
            sheet: *Sheet,
            key: K,
            context: anytype,
        ) Allocator.Error!void {
            var kv, const merge_info = tree.root.remove(sheet, key) orelse return;

            if (@TypeOf(context) != void)
                context.deinit(sheet.allocator, &kv.value);

            var node_to_merge = blk: {
                if (!tree.root.isLeaf()) {
                    // Remove the root node if it goes under `min_children`, so all of its leaves
                    // can be re-added
                    const root_len = tree.root.data.children.len -
                        @intFromBool(merge_info != null and merge_info.?[0] == &tree.root);
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
                const parent, const index = merge_info orelse return;
                break :blk parent.data.children.swapRemove(index);
            };

            try tree.reAddRecursive(sheet, &node_to_merge, context);
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
            tree.pool.deinit(allocator);
            tree.* = undefined;
        }

        /// Adds all keys contained in the tree belonging to `root` into `tree`
        fn reAddRecursive(
            tree: *Self,
            sheet: *Sheet,
            root: *Node,
            context: anytype,
        ) Allocator.Error!void {
            var maybe_err: Allocator.Error!void = {};
            if (root.isLeaf()) {
                defer root.data.values.deinit(sheet.allocator);
                while (root.data.values.popOrNull()) |temp| {
                    var kv = temp;
                    tree.put(sheet, kv.key, kv.value) catch |err| {
                        if (@TypeOf(context) != void)
                            context.deinit(sheet.allocator, &kv.value);
                        maybe_err = err;
                    };
                }
            } else {
                while (root.data.children.popOrNull()) |temp| {
                    var child = temp;
                    tree.reAddRecursive(sheet, &child, context) catch |err| {
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
        rtree: Tree = .{},

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
            sheet: *Sheet,
            key: Range,
            value: *Cell,
        ) Allocator.Error!void {
            return self.putSlice(sheet, key, &.{value});
        }

        pub fn putSlice(
            self: *Self,
            sheet: *Sheet,
            key: Range,
            values: []const *Cell,
        ) Allocator.Error!void {
            if (self.get(key)) |kv| {
                try kv[1].appendSlice(sheet.allocator, values);
                return;
            }

            var list = try ValueList.initCapacity(sheet.allocator, values.len);
            list.appendSliceAssumeCapacity(values);

            var maybe_new_node = self.rtree.putNode(
                sheet,
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
                errdefer new_node.deinitContext(sheet.allocator, Context{});
                try self.rtree.mergeRoots(sheet, new_node.*);
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
            sheet: *Sheet,
            key: Range,
            value: *Cell,
        ) Allocator.Error!void {
            const merge_info = removeNode(&self.rtree.root, sheet, key, value) orelse return;

            var node_to_merge = blk: {
                if (!self.rtree.root.isLeaf()) {
                    const root_len = self.rtree.root.data.children.len -
                        @intFromBool(merge_info != null and
                        merge_info.?[0] == &self.rtree.root);
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
                const parent, const index = merge_info orelse return;
                break :blk parent.data.children.swapRemove(index);
            };

            try self.reAddRecursive(sheet, &node_to_merge);
        }

        /// Adds all keys contained in the tree belonging to `root` into `tree`
        fn reAddRecursive(
            self: *Self,
            sheet: *Sheet,
            root: *Tree.Node,
        ) Allocator.Error!void {
            return self.rtree.reAddRecursive(sheet, root, Context{});
        }

        const RemoveNodeRet = struct { *Tree.Node, usize };
        /// Custom implementation of `remove` for the DependentTree
        /// Removes `value` from the entry with key `key`
        fn removeNode(
            node: *Tree.Node,
            sheet: *Sheet,
            key: Range,
            value: *Cell,
        ) ??RemoveNodeRet {
            if (node.isLeaf()) {
                const list = &node.data.values;
                return for (list.items(.key), 0..) |k, i| {
                    if (!k.eql(key)) continue;

                    const values = &list.items(.value)[i];
                    errdefer if (values.items.len == 0) {
                        var old_kv = list.swapRemove(i);
                        Context.deinit(.{}, sheet.allocator, &old_kv.value);
                    };

                    // Found matching key
                    // Now find the matching value
                    for (values.items, 0..) |v, j| {
                        if (v != value) continue;
                        _ = values.swapRemove(j);
                        break;
                    }

                    if (values.items.len == 0) {
                        // This KV has no more values, so remove it entirely
                        var old_value = list.items(.value)[i];
                        list.swapRemove(i);
                        Context.deinit(.{}, sheet.allocator, &old_value);

                        if (list.len > 0 and
                            (key.rect().tl.anyMatch(node.range.rect().tl) or
                            key.rect().br.anyMatch(node.range.rect().br)))
                        {
                            node.recalcBoundingRange(sheet);
                        }

                        break @as(?RemoveNodeRet, null);
                    }

                    // Removed a value but not a key
                    break @as(?RemoveNodeRet, null);
                } else null;
            }

            const list = node.data.children;
            return for (list.slice(), 0..) |*n, i| {
                const r = n.range.rect();
                if (!r.contains(key.rect())) continue;

                const res = removeNode(n, sheet, key, value);
                var p = res orelse continue;

                const recalc = key.rect().tl.anyMatch(r.tl) or
                    key.rect().br.anyMatch(r.br);
                const merge_node = if (n.isLeaf())
                    n.data.values.len < min_children
                else
                    // If p[0] == n, then a child of n has to be merged (removed),
                    // so -1 from its length
                    n.data.children.len - @intFromBool(p != null and p.?[0] == n) < min_children;

                assert(list.len > 0);
                if (merge_node) {
                    p = .{ node, i };

                    if (recalc) {
                        const start = @intFromBool(i == 0);
                        var rect = list.constSlice()[start].range.rect();
                        for (list.constSlice()[0..i]) |c| rect = rect.merge(c.range.rect());
                        for (list.constSlice()[i + 1 ..]) |c| rect = rect.merge(c.range.rect());
                        node.range = Range.fromRect(sheet, rect);
                    }
                } else if (recalc) {
                    node.recalcBoundingRange(sheet);
                }

                break p;
            } else null;
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
