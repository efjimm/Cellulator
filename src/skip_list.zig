const std = @import("std");
const assert = std.debug.assert;

pub fn SkipList(
    T: type,
    levels: usize,
    Context: type,
) type {
    return struct {
        /// Head node of the highest (most sparse) level
        heads: [levels]Handle,
        nodes: std.MultiArrayList(Node).Slice,
        rand: std.Random.DefaultPrng,
        ctx: Context,

        pub const Node = struct {
            value: T,
            next: Handle = .invalid,
            prev: Handle = .invalid,
            below: Handle = .invalid,
        };

        // This is a packed struct so we can use equality operators on it.
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

            pub fn orElse(index: Handle, n: Handle) Handle {
                return if (index.isValid()) index else n;
            }
        };

        pub fn clearRetainingCapacity(list: *@This()) void {
            list.nodes.len = 0;
            list.heads = [_]Handle{.invalid} ** levels;
        }

        pub fn get(list: *const @This(), index: Handle) ?T {
            return if (index.isValid())
                list.nodes.items(.value)[index.n]
            else
                null;
        }

        /// Callers should NOT modify the returned value in such a way that changes the ordering.
        pub fn getPtr(list: *const @This(), index: Handle) ?*T {
            return if (index.isValid())
                &list.nodes.items(.value)[index.n]
            else
                null;
        }

        pub fn insert(
            list: *@This(),
            allocator: std.mem.Allocator,
            value: T,
        ) !Handle {
            const head = list.heads[list.heads.len - 1];
            if (!head.isValid() or list.ctx.order(value, list.nodes.items(.value)[head.n]) != .gt) {
                return list.insertAtBeggining(allocator, value);
            }

            return list.insertCommon(allocator, value);
        }

        pub fn iterator(list: *@This()) Iterator {
            return .{ .node = list.heads[list.heads.len - 1], .nodes = list.nodes };
        }

        pub const Iterator = struct {
            nodes: std.MultiArrayList(Node).Slice,
            node: Handle,

            pub fn next(iter: *Iterator) Handle {
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
        pub fn searchToGreater(
            list: *@This(),
            start: Handle,
            value: T,
        ) Handle {
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
                .heads = [_]Handle{.invalid} ** levels,
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

        pub fn search(list: *@This(), value: T) Handle {
            const values = list.nodes.items(.value);
            const nexts = list.nodes.items(.next);

            for (list.heads) |head| {
                if (!head.isValid()) continue;
                if (list.ctx.order(value, values[head.n]) == .lt) continue;

                var i = head;

                for (0..levels) |_| {
                    while (nexts[i.n].isValid() and list.ctx.order(value, values[nexts[i.n].n]) != .lt)
                        i = nexts[i.n];

                    i = list.nodes.items(.below)[i.n].orElse(i);
                }

                if (i.isValid() and list.ctx.order(value, values[i.n]) == .eq) {
                    const belows = list.nodes.items(.below);
                    while (belows[i.n].isValid()) i = belows[i.n];
                    return i;
                }

                return .invalid;
            }

            return .invalid;
        }

        /// Ensures enough space for at least `n` inserted nodes.
        pub fn ensureUnusedCapacity(list: *@This(), allocator: std.mem.Allocator, n: usize) !void {
            var nodes = list.nodes.toMultiArrayList();
            try nodes.ensureUnusedCapacity(allocator, n * levels);
            list.nodes = nodes.slice();
        }

        fn createNodeAssumeCapacity(list: *@This()) Handle {
            const ret: Handle = .from(@intCast(list.nodes.len));
            list.nodes.len += 1;
            return ret;
        }

        fn insertAtBeggining(list: *@This(), allocator: std.mem.Allocator, value: T) !Handle {
            try list.ensureUnusedCapacity(allocator, 1);
            errdefer comptime unreachable;

            const level_count = randomLevelCount(list.rand.random());
            const level_start = levels - level_count;

            for (list.heads[level_start..]) |*head| {
                const node = list.createNodeAssumeCapacity();

                if (head.isValid()) {
                    list.nodes.items(.prev)[head.n] = node;
                }

                list.nodes.set(node.n, .{
                    .value = value,
                    .next = head.*,
                    .below = .from(node.n + 1),
                });
                head.* = node;
            }

            list.nodes.items(.below)[list.nodes.len - 1] = .invalid;

            return .from(@intCast(list.nodes.len - 1));
        }

        fn insertCommon(list: *@This(), allocator: std.mem.Allocator, value: T) !Handle {
            assert(list.heads[list.heads.len - 1].isValid());

            try list.ensureUnusedCapacity(allocator, 1);
            errdefer comptime unreachable;

            const level_count = randomLevelCount(list.rand.random());
            const level_start = levels - level_count;
            const values = list.nodes.items(.value);

            // Index of the first head <= `value`.
            const index = for (list.heads, 0..) |head, i| {
                if (!head.isValid()) continue;
                if (list.ctx.order(value, values[head.n]) != .lt)
                    break i;
            } else unreachable;

            var prev_nodes: std.BoundedArray(Handle, levels) = .{};
            prev_nodes.appendNTimesAssumeCapacity(.invalid, index);
            var start = list.heads[index];
            const belows = list.nodes.items(.below);

            while (start.isValid()) : (start = belows[start.n]) {
                const n = list.searchToGreater(start, value);
                prev_nodes.appendAssumeCapacity(n);
            }

            const nexts = list.nodes.items(.next);
            const prevs = list.nodes.items(.prev);

            for (prev_nodes.constSlice()[level_start..]) |prev| {
                const new_node = list.createNodeAssumeCapacity();

                list.nodes.set(new_node.n, .{
                    .value = value,
                    .next = if (prev.isValid()) nexts[prev.n] else .invalid,
                    .prev = prev,
                    // NOTE: Needs to change if freeing nodes is implemented.
                    .below = .from(new_node.n + 1),
                });

                if (prev.isValid()) {
                    if (nexts[prev.n].isValid()) {
                        prevs[nexts[prev.n].n] = new_node;
                    }

                    nexts[prev.n] = new_node;
                }
            }

            list.nodes.items(.below)[list.nodes.len - 1] = .invalid;

            return .from(@intCast(list.nodes.len - 1));
        }

        fn randomLevelCount(rand: std.Random) usize {
            // Generate `levels` random floats to determine how many levels this node will use.
            var rand_buf: [levels - 1]f32 = undefined;
            rand.bytes(std.mem.asBytes(&rand_buf));

            for (rand_buf, 1..) |f, level| {
                if (f < 0.5) return level;
            }

            assert(levels != 0);
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
    var list: SkipList(u32, 1, IntContext(u32)) = .init(123);
    defer list.deinit(std.testing.allocator);

    _ = try list.insert(std.testing.allocator, 10);

    const head = list.heads[list.heads.len - 1];
    try expect(head.isValid());
    try expectEqual(10, list.nodes.items(.value)[head.n]);

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
