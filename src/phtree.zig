// TODO: Discover and assert more invariants to improve robustness
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const utils = @import("utils.zig");

const runtime_safety = switch (@import("builtin").mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

pub fn PhTree(comptime V: type, comptime dims: usize) type {
    return struct {
        root: Handle,
        free: Handle,
        free_count: u32,
        entries: std.MultiArrayList(Entry).Slice,
        // ensured_capacity: if (runtime_safety) u32 else void,

        fn calculateHypercubeAddress(p: *const Point, postfix_length: u8) u8 {
            const pl: u5 = @intCast(postfix_length);
            const bit_mask = @as(u32, 1) << pl;
            var address: u32 = 0;
            for (p) |v| {
                address <<= 1;
                address |= (bit_mask & v) >> pl;
            }
            return @intCast(address);
        }

        pub fn createHandle(
            tree: *@This(),
            allocator: Allocator,
            p: *const Point,
            value: V,
        ) Allocator.Error!Handle {
            const handle = try tree.createEntry(allocator);
            tree.entries.set(handle.n, .{
                .point = p.*,
                .parent = .invalid,
                .data = .{ .value = value },
            });
            return handle;
        }

        pub fn createHandleAssumeCapacity(tree: *@This(), p: *const Point, value: V) Handle {
            const handle = tree.createEntryAssumeCapacity();
            tree.entries.set(handle.n, .{
                .point = p.*,
                .parent = .invalid,
                .data = .{ .value = value },
            });
            return handle;
        }

        fn createEntry(tree: *@This(), allocator: Allocator) Allocator.Error!Handle {
            if (!tree.free.isValid()) {
                var m = tree.entries.toMultiArrayList();
                defer tree.entries = m.slice();

                try m.ensureUnusedCapacity(allocator, 1);
            }

            return tree.createEntryAssumeCapacity();
        }

        fn createEntryAssumeCapacity(tree: *@This()) Handle {
            if (tree.free.isValid()) {
                const ret = tree.free;
                tree.free = tree.entries.items(.data)[ret.n].free;
                assert(!tree.free.isValid() or tree.free.n < tree.entries.len);
                tree.free_count -= 1;
                return ret;
            }

            assert(tree.entries.capacity > tree.entries.len);
            const handle: Handle = .from(@intCast(tree.entries.len));
            tree.entries.len += 1;
            return handle;
        }

        pub fn destroyHandle(tree: *@This(), handle: Handle) void {
            tree.entries.items(.parent)[handle.n] = .invalid;
            if (handle.n == tree.entries.len - 1) {
                tree.entries.len -= 1;
            } else {
                tree.entries.items(.data)[handle.n].free = tree.free;
                tree.free = handle;
                tree.free_count += 1;
            }
        }

        fn addNodeKv(
            tree: *@This(),
            handle: Handle,
            p: *const Point,
            kv_handle: Handle,
        ) Handle {
            const node = tree.nodePtr(handle);
            assert(node.isLeaf());

            const address = calculateHypercubeAddress(p, 0);
            tree.entries.items(.parent)[kv_handle.n] = handle;

            if (!node.children[address].isValid()) {
                node.children_len += 1;
            }

            const old_child = node.children[address];
            node.children[address] = kv_handle;

            return old_child;
        }

        fn createNodeAssumeCapacity(
            tree: *@This(),
            parent: Handle,
            infix_length: u8,
            postfix_length: u8,
            p: *const Point,
            kv: Handle,
        ) Handle {
            const handle = tree.createEntryAssumeCapacity();
            assert(handle.isValid());

            const one: u32 = 1;
            const max: u32 = std.math.maxInt(u32);
            const pl: u5 = @intCast(postfix_length);
            const key_mask = if (pl < 31) (max << (pl + 1)) else 0;
            var new_point = p.*;
            for (&new_point) |*v| {
                v.* &= key_mask;
                v.* |= one << pl;
            }

            tree.entries.set(handle.n, .{
                .point = new_point,
                .parent = parent,
                .data = .{
                    .node = .{
                        .children = @splat(.invalid),
                        .children_len = 0,
                        .infix_length = infix_length,
                        .postfix_length = postfix_length,
                    },
                },
            });

            if (postfix_length == 0) {
                const old_kv = tree.addNodeKv(handle, p, kv);
                assert(!old_kv.isValid());
            }

            return handle;
        }

        fn tryAddNode(
            tree: *@This(),
            handle: Handle,
            address: u8,
            p: *const Point,
            kv: Handle,
        ) struct { Handle, bool } {
            const node = tree.nodePtr(handle);
            var added = false;
            if (!node.children[address].isValid()) {
                node.children[address] = tree.createNodeAssumeCapacity(
                    handle,
                    node.postfix_length - 1,
                    0,
                    p,
                    kv,
                );
                node.children_len += 1;
                added = true;
            }

            return .{ node.children[address], added };
        }

        /// Returns the index of the bit at which the two points diverge
        fn numberOfDivergingBits(p1: *const Point, p2: *const Point) u8 {
            var diff: u32 = 0;
            for (p1, p2) |v1, v2| {
                diff |= v1 ^ v2;
            }
            return 32 - @clz(diff);
        }

        /// Insert a new node between existing nodes
        fn insertNodeSplit(
            tree: *@This(),
            handle: Handle,
            child_handle: Handle,
            p: *const Point,
            max_conflicting_bits: u8,
        ) Handle {
            // TODO: Add pointer stability locks
            const node = tree.nodePtr(handle);
            const new_handle = tree.createNodeAssumeCapacity(
                handle,
                node.postfix_length - max_conflicting_bits,
                max_conflicting_bits - 1,
                p,
                undefined, // A value never gets inserted in this case
            );
            const new_node = tree.nodePtr(new_handle);
            const child_point = &tree.entries.items(.point)[child_handle.n];

            const parent_address = calculateHypercubeAddress(p, node.postfix_length);
            assert(node.children[parent_address] == child_handle);
            node.children[parent_address] = new_handle;

            const new_node_address = calculateHypercubeAddress(child_point, new_node.postfix_length);
            new_node.children[new_node_address] = child_handle;
            new_node.children_len += 1;

            tree.entries.items(.parent)[child_handle.n] = new_handle;

            const child_node = tree.nodePtr(child_handle);
            child_node.infix_length = (new_node.postfix_length - child_node.postfix_length) - 1;

            return new_handle;
        }

        fn handleNodeCollision(
            tree: *@This(),
            handle: Handle,
            child_handle: Handle,
            p: *const Point,
            kv: Handle,
        ) struct {
            /// Handle of the newly inserted node
            Handle,
            /// Handle of any old KV that was removed
            Handle,
        } {
            const child_node = tree.nodePtr(child_handle);
            if (child_node.isLeaf()) {
                if (child_node.infix_length > 0) {
                    const child_point = &tree.entries.items(.point)[child_handle.n];
                    const conflicting_bits = numberOfDivergingBits(p, child_point);
                    if (conflicting_bits > 1) {
                        const new_handle = tree.insertNodeSplit(handle, child_handle, p, conflicting_bits);
                        return .{ new_handle, .invalid };
                    }
                }

                const removed_kv = tree.addNodeKv(child_handle, p, kv);
                return .{ child_handle, removed_kv };
            }

            if (child_node.infix_length > 0) {
                const child_point = &tree.entries.items(.point)[child_handle.n];
                const conflicting_bits = numberOfDivergingBits(p, child_point);
                if (conflicting_bits > child_node.postfix_length + 1) {
                    const new_handle = tree.insertNodeSplit(handle, child_handle, p, conflicting_bits);
                    return .{ new_handle, .invalid };
                }
            }

            return .{ child_handle, .invalid };
        }

        fn addNode(tree: *@This(), handle: Handle, p: *const Point, kv: Handle) struct { Handle, Handle } {
            const node = tree.nodePtr(handle);
            const address = calculateHypercubeAddress(p, node.postfix_length);
            const child_node, const added = tree.tryAddNode(handle, address, p, kv);

            if (added) {
                return .{ child_node, .invalid };
            }

            return tree.handleNodeCollision(handle, child_node, p, kv);
        }

        pub fn ensureUnusedCapacity(tree: *@This(), allocator: Allocator, n: u32) Allocator.Error!void {
            const count = std.math.mul(u32, n, 3) catch return error.OutOfMemory;
            if (tree.entries.len + count > tree.entries.capacity) {
                var m = tree.entries.toMultiArrayList();
                defer tree.entries = m.slice();
                try m.setCapacity(allocator, m.len * 2 + count);
            }
        }

        // TODO: Make the return type a normal struct instead of a tuple.
        pub fn getOrPut(
            tree: *@This(),
            allocator: Allocator,
            p: *const Point,
        ) Allocator.Error!struct {
            /// True if this point already existed in the tree
            bool,
            /// Pointer to the value associated with `p`. If no entry previously existed for `p`,
            /// the value pointed to is undefined.
            *V,
            /// Handle of the `Entry` associated with `p`.
            Handle,
        } {
            try tree.ensureUnusedCapacity(allocator, 1);
            return tree.getOrPutAssumeCapacity(p);
        }

        pub fn getOrPutAssumeCapacity(tree: *@This(), p: *const Point) struct {
            /// True if this point already existed in the tree
            bool,
            /// Pointer to the value associated with `p`. If no entry previously existed for `p`,
            /// the value pointed to is undefined.
            *V,
            /// Handle of the `Entry` associated with `p`.
            Handle,
        } {
            const h = tree.findEntry(p);
            if (h.isValid()) {
                return .{ true, &tree.entries.items(.data)[h.n].value, h };
            }

            const handle = tree.createHandleAssumeCapacity(p, undefined);
            const removed_kv = tree.insertAssumeCapacity(p, handle);
            assert(!removed_kv.isValid());

            const value_ptr = &tree.entries.items(.data)[handle.n].value;
            return .{ false, value_ptr, handle };
        }

        pub fn insert(
            tree: *@This(),
            allocator: Allocator,
            p: *const Point,
            kv: Handle,
        ) Allocator.Error!Handle {
            try tree.ensureUnusedCapacity(allocator, 1);
            return tree.insertAssumeCapacity(p, kv);
        }

        fn hasCapacity(tree: *@This(), n: u32) bool {
            const unused_entries = tree.entries.capacity - tree.entries.len;
            return n <= tree.free_count + unused_entries;
        }

        pub fn insertAssumeCapacity(tree: *@This(), p: *const Point, kv: Handle) Handle {
            // assert(tree.hasCapacity(2));
            assert(tree.root.isValid());
            var current_node = tree.root;
            var removed_kv: Handle = .invalid;
            while (!tree.nodePtr(current_node).isLeaf()) {
                // If `addNode` adds a value it must be the last call to `addNode`.
                assert(!removed_kv.isValid());
                current_node, removed_kv = tree.addNode(current_node, p, kv);
            }

            const node = tree.nodePtr(current_node);
            const address = calculateHypercubeAddress(p, node.postfix_length);
            assert(node.children[address] == kv);
            if (removed_kv.isValid())
                tree.entries.items(.parent)[removed_kv.n] = .invalid;
            return removed_kv;
        }

        pub fn clearRetainingCapacity(tree: *@This()) void {
            tree.entries.len = 1;
            tree.root = .from(0);
            tree.free = .invalid;
            tree.entries.set(0, .{
                .point = @splat(0),
                .parent = .invalid,
                .data = .{
                    .node = .{
                        .children = @splat(.invalid),
                        .children_len = 0,
                        .infix_length = 0,
                        .postfix_length = 31,
                    },
                },
            });
        }

        fn printNode(tree: *@This(), handle: Handle) void {
            const entry = tree.entries.get(handle.n);
            std.debug.print(
                \\Node {c} ({c}): postfix {d}, infix {d}, [{d} children]
                \\{x:0>8}
                \\
            ,
                .{
                    @as(u8, @intCast(handle.n + 'A')),
                    if (entry.parent.isValid()) @as(u8, @intCast(entry.parent.n + 'A')) else '!',
                    entry.data.node.postfix_length,
                    entry.data.node.infix_length,
                    entry.data.node.children_len,
                    entry.point,
                },
            );

            if (entry.data.node.isLeaf()) {
                for (entry.data.node.children, 0..) |child, i| {
                    if (child.isValid()) {
                        const child_entry = tree.entries.get(child.n);
                        std.debug.print("  {b:0>2}: {}, point: {d}, parent: {c}\n", .{
                            i,
                            child_entry.data.value,
                            child_entry.point,
                            child_entry.parent.toAscii(),
                        });
                    } else {
                        std.debug.print("  {b:0>2}: invalid\n", .{i});
                    }
                }
                std.debug.print("\n", .{});
                return;
            }

            for (entry.data.node.children, 0..) |child, i| {
                if (child.isValid()) {
                    std.debug.print("  {b:0>2}: {c}\n", .{ i, @as(u8, @intCast(child.n + 'A')) });
                } else {
                    std.debug.print("  {b:0>2}: invalid\n", .{i});
                }
            }
            std.debug.print("\n", .{});
            for (entry.data.node.children) |child| {
                if (child.isValid())
                    tree.printNode(child);
            }
        }

        pub fn print(tree: *@This()) void {
            std.debug.print("========================\n", .{});
            tree.printNode(tree.root);
            std.debug.print("========================\n", .{});
        }

        pub fn largestDim(tree: *@This(), dim: u8) Handle {
            var largest: Handle = .invalid;
            for (tree.entries.items(.point), 0..) |p, i| {
                const handle: Handle = .from(@intCast(i));
                if (tree.isValue(handle) and
                    (!largest.isValid() or tree.point(largest)[dim] < p[dim]))
                {
                    largest = handle;
                }
            }
            return largest;
        }

        pub fn findEntry(tree: *@This(), p: *const Point) Handle {
            var h = tree.root;
            while (h.isValid()) {
                const node = tree.nodePtr(h);
                h = node.children[calculateHypercubeAddress(p, node.postfix_length)];
                if (node.isLeaf()) {
                    if (h.isValid()) {
                        const p2 = tree.entries.items(.point)[h.n];
                        if (std.mem.eql(u32, p, &p2))
                            return h;

                        return .invalid;
                    }
                    return h;
                }
            }

            return .invalid;
        }

        pub fn findEntryOrParent(tree: *@This(), p: *const Point) struct { Handle, u8 } {
            var h = tree.root;
            var parent: Handle = .invalid;
            var address: u8 = 0;
            while (h.isValid()) {
                const node = tree.nodePtr(h);
                parent = h;
                address = calculateHypercubeAddress(p, node.postfix_length);
                h = node.children[address];
                if (node.isLeaf()) return .{ parent, address };
            }

            assert(parent.isValid());
            return .{ parent, address };
        }

        const Self = @This();

        pub const Iterator = struct {
            tree: *Self,
            current: Handle,
            index: u8,

            pub fn next(iter: *Iterator) ?Handle {
                const node = iter.tree.nodePtr(iter.current);
                if (node.isLeaf()) {
                    for (node.children[iter.index..], iter.index..) |child_handle, i| {
                        if (!child_handle.isValid()) continue;

                        iter.index = @intCast(i + 1);
                        return child_handle;
                    }
                } else {
                    for (node.children[iter.index..]) |child_handle| {
                        if (!child_handle.isValid()) continue;

                        iter.index = 0;
                        iter.current = child_handle;
                        return iter.next();
                    }
                }

                const parent = iter.tree.getParent(iter.current);
                if (!parent.isValid()) {
                    // iter.current is the root node, and we have processed all the children
                    return null;
                }

                const parent_node = iter.tree.nodePtr(parent);
                for (parent_node.children, 0..) |child_handle, i| {
                    if (child_handle == iter.current) {
                        iter.index = @intCast(i + 1);
                        break;
                    }
                } else unreachable;

                iter.current = parent;
                return iter.next();
            }
        };

        pub fn iterator(tree: *Self) Iterator {
            return .{
                .tree = tree,
                .current = tree.root,
                .index = 0,
            };
        }

        pub fn iteratorAt(tree: *Self, start: Point) Iterator {
            const handle, const index = tree.findEntryOrParent(&start);
            return .{
                .tree = tree,
                .current = handle,
                .index = index,
            };
        }

        pub fn find(tree: *@This(), p: *const Point) ?*V {
            const handle = tree.findEntry(p);
            if (handle.isValid()) {
                return &tree.entries.items(.data)[handle.n].value;
            }
            return null;
        }

        /// Returns true if `handle` is not in the tree.
        pub fn isOrphaned(tree: *@This(), handle: Handle) bool {
            return !tree.entries.items(.parent)[handle.n].isValid();
        }

        pub fn isValue(tree: *@This(), handle: Handle) bool {
            const parent = tree.getParent(handle);
            return parent.isValid() and tree.nodePtr(parent).isLeaf();
        }

        pub fn removeHandle(tree: *@This(), handle: Handle, p: *const Point) void {
            var current = tree.entries.items(.parent)[handle.n];
            tree.entries.items(.parent)[handle.n] = .invalid;

            assert(tree.nodePtr(current).isLeaf());
            var address = calculateHypercubeAddress(p, tree.nodePtr(current).postfix_length);

            tree.getChildren(current)[address] = .invalid;
            tree.getChildrenLenPtr(current).* -= 1;

            if (tree.getChildrenLen(current) != 0) return;

            // Need to delete the leaf node

            var parent = tree.entries.items(.parent)[current.n];

            address = calculateHypercubeAddress(
                &tree.entries.items(.point)[current.n],
                tree.nodePtr(parent).postfix_length,
            );
            tree.getChildren(parent)[address] = .invalid;
            tree.getChildrenLenPtr(parent).* -= 1;
            tree.destroyHandle(current);

            current = parent;
            parent = tree.getParent(parent);

            while (tree.getParent(current).isValid()) {
                if (tree.getChildrenLen(current) != 1) break;
                assert(tree.getChildrenLen(current) != 0);

                const child: Handle = for (tree.getChildren(current)) |child| {
                    if (child.isValid()) {
                        break child;
                    }
                } else .invalid;

                address = calculateHypercubeAddress(
                    &tree.entries.items(.point)[current.n],
                    tree.nodePtr(parent).postfix_length,
                );
                tree.nodePtr(child).infix_length += tree.nodePtr(current).infix_length + 1;
                tree.entries.items(.parent)[child.n] = parent;
                tree.getChildren(parent)[address] = child;
                tree.destroyHandle(current);

                current = parent;
                parent = tree.getParent(parent);
            }
        }

        pub fn remove(tree: *@This(), p: *const Point) ?Handle {
            const handle = tree.findEntry(p);
            if (!handle.isValid()) return null;
            tree.removeHandle(handle, p);
            return handle;
        }

        pub const KV = struct {
            key: Point,
            value: V,
        };

        /// Appends all key/value pairs whose key falls between `min` and `max`.
        pub fn queryWindow(
            tree: *@This(),
            min: *const Point,
            max: *const Point,
            results: *std.ArrayList(Handle),
        ) Allocator.Error!void {
            if (!tree.root.isValid())
                return;

            const root = tree.nodePtr(tree.root);
            for (root.children) |child_handle| {
                if (child_handle.isValid())
                    try tree.queryNodeWindow(child_handle, min, max, results);
            }
        }

        /// Appends all key/value pairs whose key intersects the rectangle of `min` and `max`.
        /// Only works for 4 dimensional trees whose keys are assumed to be rectangles.
        /// e.g. { top_left_x, top_left_y, bottom_right_x, bottom_right_y }.
        pub fn queryWindowRect(
            tree: *@This(),
            min: [2]u32,
            max: [2]u32,
            results: *std.ArrayList(Handle),
        ) Allocator.Error!void {
            if (dims != 4) {
                @compileError("queryWindowRect only supports 4 dimensional trees");
            }

            return tree.queryWindow(
                &.{ 0, 0, min[0], min[1] },
                &.{ max[0], max[1], std.math.maxInt(u32), std.math.maxInt(u32) },
                results,
            );
        }

        fn getParent(tree: *@This(), handle: Handle) Handle {
            return tree.entries.items(.parent)[handle.n];
        }

        fn getChildrenLen(tree: *@This(), handle: Handle) u8 {
            return tree.nodePtr(handle).children_len;
        }

        fn getChildrenLenPtr(tree: *@This(), handle: Handle) *u8 {
            return &tree.nodePtr(handle).children_len;
        }

        fn getChildren(tree: *@This(), handle: Handle) *[1 << dims]Handle {
            return &tree.nodePtr(handle).children;
        }

        pub fn init(allocator: std.mem.Allocator) !@This() {
            var ret: @This() = .{
                .root = .invalid,
                .free = .invalid,
                .free_count = 0,
                .entries = .empty,
            };
            ret.root = try ret.createEntry(allocator);
            ret.entries.set(ret.root.n, .{
                .point = @splat(0),
                .parent = .invalid,
                .data = .{
                    .node = .{
                        .children = @splat(.invalid),
                        .children_len = 0,
                        .infix_length = 0,
                        .postfix_length = 31,
                    },
                },
            });
            return ret;
        }

        pub fn deinit(tree: *@This(), allocator: Allocator) void {
            tree.entries.deinit(allocator);
        }

        pub fn valuePtr(tree: *@This(), handle: Handle) *V {
            assert(handle.isValid());
            return &tree.entries.items(.data)[handle.n].value;
        }

        pub fn point(tree: *@This(), handle: Handle) Point {
            assert(handle.isValid());
            return tree.entries.items(.point)[handle.n];
        }

        pub const Header = extern struct {
            entries_len: u32,
            entries_cap: u32,
            root: Handle,
            free: Handle,
            free_count: u32,
        };

        pub const IoVecs = utils.MultiArrayListIoVecs(Entry);
        pub const IoVecsMut = utils.MultiArrayListIoVecsMut(Entry);

        pub fn iovecs(tree: *@This()) IoVecs {
            return utils.multiArrayListSliceIoVec(Entry, &tree.entries);
        }

        pub fn getHeader(tree: *@This()) Header {
            return .{
                .entries_len = @intCast(tree.entries.len),
                .entries_cap = @intCast(tree.entries.capacity),
                .root = tree.root,
                .free = tree.free,
                .free_count = tree.free_count,
            };
        }

        pub fn fromHeader(tree: *@This(), allocator: Allocator, header: Header) !IoVecsMut {
            var m = tree.entries.toMultiArrayList();

            try m.setCapacity(allocator, header.entries_cap);
            m.len = header.entries_len;
            tree.entries = m.slice();

            tree.root = header.root;
            tree.free = header.free;
            tree.free_count = header.free_count;

            return @bitCast(tree.iovecs());
        }

        pub fn nodePtr(tree: *@This(), handle: Handle) *Node {
            return &tree.entries.items(.data)[handle.n].node;
        }

        fn pointGreaterOrEqual(a: *const Point, b: *const Point) bool {
            for (a, b) |v1, v2| {
                if (v1 < v2) return false;
            }
            return true;
        }

        fn pointLessOrEqual(a: *const Point, b: *const Point) bool {
            for (a, b) |v1, v2| {
                if (v1 > v2) return false;
            }
            return true;
        }

        fn prefixGreaterOrEqual(a: *const Point, b: *const Point, postfix_length: u8) bool {
            var p1 = a.*;
            var p2 = b.*;
            for (&p1, &p2) |*v1, *v2| {
                v1.* >>= @intCast(postfix_length + 1);
                v2.* >>= @intCast(postfix_length + 1);
            }

            return pointGreaterOrEqual(&p1, &p2);
        }

        fn prefixLessOrEqual(a: *const Point, b: *const Point, postfix_length: u8) bool {
            var p1 = a.*;
            var p2 = b.*;
            for (&p1, &p2) |*v1, *v2| {
                v1.* >>= @intCast(postfix_length + 1);
                v2.* >>= @intCast(postfix_length + 1);
            }

            return pointLessOrEqual(&p1, &p2);
        }

        fn nodeInWindow(p: *const Point, postfix_length: u8, min: *const Point, max: *const Point) bool {
            return prefixGreaterOrEqual(p, min, postfix_length) and prefixLessOrEqual(p, max, postfix_length);
        }

        fn entryInWindow(p: *const Point, min: *const Point, max: *const Point) bool {
            return pointGreaterOrEqual(p, min) and pointLessOrEqual(p, max);
        }

        // TODO: Adapt this function to a range iterator
        fn queryNodeWindow(
            tree: *@This(),
            handle: Handle,
            min: *const Point,
            max: *const Point,
            results: *std.ArrayList(Handle),
        ) Allocator.Error!void {
            assert(handle.isValid());
            const p = &tree.entries.items(.point)[handle.n];
            const node = tree.nodePtr(handle);
            if (!nodeInWindow(p, node.postfix_length, min, max))
                return;

            var mask_lower: u32 = 0;
            var mask_upper: u32 = 0;

            for (p, min, max) |v, minv, maxv| {
                mask_lower = (mask_lower << 1) | @intFromBool(minv >= v);
                mask_upper = (mask_upper << 1) | @intFromBool(maxv >= v);
            }

            if (node.isLeaf()) {
                for (node.children, 0..) |child_handle, i| {
                    if (!child_handle.isValid() or ((i | mask_lower) & mask_upper) != i)
                        continue;

                    const child_point = &tree.entries.items(.point)[child_handle.n];
                    if (entryInWindow(child_point, min, max)) {
                        try results.append(child_handle);
                    }
                }
                return;
            }

            for (node.children, 0..) |child_handle, i| {
                if (!child_handle.isValid() or ((i | mask_lower) & mask_upper) != i)
                    continue;

                try tree.queryNodeWindow(child_handle, min, max, results);
            }
        }

        pub const Entry = extern struct {
            point: Point,
            parent: Handle,
            data: extern union {
                node: Node,
                value: V,
                free: Handle,
            },
        };

        pub const Node = extern struct {
            children: [1 << dims]Handle,
            children_len: u8,

            infix_length: u8,
            postfix_length: u8,

            pub fn isLeaf(node: *const Node) bool {
                return node.postfix_length == 0;
            }
        };

        pub const Point = [dims]u32;

        pub const Handle = packed struct {
            n: u32,

            fn toAscii(h: Handle) u8 {
                return @intCast(h.n + 'A');
            }

            pub fn from(n: u32) Handle {
                assert(n != std.math.maxInt(u32));
                return .{ .n = n };
            }

            pub fn isValid(handle: Handle) bool {
                return handle != invalid;
            }

            pub const invalid: Handle = .{ .n = std.math.maxInt(u32) };

            pub fn format(
                handle: Handle,
                comptime _: []const u8,
                _: std.fmt.FormatOptions,
                writer: anytype,
            ) !void {
                if (handle.isValid()) {
                    try writer.print("{d}", .{handle.n});
                } else {
                    try writer.writeAll("none");
                }
            }
        };
    };
}

test "Basics" {
    var tree: PhTree([*:0]const u8, 2) = try .init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);

    const kv1 = try tree.createHandle(std.testing.allocator, &.{ 1, 1 }, "1, 1! :D");
    const old_kv = try tree.insert(std.testing.allocator, &.{ 1, 1 }, kv1);
    try std.testing.expect(!old_kv.isValid());
    const value = tree.entries.items(.data)[kv1.n].value;
    try std.testing.expectEqualStrings("1, 1! :D", std.mem.span(value));

    const v = tree.find(&.{ 1, 1 }).?.*;
    try std.testing.expectEqualStrings("1, 1! :D", std.mem.span(v));

    const removed = tree.remove(&.{ 1, 1 }).?;
    const removed_value = tree.entries.items(.data)[removed.n].value;
    try std.testing.expectEqualStrings("1, 1! :D", std.mem.span(removed_value));

    try std.testing.expectEqual(null, tree.find(&.{ 1, 1 }));
}

