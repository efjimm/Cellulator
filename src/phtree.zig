const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

const utils = @import("utils.zig");

const runtime_safety = switch (@import("builtin").mode) {
    .Debug, .ReleaseSafe => true,
    .ReleaseFast, .ReleaseSmall => false,
};

/// See https://tzaeschke.github.io/phtree-site/
pub fn PhTree(
    /// Value associated with each leaf node.
    comptime V: type,
    /// Number of dimensions. The number of children per branch node is `1 << dims` so values >= 4
    /// can result in high memory usage.
    comptime dims: usize,
    /// Integer type to use for handles. Handles are just indexes into the underlying arrays.
    comptime HandleInt: type,
) type {
    return struct {
        entries: std.MultiArrayList(Entry).Slice,
        nodes: std.MultiArrayList(Node).Slice,

        root: NodeOrEntry,

        freelist_head_entries: Entry.Handle,
        freelist_count_entries: Entry.Handle.Int,
        freelist_head_nodes: Node.Handle,
        freelist_count_nodes: Node.Handle.Int,

        /// Prevents a mismatch between requested allocation size and actual allocation size.
        /// We always allocate more than the requested alloc size for performance reasons, so this
        /// variable is necessary to keep track of the actual requested size.
        requested_entries_alloc: if (runtime_safety) usize else u0,

        /// See `requested_values_alloc`.
        requested_nodes_alloc: if (runtime_safety) usize else u0,

        pub const Point = [dims]u32;

        pub const Entry = extern struct {
            point: Point,
            parent: Node.Handle,
            value: V,

            /// Integer handle for leaf nodes. Is an index into the `values` array.
            pub const Handle = enum(HandleInt) {
                invalid = std.math.maxInt(Int),
                _,

                pub const Int = HandleInt;

                pub fn int(handle: Handle) Int {
                    return @intFromEnum(handle);
                }

                pub fn from(n: Int) Handle {
                    const handle: Handle = .fromUnchecked(n);
                    assert(handle != .invalid);
                    return handle;
                }

                pub fn fromUnchecked(n: Int) Handle {
                    return @enumFromInt(n);
                }
            };
        };

        pub const Node = extern struct {
            // TODO: Investigate if it's possible to remove this field.
            point: Point,
            parent: Handle,
            children: [1 << dims]Handle,

            /// Integers in extern structs must be at least 8 bits, with <= 3 dims the extra bits
            /// are unused.
            child_flags: FlagInt,

            /// Number of bits following the bit with which this node is concerned. This is the
            /// same as the zero-based index of the bit.
            postfix_length: u8,

            pub const FlagInt = std.meta.Int(.unsigned, @max(1 << dims, 8));
            pub const Tag = enum(u8) { entry, node };

            /// Integer handle for internal nodes. Is an index in the `nodes` array.
            pub const Handle = enum(HandleInt) {
                invalid = std.math.maxInt(Int),
                _,

                const Int = HandleInt;

                pub fn int(handle: Handle) Int {
                    return @intFromEnum(handle);
                }

                pub fn from(n: Int) Handle {
                    const ret: Handle = .fromUnchecked(n);
                    assert(ret != .invalid);
                    return ret;
                }

                pub fn fromUnchecked(n: Int) Handle {
                    return @enumFromInt(n);
                }
            };
        };

        pub const NodeOrEntry = union(enum) {
            entry: Entry.Handle,
            node: Node.Handle,
            invalid,

            pub fn init(value: anytype) NodeOrEntry {
                assert(value != .invalid);
                return switch (@TypeOf(value)) {
                    Entry.Handle => .{ .entry = value },
                    Node.Handle => .{ .node = value },
                    else => comptime unreachable,
                };
            }
        };

        pub const empty: @This() = .{
            .nodes = .empty,
            .entries = .empty,

            .root = .invalid,

            .freelist_head_entries = .invalid,
            .freelist_count_entries = 0,
            .freelist_head_nodes = .invalid,
            .freelist_count_nodes = 0,
            .requested_entries_alloc = 0,
            .requested_nodes_alloc = 0,
        };

        pub fn deinit(tree: *@This(), allocator: Allocator) void {
            tree.nodes.deinit(allocator);
            tree.entries.deinit(allocator);
        }

        /// Create many values at a time, returning a slice of the newly created values.
        /// Sidesteps the free-list in order to provide a block of contiguous handles quickly. This
        /// can be very, very, beneficial for performance for multiple reasons, but can cause memory
        /// fragmentation. The handles being contiguous allows referring to all of them using just
        /// a start index and a length. The memory for the cells is also contiguous. It also means
        /// allocating them is just bumping the length, instead of traversing the free list.
        pub fn addMany(tree: *@This(), n: HandleInt) Slice {
            assert(tree.entries.capacity - tree.entries.len >= n);
            const start = tree.entries.len;
            tree.entries.len += n;
            const ret = tree.slice(@intCast(start), n);
            if (runtime_safety) {
                for (0..n) |i| ret.set(@intCast(i), undefined);
            }
            return ret;
        }

        pub fn slice(tree: *@This(), i: HandleInt, len: HandleInt) Slice {
            assert(i + len <= tree.entries.len);
            return .{
                .points_ptr = tree.entries.items(.point)[i..].ptr,
                .parents_ptr = tree.entries.items(.parent)[i..].ptr,
                .values_ptr = tree.entries.items(.value)[i..].ptr,
                .len = len,
                .offset = i,
                .capacity = @intCast(tree.entries.capacity - i),
            };
        }

        // Returns a slice of the last `n` leaves.
        pub fn endSlice(tree: *@This(), n: HandleInt) Slice {
            return tree.slice(@intCast(tree.entries.len - n), n);
        }

        pub fn sliceToEnd(tree: *@This(), offset: HandleInt) Slice {
            return tree.slice(offset, @intCast(tree.entries.len - offset));
        }

        pub fn commitSlice(tree: *@This(), s: *const Slice) void {
            if (s.offset + s.len > tree.entries.len) {
                tree.entries.len = s.offset + s.len;
                assert(tree.entries.len <= tree.entries.capacity);
            }
        }

        pub const Slice = struct {
            points_ptr: [*]Point,
            parents_ptr: [*]Node.Handle,
            values_ptr: [*]V,

            offset: HandleInt,
            len: HandleInt,
            capacity: HandleInt,

            pub fn set(s: *const Slice, i: HandleInt, leaf: Entry) void {
                assert(i < s.len);
                s.parents_ptr[i] = leaf.parent;
                s.points_ptr[i] = leaf.point;
                s.values_ptr[i] = leaf.value;
            }

            pub fn getPoint(s: *const Slice, i: HandleInt) *Point {
                assert(i < s.len);
                return &s.points_ptr[i];
            }

            pub fn end(s: *const Slice) HandleInt {
                return s.offset + s.len;
            }

            /// Converts an index into this slice into a handle.
            pub fn handle(s: *const Slice, i: HandleInt) Entry.Handle {
                return .from(s.offset + i);
            }

            pub fn values(s: *const Slice) []V {
                return s.values_ptr[0..s.len];
            }

            pub fn parents(s: *const Slice) []Node.Handle {
                return s.parents_ptr[0..s.len];
            }

            pub fn points(s: *const Slice) []Point {
                return s.points_ptr[0..s.len];
            }

            /// Assumes that `s` is at the end of the original list.
            pub fn append(s: *Slice, leaf: Entry) void {
                assert(s.len < s.capacity);
                s.len += 1;
                s.set(s.len - 1, leaf);
            }
        };

        pub fn clearRetainingCapacity(tree: *@This()) void {
            tree.nodes.len = 0;
            tree.entries.len = 0;

            tree.root = .invalid;

            tree.freelist_head_nodes = .invalid;
            tree.freelist_count_nodes = 0;
            tree.freelist_head_entries = .invalid;
            tree.freelist_count_entries = 0;
        }

        /// Create a value and return a handle to it. Does not insert the value into the tree.
        /// Values created this way must either be inserted into the tree or destroy with a call to
        /// `destroyValue`.
        pub fn createValue(
            tree: *@This(),
            allocator: Allocator,
            p: *const Point,
            value: V,
        ) Allocator.Error!Entry.Handle {
            var m = tree.entries.toMultiArrayList();
            try m.ensureUnusedCapacity(allocator, 1);
            tree.entries = m.toOwnedSlice();
            if (runtime_safety)
                tree.requested_entries_alloc = @max(tree.requested_entries_alloc, m.len + 1);
            return tree.createValueAssumeCapacity(p, value);
        }

        pub fn createValueAssumeCapacity(tree: *@This(), p: *const Point, value: V) Entry.Handle {
            if (tree.freelist_head_entries != .invalid) {
                assert(tree.freelist_count_entries > 0);
                const ret = tree.freelist_head_entries;
                tree.freelist_head_entries = .fromUnchecked(tree.entryItem(ret, .parent).int());
                tree.freelist_count_entries -= 1;

                tree.entries.set(ret.int(), .{
                    .point = p.*,
                    .parent = .invalid,
                    .value = value,
                });

                assert(tree.root != .entry or tree.root.entry != ret);
                assert(tree.freelist_head_entries != ret);
                assert(tree.freelist_head_entries == .invalid or
                    tree.freelist_head_entries.int() < tree.entries.len);
                return ret;
            }

            assert(tree.requestedCapacity() > tree.entries.len);
            const handle: Entry.Handle = .from(@intCast(tree.entries.len));
            tree.entries.len += 1;

            tree.entries.set(handle.int(), .{
                .point = p.*,
                .parent = .invalid,
                .value = value,
            });

            assert(tree.root != .entry or tree.root.entry != handle);
            return handle;
        }

        pub fn destroyValue(tree: *@This(), handle: Entry.Handle) void {
            assert(tree.root != .entry or tree.root.entry != handle);

            if (handle.int() == tree.entries.len - 1) {
                tree.entryItem(handle, .parent).* = .invalid;
                tree.entries.len -= 1;
            } else {
                tree.entries.set(handle.int(), .{
                    .point = @splat(0),
                    .parent = .fromUnchecked(tree.freelist_head_entries.int()),
                    .value = undefined,
                });
                tree.freelist_head_entries = handle;
                tree.freelist_count_entries += 1;
            }
        }

        pub fn ensureUnusedCapacity(tree: *@This(), allocator: Allocator, n: Node.Handle.Int) Allocator.Error!void {
            const count = std.math.mul(Node.Handle.Int, n, 2) catch return error.OutOfMemory;
            if (tree.nodes.len + count > tree.nodes.capacity) {
                var m = tree.nodes.toMultiArrayList();
                try m.setCapacity(allocator, m.len * 2 + count);
                tree.nodes = m.slice();
            }

            if (runtime_safety)
                tree.requested_nodes_alloc = @max(tree.requested_nodes_alloc, tree.nodes.len + count);

            if (tree.entries.len + n > tree.entries.capacity) {
                var m = tree.entries.toMultiArrayList();
                try m.setCapacity(allocator, m.len * 2 + n);
                tree.entries = m.slice();
            }

            if (runtime_safety)
                tree.requested_entries_alloc = @max(tree.requested_entries_alloc, tree.entries.len + n);
        }

        pub const GetOrPutResult = struct {
            handle: Entry.Handle,
            value_ptr: *V,
            found_existing: bool,
        };

        pub fn getOrPut(
            tree: *@This(),
            allocator: Allocator,
            p: *const Point,
        ) Allocator.Error!GetOrPutResult {
            try tree.ensureUnusedCapacity(allocator, 1);
            return tree.getOrPutAssumeCapacity(p);
        }

        pub fn getOrPutAssumeCapacity(tree: *@This(), p: *const Point) GetOrPutResult {
            const h = tree.findEntry(p);
            if (h != .invalid) return .{
                .handle = h,
                .value_ptr = tree.getValue(h),
                .found_existing = true,
            };

            const handle = tree.createValueAssumeCapacity(p, undefined);
            const removed_kv = tree.insertAssumeCapacity(p, handle);
            if (removed_kv != .invalid) {
                // Re-insert this kv and destroy the new one
                const parent = tree.entryItem(handle, .parent).*;
                if (parent == .invalid) {
                    tree.removeHandle(handle);
                    assert(tree.root == .invalid);
                    tree.insertEmpty(removed_kv);
                } else {
                    const address = calculateHypercubeAddress(p, tree.branchItem(parent, .postfix_length).*);
                    tree.entryItem(removed_kv, .parent).* = parent;
                    tree.setChild(parent, address, .entry, removed_kv);
                }

                tree.destroyValue(handle);
                return .{
                    .handle = removed_kv,
                    .value_ptr = tree.getValue(removed_kv),
                    .found_existing = true,
                };
            }

            const value_ptr = tree.getValue(handle);
            return .{
                .handle = handle,
                .value_ptr = value_ptr,
                .found_existing = false,
            };
        }

        pub fn getPoint(tree: *const @This(), handle: Entry.Handle) *Point {
            return tree.entryItem(handle, .point);
        }

        pub fn getValue(tree: *const @This(), handle: Entry.Handle) *V {
            return tree.entryItem(handle, .value);
        }

        pub fn isValidHandle(tree: *const @This(), handle: Entry.Handle) bool {
            return handle.int() < tree.entries.len;
        }

        pub fn insert(
            tree: *@This(),
            allocator: Allocator,
            p: *const Point,
            kv: Entry.Handle,
        ) Allocator.Error!Entry.Handle {
            try tree.ensureUnusedCapacity(allocator, 1);
            return tree.insertAssumeCapacity(p, kv);
        }

        pub fn insertAssumeCapacityNoClobber(
            tree: *@This(),
            p: *const Point,
            kv: Entry.Handle,
        ) void {
            const removed = tree.insertAssumeCapacity(p, kv);
            assert(removed == .invalid);
        }

        pub fn insertAssumeCapacity(tree: *@This(), p: *const Point, kv: Entry.Handle) Entry.Handle {
            tree.entryItem(kv, .point).* = p.*;
            if (tree.root == .invalid) {
                tree.insertEmpty(kv);
                return .invalid;
            }

            if (tree.root == .entry)
                return tree.insertWithLeafRoot(kv);

            const root = tree.root.node;
            const root_point = tree.branchItem(root, .point);
            const root_conflicting_bit = firstDifferingBit(p, root_point);

            const root_pl = tree.branchItem(root, .postfix_length).*;
            if (root_conflicting_bit > root_pl + 1) {
                tree.insertAboveRoot(kv, root_conflicting_bit);
                return .invalid;
            }

            return tree.insertGeneric(kv);
        }

        fn childTag(tree: *const @This(), handle: Node.Handle, index: u8) Node.Tag {
            const mask = @as(Node.FlagInt, 1) << @intCast(index);
            const flags = tree.nodes.items(.child_flags)[handle.int()];
            return @enumFromInt((flags & mask) >> @intCast(index));
        }

        fn setChild(
            tree: *const @This(),
            handle: Node.Handle,
            address: u8,
            comptime tag: Node.Tag,
            child: switch (tag) {
                .entry => Entry.Handle,
                .node => Node.Handle,
            },
        ) void {
            const mask = @as(Node.FlagInt, 1) << @intCast(address);
            const flags = &tree.nodes.items(.child_flags)[handle.int()];

            switch (tag) {
                .entry => {
                    flags.* &= ~mask;
                    tree.branchItem(handle, .children)[address] = .fromUnchecked(child.int());
                    if (child != .invalid)
                        tree.entryItem(child, .parent).* = handle;
                },
                .node => {
                    flags.* |= mask;
                    tree.branchItem(handle, .children)[address] = child;
                    if (child != .invalid)
                        tree.branchItem(child, .parent).* = handle;
                },
            }
        }

        fn getChild(tree: *const @This(), handle: Node.Handle, address: u8) NodeOrEntry {
            const children = tree.branchItem(handle, .children);
            return switch (tree.childTag(handle, address)) {
                .entry => {
                    const child: Entry.Handle = .fromUnchecked(children[address].int());
                    if (child == .invalid) return .invalid;
                    return .init(child);
                },
                .node => .init(children[address]),
            };
        }

        fn getInfixLength(tree: *@This(), handle: Node.Handle) u8 {
            const parent = tree.branchItem(handle, .parent).*;
            const parent_pl =
                if (parent != .invalid)
                    tree.branchItem(parent, .postfix_length).*
                else
                    32;
            const pl = tree.branchItem(handle, .postfix_length).*;
            return parent_pl - pl - 1;
        }

        fn calculateHypercubeAddress(p: *const Point, postfix_length: u8) u8 {
            const pl: u5 = @intCast(postfix_length);
            const bit_mask = @as(u32, 1) << pl;
            var address: u32 = 0;
            for (p) |v| {
                address <<= 1;
                address |= (bit_mask & v) >> pl;
            }
            assert(address < 1 << dims);
            return @intCast(address);
        }

        fn requestedCapacity(tree: *const @This()) usize {
            return if (runtime_safety) tree.requested_entries_alloc else tree.entries.capacity;
        }

        fn createBranchNode(tree: *@This(), allocator: Allocator) Allocator.Error!Node.Handle {
            if (tree.freelist_head_nodes == .invalid) {
                var m = tree.nodes.toMultiArrayList();
                defer tree.nodes = m.slice();

                try m.ensureUnusedCapacity(allocator, 1);
                if (runtime_safety)
                    tree.requested_nodes_alloc = @max(tree.requested_nodes_alloc, m.len + 1);
            }

            return tree.createBranchNodeAssumeCapacity();
        }

        fn createBranchNodeAssumeCapacity(tree: *@This()) Node.Handle {
            if (tree.freelist_head_nodes != .invalid) {
                const ret = tree.freelist_head_nodes;
                tree.freelist_head_nodes = tree.branchItem(ret, .parent).*;
                tree.freelist_count_nodes -= 1;

                assert(tree.freelist_head_nodes == .invalid or
                    tree.freelist_head_nodes.int() < tree.nodes.len);
                assert(ret != .invalid);
                return ret;
            }

            assert(tree.nodes.capacity > tree.nodes.len);

            tree.nodes.len += 1;
            return .from(@intCast(tree.nodes.len - 1));
        }

        fn destroyHandle(tree: *@This(), branch: Node.Handle) void {
            if (branch.int() == tree.nodes.len - 1) {
                tree.branchItem(branch, .parent).* = .invalid;
                tree.nodes.len -= 1;
            } else {
                tree.nodes.set(branch.int(), undefined);
                tree.branchItem(branch, .parent).* = tree.freelist_head_nodes;
                tree.freelist_head_nodes = branch;
                tree.freelist_count_nodes += 1;
            }
        }

        fn createNodeAssumeCapacity(
            tree: *@This(),
            parent: Node.Handle,
            postfix_length: u8,
            p: *const Point,
        ) Node.Handle {
            const handle = tree.createBranchNodeAssumeCapacity();
            assert(handle != .invalid);

            const key_mask = std.math.shl(u32, std.math.maxInt(u32), postfix_length + 1);
            var new_point = p.*;
            for (&new_point) |*v| {
                v.* &= key_mask;
                v.* |= @as(u32, 1) << @intCast(postfix_length);
            }

            tree.nodes.set(handle.int(), .{
                .point = new_point,
                .parent = parent,
                .children = @splat(.invalid),
                .child_flags = 0,
                .postfix_length = postfix_length,
            });

            return handle;
        }

        /// Returns the 1-based index of the bit at which the two points diverge, or zero if the
        /// points are the same.
        fn firstDifferingBit(p1: *const Point, p2: *const Point) u8 {
            var diff: u32 = 0;
            for (p1, p2) |v1, v2| {
                diff |= v1 ^ v2;
            }
            const ret = 32 - @clz(diff);
            if (ret == 0) assert(std.mem.eql(u32, p1, p2));
            return ret;
        }

        pub fn entryItem(
            tree: *const @This(),
            handle: Entry.Handle,
            comptime tag: std.MultiArrayList(Entry).Field,
        ) *@FieldType(Entry, @tagName(tag)) {
            assert(handle != .invalid);
            return &tree.entries.items(tag)[handle.int()];
        }

        fn branchItem(
            tree: *const @This(),
            handle: Node.Handle,
            comptime tag: std.meta.FieldEnum(Node),
        ) *@FieldType(Node, @tagName(tag)) {
            assert(handle != .invalid);
            return &tree.nodes.items(tag)[handle.int()];
        }

        fn insertEmpty(tree: *@This(), kv: Entry.Handle) void {
            assert(tree.root == .invalid);
            assert(kv != tree.freelist_head_entries);

            tree.entryItem(kv, .parent).* = .invalid;
            tree.root = .init(kv);
        }

        fn insertWithLeafRoot(tree: *@This(), kv: Entry.Handle) Entry.Handle {
            assert(kv != .invalid);
            const p = tree.entryItem(kv, .point);

            const root = tree.root.entry;
            const root_point = tree.entryItem(root, .point);
            const root_conflicting_bit = firstDifferingBit(p, root_point);

            // The points are the same
            if (root_conflicting_bit == 0) {
                tree.entryItem(kv, .parent).* = .invalid;
                tree.root = .init(kv);
                return root;
            }

            // Need to insert a new branch node above the current root node.
            const pl = root_conflicting_bit - 1;
            const new_root = tree.createNodeAssumeCapacity(.invalid, pl, p);
            const address = calculateHypercubeAddress(p, pl);
            tree.setChild(new_root, address, .entry, kv);

            const root_address = calculateHypercubeAddress(root_point, pl);
            assert(address != root_address);
            tree.setChild(new_root, root_address, .entry, root);

            tree.root = .init(new_root);
            return .invalid;
        }

        fn insertAboveRoot(tree: *@This(), kv: Entry.Handle, root_conflicting_bit: u8) void {
            const p = tree.entryItem(kv, .point);

            // Need to insert a new branch node above the current root node.
            const pl = root_conflicting_bit - 1;
            const new_root = tree.createNodeAssumeCapacity(.invalid, pl, p);

            const address = calculateHypercubeAddress(p, pl);
            tree.setChild(new_root, address, .entry, kv);

            const root = tree.root.node;
            const root_address = calculateHypercubeAddress(tree.branchItem(root, .point), pl);
            assert(address != root_address);
            tree.setChild(new_root, root_address, .node, root);

            tree.root = .init(new_root);
        }

        fn insertGeneric(tree: *@This(), kv: Entry.Handle) Entry.Handle {
            const p = tree.entryItem(kv, .point);
            // PH trees cannot be deeper than the bit length of their keys.
            const max_depth = @typeInfo(@typeInfo(Point).array.child).int.bits;
            var last_pl: u8 = max_depth;
            var handle = tree.root.node;
            for (0..max_depth) |_| {
                const pl = tree.branchItem(handle, .postfix_length).*;
                assert(last_pl > pl);
                last_pl = pl;
                const address = calculateHypercubeAddress(p, pl);

                const child_handle = tree.getChild(handle, address);
                if (child_handle == .invalid) {
                    tree.setChild(handle, address, .entry, kv);
                    return .invalid;
                }

                if (child_handle == .entry) {
                    const child = child_handle.entry;
                    const child_point = tree.entryItem(child, .point);
                    assert(calculateHypercubeAddress(child_point, pl) == address);
                    const conflicting_bit = firstDifferingBit(p, child_point);
                    if (conflicting_bit == 0) {
                        tree.entryItem(child, .parent).* = .invalid;
                        tree.setChild(handle, address, .entry, kv);
                        return child;
                    }
                    assert(conflicting_bit <= pl);
                    const new_pl = conflicting_bit - 1;
                    const new_handle = tree.createNodeAssumeCapacity(handle, new_pl, p);
                    tree.setChild(handle, address, .node, new_handle);

                    const old_child_address = calculateHypercubeAddress(child_point, new_pl);
                    const new_child_address = calculateHypercubeAddress(p, new_pl);
                    assert(old_child_address != new_child_address);
                    tree.setChild(new_handle, old_child_address, .entry, child);
                    tree.setChild(new_handle, new_child_address, .entry, kv);
                    return .invalid;
                }

                // Both nodes are branch nodes
                const child = child_handle.node;
                assert(child != handle);

                if (tree.getInfixLength(child) == 0) {
                    handle = child;
                    continue;
                }

                // There is a bit gap between the parent and child so the new node may need to
                // be inserted between the parent and child.

                const child_point = tree.branchItem(child, .point);
                const conflicting_bit = firstDifferingBit(p, child_point);
                const child_pl = tree.branchItem(child, .postfix_length).*;
                if (conflicting_bit <= child_pl + 1) {
                    handle = child;
                    continue;
                }

                assert(conflicting_bit <= pl);
                const new_pl = conflicting_bit - 1;
                const new_handle = tree.createNodeAssumeCapacity(handle, new_pl, p);

                tree.setChild(handle, address, .node, new_handle);

                const new_node_address = calculateHypercubeAddress(child_point, new_pl);
                tree.setChild(new_handle, new_node_address, .node, child);

                handle = new_handle;
            }
            unreachable;
        }

        pub fn largestDim(tree: *@This(), dim: u8) Entry.Handle {
            var largest: Entry.Handle = .invalid;
            const s = tree.slice(0, @intCast(tree.entries.len));
            for (s.points(), 0..) |p, i| {
                const handle = s.handle(i);
                if (largest == .invalid or tree.entryItem(largest, .point)[dim] < p[dim])
                    largest = handle;
            }
            return largest;
        }

        pub fn findEntry(tree: *@This(), p: *const Point) Entry.Handle {
            if (tree.root == .invalid) return .invalid;

            if (tree.root == .entry) {
                const root = tree.root.entry;
                const p2 = tree.entryItem(root, .point);
                return if (std.mem.eql(u32, p, p2)) root else .invalid;
            }

            var h = tree.root.node;
            const max_depth = @typeInfo(@typeInfo(Point).array.child).int.bits + 2;
            for (0..max_depth) |_| {
                if (h == .invalid) return .invalid;

                const pl = tree.branchItem(h, .postfix_length).*;
                const address = calculateHypercubeAddress(p, pl);
                switch (tree.getChild(h, address)) {
                    .invalid => return .invalid,
                    .entry => |child| {
                        const child_point = tree.entryItem(child, .point);
                        return if (std.mem.eql(u32, p, child_point)) child else .invalid;
                    },
                    .node => |child| {
                        assert(child.int() != h.int());
                        h = child;
                    },
                }
            }

            unreachable;
        }

        pub fn findParent(tree: *const @This(), p: *const Point) struct { Entry.Handle, Node.Handle } {
            switch (tree.root) {
                .invalid => return .{ .invalid, .invalid },
                .entry => |leaf| return .{ leaf, .invalid },
                .node => {},
            }

            var h = tree.root.node;
            var parent: Node.Handle = .invalid;
            var address: u8 = 0;
            while (h != .invalid) {
                parent = h;
                address = calculateHypercubeAddress(p, tree.branchItem(h, .postfix_length).*);
                const children = tree.branchItem(h, .children);
                switch (tree.childTag(h, address)) {
                    .entry => return .{
                        .fromUnchecked(children[address].int()),
                        h,
                    },
                    .node => h = children[address],
                }
            }

            assert(parent != .invalid);
            return .{ .invalid, parent };
        }

        pub const Iterator = struct {
            tree: *const PhTree(V, dims, HandleInt),
            current: NodeOrEntry,
            index: u8,

            pub fn next(iter: *Iterator) ?Entry.Handle {
                const tree = iter.tree;
                switch (iter.current) {
                    .invalid => return null,
                    .entry => |handle| {
                        const parent = tree.entryItem(handle, .parent).*;

                        if (parent != .invalid) {
                            iter.current = .init(parent);
                            const p = tree.entryItem(handle, .point);
                            iter.index = 1 + calculateHypercubeAddress(
                                p,
                                tree.branchItem(parent, .postfix_length).*,
                            );
                        } else {
                            iter.current = .invalid;
                        }
                        return handle;
                    },
                    .node => |handle| {
                        const children = tree.branchItem(handle, .children);
                        for (children[iter.index..], iter.index..) |child_handle, i| {
                            if (child_handle == .invalid) continue;
                            iter.current = tree.getChild(handle, @intCast(i));
                            iter.index = 0;
                            return iter.next();
                        }

                        const parent = tree.branchItem(handle, .parent).*;
                        if (parent == .invalid) {
                            iter.current = .invalid;
                            return null;
                        }

                        const child_point = tree.branchItem(handle, .point);
                        iter.index = 1 + calculateHypercubeAddress(
                            child_point,
                            tree.branchItem(parent, .postfix_length).*,
                        );
                        iter.current = .init(parent);
                        return iter.next();
                    },
                }
                comptime unreachable;
            }
        };

        pub fn iterator(tree: *const @This()) Iterator {
            return .{
                .tree = tree,
                .current = tree.root,
                .index = 0,
            };
        }

        pub fn iteratorAt(tree: *const @This(), start: Point) Iterator {
            const value, const parent = tree.findParent(&start);

            return .{
                .tree = tree,
                .current = switch (value) {
                    .invalid => switch (parent) {
                        .invalid => .invalid,
                        else => .init(parent),
                    },
                    else => .init(value),
                },
                .index = switch (parent) {
                    .invalid => 0,
                    else => 1 + calculateHypercubeAddress(
                        &start,
                        tree.branchItem(parent, .postfix_length).*,
                    ),
                },
            };
        }

        /// Return a pointer to the value associated with `p` if it exists, otherwise returns
        /// `null`. This function should not be used when `@sizeOf(V) == 0`, as the
        /// `std.MultiArrayList` implementation causes the result of this function to be
        /// undefined.
        pub fn find(tree: *@This(), p: *const Point) ?*V {
            const handle = tree.findEntry(p);
            if (handle != .invalid) {
                return tree.getValue(handle);
            }
            return null;
        }

        pub fn removeHandle(tree: *@This(), handle: Entry.Handle) void {
            const p: *const Point = tree.entryItem(handle, .point);
            const parent = tree.entryItem(handle, .parent).*;
            tree.entryItem(handle, .parent).* = .invalid;
            if (parent == .invalid) {
                if (tree.root == .entry and tree.root.entry == handle)
                    tree.root = .invalid;
                return;
            }

            // There should never be any branch nodes in the tree that have < 2 children
            assert(tree.getChildrenLen(parent) >= 2);
            // Remove the value from its parent
            const address = calculateHypercubeAddress(p, tree.branchItem(parent, .postfix_length).*);
            tree.setChild(parent, address, .entry, .invalid);

            if (tree.getChildrenLen(parent) >= 2) return;

            const reparented_node =
                for (tree.branchItem(parent, .children), 0..) |child, i| {
                    if (child != .invalid) {
                        break tree.getChild(parent, @intCast(i));
                    }
                } else unreachable;

            const grandparent = tree.branchItem(parent, .parent).*;
            if (grandparent == .invalid) {
                tree.destroyHandle(parent);
                switch (reparented_node) {
                    .invalid => unreachable,
                    .entry => |h| tree.entryItem(h, .parent).* = .invalid,
                    .node => |h| tree.branchItem(h, .parent).* = .invalid,
                }
                tree.root = reparented_node;
                return;
            }

            const grandparent_pl = tree.branchItem(grandparent, .postfix_length).*;
            const address2 = calculateHypercubeAddress(p, grandparent_pl);
            assert(address2 == calculateHypercubeAddress(tree.branchItem(parent, .point), grandparent_pl));
            assert(tree.getChild(grandparent, address2).node == parent);
            switch (reparented_node) {
                .invalid => unreachable,
                .entry => |h| tree.setChild(grandparent, address2, .entry, h),
                .node => |h| tree.setChild(grandparent, address2, .node, h),
            }
            tree.destroyHandle(parent);
        }

        pub fn remove(tree: *@This(), p: *const Point) ?Entry.Handle {
            const handle = tree.findEntry(p);
            if (handle == .invalid) return null;
            tree.removeHandle(handle);
            return handle;
        }

        pub fn traverse(
            tree: *@This(),
            min: *const Point,
            max: *const Point,
            ctx: anytype,
        ) !void {
            switch (tree.root) {
                .invalid => {},
                .entry => |root| {
                    const p = tree.entryItem(root, .point);
                    if (entryInWindow(p, min, max))
                        try ctx.func(root);
                },
                .node => |root| {
                    try tree.traverseNodeWindow(root, min, max, ctx);
                },
            }
        }

        /// Appends all key/value pairs whose key falls between `min` and `max`.
        pub fn queryWindow(
            tree: *@This(),
            min: *const Point,
            max: *const Point,
            results: *std.ArrayList(Entry.Handle),
        ) Allocator.Error!void {
            const Context = struct {
                results: *std.ArrayList(Entry.Handle),

                pub fn func(ctx: @This(), h: Entry.Handle) !void {
                    try ctx.results.append(h);
                }
            };

            try tree.traverse(min, max, Context{ .results = results });
        }

        /// Appends all key/value pairs whose key intersects the rectangle of `min` and `max`.
        /// Only works for 4 dimensional trees whose keys are assumed to be rectangles.
        /// e.g. { top_left_x, top_left_y, bottom_right_x, bottom_right_y }.
        pub fn queryWindowRect(
            tree: *@This(),
            min: [2]u32,
            max: [2]u32,
            results: *std.ArrayList(Entry.Handle),
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

        fn getChildrenLen(tree: *const @This(), handle: Node.Handle) u8 {
            var count: u8 = 0;
            for (tree.branchItem(handle, .children)) |child| {
                if (child != .invalid) count += 1;
            }
            return count;
        }

        pub const Header = extern struct {
            nodes_len: Node.Handle.Int,
            nodes_cap: Node.Handle.Int,
            values_len: Node.Handle.Int,
            values_cap: Node.Handle.Int,
            root: Node.Handle.Int,
            root_tag: blk: {
                var t = @typeInfo(@typeInfo(NodeOrEntry).@"union".tag_type.?);
                t.@"enum".tag_type = u8;
                break :blk @Type(t);
            },
            free: Node.Handle,
            free_count: Node.Handle.Int,
        };

        pub fn iovecs(tree: *@This()) [8][]u8 {
            return utils.multiArrayListSliceIoVec(&tree.nodes) ++
                utils.multiArrayListSliceIoVec(&tree.entries);
        }

        pub fn getHeader(tree: *@This()) Header {
            return .{
                .nodes_len = @intCast(tree.nodes.len),
                .nodes_cap = @intCast(tree.nodes.capacity),
                .values_len = @intCast(tree.entries.len),
                .values_cap = @intCast(tree.entries.capacity),
                .root = switch (tree.root) {
                    .invalid => Entry.Handle.invalid.int(),
                    .entry => |handle| handle.int(),
                    .node => |handle| handle.int(),
                },
                .root_tag = @enumFromInt(@intFromEnum(tree.root)),
                .free = tree.freelist_head_nodes,
                .free_count = tree.freelist_count_nodes,
            };
        }

        pub fn initFromHeader(tree: *@This(), allocator: Allocator, header: Header) !void {
            var nodes = tree.nodes.toMultiArrayList();
            try nodes.setCapacity(allocator, header.nodes_cap);
            errdefer nodes.deinit(allocator);

            var values = tree.entries.toMultiArrayList();
            try values.setCapacity(allocator, header.values_cap);

            nodes.len = header.nodes_len;
            tree.nodes = nodes.slice();

            values.len = header.values_len;
            tree.entries = values.slice();

            tree.root = switch (header.root_tag) {
                .invalid => .invalid,
                .entry => .init(Entry.Handle.from(header.root)),
                .node => .init(Node.Handle.from(header.root)),
            };
            tree.freelist_head_nodes = header.free;
            tree.freelist_count_nodes = header.free_count;

            if (runtime_safety) {
                tree.requested_entries_alloc = tree.entries.capacity;
                tree.requested_nodes_alloc = tree.nodes.capacity;
            }
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
                v1.* = std.math.shr(u32, v1.*, postfix_length + 1);
                v2.* = std.math.shr(u32, v2.*, postfix_length + 1);
            }

            return pointGreaterOrEqual(&p1, &p2);
        }

        fn prefixLessOrEqual(a: *const Point, b: *const Point, postfix_length: u8) bool {
            var p1 = a.*;
            var p2 = b.*;
            for (&p1, &p2) |*v1, *v2| {
                v1.* = std.math.shr(u32, v1.*, postfix_length + 1);
                v2.* = std.math.shr(u32, v2.*, postfix_length + 1);
            }

            return pointLessOrEqual(&p1, &p2);
        }

        fn nodeInWindow(p: *const Point, postfix_length: u8, min: *const Point, max: *const Point) bool {
            return prefixGreaterOrEqual(p, min, postfix_length) and prefixLessOrEqual(p, max, postfix_length);
        }

        fn entryInWindow(p: *const Point, min: *const Point, max: *const Point) bool {
            return pointGreaterOrEqual(p, min) and pointLessOrEqual(p, max);
        }

        fn traverseNodeWindow(
            tree: *@This(),
            handle: Node.Handle,
            min: *const Point,
            max: *const Point,
            ctx: anytype,
        ) !void {
            assert(handle != .invalid);
            const p = tree.branchItem(handle, .point);
            if (!nodeInWindow(p, tree.branchItem(handle, .postfix_length).*, min, max))
                return;

            var mask_lower: u32 = 0;
            var mask_upper: u32 = 0;

            for (p, min, max) |v, minv, maxv| {
                assert(minv <= maxv);
                mask_lower = (mask_lower << 1) | @intFromBool(minv >= v);
                mask_upper = (mask_upper << 1) | @intFromBool(maxv >= v);
            }

            for (tree.branchItem(handle, .children), 0..) |child_handle, i| {
                if ((i | mask_lower) & mask_upper != i)
                    continue;

                switch (tree.getChild(handle, @intCast(i))) {
                    .invalid => {},
                    .entry => |leaf| {
                        const child_point = tree.entryItem(leaf, .point);
                        if (entryInWindow(child_point, min, max)) {
                            const h: Entry.Handle = .from(child_handle.int());
                            try ctx.func(h);
                        }
                    },
                    .node => |branch| {
                        try tree.traverseNodeWindow(branch, min, max, ctx);
                    },
                }
            }
        }

        pub fn validate(tree: *const @This()) bool {
            if (tree.requested_nodes_alloc < tree.nodes.len) return false;
            if (tree.requested_entries_alloc < tree.entries.len) return false;

            if (tree.root != .invalid) {
                if (tree.root == .node and tree.nodes.len == 0) return false;
            }

            if (tree.root == .invalid and tree.nodes.len > 0) {
                if (tree.freelist_head_nodes == .invalid) return false;
                if (tree.freelist_count_nodes == 0) return false;
            }

            if (tree.root == .invalid and tree.entries.len > 0) {
                if (tree.freelist_head_entries == .invalid) return false;
                if (tree.freelist_count_entries == 0) return false;
            }

            var iter = tree.iterator();
            while (iter.next()) |_| {}
            return true;
        }
    };
}

