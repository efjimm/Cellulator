// TODO: Discover and assert more invariants to improve robustness
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const utils = @import("utils.zig");

const runtime_safety = switch (@import("builtin").mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

pub fn PhTree(comptime V: type, comptime dims: usize, comptime HandleInt: type) type {
    return struct {
        root: HandleUnion,
        free: Handle,
        free_count: Handle.Int,
        values: std.MultiArrayList(Value).Slice,
        nodes: std.MultiArrayList(Node).Slice,

        pub const Value = extern struct {
            point: Point,
            parent: Handle,
            value: V,
        };

        pub const Node = extern struct {
            // TODO: Get rid of this
            point: Point,
            parent: Handle,
            node: InternalNode,
        };

        pub const InternalNode = extern struct {
            children: [1 << dims]Handle,

            /// Integers in extern structs must be at least 8 bits, with <= 3 dims the extra bits
            /// are unused.
            child_flags: FlagInt,

            // TODO: Get rid of this
            children_len: u8,

            // TODO: Get rid of this
            infix_length: u8,
            /// Number of bits following the bit with which this node is concerned. This is the
            /// same as the zero-based index of the bit.
            postfix_length: u8,

            pub const FlagInt = std.meta.Int(.unsigned, @max(1 << dims, 8));
            pub const Tag = enum(u8) { leaf, branch };

            pub fn childTag(node: *const InternalNode, index: u8) Tag {
                const mask = @as(FlagInt, 1) << @intCast(index);
                return @enumFromInt((node.child_flags & mask) >> @intCast(index));
            }

            pub fn setChildTag(node: *InternalNode, index: u8, comptime tag: Tag) void {
                const mask = @as(FlagInt, 1) << @intCast(index);
                switch (tag) {
                    .leaf => node.child_flags &= ~mask,
                    .branch => node.child_flags |= mask,
                }
            }

            pub fn setChild(node: *InternalNode, address: u8, child: HandleUnion) void {
                switch (child) {
                    .leaf => |handle| {
                        node.children[address] = @bitCast(handle);
                        node.setChildTag(address, .leaf);
                    },
                    .branch => |handle| {
                        node.children[address] = handle;
                        node.setChildTag(address, .branch);
                    },
                }
            }

            pub fn getChild(node: *InternalNode, address: u8) HandleUnion {
                return switch (node.childTag(address)) {
                    .leaf => .{ .leaf = .from(node.children[address].n) },
                    .branch => .{ .branch = node.children[address] },
                };
            }
        };

        pub const Point = [dims]u32;

        const Handle = packed struct {
            n: Int,

            const Int = HandleInt;

            pub fn from(n: Int) Handle {
                assert(n != std.math.maxInt(Int));
                return .{ .n = n };
            }

            pub fn isValid(handle: Handle) bool {
                return handle != invalid;
            }

            pub const invalid: Handle = .{ .n = std.math.maxInt(Int) };

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
            n: Int,

            pub const Int = Handle.Int;

            pub fn from(n: Int) ValueHandle {
                assert(n != std.math.maxInt(Int));
                return .{ .n = n };
            }

            pub fn isValid(handle: ValueHandle) bool {
                return handle != invalid;
            }

            pub const invalid: ValueHandle = .{ .n = std.math.maxInt(Int) };

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

        fn createNodeAssumeCapacity(
            tree: *@This(),
            parent: Handle,
            infix_length: u8,
            postfix_length: u8,
            p: *const Point,
        ) Handle {
            const handle = tree.createEntryAssumeCapacity();
            assert(handle.isValid());

            const key_mask = std.math.shl(u32, std.math.maxInt(u32), postfix_length + 1);
            var new_point = p.*;
            for (&new_point) |*v| {
                v.* &= key_mask;
                v.* |= @as(u32, 1) << @intCast(postfix_length);
            }

            tree.nodes.set(handle.n, .{
                .point = new_point,
                .parent = parent,
                .node = .{
                    .children = @splat(.invalid),
                    .child_flags = 0,
                    .children_len = 0,
                    .infix_length = infix_length,
                    .postfix_length = postfix_length,
                },
            });

            return handle;
        }

        fn tryAddNode(
            tree: *@This(),
            handle: Handle,
            address: u8,
            kv: ValueHandle,
        ) struct { Handle, bool } {
            const node = tree.nodePtr(handle);
            var added = false;
            if (!node.children[address].isValid()) {
                node.children[address] = @bitCast(kv);
                node.setChildTag(address, .leaf);
                node.children_len += 1;
                added = true;
            }

            return .{ node.children[address], added };
        }

        /// Returns the 1-based index of the bit at which the two points diverge, or zero if the
        /// points are the same.
        fn firstDifferingBit(p1: *const Point, p2: *const Point) u8 {
            var diff: u32 = 0;
            for (p1, p2) |v1, v2| {
                diff |= v1 ^ v2;
            }
            return 32 - @clz(diff);
        }

        pub fn ensureUnusedCapacity(tree: *@This(), allocator: Allocator, n: Handle.Int) Allocator.Error!void {
            const count = std.math.mul(Handle.Int, n, 2) catch return error.OutOfMemory;
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

        pub fn insertAssumeCapacity(tree: *@This(), _: *const Point, kv: ValueHandle) ValueHandle {
            const p = tree.getPoint(kv);

            if (!tree.root.isValid()) {
                tree.root = .{ .leaf = kv };
                return .invalid;
            }

            if (tree.root == .leaf) {
                const root = tree.root.leaf;
                const root_point = tree.getPoint(root);
                const root_conflicting_bit = firstDifferingBit(p, root_point);

                // The points are the same
                if (root_conflicting_bit == 0) {
                    tree.root = .{ .leaf = kv };
                    return root;
                }

                // Need to insert a new branch node above the current root node.
                const new_root = tree.createNodeAssumeCapacity(
                    .invalid,
                    32 - root_conflicting_bit,
                    root_conflicting_bit - 1,
                    p,
                );
                const node = tree.nodePtr(new_root);
                const address = calculateHypercubeAddress(p, node.postfix_length);
                node.setChild(address, .{ .leaf = kv });
                tree.getValueParent(kv).* = new_root;

                const root_address = calculateHypercubeAddress(
                    root_point,
                    node.postfix_length,
                );
                assert(address != root_address);
                node.setChild(root_address, .{ .leaf = root });
                node.children_len = 2;

                tree.getValueParent(root).* = new_root;
                tree.root = .{ .branch = new_root };
                return .invalid;
            }

            const root = tree.root.branch;
            const root_point = tree.getNodePoint(root);
            const root_conflicting_bit = firstDifferingBit(p, root_point);

            const root_node = tree.nodePtr(root);
            if (root_conflicting_bit > root_node.postfix_length + 1) {
                // Need to insert a new branch node above the current root node.
                const new_root = tree.createNodeAssumeCapacity(
                    .invalid,
                    32 - root_conflicting_bit,
                    root_conflicting_bit - 1,
                    p,
                );
                const node = tree.nodePtr(new_root);
                const address = calculateHypercubeAddress(p, node.postfix_length);
                node.setChildTag(address, .leaf);
                node.children[address] = @bitCast(kv);
                tree.getValueParent(kv).* = new_root;

                const root_address = calculateHypercubeAddress(
                    tree.getNodePoint(root),
                    node.postfix_length,
                );
                assert(address != root_address);
                node.setChildTag(root_address, .branch);
                node.children[root_address] = root;
                node.children_len = 2;

                tree.getNodeParent(root).* = new_root;
                root_node.infix_length = (node.postfix_length - root_node.postfix_length) - 1;
                tree.root = .{ .branch = new_root };
                return .invalid;
            }

            var handle = root;
            // PH trees cannot be deeper than the bit length of their keys.
            const max_depth = @typeInfo(@typeInfo(Point).array.child).int.bits;
            var last_pl: u8 = max_depth;
            for (0..max_depth) |_| {
                const node = tree.nodePtr(handle);
                assert(last_pl > node.postfix_length);
                last_pl = node.postfix_length;
                const address = calculateHypercubeAddress(p, node.postfix_length);

                const child_handle = node.children[address];
                if (!child_handle.isValid()) {
                    tree.getValueParent(kv).* = handle;

                    node.children[address] = @bitCast(kv);
                    node.setChildTag(address, .leaf);
                    node.children_len += 1;

                    return .invalid;
                }

                if (node.childTag(address) == .leaf) {
                    const child: ValueHandle = @bitCast(child_handle);
                    const child_point = tree.getPoint(child);
                    assert(calculateHypercubeAddress(child_point, node.postfix_length) == address);
                    const conflicting_bit = firstDifferingBit(p, child_point);
                    if (conflicting_bit == 0) {
                        tree.getValueParent(child).* = .invalid;
                        node.children[address] = @bitCast(kv);
                        tree.getValueParent(kv).* = handle;
                        return child;
                    }
                    assert(conflicting_bit <= node.postfix_length);
                    const new_handle = tree.createNodeAssumeCapacity(
                        handle,
                        node.postfix_length - conflicting_bit,
                        conflicting_bit - 1,
                        p,
                    );
                    const new_node = tree.nodePtr(new_handle);
                    node.setChild(address, .{ .branch = new_handle });

                    const old_child_address = calculateHypercubeAddress(child_point, new_node.postfix_length);
                    const new_child_address = calculateHypercubeAddress(p, new_node.postfix_length);
                    assert(old_child_address != new_child_address);
                    new_node.setChild(old_child_address, .{ .leaf = child });
                    new_node.setChild(new_child_address, .{ .leaf = kv });
                    tree.getValueParent(child).* = new_handle;
                    tree.getValueParent(kv).* = new_handle;
                    new_node.children_len = 2;
                    return .invalid;
                }

                // Both nodes are branch nodes
                assert(child_handle.n != handle.n);

                const child_node = tree.nodePtr(child_handle);

                // TODO: Couldn't we derive infix length by comparing parent and child's postfix length?
                if (child_node.infix_length == 0) {
                    handle = child_handle;
                    continue;
                }

                // There is a bit gap between the parent and child so the new node may need to
                // be inserted between the parent and child.

                const child_point = tree.getNodePoint(child_handle);
                const conflicting_bit = firstDifferingBit(p, child_point);
                if (conflicting_bit <= child_node.postfix_length + 1) {
                    handle = child_handle;
                    continue;
                }

                assert(conflicting_bit <= node.postfix_length);
                const new_handle = tree.createNodeAssumeCapacity(
                    handle,
                    node.postfix_length - conflicting_bit,
                    conflicting_bit - 1,
                    p,
                );
                const new_node = tree.nodePtr(new_handle);

                node.children[address] = new_handle;

                const new_node_address = calculateHypercubeAddress(child_point, new_node.postfix_length);
                new_node.setChild(new_node_address, .{ .branch = child_handle });
                new_node.children_len += 1;

                tree.getNodeParent(child_handle).* = new_handle;

                child_node.infix_length = (new_node.postfix_length - child_node.postfix_length) - 1;
                handle = new_handle;
            }
            unreachable;
        }

        pub fn clearRetainingCapacity(tree: *@This()) void {
            tree.nodes.len = 0;
            tree.values.len = 0;

            tree.root = .{ .leaf = .invalid };
            tree.free = .invalid;
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
                            @as(u8, @intCast(child_entry.parent.n + 'A')),
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
            if (!tree.root.isValid()) return .invalid;
            if (tree.root == .leaf) {
                const value = tree.root.leaf;
                const p2 = tree.getPoint(value);
                return if (std.mem.eql(u32, p, p2)) value else .invalid;
            }

            var h = tree.root.branch;
            const max_depth = @typeInfo(@typeInfo(Point).array.child).int.bits;
            for (0..max_depth) |_| {
                if (!h.isValid()) return .invalid;

                const node = tree.nodePtr(h);
                const address = calculateHypercubeAddress(p, node.postfix_length);
                assert(node.children[address].n != h.n or node.childTag(address) == .leaf);
                h = node.children[address];
                switch (node.childTag(address)) {
                    .leaf => {
                        const value: ValueHandle = .{ .n = h.n };
                        if (value.isValid()) {
                            const p2 = tree.getPoint(value);
                            return if (std.mem.eql(u32, p, p2)) value else .invalid;
                        }
                        return value;
                    },
                    .branch => {},
                }
            }

            unreachable;
        }

        pub const HandleUnion = union(InternalNode.Tag) {
            leaf: ValueHandle,
            branch: Handle,

            pub fn isValid(h: HandleUnion) bool {
                return switch (h) {
                    inline else => |pl| pl.isValid(),
                };
            }

            pub const invalid: HandleUnion = .{ .leaf = .invalid };
        };

        pub fn findParent(tree: *@This(), p: *const Point) struct { ValueHandle, Handle } {
            if (!tree.root.isValid() or tree.root == .leaf)
                return .{ tree.root.leaf, .invalid };

            var h = tree.root.branch;
            var parent: Handle = .invalid;
            var address: u8 = 0;
            while (h.isValid()) {
                const node = tree.nodePtr(h);
                parent = h;
                address = calculateHypercubeAddress(p, node.postfix_length);
                switch (node.childTag(address)) {
                    .leaf => return .{
                        @bitCast(node.children[address]),
                        h,
                    },
                    .branch => h = node.children[address],
                }
            }

            assert(parent.isValid());
            return .{ .invalid, parent };
        }

        const Self = @This();

        pub const Iterator = struct {
            tree: *Self,
            current: HandleUnion,
            index: u8,

            pub fn next(iter: *Iterator) ?ValueHandle {
                if (!iter.current.isValid()) return null;

                const tree = iter.tree;
                switch (iter.current) {
                    .leaf => |handle| {
                        const parent = tree.getValueParent(handle).*;

                        iter.current = .{ .branch = parent };
                        if (parent.isValid()) {
                            const node = tree.nodePtr(parent);
                            const p = tree.getPoint(handle);
                            iter.index = 1 + calculateHypercubeAddress(p, node.postfix_length);
                        }
                        return handle;
                    },
                    .branch => |handle| {
                        const node = tree.nodePtr(handle);
                        for (node.children[iter.index..], iter.index..) |child_handle, i| {
                            if (!child_handle.isValid()) continue;
                            iter.current = switch (node.childTag(@intCast(i))) {
                                .leaf => .{ .leaf = @bitCast(child_handle) },
                                .branch => .{ .branch = child_handle },
                            };
                            iter.index = 0;
                            return iter.next();
                        }

                        const parent = tree.getNodeParent(handle).*;
                        if (!parent.isValid()) {
                            iter.current = .{ .leaf = .invalid };
                            return null;
                        }

                        const parent_node = tree.nodePtr(parent);
                        const child_point = tree.getNodePoint(handle);
                        iter.index = 1 + calculateHypercubeAddress(child_point, parent_node.postfix_length);
                        iter.current = .{ .branch = parent };
                        return iter.next();
                    },
                }
                comptime unreachable;
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
            const value, const parent = tree.findParent(&start);

            return .{
                .tree = tree,
                .current = switch (value.isValid()) {
                    false => .{ .branch = parent },
                    true => .{ .leaf = value },
                },
                .index = switch (parent.isValid()) {
                    false => 0,
                    true => 1 + calculateHypercubeAddress(&start, tree.nodePtr(parent).postfix_length),
                },
            };
        }

        /// Return a pointer to the value associated with `p` if it exists, otherwise returns
        /// `null`. This function should not be used when `@sizeOf(V) == 0`, as the
        /// `std.MultiArrayList` implementation causes the result of this function to be
        /// undefined.
        pub fn find(tree: *@This(), p: *const Point) ?*V {
            const handle = tree.findEntry(p);
            if (handle.isValid()) {
                return tree.getValue(handle);
            }
            return null;
        }

        // TODO: Remove redundant point parameter
        pub fn removeHandle(tree: *@This(), handle: ValueHandle, p: *const Point) void {
            const parent = tree.getValueParent(handle).*;
            tree.getValueParent(handle).* = .invalid;
            if (!parent.isValid()) {
                tree.root = .invalid;
                return;
            }

            const parent_node = tree.nodePtr(parent);
            // There should never be any branch nodes in the tree that have < 2 children
            assert(parent_node.children_len >= 2);
            // Remove the value from its parent
            const address = calculateHypercubeAddress(p, parent_node.postfix_length);
            parent_node.setChild(address, .invalid);
            parent_node.children_len -= 1;

            if (parent_node.children_len >= 2) return;

            const reparented_node =
                for (parent_node.children, 0..) |child, i| {
                    if (child.isValid()) {
                        break parent_node.getChild(@intCast(i));
                    }
                } else unreachable;

            const grandparent = tree.getNodeParent(parent).*;
            if (!grandparent.isValid()) {
                tree.destroyHandle(parent);
                switch (reparented_node) {
                    .leaf => |h| tree.getValueParent(h).* = .invalid,
                    .branch => |h| {
                        tree.getNodeParent(h).* = .invalid;
                        tree.nodePtr(h).infix_length = 31 - tree.nodePtr(h).postfix_length;
                    },
                }
                tree.root = reparented_node;
                return;
            }

            const grandparent_node = tree.nodePtr(grandparent);
            const address2 = calculateHypercubeAddress(
                p,
                grandparent_node.postfix_length,
            );
            assert(address2 == calculateHypercubeAddress(
                tree.getNodePoint(parent),
                grandparent_node.postfix_length,
            ));
            assert(grandparent_node.getChild(address2).branch == parent);
            grandparent_node.setChild(address2, reparented_node);
            tree.destroyHandle(parent);
            switch (reparented_node) {
                .leaf => |h| tree.getValueParent(h).* = grandparent,
                .branch => |h| {
                    tree.getNodeParent(h).* = grandparent;
                    const node = tree.nodePtr(h);
                    node.infix_length = grandparent_node.postfix_length - node.postfix_length - 1;
                },
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
            if (!tree.root.isValid()) return;
            switch (tree.root) {
                .leaf => |root| {
                    const p = tree.getPoint(root);
                    if (entryInWindow(p, min, max))
                        try results.append(root);
                },
                .branch => |root| {
                    try tree.queryNodeWindow(root, min, max, results);
                },
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

        pub const empty: @This() = .{
            .root = .{ .leaf = .invalid },
            .free = .invalid,
            .free_count = 0,
            .nodes = .empty,
            .values = .empty,
        };

        // TODO: Remove this
        pub fn init(_: std.mem.Allocator) !@This() {
            const ret: @This() = .{
                .root = .{ .leaf = .invalid },
                .free = .invalid,
                .free_count = 0,
                .nodes = .empty,
                .values = .empty,
            };
            return ret;
        }

        pub fn deinit(tree: *@This(), allocator: Allocator) void {
            tree.nodes.deinit(allocator);
            tree.values.deinit(allocator);
        }

        pub const Header = extern struct {
            nodes_len: Handle.Int,
            nodes_cap: Handle.Int,
            values_len: Handle.Int,
            values_cap: Handle.Int,
            root: Handle.Int,
            root_tag: InternalNode.Tag,
            free: Handle,
            free_count: Handle.Int,
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
                .root = switch (tree.root) {
                    .leaf => |handle| handle.n,
                    .branch => |handle| handle.n,
                },
                .root_tag = tree.root,
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

            tree.root = switch (header.root_tag) {
                .leaf => .{ .leaf = .from(header.root) },
                .branch => .{ .branch = .from(header.root) },
            };
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

            for (node.children, 0..) |child_handle, i| {
                if (!child_handle.isValid() or ((i | mask_lower) & mask_upper) != i)
                    continue;

                switch (node.childTag(@intCast(i))) {
                    .leaf => {
                        const child_point = tree.getPoint(.from(child_handle.n));
                        if (entryInWindow(child_point, min, max)) {
                            try results.append(.from(child_handle.n));
                        }
                    },
                    .branch => {
                        try tree.queryNodeWindow(child_handle, min, max, results);
                    },
                }
            }
        }
    };
}

test "Basics" {
    var tree: PhTree([*:0]const u8, 2, u32) = try .init(std.testing.allocator);
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

    var tree: PhTree(u32, 4, u32) = try .init(std.testing.allocator);
    defer tree.deinit(std.testing.allocator);

    const KV = extern struct {
        p: PhTree(u32, 4, u32).Point,
        value: u32,
    };

    const len = input.len - input.len % @sizeOf(KV);
    // try file.writeAll(input[0..len]);
    const slice = std.mem.bytesAsSlice(KV, input[0..len]);
    for (slice) |kv| {
        _, const v, _ = try tree.getOrPut(std.testing.allocator, &kv.p);
        v.* = kv.value;
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

test "phtree remove basic" {
    const expect = std.testing.expect;
    var tree: PhTree(u32, 1, u32) = .empty;
    defer tree.deinit(std.testing.allocator);

    _ = try tree.getOrPut(std.testing.allocator, &.{0});
    _ = try tree.getOrPut(std.testing.allocator, &.{1});

    try expect(tree.root == .branch);
    _ = tree.remove(&.{1});
    try expect(tree.root == .leaf);
    _ = tree.remove(&.{0});
}

test "phtree remove last" {
    const expect = std.testing.expect;
    var tree: PhTree(u32, 1, u32) = .empty;
    defer tree.deinit(std.testing.allocator);

    const positions = [_]u32{
        0b000,
        0b100,
        0b101,
        0b110,
    };

    for (positions) |i| {
        _ = try tree.getOrPut(std.testing.allocator, &.{@intCast(i)});
    }

    const last = positions[positions.len - 1];
    const removed = tree.remove(&.{last}).?;

    try expect(tree.nodePtr(tree.root.branch).postfix_length == 2);
    const child = tree.nodePtr(tree.root.branch).children[1];
    try expect(tree.nodePtr(child).postfix_length == 0);
    try expect(tree.nodePtr(child).infix_length == 1);

    _ = tree.insertAssumeCapacity(&.{last}, removed);
}

test "phtree iterator" {
    const expect = std.testing.expect;
    var tree: PhTree(usize, 1, u32) = .empty;
    defer tree.deinit(std.testing.allocator);

    const positions = [_]u32{
        0b000,
        0b001,
        0b101,
        0b110,
        0b111,
    };

    for (positions, 0..) |pos, i| {
        const found, const v, _ = try tree.getOrPut(std.testing.allocator, &.{pos});
        try expect(!found);
        v.* = i;
    }

    var iter = tree.iterator();
    var i: usize = 0;
    while (iter.next()) |handle| : (i += 1) {
        const point = tree.getPoint(handle);
        const value = tree.getValue(handle);
        try std.testing.expectEqual(positions[i], point[0]);
        try std.testing.expectEqual(i, value.*);
    }
    try std.testing.expectEqual(positions.len, i);
}
