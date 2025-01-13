const std = @import("std");
const assert = std.debug.assert;
const testing = std.testing;
const Order = std.math.Order;
const utils = @import("utils.zig");

pub fn Treap(comptime Key: type, comptime compareFn: anytype) type {
    return struct {
        const Self = @This();

        // Allow for compareFn to be fn (anytype, anytype) anytype
        // which allows the convenient use of std.math.order.
        fn compare(a: Key, b: Key) Order {
            return compareFn(a, b);
        }

        nodes: std.ArrayListUnmanaged(Node),
        root: Handle,
        prng: std.Random.DefaultPrng,

        pub fn init(seed: u64) Self {
            return .{
                .nodes = .empty,
                .root = .invalid,
                .prng = .init(seed),
            };
        }

        pub const Handle = packed struct {
            n: u32,

            pub fn from(n: u32) Handle {
                assert(n < std.math.maxInt(u32));
                return .{ .n = n };
            }

            pub fn isValid(handle: Handle) bool {
                return handle != invalid;
            }

            pub fn get(handle: Handle) ?Handle {
                if (handle.isValid())
                    return handle;
                return null;
            }

            pub const invalid: Handle = .{ .n = std.math.maxInt(u32) };
        };

        /// A Node represents an item or point in the treap with a uniquely associated key.
        pub const Node = extern struct {
            key: Key,
            priority: usize,
            parent: Handle,
            children: [2]Handle,
        };

        pub fn nextNode(treap: *Self, handle: Handle) Handle {
            return treap.nextOnDirection(handle, 1);
        }
        pub fn prevNode(treap: *Self, handle: Handle) Handle {
            return treap.nextOnDirection(handle, 0);
        }

        /// Returns a handle to a new uninitialized node.
        pub fn createNode(treap: *Self, allocator: std.mem.Allocator) !Handle {
            try treap.nodes.ensureUnusedCapacity(allocator, 1);
            return treap.createNodeAssumeCapacity();
        }

        /// Returns a handle to a new uninitialized node.
        /// Asserts that the underlying nodes array has enough capacity.
        pub fn createNodeAssumeCapacity(treap: *Self) Handle {
            const ret: Handle = .from(@intCast(treap.nodes.items.len));
            treap.nodes.items.len += 1;
            return ret;
        }

        fn extremeInSubtreeOnDirection(treap: Self, handle: Handle, direction: u1) Handle {
            assert(handle.isValid());
            var cur = handle;
            while (treap.node(cur).children[direction].get()) |child| {
                cur = child;
            }
            return cur;
        }

        pub fn node(treap: *const Self, handle: Handle) *Node {
            return &treap.nodes.items[handle.n];
        }

        pub fn handleFromNode(treap: *const Self, n: *const Node) Handle {
            const nodes_ptr = treap.nodes.items.ptr;
            const index = @divExact(@intFromPtr(n) - @intFromPtr(nodes_ptr), @sizeOf(Node));
            return .from(@intCast(index));
        }

        fn nextOnDirection(treap: *Self, handle: Handle, direction: u1) Handle {
            if (treap.node(handle).children[direction].get()) |child| {
                return treap.extremeInSubtreeOnDirection(child, direction ^ 1);
            }
            var cur = handle;
            // Traversing upward until we find `parent` to `cur` is NOT on
            // `direction`, or equivalently, `cur` to `parent` IS on
            // `direction` thus `parent` is the next.
            while (treap.node(cur).parent.get()) |parent| : (cur = parent) {
                // If `parent -> node` is NOT on `direction`, then
                // `node -> parent` IS on `direction`
                if (treap.node(parent).children[direction] != cur)
                    return parent;
            }

            return .invalid;
        }

        /// Returns the smallest Node by key in the treap if there is one.
        /// Use `getEntryForExisting()` to replace/remove this Node from the treap.
        pub fn getMin(self: Self) Handle {
            if (self.root.get()) |root|
                return self.extremeInSubtreeOnDirection(root, 0);
            return .invalid;
        }

        /// Returns the largest Node by key in the treap if there is one.
        /// Use `getEntryForExisting()` to replace/remove this Node from the treap.
        pub fn getMax(self: Self) Handle {
            if (self.root.get()) |root|
                return self.extremeInSubtreeOnDirection(root, 1);
            return .invalid;
        }

        /// Lookup the Entry for the given key in the treap.
        /// The Entry act's as a slot in the treap to insert/replace/remove the node associated with the key.
        pub fn getEntryFor(self: *Self, key: Key) Entry {
            var parent: Handle = undefined;
            const handle = self.find(key, &parent);

            return Entry{
                .key = key,
                .treap = self,
                .node = handle,
                .context = .{ .inserted_under = parent },
            };
        }

        /// Get an entry for a Node that currently exists in the treap.
        /// It is undefined behavior if the Node is not currently inserted in the treap.
        /// The Entry act's as a slot in the treap to insert/replace/remove the node associated with the key.
        pub fn getEntryForExisting(self: *Self, handle: Handle) Entry {
            assert(self.node(handle).priority != 0);

            return Entry{
                .key = self.node(handle).key,
                .treap = self,
                .node = handle,
                .context = .{ .inserted_under = self.node(handle).parent },
            };
        }

        /// An Entry represents a slot in the treap associated with a given key.
        pub const Entry = struct {
            /// The associated key for this entry.
            key: Key,
            /// A reference to the treap this entry is apart of.
            treap: *Self,
            /// The current node at this entry.
            node: Handle,
            /// The current state of the entry.
            context: union(enum) {
                /// A find() was called for this entry and the position in the treap is known.
                inserted_under: Handle,
                /// The entry's node was removed from the treap and a lookup must occur again for modification.
                removed,
            },

            /// Update's the Node at this Entry in the treap with the new node (null for deleting). `new_node`
            /// can have `undefind` content because the value will be initialized internally.
            pub fn set(self: *Entry, new_node: Handle) void {
                // Update the entry's node reference after updating the treap below.
                defer self.node = new_node;

                if (self.node.get()) |old| {
                    if (new_node.get()) |new| {
                        self.treap.replace(old, new);
                        return;
                    }

                    self.treap.remove(old);
                    self.context = .removed;
                    return;
                }

                if (new_node.get()) |new| {
                    // A previous treap.remove() could have rebalanced the nodes
                    // so when inserting after a removal, we have to re-lookup the parent again.
                    // This lookup shouldn't find a node because we're yet to insert it..
                    var parent: Handle = undefined;
                    switch (self.context) {
                        .inserted_under => |p| parent = p,
                        .removed => assert(!self.treap.find(self.key, &parent).isValid()),
                    }

                    self.treap.insert(self.key, parent, new);
                    self.context = .{ .inserted_under = parent };
                }
            }
        };

        fn find(self: Self, key: Key, parent_ref: *Handle) Handle {
            var handle = self.root;
            parent_ref.* = .invalid;

            // basic binary search while tracking the parent.
            while (handle.get()) |current| {
                const order = compare(key, self.node(current).key);
                if (order == .eq) break;

                parent_ref.* = current;
                handle = self.node(current).children[@intFromBool(order == .gt)];
            }

            return handle;
        }

        fn insert(self: *Self, key: Key, parent: Handle, handle: Handle) void {
            assert(handle.isValid());
            // generate a random priority & prepare the node to be inserted into the tree
            self.node(handle).* = .{
                .key = key,
                .priority = self.prng.random().int(usize),
                .parent = parent,
                .children = .{ .invalid, .invalid },
            };

            // point the parent at the new node
            const link = if (parent.get()) |p|
                &self.node(p).children[@intFromBool(compare(key, self.node(p).key) == .gt)]
            else
                &self.root;
            assert(!link.isValid());
            link.* = handle;

            // rotate the node up into the tree to balance it according to its priority
            while (self.node(handle).parent.get()) |p| {
                if (self.node(p).priority <= self.node(handle).priority) break;

                const is_right = self.node(p).children[1] == handle;
                assert(self.node(p).children[@intFromBool(is_right)] == handle);

                const rotate_right = !is_right;
                self.rotate(p, rotate_right);
            }
        }

        fn replace(self: *Self, old: Handle, new: Handle) void {
            assert(old.isValid());
            assert(new.isValid());
            // copy over the values from the old node
            self.node(new).* = .{
                .key = self.node(old).key,
                .priority = self.node(old).priority,
                .parent = self.node(old).parent,
                .children = self.node(old).children,
            };

            // point the parent at the new node
            const link = if (self.node(old).parent.get()) |p|
                &self.node(p).children[@intFromBool(self.node(p).children[1] == old)]
            else
                &self.root;
            assert(link.* == old);
            link.* = new;

            // point the children's parent at the new node
            for (self.node(old).children) |child| {
                if (child.isValid()) {
                    assert(self.node(child).parent == old);
                    self.node(child).parent = new;
                }
            }
        }

        pub fn remove(self: *Self, handle: Handle) void {
            assert(handle.isValid());
            // rotate the node down to be a leaf of the tree for removal, respecting priorities.
            while (self.node(handle).children[0].get() orelse self.node(handle).children[1].get()) |_| {
                self.rotate(handle, rotate_right: {
                    const right = self.node(handle).children[1].get() orelse break :rotate_right true;
                    const left = self.node(handle).children[0].get() orelse break :rotate_right false;
                    break :rotate_right (self.node(left).priority < self.node(right).priority);
                });
            }

            // node is a now a leaf; remove by nulling out the parent's reference to it.
            const link = if (self.node(handle).parent.get()) |p|
                &self.node(p).children[@intFromBool(self.node(p).children[1] == handle)]
            else
                &self.root;
            assert(link.* == handle);
            link.* = .invalid;

            // clean up after ourselves
            self.node(handle).priority = 0;
            self.node(handle).parent = .invalid;
            self.node(handle).children = .{ .invalid, .invalid };
        }

        fn rotate(self: *Self, handle: Handle, right: bool) void {
            // if right, converts the following:
            //      parent -> (node (target YY adjacent) XX)
            //      parent -> (target YY (node adjacent XX))
            //
            // if left (!right), converts the following:
            //      parent -> (node (target YY adjacent) XX)
            //      parent -> (target YY (node adjacent XX))
            const parent = self.node(handle).parent;
            const target = self.node(handle).children[@intFromBool(!right)].get() orelse unreachable;
            const adjacent = self.node(target).children[@intFromBool(right)];

            // rotate the children
            self.node(target).children[@intFromBool(right)] = handle;
            self.node(handle).children[@intFromBool(!right)] = adjacent;

            // rotate the parents
            self.node(handle).parent = target;
            self.node(target).parent = parent;
            if (adjacent.get()) |adj| self.node(adj).parent = handle;

            // fix the parent link
            const link = if (parent.get()) |p|
                &self.node(p).children[@intFromBool(self.node(p).children[1] == handle)]
            else
                &self.root;
            assert(link.* == handle);
            link.* = target;
        }

        /// Usage example:
        ///   var iter = treap.inorderIterator();
        ///   while (iter.next()) |node| {
        ///     ...
        ///   }
        pub const InorderIterator = struct {
            current: Handle,
            treap: *Self,

            pub fn next(it: *InorderIterator) ?Handle {
                const current = it.current;
                it.current = if (current.get()) |cur|
                    it.treap.nextNode(cur)
                else
                    .invalid;
                return current.get();
            }
        };

        pub fn inorderIterator(self: *Self) InorderIterator {
            return .{ .current = self.getMin(), .treap = self };
        }

        // For serialization

        pub const Header = extern struct {
            nodes_len: u32,
            root: Handle,
        };

        pub fn iovecs(treap: *Self) std.posix.iovec_const {
            return utils.ptrToIoVec(treap.nodes.items);
        }

        pub fn getHeader(treap: *const Self) Header {
            return .{ .nodes_len = @intCast(treap.nodes.items.len), .root = treap.root };
        }

        pub fn fromHeader(
            treap: *Self,
            allocator: std.mem.Allocator,
            header: Header,
            seed: u64,
        ) !std.posix.iovec {
            treap.* = .init(seed);
            errdefer treap.nodes.deinit(allocator);

            treap.root = header.root;
            _ = try treap.nodes.addManyAt(allocator, 0, header.nodes_len);

            return @bitCast(treap.iovecs());
        }
    };
}