test "Basics" {
    var tree: PhTree([*:0]const u8, 2, u32) = .empty;
    defer tree.deinit(std.testing.allocator);

    const kv1 = try tree.createValue(std.testing.allocator, &.{ 1, 1 }, "1, 1! :D");
    const old_kv = try tree.insert(std.testing.allocator, &.{ 1, 1 }, kv1);
    try std.testing.expect(old_kv == .invalid);
    const value = tree.getValue(kv1).*;
    try std.testing.expectEqualStrings("1, 1! :D", std.mem.span(value));

    const v = tree.find(&.{ 1, 1 }).?.*;
    try std.testing.expectEqualStrings("1, 1! :D", std.mem.span(v));

    const removed = tree.remove(&.{ 1, 1 }).?;
    const removed_value = tree.getValue(removed).*;
    try std.testing.expectEqualStrings("1, 1! :D", std.mem.span(removed_value));

    try std.testing.expectEqual(null, tree.find(&.{ 1, 1 }));
}

test "phtree remove basic" {
    const expect = std.testing.expect;
    var tree: PhTree(u32, 1, u32) = .empty;
    defer tree.deinit(std.testing.allocator);

    _ = try tree.getOrPut(std.testing.allocator, &.{0});
    _ = try tree.getOrPut(std.testing.allocator, &.{1});

    try expect(tree.root == .node);
    _ = tree.remove(&.{1});
    try expect(tree.root == .entry);
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

    try expect(tree.branchItem(tree.root.node, .postfix_length).* == 2);
    const child = tree.branchItem(tree.root.node, .children)[1];
    try expect(tree.branchItem(child, .postfix_length).* == 0);
    try expect(tree.getInfixLength(child) == 1);

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
        const res = try tree.getOrPut(std.testing.allocator, &.{pos});
        try expect(!res.found_existing);
        res.value_ptr.* = i;
    }

    var iter = tree.iterator();
    var i: usize = 0;
    while (iter.next()) |handle| : (i += 1) {
        const point = tree.entryItem(handle, .point);
        const value = tree.getValue(handle);
        try std.testing.expectEqual(positions[i], point[0]);
        try std.testing.expectEqual(i, value.*);
    }
    try std.testing.expectEqual(positions.len, i);
}

