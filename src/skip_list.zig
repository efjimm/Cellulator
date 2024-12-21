const std = @import("std");
const assert = std.debug.assert;

pub fn SkipList(
    T: type,
    levels: usize,
    Context: type,
) type {
    return struct {
        /// Head node of the highest (most sparse) level
        head: NodeIndex,
        nodes: std.MultiArrayList(Node).Slice,
        rand: std.Random.DefaultPrng,
        ctx: Context,

        pub const Node = struct {
            value: T,
            next: NodeIndex = .invalid,
            prev: NodeIndex = .invalid,
            below: NodeIndex = .invalid,
        };

        // This is a packed struct so we can use equality operators on it.
        pub const NodeIndex = packed struct {
            n: u32,

            pub const invalid: NodeIndex = .{ .n = std.math.maxInt(u32) };

            pub fn from(n: u32) NodeIndex {
                return .{ .n = n };
            }

            pub fn isValid(index: NodeIndex) bool {
                return index != invalid;
            }

            pub fn orElse(index: NodeIndex, n: NodeIndex) NodeIndex {
                return if (index.isValid()) index else n;
            }
        };

        pub fn clearRetainingCapacity(list: *@This()) void {
            list.nodes.len = 0;
            list.head = .invalid;
        }

        pub fn get(list: *const @This(), index: NodeIndex) ?T {
            return if (index.isValid())
                list.nodes.items(.value)[index.n]
            else
                null;
        }

        pub fn insert(
            list: *@This(),
            allocator: std.mem.Allocator,
            value: T,
        ) !NodeIndex {
            if (!list.head.isValid()) {
                return list.insertEmpty(allocator, value);
            }

            if (list.ctx.order(value, list.nodes.items(.value)[list.head.n]) == .lt) {
                return list.insertAtBeggining(allocator, value);
            }

            return list.insertCommon(allocator, value);
        }

        pub fn iterator(list: *@This()) Iterator {
            assert(list.head.isValid());
            const belows = list.nodes.items(.below);

            var index = list.head;
            while (belows[index.n].isValid())
                index = belows[index.n];

            return .{ .node = index, .nodes = list.nodes };
        }

        pub const Iterator = struct {
            nodes: std.MultiArrayList(Node).Slice,
            node: NodeIndex,

            pub fn next(iter: *Iterator) NodeIndex {
                if (iter.node.isValid()) {
                    assert(!iter.nodes.items(.below)[iter.node.n].isValid());
                    const n = iter.node;
                    iter.node = iter.nodes.items(.next)[iter.node.n];
                    return n;
                }

                return .invalid;
            }
        };

        /// From `start`, returns the first node that is >= `value`.
        fn searchToGreater(
            list: *@This(),
            start: NodeIndex,
            value: T,
        ) NodeIndex {
            const values = list.nodes.items(.value);
            const nexts = list.nodes.items(.next);
            assert(start.isValid());
            assert(list.ctx.order(value, values[start.n]) != .lt);

            var n = start;
            while (nexts[n.n].isValid() and list.ctx.order(values[nexts[n.n].n], value) == .lt)
                n = nexts[n.n];

            return n;
        }

        pub fn init(rand_seed: u64) @This() {
            comptime assert(@sizeOf(Context) == 0);

            return .{
                .head = .invalid,
                .rand = .init(rand_seed),
                .nodes = std.MultiArrayList(Node).empty.slice(),
                .ctx = undefined,
            };
        }

        pub fn initContext(rand_seed: u64, context: Context) @This() {
            return .{
                .head = .invalid,
                .rand = .init(rand_seed),
                .free = .invalid,
                .nodes = std.MultiArrayList(Node).empty.slice(),
                .ctx = context,
            };
        }

        pub fn deinit(list: *@This(), allocator: std.mem.Allocator) void {
            list.nodes.deinit(allocator);
        }

        pub fn search(list: *@This(), value: T) NodeIndex {
            if (!list.head.isValid()) return .invalid;
            var i = list.head;

            const values = list.nodes.items(.value);
            const nexts = list.nodes.items(.next);

            for (0..levels) |_| {
                while (nexts[i.n].isValid() and list.ctx.order(value, values[nexts[i.n].n]) != .lt)
                    i = nexts[i.n];

                i = list.nodes.items(.below)[i.n].orElse(i);
            }

            if (i.isValid() and std.math.order(value, values[i.n]) == .eq) {
                return i;
            }

            return .invalid;
        }

        /// Ensures enough space for at laest `n` inserted nodes. May over-allocate by a lot.
        pub fn ensureUnusedCapacity(list: *@This(), allocator: std.mem.Allocator, n: usize) !void {
            var nodes = list.nodes.toMultiArrayList();
            try nodes.ensureUnusedCapacity(allocator, n * levels);
            list.nodes = nodes.slice();
        }

        fn freeNode(list: *@This(), node: NodeIndex) void {
            list.nodes.items(.next)[node.n] = list.free;
            list.free = node;
        }

        fn createNodeAssumeCapacity(list: *@This()) NodeIndex {
            const ret: NodeIndex = .from(@intCast(list.nodes.len));
            list.nodes.len += 1;
            return ret;
        }

        fn insertEmpty(list: *@This(), allocator: std.mem.Allocator, value: T) !NodeIndex {
            assert(!list.head.isValid());

            try list.ensureUnusedCapacity(allocator, 1);
            errdefer comptime unreachable;

            var nodes: [levels]NodeIndex = undefined;
            for (&nodes) |*node| node.* = list.createNodeAssumeCapacity();

            inline for (nodes, 1..) |node, i| {
                list.nodes.set(node.n, .{
                    .value = value,
                    .below = if (i >= nodes.len) .invalid else nodes[i],
                });
            }

            list.head = nodes[0];
            return nodes[nodes.len - 1];
        }

        /// Special case: Inserting at the beginning of the list
        ///
        /// The head of the list must be at the top level and have a node on each level below.
        /// To preserve the performance of the list, we prepend by doing a normal insert after
        /// the head and swapping the values with the head nodes.
        fn insertAtBeggining(list: *@This(), allocator: std.mem.Allocator, value: T) !NodeIndex {
            assert(list.head.isValid());

            try list.ensureUnusedCapacity(allocator, 1);
            errdefer comptime unreachable;

            const level_count = randomLevelCount(list.rand.random());
            const level_start = levels - level_count;

            const values = list.nodes.items(.value);
            const nexts = list.nodes.items(.next);
            const belows = list.nodes.items(.below);

            // Collect the last `level_count` heads.
            const heads = blk: {
                var heads: std.BoundedArray(NodeIndex, levels) = .{};
                var index = list.head;
                for (0..level_start) |_| index = belows[index.n];
                for (0..level_count) |_| {
                    heads.appendAssumeCapacity(index);
                    index = belows[index.orElse(.from(0)).n];
                }
                break :blk heads;
            };

            var nodes: std.BoundedArray(NodeIndex, levels) = .{};
            for (0..level_count) |_|
                nodes.appendAssumeCapacity(list.createNodeAssumeCapacity());

            // Populate and insert nodes
            for (heads.slice(), nodes.slice(), 1..) |head, node, i| {
                list.nodes.set(node.n, .{
                    .value = values[head.n],
                    .prev = head,
                    .next = nexts[head.n],
                    .below = if (i >= nodes.len) .invalid else nodes.get(i),
                });
                nexts[head.n] = node;
            }

            // Overwrite values of head nodes
            var index = list.head;
            while (index.isValid()) : (index = belows[index.n])
                values[index.n] = value;
            return nodes.buffer[nodes.len - 1];
        }

        fn insertCommon(list: *@This(), allocator: std.mem.Allocator, value: T) !NodeIndex {
            assert(list.head.isValid());

            try list.ensureUnusedCapacity(allocator, 1);
            errdefer comptime unreachable;

            const level_count = randomLevelCount(list.rand.random());
            const level_start = levels - level_count;

            const belows = list.nodes.items(.below);
            const nexts = list.nodes.items(.next);
            const prevs = list.nodes.items(.prev);

            // The previous nodes for each level
            const prev_nodes = blk: {
                var start = list.head;
                var prev_nodes: [levels]NodeIndex = undefined;

                for (&prev_nodes) |*node| {
                    const n = list.searchToGreater(start, value);
                    node.* = n;
                    start = belows[n.orElse(.from(0)).n];
                }

                break :blk prev_nodes;
            };

            var nodes: std.BoundedArray(NodeIndex, levels) = .{};
            for (nodes.addManyAsSlice(level_count) catch unreachable) |*node|
                node.* = list.createNodeAssumeCapacity();

            // Create the new nodes to insert
            for (
                prev_nodes[level_start..],
                nodes.constSlice(),
                1..,
            ) |prev, node, i| {
                list.nodes.set(node.n, .{
                    .value = value,
                    .prev = prev,
                    .next = nexts[prev.n],
                    .below = if (i < nodes.len) nodes.get(i) else .invalid,
                });
                if (nexts[prev.n].isValid())
                    prevs[nexts[prev.n].n] = node;
                nexts[prev.n] = node;
            }
            return nodes.buffer[nodes.len - 1];
        }

        fn randomLevelCount(rand: std.Random) usize {
            // Generate `levels` random floats to determine how many levels this node will use.
            var rand_buf: [levels - 1]f32 = undefined;
            rand.bytes(std.mem.asBytes(&rand_buf));

            for (rand_buf, 1..) |f, level| {
                if (f < 0.5) return level;
            }

            return levels;
        }
    };
}

