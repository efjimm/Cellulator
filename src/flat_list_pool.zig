const std = @import("std");
const GapBuffer = @import("GapBuffer.zig").GapBuffer;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const utils = @import("utils.zig");

/// A data structure for storing many ArrayLists inside a single flat list. Useful if iterating over
/// the value of every list needs to be quick, or for serialisation.
pub fn FlatListPool(comptime T: type) type {
    return struct {
        values: GapBuffer(T),
        entries: std.ArrayListUnmanaged(Entry),
        free_entries_head: List.Index,

        pub const Entry = extern union {
            list: List,
            free: List.Index,
        };

        pub const List = extern struct {
            len: usize,
            offset: usize,

            pub const Index = packed struct {
                n: u32,

                pub fn from(n: u32) Index {
                    return .{ .n = n };
                }

                pub fn isValid(index: Index) bool {
                    return index != invalid;
                }

                pub const invalid: Index = .{ .n = std.math.maxInt(u32) };
            };
        };

        const Self = @This();

        pub const empty: Self = .{
            .values = .{},
            .entries = .empty,
            .free_entries_head = .invalid,
        };

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.values.deinit(allocator);
            self.entries.deinit(allocator);
            self.* = undefined;
        }

        pub fn createList(self: *Self, allocator: Allocator) Allocator.Error!List.Index {
            if (!self.free_entries_head.isValid())
                try self.entries.ensureUnusedCapacity(allocator, 1);
            return self.createListAssumeCapacity();
        }

        pub fn createListAssumeCapacity(self: *Self) List.Index {
            if (self.free_entries_head.isValid()) {
                const ret = self.free_entries_head;
                self.free_entries_head = self.entries.items[ret.n].free;
                self.entries.items[ret.n] = .{ .list = .{
                    .offset = self.values.len,
                    .len = 0,
                } };
                return ret;
            }

            const index: List.Index = .from(@intCast(self.entries.items.len));
            self.entries.appendAssumeCapacity(.{ .list = .{
                .offset = self.values.len,
                .len = 0,
            } });
            return index;
        }

        pub fn destroyList(self: *Self, list: List.Index) void {
            assert(list.isValid());
            self.entries.items[list.n] = .{ .free = self.free_entries_head };
            self.free_entries_head = list;
        }

        pub fn appendSlice(
            self: *Self,
            allocator: Allocator,
            index: List.Index,
            slice: []const T,
        ) !void {
            try self.ensureUnusedCapacity(allocator, slice.len);
            return self.appendSliceAssumeCapacity(index, slice);
        }

        pub fn appendSliceAssumeCapacity(self: *Self, index: List.Index, slice: []const T) void {
            const list = &self.entries.items[index.n].list;
            self.values.insertSliceAssumeCapacity(@intCast(list.offset + list.len), slice);
            list.len += slice.len;
            for (self.entries.items) |*entry| {
                if (entry.list.offset > list.offset) {
                    entry.list.offset += slice.len;
                }
            }
        }

        pub fn insert(
            self: *Self,
            allocator: Allocator,
            list_index: List.Index,
            item: T,
            index: usize,
        ) !void {
            try self.ensureUnusedCapacity(allocator, 1);
            return self.insertAssumeCapacity(list_index, item, index);
        }

        pub fn insertAssumeCapacity(self: *Self, list_index: List.Index, item: T, index: usize) void {
            assert(list_index.isValid());
            const list = &self.entries.items[list_index.n].list;
            assert(index <= list.len);
            self.values.insertAssumeCapacity(@intCast(list.offset + index), item);
            list.len += 1;
        }

        pub fn ensureUnusedCapacity(self: *Self, allocator: Allocator, n: usize) !void {
            try self.values.ensureUnusedCapacity(allocator, @intCast(n));
        }

        pub fn swapRemove(self: *Self, index: List.Index, n: usize) void {
            assert(index.isValid());
            const list = &self.entries.items[index.n].list;
            assert(n < list.len);
            assert(list.len <= self.values.len - list.offset);

            self.values.replaceRange(
                undefined,
                @intCast(list.offset + n),
                1,
                &.{self.values.get(@intCast(list.len - 1))},
            ) catch unreachable;

            self.values.setGap(@intCast(list.offset + list.len));
            self.values.gap_start -= 1;

            list.len -= 1;
        }

        pub fn items(self: *Self, index: List.Index) []T {
            const list = self.entries.items[index.n].list;
            return self.values.items()[list.offset..][0..list.len];
        }

        pub fn len(self: *const Self, index: List.Index) usize {
            return self.entries.items[index.n].list.len;
        }

        // For serialization.

        pub const Header = extern struct {
            values_len: u32,
            entries_len: u32,
            free: List.Index,
        };

        pub fn getHeader(self: *const Self) Header {
            return .{
                .values_len = self.values.len,
                .entries_len = @intCast(self.entries.items.len),
                .free = self.free_entries_head,
            };
        }

        pub fn fromHeader(
            self: *Self,
            allocator: std.mem.Allocator,
            header: Header,
        ) ![2]std.posix.iovec {
            self.* = .{
                .values = .{},
                .entries = .empty,
                .free_entries_head = header.free,
            };
            errdefer self.deinit(allocator);

            _ = try self.values.addManyAt(allocator, 0, header.values_len);
            _ = try self.entries.addManyAt(allocator, 0, header.entries_len);

            return @bitCast(self.iovecs());
        }

        pub fn iovecs(self: *Self) [2]std.posix.iovec_const {
            return .{ self.values.iovecs(), utils.arrayListIoVec(&self.entries) };
        }
    };
}
