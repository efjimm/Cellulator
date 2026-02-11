const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// Wrapper around an ArrayList that exposes an Index type with wrapper functions
pub fn List(T: type, I: type) type {
    return struct {
        list: std.ArrayList(T),
        offset: usize,
        sliced: bool,

        const Self = @This();

        pub const empty: Self = .{
            .list = .empty,
            .offset = 0,
            .sliced = false,
        };

        pub fn deinit(self: *Self, gpa: Allocator) void {
            self.list.deinit(gpa);
        }

        pub fn get(self: *Self, i: Index) T {
            return self.list.items[self.resolve(i)];
        }

        pub fn getPtr(self: *Self, i: Index) *T {
            return &self.list.items[self.resolve(i)];
        }

        pub fn set(self: *Self, i: Index, value: T) void {
            self.list.items[self.resolve(i)] = value;
        }

        pub fn ensureUnusedCapacity(self: *Self, gpa: Allocator, n: usize) Allocator.Error!void {
            try self.list.ensureUnusedCapacity(gpa, n);
        }

        pub fn ensureTotalCapacity(self: *Self, gpa: Allocator, n: usize) Allocator.Error!void {
            try self.list.ensureTotalCapacity(gpa, n);
        }

        pub fn clearRetainingCapacity(self: *Self) void {
            self.list.clearRetainingCapacity();
        }

        pub fn append(self: *Self, gpa: Allocator, value: T) Allocator.Error!void {
            try self.list.append(gpa, value);
        }

        pub fn appendSlice(self: *Self, gpa: Allocator, values: []const T) Allocator.Error!void {
            try self.list.appendSlice(gpa, values);
        }

        pub fn appendAssumeCapacity(self: *Self, value: T) void {
            self.list.appendAssumeCapacity(value);
        }

        pub fn appendSliceAssumeCapacity(self: *Self, values: []const T) void {
            self.list.appendSliceAssumeCapacity(values);
        }

        pub fn subsliceIndexInclusive(self: *const Self, start: Index, end_inclusive: Index) Self {
            return self.subsliceIndex(start, end_inclusive.addi(1));
        }

        pub fn subsliceIndex(self: *const Self, start: Index, end: Index) Self {
            const length = self.resolve(end) - self.resolve(start);
            return self.subslice(self.resolve(start), length);
        }

        pub fn subslice(self: *const Self, start: usize, length: usize) Self {
            return .{
                .list = .{
                    .capacity = length,
                    .items = self.list.items[start..][0..length],
                },
                .offset = self.offset + start,
                .sliced = true,
            };
        }

        pub fn items(self: *const Self) []T {
            return self.list.items;
        }

        pub fn len(self: *const Self) usize {
            return self.list.items.len;
        }

        pub fn capacity(self: *const Self) usize {
            return self.list.capacity;
        }

        pub fn pop(self: *Self) ?T {
            return self.list.pop();
        }

        pub fn insert(self: *Self, gpa: Allocator, i: Index, value: T) Allocator.Error!void {
            try self.list.insert(gpa, self.resolve(i), value);
        }

        pub fn insertAssumeCapacity(self: *Self, i: Index, value: T) void {
            self.list.insertAssumeCapacity(self.resolve(i), value);
        }

        pub fn inserti(self: *Self, gpa: Allocator, i: usize, value: T) Allocator.Error!void {
            try self.list.insert(gpa, i, value);
        }

        pub fn insertiAssumeCapacity(self: *Self, i: usize, value: T) void {
            self.list.insertAssumeCapacity(i, value);
        }

        pub fn shrinkRetainingCapacity(self: *Self, end: Index) void {
            self.list.shrinkRetainingCapacity(self.resolve(end));
        }

        pub fn lastIndex(self: *const Self) Index {
            return @enumFromInt(self.offset + self.len());
        }

        fn resolve(self: *const Self, i: Index) usize {
            return @intFromEnum(i) - self.offset;
        }

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
        };

        pub const OptionalIndex = enum(I) {
            none = std.math.maxInt(I),
            _,

            pub fn unwrap(o: OptionalIndex) ?Index {
                return if (o == .none) null else @enumFromInt(@intFromEnum(o));
            }
        };
    };
}
