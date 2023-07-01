const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// An ArrayList implementation that accepts a type parameter for the `len` and `capacity` fields,
/// allowing it to use less memory than the normal `std.ArrayList`
pub fn SizedArrayListUnmanaged(comptime T: type, comptime Size: type) type {
    if (@typeInfo(Size) != .Int) @compileError("'Size' parameter must be an integer type");

    return struct {
        ptr: [*]T = @constCast(&[_]T{}).ptr,
        len: Size = 0,
        capacity: Size = 0,

        const Self = @This();

        pub fn deinit(self: *Self, allocator: Allocator) void {
            const slice = self.allocatedSlice();
            allocator.free(slice);
        }

        pub fn allocatedSlice(self: Self) []T {
            return self.ptr[0..self.capacity];
        }

        pub fn unusedSlice(self: Self) []T {
            return self.ptr[self.len..self.capacity];
        }

        pub inline fn items(self: Self) []T {
            return self.ptr[0..self.len];
        }

        pub fn ensureTotalCapacity(
            self: *Self,
            allocator: Allocator,
            new_capacity: Size,
        ) Allocator.Error!void {
            if (self.capacity >= new_capacity) return;

            var better_capacity = self.capacity;
            while (true) {
                better_capacity +|= better_capacity / 2 + 8;
                if (better_capacity >= new_capacity) break;
            }

            return self.ensureTotalCapacityPrecise(allocator, better_capacity);
        }

        pub fn ensureTotalCapacityPrecise(
            self: *Self,
            allocator: Allocator,
            new_capacity: Size,
        ) Allocator.Error!void {
            if (self.capacity >= new_capacity) return;

            const old_memory = self.allocatedSlice();
            const new_memory = try allocator.realloc(old_memory, new_capacity);
            self.ptr = new_memory.ptr;
            self.capacity = new_capacity;
        }

        pub fn ensureUnusedCapacity(
            self: *Self,
            allocator: Allocator,
            n: Size,
        ) Allocator.Error!void {
            return self.ensureTotalCapacity(allocator, self.len + n);
        }

        pub fn addOne(self: *Self, allocator: Allocator) Allocator.Error!*T {
            const newlen = self.len + 1;
            try self.ensureTotalCapacity(allocator, newlen);
            return self.addOneAssumeCapacity();
        }

        pub fn addOneAssumeCapacity(self: *Self) Allocator.Error!*T {
            assert(self.len < self.capacity);
            self.len += 1;
            return &self.items()[self.len - 1];
        }

        pub fn append(self: *Self, allocator: Allocator, item: T) Allocator.Error!void {
            const new_item_ptr = try self.addOne(allocator);
            new_item_ptr.* = item;
        }

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            const new_item_ptr = self.addOneAssumeCapacity();
            new_item_ptr.* = item;
        }

        pub fn appendSliceAssumeCapacity(
            self: *Self,
            slice: []const T,
        ) void {
            const len: Size = @intCast(slice.len);
            assert(self.capacity - self.len >= len);
            @memcpy(self.unusedSlice().ptr, slice);
            self.len += len;
        }

        pub fn appendSlice(
            self: *Self,
            allocator: Allocator,
            slice: []const T,
        ) Allocator.Error!void {
            const len: Size = @intCast(slice.len);
            try self.ensureUnusedCapacity(allocator, len);
            self.appendSliceAssumeCapacity(slice);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.len = 0;
        }

        pub fn insertSlice(
            self: *Self,
            allocator: Allocator,
            i: Size,
            slice: []const T,
        ) Allocator.Error!void {
            const len: Size = @intCast(slice.len);
            try self.ensureUnusedCapacity(allocator, len);
            self.len += len;

            std.mem.copyBackwards(T, self.items()[i + len .. self.len], self.items()[i .. self.len - len]);
            @memcpy(self.items()[i..][0..len], slice);
        }

        pub fn replaceRange(
            self: *Self,
            allocator: Allocator,
            start: Size,
            len: Size,
            new_items: []const T,
        ) Allocator.Error!void {
            const after_range = start + len;
            const range = self.items()[start..after_range];

            if (range.len == new_items.len)
                @memcpy(range[0..new_items.len], new_items)
            else if (range.len < new_items.len) {
                const first = new_items[0..range.len];
                const rest = new_items[range.len..];

                @memcpy(range[0..first.len], first);
                try self.insertSlice(allocator, after_range, rest);
            } else {
                @memcpy(range[0..new_items.len], new_items);
                const after_subrange = start + new_items.len;

                for (self.items()[after_range..], 0..) |item, i| {
                    self.items()[after_subrange..][i] = item;
                }

                self.len -= len - @as(Size, @intCast(new_items.len));
            }
        }
    };
}
