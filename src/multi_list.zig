const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub fn MultiList(T: type, I: type) type {
    return struct {
        slice: std.MultiArrayList(T).Slice,
        start: usize,
        sliced: bool,

        const Self = @This();

        pub const empty: Self = .{
            .slice = .empty,
            .start = 0,
            .sliced = false,
        };

        pub const Index = enum(I) {
            _,

            fn assertValid(i: Index) void {
                assert(@intFromEnum(i) != @intFromEnum(OptionalIndex.none));
            }

            pub fn toOptional(i: Index) OptionalIndex {
                const res: OptionalIndex = @enumFromInt(@intFromEnum(i));
                assert(res != .none);
                return res;
            }

            pub fn addi(ind: Index, n: I) Index {
                assertValid(ind);
                return @enumFromInt(@intFromEnum(ind) + n);
            }

            pub fn subi(ind: Index, n: I) Index {
                assertValid(ind);
                return @enumFromInt(@intFromEnum(ind) - n);
            }

            pub fn add(a: Index, b: Index) Index {
                assertValid(a);
                assertValid(b);
                return a.addi(@intFromEnum(b));
            }

            pub fn sub(a: Index, b: Index) Index {
                assertValid(a);
                assertValid(b);
                return a.subi(@intFromEnum(b));
            }

            pub fn le(a: Index, b: Index) bool {
                assertValid(a);
                assertValid(b);
                return @intFromEnum(a) <= @intFromEnum(b);
            }

            pub fn lt(a: Index, b: Index) bool {
                assertValid(a);
                assertValid(b);
                return @intFromEnum(a) < @intFromEnum(b);
            }
        };

        pub const OptionalIndex = enum(I) {
            none = std.math.maxInt(I),
            _,

            pub fn unwrap(o: OptionalIndex) ?Index {
                return if (o == .none) null else @enumFromInt(@intFromEnum(o));
            }
        };

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.slice.deinit(gpa);
        }

        pub fn item(
            self: *const Self,
            i: Index,
            comptime field: std.MultiArrayList(T).Field,
        ) @FieldType(T, @tagName(field)) {
            return self.ptr(i, field).*;
        }

        pub fn ptr(
            self: *const Self,
            i: Index,
            comptime field: std.MultiArrayList(T).Field,
        ) *@FieldType(T, @tagName(field)) {
            return &self.slice.items(field)[self.offset(i)];
        }

        pub fn items(
            self: *const Self,
            comptime field: std.MultiArrayList(T).Field,
        ) []@FieldType(T, @tagName(field)) {
            return self.slice.items(field);
        }

        pub fn get(self: *const Self, i: Index) T {
            return self.geti(self.offset(i));
        }

        pub fn set(self: *const Self, i: Index, elem: T) void {
            return self.seti(self.offset(i), elem);
        }

        pub fn geti(self: *const Self, i: usize) T {
            return self.slice.get(i);
        }

        pub fn seti(self: *const Self, i: usize, elem: T) void {
            // `slice.set` requires a mutable pointer but doesn't actually do any mutation, so
            // this is safe.
            const mut_self: *Self = @constCast(self);
            mut_self.slice.set(i, elem);
        }

        pub fn ensureUnusedCapacity(self: *Self, gpa: Allocator, n: usize) !void {
            var m = self.slice.toMultiArrayList();
            try m.ensureUnusedCapacity(gpa, n);
            self.slice = m.slice();
        }

        pub fn subsliceEnd(self: Self, start: usize, end: usize) Self {
            return self.subslice(start, end - start);
        }

        pub fn subslice(self: Self, start: usize, length: usize) Self {
            return .{
                .slice = self.slice.subslice(start, length),
                .start = self.start + start,
                .sliced = self.sliced or start > 0 or length < self.slice.len,
            };
        }

        pub fn subsliceIndex(self: Self, start: Index, length: usize) Self {
            return self.subslice(self.offset(start), length);
        }

        pub fn subsliceEndIndex(self: Self, start: Index, end: Index) Self {
            return self.subsliceEnd(self.offset(start), self.offset(end));
        }

        pub fn pop(self: *Self) ?T {
            var m = self.slice.toMultiArrayList();
            defer self.slice = m.toOwnedSlice();
            return m.pop();
        }

        pub fn index(self: *const Self, n: usize) Index {
            return @enumFromInt(self.start + n);
        }

        pub fn offset(self: *const Self, i: Index) I {
            return @intCast(@intFromEnum(i) - self.start);
        }

        /// Returns the last available index + 1. Not a valid index to access.
        /// This would be the index created by the next `append` operation.
        pub fn nextIndex(self: *const Self) Index {
            return @enumFromInt(self.start + self.len());
        }

        pub fn append(self: *Self, gpa: Allocator, elem: T) !Index {
            try self.ensureUnusedCapacity(gpa, 1);
            return self.appendAssumeCapacity(elem);
        }

        pub fn appendAssumeCapacity(self: *Self, elem: T) Index {
            var m = self.slice.toMultiArrayList();
            defer self.slice = m.toOwnedSlice();

            const ret: Index = @enumFromInt(m.len);
            m.appendAssumeCapacity(elem);
            return ret;
        }

        pub fn appendMany(self: *Self, gpa: Allocator, n: usize) !Self {
            assert(!self.sliced);
            try self.ensureUnusedCapacity(gpa, n);
            return self.appendManyAssumeCapacity(n);
        }

        pub fn appendManyAssumeCapacity(self: *Self, n: usize) Self {
            assert(!self.sliced);
            assert(self.slice.capacity - self.slice.len >= n);
            const start = self.len();
            self.slice.len += n;
            return self.subslice(start, n);
        }

        pub fn insertMany(self: *Self, gpa: Allocator, n: usize, count: usize) !Self {
            try self.ensureUnusedCapacity(gpa, count);
            return self.insertManyAssumeCapacity(n, count);
        }

        pub fn insertManyAssumeCapacity(self: *Self, n: usize, count: usize) Self {
            assert(!self.sliced);
            self.slice.len += count;
            inline for (@typeInfo(T).@"struct".fields) |f| {
                const E = std.MultiArrayList(T).Field;
                const Type = @FieldType(T, f.name);
                const slice = self.items(comptime std.meta.stringToEnum(E, f.name).?);
                std.mem.copyBackwards(Type, slice[n + count ..], slice[n .. slice.len - count]);
            }

            return self.subslice(n, count);
        }

        pub fn len(self: *const Self) usize {
            return self.slice.len;
        }

        pub fn capacity(self: *const Self) usize {
            return self.slice.capacity;
        }

        pub fn shrinkRetainingCapacity(self: *Self, n: usize) void {
            assert(n <= self.slice.len);
            self.slice.len = n;
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.slice.len = 0;
        }

        pub fn setAndExpandCapacity(
            self: *Self,
            gpa: Allocator,
            length: usize,
            cap: usize,
        ) !void {
            assert(!self.sliced);
            var m = self.slice.toMultiArrayList();
            defer self.slice = m.toOwnedSlice();

            try m.setCapacity(gpa, cap);
            m.len = length;
        }

        pub fn containsIndex(self: *const Self, ind: Index) bool {
            const n = @intFromEnum(ind);
            return n >= self.start and n < self.len();
        }

        pub fn reverseIterator(self: *const Self) ReverseIterator {
            return .{
                .list = self.*,
                .i = @enumFromInt(self.len()),
            };
        }

        pub const ReverseIterator = struct {
            list: Self,
            i: Index,

            pub fn next(iter: *ReverseIterator) ?Index {
                if (@intFromEnum(iter.i) <= iter.list.start)
                    return null;

                iter.i = iter.i.subi(1);
                return iter.i;
            }

            pub fn skip(iter: *ReverseIterator, n: usize) void {
                iter.i = @enumFromInt(@intFromEnum(iter.i) -| n);
            }
        };
    };
}
