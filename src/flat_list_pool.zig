const std = @import("std");
const utils = @import("utils.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.flat_list_pool);

pub fn FlatListPool(comptime T: type) type {
    return struct {
        buf: std.ArrayListUnmanaged(T),
        entries: std.ArrayListUnmanaged(Entry),
        free_entries_head: List.Index,

        pub const Entry = extern union {
            list: List,
            free: List.Index,
        };

        pub const List = extern struct {
            len: usize,
            offset: usize,
            capacity: usize,

            pub const Index = packed struct {
                n: u32,

                pub const invalid: Index = .{ .n = std.math.maxInt(u32) };

                pub fn from(n: u32) Index {
                    assert(n != std.math.maxInt(u32));
                    return .{ .n = n };
                }

                pub fn isValid(index: Index) bool {
                    return index != invalid;
                }
            };
        };

        const Pool = @This();

        pub const empty: Pool = .{
            .buf = .empty,
            .entries = .empty,
            .free_entries_head = .invalid,
        };

        pub fn deinit(pool: *Pool, allocator: Allocator) void {
            pool.buf.deinit(allocator);
            pool.entries.deinit(allocator);
        }

        pub fn clearRetainingCapacity(pool: *Pool) void {
            pool.buf.clearRetainingCapacity();
            pool.entries.clearRetainingCapacity();
            pool.free_entries_head = .invalid;
        }

        pub fn createList(pool: *Pool, allocator: Allocator) !List.Index {
            if (!pool.free_entries_head.isValid())
                try pool.entries.ensureUnusedCapacity(allocator, 1);
            return pool.createListAssumeCapacity();
        }

        pub fn createListAssumeCapacity(pool: *Pool) List.Index {
            assert(pool.free_entries_head.isValid() or pool.entries.items.len < pool.entries.capacity);
            if (pool.free_entries_head.isValid()) {
                const ret = pool.free_entries_head;
                pool.free_entries_head = pool.entries.items[ret.n].free;
                pool.entries.items[ret.n].list.len = 0;
                return ret;
            }

            const ret: List.Index = .from(@intCast(pool.entries.items.len));
            const list = &pool.entries.addOneAssumeCapacity().list;
            const offset = pool.buf.items.len;
            list.* = .{
                .offset = offset,
                .len = 0,
                .capacity = 0,
            };
            return ret;
        }

        pub fn destroyList(pool: *Pool, list_index: List.Index) void {
            assert(list_index.isValid());
            pool.entries.items[list_index.n].free = pool.free_entries_head;
            pool.free_entries_head = list_index;
        }

        pub fn items(pool: *Pool, list_index: List.Index) []T {
            const list = pool.entries.items[list_index.n].list;
            return pool.buf.items[list.offset..][0..list.len];
        }

        pub fn append(
            pool: *Pool,
            allocator: Allocator,
            list_index: List.Index,
            item: T,
        ) Allocator.Error!void {
            try pool.ensureUnusedCapacity(allocator, list_index, 1);
            pool.appendAssumeCapacity(list_index, item);
        }

        pub fn appendAssumeCapacity(pool: *Pool, list_index: List.Index, item: T) void {
            const list = &pool.entries.items[list_index.n].list;

            assert(list.len < list.capacity);
            pool.buf.items[list.offset + list.len] = item;
            list.len += 1;
        }

        pub fn appendSlice(
            pool: *Pool,
            allocator: Allocator,
            list_index: List.Index,
            slice: []const T,
        ) Allocator.Error!void {
            try pool.ensureUnusedCapacity(allocator, list_index, slice.len);
            pool.appendSliceAssumeCapacity(list_index, slice);
        }

        pub fn appendSliceAssumeCapacity(pool: *Pool, list_index: List.Index, slice: []const T) void {
            const list = &pool.entries.items[list_index.n].list;

            const dest = pool.buf.items[list.offset + list.len ..][0..slice.len];
            @memcpy(dest, slice);
            list.len += slice.len;
        }

        pub fn ensureUnusedListCapacity(pool: *Pool, allocator: Allocator, n: u32) !void {
            // TODO: Keep a count of the number of entries in the free list
            try pool.entries.ensureUnusedCapacity(allocator, n);
        }

        pub fn ensureUnusedCapacity(
            noalias pool: *Pool,
            allocator: Allocator,
            list_index: List.Index,
            n: usize,
        ) !void {
            const list = &pool.entries.items[list_index.n].list;
            if (list.capacity - list.len < n) {
                const new_capacity = growCapacity(list.capacity, list.len + n);
                try pool.buf.ensureTotalCapacity(
                    allocator,
                    pool.buf.items.len * 2 + new_capacity,
                );

                const new_offset = pool.buf.items.len;
                pool.buf.items.len += new_capacity;

                const new_slice = pool.buf.items[new_offset..][0..list.len];
                @memcpy(new_slice, pool.items(list_index));

                list.offset = new_offset;
                list.capacity = new_capacity;
            }
        }

        pub fn swapRemove(pool: *Pool, list_index: List.Index, index: usize) void {
            const list = &pool.entries.items[list_index.n].list;
            assert(index < list.len);
            pool.buf.items[list.offset..][index] = pool.buf.items[list.offset..][list.len - 1];
            list.len -= 1;
        }

        pub fn len(pool: *Pool, list_index: List.Index) usize {
            assert(list_index.isValid());
            return pool.entries.items[list_index.n].list.len;
        }

        fn growCapacity(current: usize, minimum: usize) usize {
            var new = current;
            while (true) {
                new +|= new + 1;
                if (new >= minimum)
                    return new;
            }
        }

        pub const Header = extern struct {
            buf_len: u32,
            entries_len: u32,
            free: List.Index,
        };

        pub fn getHeader(pool: *const Pool) Header {
            return .{
                .buf_len = @intCast(pool.buf.items.len),
                .entries_len = @intCast(pool.entries.items.len),
                .free = pool.free_entries_head,
            };
        }

        pub fn iovecs(pool: *Pool) [2]std.posix.iovec_const {
            return .{
                utils.arrayListIoVec(&pool.buf),
                utils.arrayListIoVec(&pool.entries),
            };
        }

        pub fn fromHeader(
            pool: *Pool,
            allocator: Allocator,
            header: Header,
        ) Allocator.Error![2]std.posix.iovec {
            pool.* = .{
                .buf = .empty,
                .entries = .empty,
                .free_entries_head = header.free,
            };
            errdefer pool.deinit(allocator);

            try pool.buf.ensureTotalCapacityPrecise(allocator, header.buf_len);
            try pool.entries.ensureTotalCapacityPrecise(allocator, header.entries_len);
            pool.buf.expandToCapacity();
            pool.entries.expandToCapacity();

            return @bitCast(pool.iovecs());
        }
    };
}