const TestTreap = Treap(u64, std.math.order);
const TestNode = TestTreap.Node;

test "getMin, getMax, simple" {
    var treap: TestTreap = .init(1);
    try treap.nodes.ensureUnusedCapacity(testing.allocator, 3);
    defer treap.nodes.deinit(testing.allocator);

    const nodes: [3]TestTreap.Handle = .{
        treap.createNodeAssumeCapacity(),
        treap.createNodeAssumeCapacity(),
        treap.createNodeAssumeCapacity(),
    };

    try testing.expect(!treap.getMin().isValid());
    try testing.expect(!treap.getMax().isValid());
    { // nodes[1]
        var entry = treap.getEntryFor(1);
        entry.set(nodes[1]);
        try testing.expectEqual(nodes[1], treap.getMin());
        try testing.expectEqual(nodes[1], treap.getMax());
    }
    { // nodes[0]
        var entry = treap.getEntryFor(0);
        entry.set(nodes[0]);
        try testing.expectEqual(nodes[0], treap.getMin());
        try testing.expectEqual(nodes[1], treap.getMax());
    }
    { // nodes[2]
        var entry = treap.getEntryFor(2);
        entry.set(nodes[2]);
        try testing.expectEqual(nodes[0], treap.getMin());
        try testing.expectEqual(nodes[2], treap.getMax());
    }
}

