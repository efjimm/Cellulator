const std = @import("std");
const Allocator = std.mem.Allocator;
const heap = std.heap;

pub fn MemoryPool(comptime T: type, comptime options: heap.MemoryPoolOptions) type {
    return struct {
        arena_state: std.heap.ArenaAllocator.State = .{},
        free_list: std.meta.FieldType(Managed, .free_list) = null,

        pub const Managed = std.heap.MemoryPoolExtra(T, options);
        pub const ResetMode = Managed.ResetMode;

        pub fn promote(self: @This(), allocator: Allocator) Managed {
            return .{
                .arena = self.arena_state.promote(allocator),
                .free_list = self.free_list,
            };
        }

        pub fn demote(managed: Managed) @This() {
            return .{
                .arena_state = managed.arena.state,
                .free_list = managed.free_list,
            };
        }

        pub fn initPreheated(allocator: Allocator, initial_size: usize) Allocator.Error!void {
            return demote(try Managed.initPreheated(allocator, initial_size));
        }

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            var p = self.promote(allocator);
            p.deinit();
            self.* = undefined;
        }

        pub fn create(self: *@This(), allocator: Allocator) Allocator.Error!*T {
            var p = self.promote(allocator);
            defer self.* = demote(p);

            const ret = try p.create();
            return ret;
        }

        pub fn destroy(self: *@This(), allocator: Allocator, item: *T) void {
            var p = self.promote(allocator);
            defer self.* = demote(p);

            return p.destroy(item);
        }

        pub fn reset(self: *@This(), allocator: Allocator, mode: ResetMode) bool {
            var p = self.promote(allocator);
            defer self.* = demote(p);

            return p.reset(mode);
        }
    };
}
