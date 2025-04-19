const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const mem = std.mem;

pub fn GapBuffer(comptime T: type) type {
    return struct {
        ptr: [*]T,
        len: u32,
        gap_start: u32,
        gap_len: u32,

        const Self = @This();

        pub const empty: Self = .{
            .ptr = undefined,
            .len = 0,
            .gap_start = 0,
            .gap_len = 0,
        };

        pub const ChildType = T;

        /// Sets the gap to the end of the buffer. iovecs are invalidated by any operation that
        /// modifies the buffer or the gap.
        pub fn iovecs(self: *Self) std.posix.iovec_const {
            const ptrToIoVec = @import("utils.zig").ptrToIoVec;
            const slice = self.items();
            return ptrToIoVec(slice);
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            allocator.free(self.allocatedSlice());
        }

        pub fn addManyAt(self: *Self, allocator: Allocator, pos: u32, count: u32) ![]T {
            try self.ensureUnusedCapacity(allocator, count);
            self.setGap(pos);
            const ret = self.ptr[self.gap_start..][0..count];
            self.gap_start += count;
            self.gap_len -= count;
            self.len += count;
            return ret;
        }

        pub fn setGap(self: *Self, new_pos: u32) void {
            if (new_pos == self.gap_start) return;
            assert(new_pos <= self.len);
            if (new_pos < self.gap_start) {
                const src = self.ptr[new_pos..self.gap_start];
                const dest = self.ptr[new_pos + self.gap_len .. self.gap_start + self.gap_len];
                mem.copyBackwards(T, dest, src);
            } else {
                const src = self.ptr[self.gap_start + self.gap_len .. new_pos + self.gap_len];
                const dest = self.ptr[self.gap_start..new_pos];
                mem.copyForwards(T, dest, src);
            }
            self.gap_start = new_pos;
        }

        pub fn allocatedSlice(self: Self) []T {
            return self.ptr[0 .. self.len + self.gap_len];
        }

        pub fn capacity(self: Self) u32 {
            return self.len + self.gap_len;
        }

        pub fn insertAtGap(self: *Self, item: T) void {
            assert(self.gap_len > 0);
            self.ptr[self.gap_start] = item;
            self.gap_start += 1;
            self.gap_len -= 1;
            self.len += 1;
        }

        pub fn insertSliceAtGap(self: *Self, slice: []const T) void {
            const len: u32 = @intCast(slice.len);
            assert(self.gap_len >= len);
            for (slice) |item| {
                self.insertAtGap(item);
            }
        }

        pub fn insert(self: *Self, allocator: Allocator, n: u32, item: T) Allocator.Error!void {
            assert(n <= self.len);
            self.setGap(n);
            try self.ensureUnusedCapacity(allocator, 1);
            self.insertAtGap(item);
        }

        pub fn insertAssumeCapacity(self: *Self, n: u32, item: T) void {
            assert(n <= self.len);
            self.setGap(n);
            self.insertAtGap(item);
        }

        pub fn insertSlice(
            self: *Self,
            allocator: Allocator,
            n: u32,
            slice: []const T,
        ) Allocator.Error!void {
            assert(n <= self.len);
            self.setGap(n);
            try self.ensureUnusedCapacity(allocator, @intCast(slice.len));
            self.insertSliceAtGap(slice);
        }

        pub fn insertSliceAssumeCapacity(
            self: *Self,
            n: u32,
            slice: []const T,
        ) void {
            assert(n <= self.len);
            self.setGap(n);
            self.insertSliceAtGap(slice);
        }

        pub fn append(self: *Self, allocator: Allocator, item: T) Allocator.Error!void {
            self.setGap(self.len);
            try self.ensureUnusedCapacity(allocator, 1);
            self.insertAtGap(item);
        }

        pub fn appendAssumeCapacity(self: *Self, item: T) void {
            self.setGap(self.len);
            self.insertAtGap(item);
        }

        pub fn appendSlice(self: *Self, allocator: Allocator, slice: []const T) Allocator.Error!void {
            self.setGap(self.len);
            try self.ensureUnusedCapacity(allocator, @intCast(slice.len));
            self.insertSliceAtGap(slice);
        }

        pub fn appendSliceAssumeCapacity(self: *Self, slice: []const T) void {
            self.setGap(self.len);
            self.insertSliceAtGap(slice);
        }

        pub fn ensureUnusedCapacity(self: *Self, allocator: Allocator, n: u32) Allocator.Error!void {
            try self.ensureTotalCapacity(allocator, self.len + n);
        }

        pub fn ensureTotalCapacity(self: *Self, allocator: Allocator, n: u32) Allocator.Error!void {
            const cap = self.capacity();
            if (n <= cap) return;

            var better_capacity = cap;
            while (true) {
                better_capacity +|= better_capacity / 2 + 8;
                if (better_capacity >= n) break;
            }

            return self.ensureTotalCapacityPrecise(allocator, better_capacity);
        }

        pub fn ensureTotalCapacityPrecise(self: *Self, allocator: Allocator, n: u32) Allocator.Error!void {
            const cap = self.capacity();
            if (n <= cap) return;

            const old_mem = self.allocatedSlice();
            const new_gap_len = n - self.len;
            if (allocator.resize(old_mem, n)) {
                assert(new_gap_len > self.gap_len);
                const src = self.ptr[self.gap_start + self.gap_len .. cap];
                const dest = self.ptr[self.gap_start + new_gap_len .. n];
                mem.copyBackwards(T, dest, src);
                self.gap_len = new_gap_len;
            } else {
                const new_mem = try allocator.alloc(T, n);
                @memcpy(new_mem[0..self.gap_start], self.ptr[0..self.gap_start]);
                @memcpy(new_mem[self.gap_start + new_gap_len ..], self.ptr[self.gap_start + self.gap_len .. cap]);
                self.gap_len = new_gap_len;
                self.ptr = new_mem.ptr;
                allocator.free(old_mem);
            }
        }

        pub inline fn left(self: Self) []T {
            return self.ptr[0..self.gap_start];
        }

        pub inline fn right(self: Self) []T {
            return self.ptr[self.gap_start + self.gap_len .. self.capacity()];
        }

        pub inline fn get(self: Self, index: u32) T {
            assert(index < self.len);
            return if (index < self.gap_start) self.ptr[index] else self.ptr[index + self.gap_len];
        }

        pub inline fn getPtr(self: Self, index: u32) T {
            assert(index < self.len);
            return if (index < self.gap_start) &self.ptr[index] else &self.ptr[index + self.gap_len];
        }

        pub inline fn length(self: Self) u32 {
            return self.len;
        }

        pub fn replaceRange(
            self: *Self,
            allocator: Allocator,
            start: u32,
            len: u32,
            new_items: []const T,
        ) Allocator.Error!void {
            if (start + len == self.gap_start) {
                // Common case: deleting backwards
                self.gap_start -= len;
            } else {
                self.setGap(start);
            }
            self.gap_len += len;
            self.len -= len;
            try self.ensureUnusedCapacity(allocator, @intCast(new_items.len));
            self.insertSliceAtGap(new_items);
        }

        pub fn deleteRange(self: *Self, start: u32, end: u32) void {
            assert(start < self.len);
            assert(end <= self.len);
            const len = end - start;
            self.setGap(start);
            self.gap_len += len;
            self.len -= len;
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.gap_len = self.capacity();
            self.len = 0;
            self.gap_start = 0;
        }

        pub fn shrinkRetainingCapacity(self: *Self, n: u32) void {
            const new_gap_len = self.capacity() - n;

            self.len = n;
            self.gap_len = new_gap_len;

            if (n < self.gap_start) {
                self.gap_start = n;
            }
        }

        /// Moves the gap to the end of the buffer, so that the contents are entirely contiguous.
        /// Avoid calling often.
        pub fn items(self: *Self) []T {
            self.setGap(self.len);
            return self.left();
        }
    };
}

