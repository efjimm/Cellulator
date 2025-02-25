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
        values: std.MultiArrayList(Value).Slice,
        nodes: std.MultiArrayList(Node).Slice,

        pub const Value = extern struct {
            point: Point,
            parent: Handle,
            value: V,
        };

        pub const Node = extern struct {
            point: Point,
            parent: Handle,
            node: InternalNode,
        };

        pub const InternalNode = extern struct {
            children: [1 << dims]Handle,
            children_len: u8,

            infix_length: u8,
            postfix_length: u8,

            pub fn isLeaf(node: *const InternalNode) bool {
                return node.postfix_length == 0;
            }
        };

        pub const Point = [dims]u32;

        const Handle = packed struct {
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

        pub const ValueHandle = packed struct {
            n: u32,

            fn toAscii(h: ValueHandle) u8 {
                return @intCast(h.n + 'A');
            }

            pub fn from(n: u32) ValueHandle {
                assert(n != std.math.maxInt(u32));
                return .{ .n = n };
            }

            pub fn isValid(handle: ValueHandle) bool {
                return handle != invalid;
            }

            pub const invalid: ValueHandle = .{ .n = std.math.maxInt(u32) };

            pub fn format(
                handle: ValueHandle,
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

        pub fn createValue(
            tree: *@This(),
            allocator: Allocator,
            p: *const Point,
            value: V,
        ) Allocator.Error!ValueHandle {
            var m = tree.values.toMultiArrayList();
            try m.ensureUnusedCapacity(allocator, 1);
            tree.values = m.toOwnedSlice();
            return tree.createValueAssumeCapacity(p, value);
        }

        pub fn createValueAssumeCapacity(tree: *@This(), p: *const Point, value: V) ValueHandle {
            assert(tree.values.capacity > tree.values.len);
            const handle: ValueHandle = .from(@intCast(tree.values.len));
            tree.values.len += 1;

            tree.values.set(handle.n, .{
                .point = p.*,
                .parent = .invalid,
                .value = value,
            });
            return handle;
        }

        fn createEntry(tree: *@This(), allocator: Allocator) Allocator.Error!Handle {
            if (!tree.free.isValid()) {
                var m = tree.nodes.toMultiArrayList();
                defer tree.nodes = m.slice();

                try m.ensureUnusedCapacity(allocator, 1);
            }

            return tree.createEntryAssumeCapacity();
        }

        fn createEntryAssumeCapacity(tree: *@This()) Handle {
            if (tree.free.isValid()) {
                const ret = tree.free;
                tree.free = tree.getNodeParent(ret).*;
                assert(!tree.free.isValid() or tree.free.n < tree.nodes.len);
                tree.free_count -= 1;
                return ret;
            }

            assert(tree.nodes.capacity > tree.nodes.len);
            const handle: Handle = .from(@intCast(tree.nodes.len));
            tree.nodes.len += 1;
            return handle;
        }

        pub fn destroyValue(tree: *@This(), handle: ValueHandle) void {
            // TODO: Implement freelist for values
            tree.getValueParent(handle).* = .invalid;
            if (handle.n == tree.values.len - 1) {
                tree.values.len -= 1;
            }
        }

        fn destroyHandle(tree: *@This(), handle: Handle) void {
            tree.getNodeParent(handle).* = .invalid;
            if (handle.n == tree.nodes.len - 1) {
                tree.nodes.len -= 1;
            } else {
                tree.nodes.set(handle.n, .{
                    .point = undefined,
                    .parent = tree.free,
                    .node = undefined,
                });
                tree.free = handle;
                tree.free_count += 1;
            }
        }

        fn addNodeKv(
            tree: *@This(),
            handle: Handle,
            p: *const Point,
            kv_handle: ValueHandle,
        ) ValueHandle {
            const node = tree.nodePtr(handle);
            assert(node.isLeaf());

            const address = calculateHypercubeAddress(p, 0);
            tree.getValueParent(kv_handle).* = handle;

            if (!node.children[address].isValid()) {
                node.children_len += 1;
            }

            const old_child: ValueHandle = @bitCast(node.children[address]);
            node.children[address] = @bitCast(kv_handle);

            return old_child;
        }

        fn createNodeAssumeCapacity(
            tree: *@This(),
            parent: Handle,
            infix_length: u8,
            postfix_length: u8,
            p: *const Point,
            kv: ValueHandle,
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

            tree.nodes.set(handle.n, .{
                .point = new_point,
                .parent = parent,
                .node = .{
                    .children = @splat(.invalid),
                    .children_len = 0,
                    .infix_length = infix_length,
                    .postfix_length = postfix_length,
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
            kv: ValueHandle,
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
            const child_point = tree.getNodePoint(child_handle);

            const parent_address = calculateHypercubeAddress(p, node.postfix_length);
            assert(node.children[parent_address] == child_handle);
            node.children[parent_address] = new_handle;

            const new_node_address = calculateHypercubeAddress(child_point, new_node.postfix_length);
            new_node.children[new_node_address] = child_handle;
            new_node.children_len += 1;

            tree.getNodeParent(child_handle).* = new_handle;

            const child_node = tree.nodePtr(child_handle);
            child_node.infix_length = (new_node.postfix_length - child_node.postfix_length) - 1;

            return new_handle;
        }

        fn handleNodeCollision(
            tree: *@This(),
            handle: Handle,
            child_handle: Handle,
            p: *const Point,
            kv: ValueHandle,
        ) struct {
            /// Handle of the newly inserted node
            Handle,
            /// Handle of any old KV that was removed
            ValueHandle,
        } {
            const child_node = tree.nodePtr(child_handle);
            if (child_node.isLeaf()) {
                if (child_node.infix_length > 0) {
                    const child_point = tree.getNodePoint(child_handle);
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
                const child_point = tree.getNodePoint(child_handle);
                const conflicting_bits = numberOfDivergingBits(p, child_point);
                if (conflicting_bits > child_node.postfix_length + 1) {
                    const new_handle = tree.insertNodeSplit(handle, child_handle, p, conflicting_bits);
                    return .{ new_handle, .invalid };
                }
            }

            return .{ child_handle, .invalid };
        }

        fn addNode(tree: *@This(), handle: Handle, p: *const Point, kv: ValueHandle) struct {
            Handle,
            ValueHandle,
        } {
            const node = tree.nodePtr(handle);
            const address = calculateHypercubeAddress(p, node.postfix_length);
            const child_node, const added = tree.tryAddNode(handle, address, p, kv);

            if (added) {
                return .{ child_node, .invalid };
            }

            return tree.handleNodeCollision(handle, child_node, p, kv);
        }

        pub fn ensureUnusedCapacity(tree: *@This(), allocator: Allocator, n: u32) Allocator.Error!void {
            const count = std.math.mul(u32, n, 2) catch return error.OutOfMemory;
            if (tree.nodes.len + count > tree.nodes.capacity) {
                var m = tree.nodes.toMultiArrayList();
                try m.setCapacity(allocator, m.len * 2 + count);
                tree.nodes = m.slice();
            }

            if (tree.values.len + n > tree.values.capacity) {
                var m = tree.values.toMultiArrayList();
                try m.setCapacity(allocator, m.len * 2 + count);
                tree.values = m.slice();
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
            ValueHandle,
        } {
            try tree.ensureUnusedCapacity(allocator, 1);
            return tree.getOrPutAssumeCapacity(p);
        }

        pub fn getPoint(tree: *const @This(), handle: ValueHandle) *Point {
            return &tree.values.items(.point)[handle.n];
        }

        pub fn getValue(tree: *const @This(), handle: ValueHandle) *V {
            return &tree.values.items(.value)[handle.n];
        }

        fn getNodePoint(tree: *const @This(), handle: Handle) *Point {
            return &tree.nodes.items(.point)[handle.n];
        }

        fn getNodeParent(tree: *const @This(), handle: Handle) *Handle {
            return &tree.nodes.items(.parent)[handle.n];
        }

        fn getValueParent(tree: *const @This(), handle: ValueHandle) *Handle {
            return &tree.values.items(.parent)[handle.n];
        }

        pub fn getOrPutAssumeCapacity(tree: *@This(), p: *const Point) struct {
            /// True if this point already existed in the tree
            bool,
            /// Pointer to the value associated with `p`. If no entry previously existed for `p`,
            /// the value pointed to is undefined.
            *V,
            /// Handle of the `Entry` associated with `p`.
            ValueHandle,
        } {
            // TODO: This lookup is redundant when the value does not exist
            const h = tree.findEntry(p);
            if (h.isValid()) {
                return .{ true, tree.getValue(h), h };
            }

            const handle = tree.createValueAssumeCapacity(p, undefined);
            const removed_kv = tree.insertAssumeCapacity(p, handle);
            assert(!removed_kv.isValid());

            const value_ptr = tree.getValue(handle);
            return .{ false, value_ptr, handle };
        }

        pub fn insert(
            tree: *@This(),
            allocator: Allocator,
            p: *const Point,
            kv: ValueHandle,
        ) Allocator.Error!ValueHandle {
            try tree.ensureUnusedCapacity(allocator, 1);
            return tree.insertAssumeCapacity(p, kv);
        }

        fn hasCapacity(tree: *@This(), n: u32) bool {
            const unused_entries = tree.nodes.capacity - tree.nodes.len;
            return n <= tree.free_count + unused_entries;
        }

        pub fn insertAssumeCapacity(tree: *@This(), p: *const Point, kv: ValueHandle) ValueHandle {
            // assert(tree.hasCapacity(2));
            assert(tree.root.isValid());
            var current_node = tree.root;
            var removed_kv: ValueHandle = .invalid;
            while (!tree.nodePtr(current_node).isLeaf()) {
                // If `addNode` adds a value it must be the last call to `addNode`.
                assert(!removed_kv.isValid());
                current_node, removed_kv = tree.addNode(current_node, p, kv);
            }

            const node = tree.nodePtr(current_node);
            const address = calculateHypercubeAddress(p, node.postfix_length);
            assert(node.children[address].n == kv.n);
            if (removed_kv.isValid())
                tree.getValueParent(removed_kv).* = .invalid;
            return removed_kv;
        }

        pub fn clearRetainingCapacity(tree: *@This()) void {
            tree.nodes.len = 1;
            tree.root = .from(0);
            tree.free = .invalid;
            tree.nodes.set(0, .{
                .point = @splat(0),
                .parent = .invalid,

                .node = .{
                    .children = @splat(.invalid),
                    .children_len = 0,
                    .infix_length = 0,
                    .postfix_length = 31,
                },
            });
        }

        fn printNode(tree: *@This(), handle: Handle) void {
            const entry = tree.nodes.get(handle.n);
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
                        const child_entry = tree.nodes.get(child.n);
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

        pub fn largestDim(tree: *@This(), dim: u8) ValueHandle {
            var largest: ValueHandle = .invalid;
            for (tree.values.items(.point), 0..) |p, i| {
                const handle: ValueHandle = .from(@intCast(i));
                if ((!largest.isValid() or tree.getPoint(largest)[dim] < p[dim]))
                    largest = handle;
            }
            return largest;
        }

        pub fn findEntry(tree: *@This(), p: *const Point) ValueHandle {
            var h = tree.root;
            while (h.isValid()) {
                const node = tree.nodePtr(h);
                h = node.children[calculateHypercubeAddress(p, node.postfix_length)];
                if (node.isLeaf()) {
                    const value: ValueHandle = .{ .n = h.n };
                    if (value.isValid()) {
                        const p2 = tree.getPoint(value);
                        return if (std.mem.eql(u32, p, p2)) value else .invalid;
                    }
                    return value;
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

            pub fn next(iter: *Iterator) ?ValueHandle {
                const node = iter.tree.nodePtr(iter.current);
                if (node.isLeaf()) {
                    for (node.children[iter.index..], iter.index..) |child_handle, i| {
                        if (!child_handle.isValid()) continue;

                        iter.index = @intCast(i + 1);
                        return .from(child_handle.n);
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
                return tree.getValue(handle);
            }
            return null;
        }

        /// Returns true if `handle` is not in the tree.
        pub fn isOrphaned(tree: *@This(), handle: ValueHandle) bool {
            return !tree.getValueParent(handle).isValid();
        }

        pub fn removeHandle(tree: *@This(), handle: ValueHandle, p: *const Point) void {
            var current = tree.getValueParent(handle).*;
            tree.getValueParent(handle).* = .invalid;

            assert(tree.nodePtr(current).isLeaf());
            var address = calculateHypercubeAddress(p, tree.nodePtr(current).postfix_length);

            tree.getChildren(current)[address] = .invalid;
            tree.getChildrenLenPtr(current).* -= 1;

            if (tree.getChildrenLen(current) != 0) return;

            // Need to delete the leaf node

            var parent = tree.getNodeParent(current).*;

            address = calculateHypercubeAddress(
                tree.getNodePoint(current),
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
                    tree.getNodePoint(current),
                    tree.nodePtr(parent).postfix_length,
                );
                tree.nodePtr(child).infix_length += tree.nodePtr(current).infix_length + 1;
                tree.getNodeParent(child).* = parent;
                tree.getChildren(parent)[address] = child;
                tree.destroyHandle(current);

                current = parent;
                parent = tree.getParent(parent);
            }
        }

        pub fn remove(tree: *@This(), p: *const Point) ?ValueHandle {
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
            results: *std.ArrayList(ValueHandle),
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
            results: *std.ArrayList(ValueHandle),
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
            return tree.nodes.items(.parent)[handle.n];
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
                .nodes = .empty,
                .values = .empty,
            };
            ret.root = try ret.createEntry(allocator);
            ret.nodes.set(ret.root.n, .{
                .point = @splat(0),
                .parent = .invalid,
                .node = .{
                    .children = @splat(.invalid),
                    .children_len = 0,
                    .infix_length = 0,
                    .postfix_length = 31,
                },
            });
            return ret;
        }

        pub fn deinit(tree: *@This(), allocator: Allocator) void {
            tree.nodes.deinit(allocator);
            tree.values.deinit(allocator);
        }

        pub const Header = extern struct {
            nodes_len: u32,
            nodes_cap: u32,
            values_len: u32,
            values_cap: u32,
            root: Handle,
            free: Handle,
            free_count: u32,
        };

        pub const IoVecs = blk: {
            const nodes = @typeInfo(Node).@"struct".fields.len;
            const values = @typeInfo(Value).@"struct".fields.len;
            break :blk [nodes + values]std.posix.iovec_const;
        };

        pub const IoVecsMut = blk: {
            const nodes = @typeInfo(Node).@"struct".fields.len;
            const values = @typeInfo(Value).@"struct".fields.len;
            break :blk [nodes + values]std.posix.iovec;
        };

        pub fn iovecs(tree: *@This()) IoVecs {
            return utils.multiArrayListSliceIoVec(Node, &tree.nodes) ++
                utils.multiArrayListSliceIoVec(Value, &tree.values);
        }

        pub fn getHeader(tree: *@This()) Header {
            return .{
                .nodes_len = @intCast(tree.nodes.len),
                .nodes_cap = @intCast(tree.nodes.capacity),
                .values_len = @intCast(tree.values.len),
                .values_cap = @intCast(tree.values.capacity),
                .root = tree.root,
                .free = tree.free,
                .free_count = tree.free_count,
            };
        }

        pub fn fromHeader(tree: *@This(), allocator: Allocator, header: Header) !IoVecsMut {
            var nodes = tree.nodes.toMultiArrayList();
            try nodes.setCapacity(allocator, header.nodes_cap);
            errdefer nodes.deinit(allocator);

            var values = tree.values.toMultiArrayList();
            try values.setCapacity(allocator, header.values_cap);

            nodes.len = header.nodes_len;
            tree.nodes = nodes.slice();

            values.len = header.values_len;
            tree.values = values.slice();

            tree.root = header.root;
            tree.free = header.free;
            tree.free_count = header.free_count;

            return @bitCast(tree.iovecs());
        }

        fn nodePtr(tree: *@This(), handle: Handle) *InternalNode {
            return &tree.nodes.items(.node)[handle.n];
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
            results: *std.ArrayList(ValueHandle),
        ) Allocator.Error!void {
            assert(handle.isValid());
            const p = tree.getNodePoint(handle);
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
                for (node.children, 0..) |uncasted_handle, i| {
                    const child_handle: ValueHandle = .{ .n = uncasted_handle.n };
                    if (!child_handle.isValid() or ((i | mask_lower) & mask_upper) != i)
                        continue;

                    const child_point = tree.getPoint(child_handle);
                    if (entryInWindow(child_point, min, max)) {
                        try results.append(.from(child_handle.n));
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
    };
}

test "Basics" {
    var tree: PhTree([*:0]const u8, 2) = try .init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);

    const kv1 = try tree.createValue(std.testing.allocator, &.{ 1, 1 }, "1, 1! :D");
    const old_kv = try tree.insert(std.testing.allocator, &.{ 1, 1 }, kv1);
    try std.testing.expect(!old_kv.isValid());
    const value = tree.getValue(kv1).*;
    try std.testing.expectEqualStrings("1, 1! :D", std.mem.span(value));

    const v = tree.find(&.{ 1, 1 }).?.*;
    try std.testing.expectEqualStrings("1, 1! :D", std.mem.span(v));

    const removed = tree.remove(&.{ 1, 1 }).?;
    const removed_value = tree.getValue(removed).*;
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
        const entry = try tree.createValue(std.testing.allocator, &kv.p, kv.value);
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
    const expect = std.testing.expect;
    var tree: PhTree(u32, 1) = try .init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);

    try tree.ensureUnusedCapacity(std.testing.allocator, 2);
    const found, const v1, _ = tree.getOrPutAssumeCapacity(&.{2});
    try expect(!found);
    v1.* = 69;

    try expect(tree.nodes.len == 2);
    try expect(tree.values.len == 1);
    _ = tree.findEntry(&.{3});
}