// For iterating a slice in a random order
// https://lemire.me/blog/2017/09/18/visiting-all-values-in-an-array-exactly-once-in-random-order/
fn SliceIterRandomOrder(comptime T: type) type {
    return struct {
        rng: std.Random,
        slice: []T,
        index: usize = undefined,
        offset: usize = undefined,
        co_prime: usize,

        const Self = @This();

        pub fn init(slice: []T, rng: std.Random) Self {
            return Self{
                .rng = rng,
                .slice = slice,
                .co_prime = blk: {
                    if (slice.len == 0) break :blk 0;
                    var prime = slice.len / 2;
                    while (prime < slice.len) : (prime += 1) {
                        var gcd = [_]usize{ prime, slice.len };
                        while (gcd[1] != 0) {
                            const temp = gcd;
                            gcd = [_]usize{ temp[1], temp[0] % temp[1] };
                        }
                        if (gcd[0] == 1) break;
                    }
                    break :blk prime;
                },
            };
        }

        pub fn reset(self: *Self) void {
            self.index = 0;
            self.offset = self.rng.int(usize);
        }

        pub fn next(self: *Self) ?T {
            if (self.index >= self.slice.len) return null;
            defer self.index += 1;
            return self.slice[((self.index *% self.co_prime) +% self.offset) % self.slice.len];
        }
    };
}