test "GapBuffer" {
    const t = std.testing;
    var buf: GapBuffer(u8) = .empty;
    defer buf.deinit(t.allocator);

    try buf.appendSlice(t.allocator, "This is epic");
    try t.expectEqualStrings("This is epic", buf.left());
    try t.expectEqualStrings("", buf.right());

    try buf.appendSlice(t.allocator, " and nice :)");
    try t.expectEqualStrings("This is epic and nice :)", buf.left());
    try t.expectEqualStrings("", buf.right());

    buf.setGap(2);
    try t.expectEqualStrings("Th", buf.left());
    try t.expectEqualStrings("is is epic and nice :)", buf.right());

    buf.setGap(2);
    try t.expectEqualStrings("Th", buf.left());
    try t.expectEqualStrings("is is epic and nice :)", buf.right());

    buf.setGap(0);
    try t.expectEqualStrings("", buf.left());
    try t.expectEqualStrings("This is epic and nice :)", buf.right());

    buf.setGap(10);
    try t.expectEqualStrings("This is ep", buf.left());
    try t.expectEqualStrings("ic and nice :)", buf.right());

    try buf.ensureUnusedCapacity(t.allocator, 30);
    try t.expectEqual(@as(u32, buf.gap_start), 10);
    try t.expect(buf.gap_len >= 30);

    buf.insertSliceAtGap("icness and ep");

    try t.expectEqualStrings("This is epicness and ep", buf.left());
    try t.expectEqualStrings("ic and nice :)", buf.right());
}

test "u32" {
    const t = std.testing;
    var buf: GapBuffer(u32) = .empty;
    defer buf.deinit(t.allocator);

    try buf.appendSlice(t.allocator, &.{ 1, 2, 3, 4, 5 });
    try t.expectEqualSlices(u32, &.{ 1, 2, 3, 4, 5 }, buf.left());
    try t.expectEqualSlices(u32, &.{}, buf.right());

    buf.setGap(2);
    try t.expectEqualSlices(u32, &.{ 1, 2 }, buf.left());
    try t.expectEqualSlices(u32, &.{ 3, 4, 5 }, buf.right());
}
