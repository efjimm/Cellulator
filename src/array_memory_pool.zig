const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// A memory pool backed by an array that returns indexes into the array as handles.
/// The index type is specefied as `Index`
pub fn ArrayMemoryPool(comptime T: type, comptime Index: type) type {
    if (@typeInfo(Index) != .Int) @compileError("Expected integer type for index");

    return struct {
        const Pool = @This();

        const U = union {
            next_free: Index,
            value: T,
        };

        first_free: Index = 0,
        ptr: [*]U = undefined,
        len: Index = 0,
        capacity: Index = 0,

        pub fn ensureTotalCapacityPrecise(
            pool: *Pool,
            allocator: Allocator,
            new_capacity: Index,
        ) Allocator.Error!void {
            const old_memory = pool.allocatedSlice();
            if (allocator.resize(old_memory, new_capacity)) {
                pool.capacity = new_capacity;
            } else {
                const new_memory = try allocator.alloc(U, new_capacity);
                @memcpy(new_memory[0..pool.len], old_memory);
                allocator.free(old_memory);
                pool.ptr = new_memory.ptr;
                pool.capacity = @intCast(new_memory.len);
            }
        }

        pub fn ensureTotalCapacity(
            pool: *Pool,
            allocator: Allocator,
            new_capacity: Index,
        ) Allocator.Error!void {
            if (pool.capacity >= new_capacity) return;

            var better_capacity = pool.capacity;
            while (true) {
                better_capacity +|= better_capacity / 2 + 8;
                if (better_capacity >= new_capacity) break;
            }

            return pool.ensureTotalCapacityPrecise(allocator, better_capacity);
        }

        fn allocatedSlice(pool: *Pool) []U {
            return pool.ptr[0..pool.capacity];
        }

        pub fn initCapacity(allocator: Allocator, capacity: Index) Allocator.Error!Pool {
            var ret = Pool{};
            try ret.ensureTotalCapacity(allocator, capacity);
            return ret;
        }

        pub fn deinit(pool: *Pool, allocator: Allocator) void {
            allocator.free(pool.allocatedSlice());
            pool.* = undefined;
        }

        pub fn create(pool: *Pool, allocator: Allocator) Allocator.Error!Index {
            if (pool.first_free < pool.len) {
                const ret = pool.first_free;
                pool.first_free = pool.ptr[ret].next_free;
                pool.ptr[ret] = .{ .value = undefined };
                return ret;
            }

            const ret = pool.len;
            try pool.ensureTotalCapacity(allocator, pool.len + 1);

            pool.ptr[pool.len] = .{ .value = undefined };
            pool.len += 1;

            pool.first_free = pool.len;
            return ret;
        }

        pub fn createWithInit(pool: *Pool, allocator: Allocator, value: T) Allocator.Error!Index {
            const ret = try pool.create(allocator);
            pool.set(ret, value);
            return ret;
        }

        pub fn destroy(pool: *Pool, index: Index) void {
            pool.ptr[index] = .{ .next_free = pool.first_free };
            pool.first_free = index;
        }

        pub fn get(pool: Pool, index: Index) T {
            assert(index < pool.len);
            return pool.ptr[index].value;
        }

        pub fn set(pool: *Pool, index: Index, value: T) void {
            assert(index < pool.len);
            pool.ptr[index].value = value;
        }
    };
}

test {
    const allocator = std.testing.allocator;
    var pool: ArrayMemoryPool([]const u8, u8) = .{};
    defer pool.deinit(std.testing.allocator);

    const index1 = try pool.create(allocator);
    const index2 = try pool.createWithInit(allocator, "This is epic");
    const index3 = try pool.createWithInit(allocator, "Epic");

    try std.testing.expect(index1 != index2);
    try std.testing.expect(index1 != index3);
    try std.testing.expect(index2 != index3);

    pool.set(index1, "Nice");
    pool.set(index3, "hehe");

    try std.testing.expectEqualStrings("Nice", pool.get(index1));
    try std.testing.expectEqualStrings("This is epic", pool.get(index2));
    try std.testing.expectEqualStrings("hehe", pool.get(index3));

    pool.destroy(index2);
    try std.testing.expectEqual(index2, pool.first_free);
    try std.testing.expectEqual(pool.len, pool.ptr[index2].next_free);

    pool.destroy(index1);
    try std.testing.expectEqual(index1, pool.first_free);
    try std.testing.expectEqual(index2, pool.ptr[index1].next_free);
    try std.testing.expectEqual(pool.len, pool.ptr[index2].next_free);

    pool.destroy(index3);
    try std.testing.expectEqual(index3, pool.first_free);
    try std.testing.expectEqual(index1, pool.ptr[index3].next_free);
    try std.testing.expectEqual(index2, pool.ptr[index1].next_free);
    try std.testing.expectEqual(pool.len, pool.ptr[index2].next_free);
}