pub fn IntContext(T: type) type {
    return struct {
        pub fn order(_: @This(), a: T, b: T) std.math.Order {
            return std.math.order(a, b);
        }
    };
}

const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;

test "Skiplist something" {
    var list: SkipList(u32, 4, IntContext(u32)) = .init(123);
    defer list.deinit(std.testing.allocator);

    _ = try list.insert(std.testing.allocator, 10);

    try expect(list.head.isValid());
    try expectEqual(10, list.nodes.items(.value)[list.head.n]);

    const n = list.search(10);
    try expect(n.isValid());

    try expectEqual(10, list.nodes.items(.value)[n.n]);
}

var map: []align(std.mem.page_size) u8 = undefined;
var mem: [1_000_000]u8 = undefined;

test "Skiplist fuzz" {
    const T = struct {
        pub fn fuzzFn(input: []const u8) anyerror!void {
            var fba: std.heap.FixedBufferAllocator = .init(&mem);

            var list: SkipList(u8, 4, IntContext(u8)) = .init(123);
            defer list.deinit(fba.allocator());

            for (input) |c| {
                _ = try list.insert(fba.allocator(), c);
            }
            const values = list.nodes.items(.value);

            for (input) |c| {
                const n = list.search(c);
                try expect(n.isValid());
                try expectEqual(c, values[n.n]);
            }
        }
    };

    {
        const file = try std.fs.cwd().createFile("fuzz_out", .{ .read = true });
        defer file.close();

        try std.posix.ftruncate(file.handle, 4096);
        map = try std.posix.mmap(
            null,
            4096,
            std.posix.PROT.READ | std.posix.PROT.WRITE,
            .{ .TYPE = .SHARED },
            file.handle,
            0,
        );
    }
    try std.testing.fuzz(T.fuzzFn, .{});
}

test "Skiplist insert" {
    const T = struct {
        fn lessThan(_: @This(), a: u8, b: u8) bool {
            return a < b;
        }
    };

    var list: SkipList(u8, 2, IntContext(u8)) = .init(123);
    defer list.deinit(std.testing.allocator);

    var input = [_]u8{ 10, 4, 5, 6, 3, 2, 7, 1, 0, 8, 9 };
    for (input) |c| _ = try list.insert(std.testing.allocator, c);
    std.sort.heap(u8, &input, T{}, T.lessThan);

    var iter = list.iterator();
    for (input) |c| {
        var n = list.search(c);
        try expect(n.isValid());
        try expectEqual(c, list.nodes.items(.value)[n.n]);

        n = iter.next();
        try expect(n.isValid());
        try expectEqual(c, list.nodes.items(.value)[n.n]);
    }
}