test "phtree query" {
    const a = std.testing.allocator;
    const Tree = PhTree(void, 1, u32);
    var tree: Tree = .empty;
    defer tree.deinit(a);

    try tree.ensureUnusedCapacity(a, 1000);

    for (0..1000) |i| {
        const res = tree.getOrPutAssumeCapacity(&.{@intCast(i)});
        try std.testing.expect(!res.found_existing);
    }

    const ranges = [_][2]u32{
        .{ 1, 1 },
        .{ 2, 100 },
        .{ 0, 999 },
        .{ 1, 999 },
        .{ 2, 3 },
    };

    var results: std.ArrayList(Tree.Entry.Handle) = .init(a);
    defer results.deinit();

    for (ranges) |range| {
        results.clearRetainingCapacity();

        const min, const max = range;
        try tree.queryWindow(&.{min}, &.{max}, &results);
        try std.testing.expectEqual(max - min + 1, results.items.len);
        for (results.items, min..) |item, i| {
            const p = tree.entryItem(item, .point);
            try std.testing.expectEqual(i, p[0]);
        }
    }

    try std.testing.expect(tree.validate());
}

export fn zig_fuzz_init() void {}

export fn zig_fuzz_test(ptr: [*]u8, len_signed: isize) void {
    const len: usize = @intCast(len_signed);
    const buf = ptr[0..len];

    const Tag = enum(u8) {
        insert,
        delete,

        fn fromInt(n: u8) @This() {
            const l = @typeInfo(@This()).@"enum".fields.len;
            const tags = comptime std.meta.tags(@This());
            return tags[n % l];
        }
    };

    const T = extern struct {
        tag: u8,
        data: extern union {
            insert: extern struct {
                p: [4]u32,
                value: u32,
            },
            delete: [4]u32,
        },
    };

    const new_len = len - len % @sizeOf(T);

    const slice: []align(1) const T = @ptrCast(buf[0..new_len]);

    var dbg: std.heap.DebugAllocator(.{}) = .init;
    defer _ = dbg.deinit();
    const gpa = dbg.allocator();

    var tree: PhTree(u32, 4, u32) = .empty;
    defer tree.deinit(gpa);

    for (slice) |t| switch (Tag.fromInt(t.tag)) {
        .insert => {
            const res = tree.getOrPut(gpa, &t.data.insert.p) catch @panic("OOM");
            res.value_ptr.* = t.data.insert.value;
        },
        .delete => {
            _ = tree.remove(&t.data.delete);
        },
    };

    assert(tree.validate());
}