fn fuzz(_: void, input: []const u8) anyerror!void {
    // const file = try std.fs.cwd().createFile("out.txt", .{ .truncate = true });
    // defer file.close();

    var tree: PhTree(u32, 4) = try .init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);

    const KV = extern struct {
        p: PhTree(u32, 4).Point,
        value: u32,
    };

    const len = input.len - input.len % @sizeOf(KV);
    // try file.writeAll(input[0..len]);
    const slice = std.mem.bytesAsSlice(KV, input[0..len]);
    for (slice) |kv| {
        const entry = try tree.createHandle(std.testing.allocator, &kv.p, kv.value);
        _ = try tree.insert(std.testing.allocator, &kv.p, entry);
        const value = tree.find(&kv.p).?;
        try std.testing.expectEqual(kv.value, value.*);
    }

    for (slice) |kv| {
        _ = tree.remove(&kv.p);
        try std.testing.expectEqual(null, tree.find(&kv.p));
    }
}

test "Fuzz phtree" {
    try std.testing.fuzz({}, fuzz, .{});
}

test "phtree crash" {
    const points = [_]PhTree(u32, 2).Point{
        .{ 0, 0 },
        .{ 0, 1 },
        .{ 0, 2 },
    };

    var tree: PhTree(u32, 2) = try .init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);

    for (&points) |p| {
        _, const ptr, _ = try tree.getOrPut(std.testing.allocator, &p);
        ptr.* = p[1];
    }
    const removed = tree.remove(&points[0]).?;
    const removed_value = tree.entries.items(.data)[removed.n].value;
    try std.testing.expectEqual(0, removed_value);

    var iter = tree.iterator();
    while (iter.next()) |_| {}
}