test "insert, find, replace, remove" {
    var treap: TestTreap = .init(1);

    try treap.nodes.ensureUnusedCapacity(testing.allocator, 10);
    defer treap.nodes.deinit(testing.allocator);

    var handles: [10]TestTreap.Handle = undefined;
    for (&handles) |*handle| {
        handle.* = treap.createNodeAssumeCapacity();
    }

    var prng = std.Random.DefaultPrng.init(0xdeadbeef);
    var iter = SliceIterRandomOrder(TestTreap.Handle).init(&handles, prng.random());

    // insert check
    iter.reset();
    while (iter.next()) |handle| {
        const key = prng.random().int(u64);

        // make sure the current entry is empty.
        var entry = treap.getEntryFor(key);
        try testing.expectEqual(key, entry.key);
        try testing.expect(!entry.node.isValid());

        // insert the entry and make sure the fields are correct.
        entry.set(handle);
        try testing.expectEqual(key, treap.node(handle).key);
        try testing.expectEqual(key, entry.key);
        try testing.expectEqual(handle, entry.node);
    }

    // find check
    iter.reset();
    while (iter.next()) |handle| {
        const node = treap.node(handle);
        const key = node.key;

        // find the entry by-key and by-node after having been inserted.
        const entry = treap.getEntryFor(node.key);
        try testing.expectEqual(key, entry.key);
        try testing.expectEqual(handle, entry.node);
        try testing.expectEqual(treap.getEntryForExisting(handle).node, entry.node);
    }

    // in-order iterator check
    {
        var it = treap.inorderIterator();
        var last_key: u64 = 0;
        while (it.next()) |handle| {
            const node = treap.node(handle);
            try std.testing.expect(node.key >= last_key);
            last_key = node.key;
        }
    }

    // replace check
    iter.reset();
    while (iter.next()) |handle| {
        const node = treap.node(handle);
        const key = node.key;

        // find the entry by node since we already know it exists
        var entry = treap.getEntryForExisting(handle);
        try testing.expectEqual(entry.key, key);
        try testing.expectEqual(entry.node, handle);

        const stub_handle = try treap.createNode(testing.allocator);

        // replace the node with a stub_node and ensure future finds point to the stub_node.
        entry.set(stub_handle);
        try testing.expectEqual(entry.node, stub_handle);
        try testing.expectEqual(entry.node, treap.getEntryFor(key).node);
        try testing.expectEqual(entry.node, treap.getEntryForExisting(stub_handle).node);

        // replace the stub_node back to the node and ensure future finds point to the old node.
        entry.set(handle);
        try testing.expectEqual(entry.node, handle);
        try testing.expectEqual(entry.node, treap.getEntryFor(key).node);
        try testing.expectEqual(entry.node, treap.getEntryForExisting(handle).node);
    }

    // remove check
    iter.reset();
    while (iter.next()) |handle| {
        const node = treap.node(handle);
        const key = node.key;

        // find the entry by node since we already know it exists
        var entry = treap.getEntryForExisting(handle);
        try testing.expectEqual(entry.key, key);
        try testing.expectEqual(entry.node, handle);

        // remove the node at the entry and ensure future finds point to it being removed.
        entry.set(.invalid);
        try testing.expect(!entry.node.isValid());
        try testing.expectEqual(entry.node, treap.getEntryFor(key).node);

        // insert the node back and ensure future finds point to the inserted node
        entry.set(handle);
        try testing.expectEqual(entry.node, handle);
        try testing.expectEqual(entry.node, treap.getEntryFor(key).node);
        try testing.expectEqual(entry.node, treap.getEntryForExisting(handle).node);

        // remove the node again and make sure it was cleared after the insert
        entry.set(.invalid);
        try testing.expect(!entry.node.isValid());
        try testing.expectEqual(entry.node, treap.getEntryFor(key).node);
    }
}
