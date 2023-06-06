const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// A list whose `len` and `capacity` are part of the allocated memory. Useful in cases where you
/// don't want the memory overhead of the list `len` and `capacity` variables when not actually
/// using the list.
pub fn HeaderList(comptime T: type, comptime Size: type) type {
    return struct {
        const List = @This();
        const alignment = @max(@alignOf(List), @alignOf(T));

        len: Size = 0,
        capacity: Size = 0,

        pub fn items(list: *List) []align(alignment) T {
            const ptr = @ptrCast([*]align(alignment) u8, list);
            return @ptrCast([*]align(alignment) T, ptr + @sizeOf(List))[0..list.len];
        }

        pub fn allocatedSlice(list: *List) []align(alignment) u8 {
            const ptr = @ptrCast([*]align(alignment) u8, list);
            return ptr[0 .. @sizeOf(List) + @as(usize, list.capacity) * @sizeOf(T)];
        }

        pub fn clearRetainingCapacity(list: *List) void {
            list.len = 0;
        }

        pub fn create(allocator: Allocator, initial_capacity: Size) Allocator.Error!*List {
            const size = @sizeOf(List) + @sizeOf(T) * initial_capacity;
            const bytes = try allocator.alignedAlloc(u8, alignment, size);

            const list = @ptrCast(*List, bytes);
            list.* = .{
                .capacity = initial_capacity,
            };
            return list;
        }

        pub fn destroy(list: *List, allocator: Allocator) void {
            const slice = list.allocatedSlice();
            allocator.free(slice);
        }

        pub fn ensureTotalCapacity(
            list: *List,
            allocator: Allocator,
            new_capacity: Size,
        ) Allocator.Error!*List {
            if (list.capacity >= new_capacity) return list;

            var better_capacity = list.capacity;
            while (true) {
                better_capacity +|= better_capacity / 2 + 8;
                if (better_capacity >= new_capacity) break;
            }

            return list.ensureTotalCapacityPrecise(allocator, better_capacity);
        }

        pub fn ensureTotalCapacityPrecise(
            list: *List,
            allocator: Allocator,
            new_capacity: Size,
        ) Allocator.Error!*List {
            if (list.capacity >= new_capacity) return list;

            const old_bytes = list.allocatedSlice();
            const new_bytes = try allocator.realloc(old_bytes, @sizeOf(List) + @sizeOf(T) * new_capacity);
            const l = @ptrCast(*List, new_bytes);
            l.capacity = new_capacity;
            return l;
        }

        pub fn ensureUnusedCapacity(
            list: *List,
            allocator: Allocator,
            capacity: Size,
        ) Allocator.Error!*List {
            const unused = list.capacity - list.len;
            if (unused >= capacity) return list;

            return list.ensureTotalCapacity(allocator, list.capacity + (capacity - unused));
        }

        pub fn append(list: *List, allocator: Allocator, item: T) Allocator.Error!*List {
            const l = try list.ensureTotalCapacity(allocator, list.len + 1);
            l.items().ptr[l.len] = item;
            l.len += 1;
            return l;
        }

        pub fn appendAssumeCapacity(list: *List, item: T) void {
            assert(list.len < list.capacity);
            list.items().ptr[list.len] = item;
            list.len += 1;
        }

        pub fn appendSlice(
            list: *List,
            allocator: Allocator,
            slice: []const T,
        ) Allocator.Error!*List {
            const l = try list.ensureUnusedCapacity(allocator, @intCast(Size, slice.len));
            for (slice) |item| {
                l.appendAssumeCapacity(item);
            }
            return l;
        }

        pub fn appendSliceAssumeCapacity(list: *List, slice: []const T) void {
            for (slice) |item| list.appendAssumeCapacity(item);
        }

        pub fn pop(list: *List) T {
            assert(list.len > 0);
            const ret = list.items()[list.len - 1];
            list.len -= 1;
            return ret;
        }

        pub fn popOrNull(list: *List) ?T {
            return if (list.len == 0) null else list.pop();
        }

        pub fn orderedRemove(list: *List, index: Size) T {
            assert(index < list.len);
            const slice = list.items();
            const new_len = list.len - 1;

            const ret = slice[index];

            for (slice[index..new_len], slice[index + 1 ..]) |*dest, src| {
                dest.* = src;
            }

            list.len = new_len;
            return ret;
        }

        pub fn swapRemove(list: *List, index: Size) T {
            assert(index < list.len);

            const new_len = list.len - 1;
            const slice = list.items();

            const ret = slice[index];
            slice[index] = slice[new_len];
            list.len = new_len;
            return ret;
        }
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const List = HeaderList(u32, u32);

    var list = try List.create(allocator, 0);
    defer {
        list.destroy(allocator);
    }

    list = try list.appendSlice(allocator, &.{ 0, 1 });
    list = try list.appendSlice(allocator, &.{ 2, 3, 4 });

    _ = list.swapRemove(2);

    for (list.items()) |elem| {
        std.debug.print("{d}\n", .{elem});
    }
}
