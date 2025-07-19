const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

pub const StringContext = struct {
    pub fn eql(_: @This(), a: []const u8, b: []const u8) bool {
        return std.mem.eql(u8, a, b);
    }

    pub fn asBytes(_: @This(), a: *const []const u8) []const u8 {
        return a.*;
    }
};

/// Context for null terminated u8 pointers
pub const StringContextZ = struct {
    pub fn eql(_: @This(), a: [*:0]const u8, b: [*:0]const u8) bool {
        return for (a, b, 0..std.math.maxInt(usize)) |c1, c2, _| {
            if (c1 != c2) break false;
            if (c1 == 0) break true;
        } else unreachable;
    }

    pub fn asBytes(_: @This(), a: *const [*:0]const u8) []const u8 {
        return std.mem.span(a.*);
    }
};

pub fn CritBitMap(
    comptime K: type,
    comptime V: type,
    comptime Context: type,
) type {
    return struct {
        pub const Enode = union {
            kv: KV,
            inode: *Inode,
            none: void,
        };

        pub const Tag = enum(u2) {
            kv,
            inode,
            none,
        };

        pub const Inode = struct {
            child: [2]Enode,
            tags: [2]Tag,
            byte: u32,
            bit: u3,
        };

        pub const KV = struct {
            key: K,
            value: V,
        };

        const Self = @This();

        head: Enode = .{ .none = {} },
        head_tag: Tag = .none,
        context: Context,

        pub fn init() Self {
            if (@sizeOf(Context) != 0)
                @compileError("Context must be specified! Call initContext(allocator, ctx) instead.");

            return .{
                .context = undefined,
            };
        }

        pub fn initContext(context: Context) Self {
            return .{
                .context = context,
            };
        }

        fn clear(allocator: Allocator, node: *Enode, tag: Tag) void {
            if (tag == .inode) {
                clear(allocator, &node.inode.child[0], node.inode.tags[0]);
                clear(allocator, &node.inode.child[1], node.inode.tags[1]);
                allocator.destroy(node.inode);
            }
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            clear(allocator, &self.head, self.head_tag);
            self.* = undefined;
        }

        pub const GetResult = union(enum) {
            kv: KV,
            prefix,
            not_found,
        };

        pub fn get(self: *const Self, key: K) GetResult {
            if (self.head_tag == .none) return .not_found;

            const kv = self.closestConst(key);

            const res_bytes = self.context.asBytes(&kv.key);
            const bytes = self.context.asBytes(&key);

            if (std.mem.startsWith(u8, res_bytes, bytes)) {
                assert(bytes.len <= res_bytes.len);
                return if (res_bytes.len == bytes.len) .{ .kv = kv } else .prefix;
            }

            return .not_found;
        }

        pub fn contains(self: *const Self, key: K) ?*Inode {
            if (self.head_tag == .none) return null;
            const bytes = self.context.asBytes(&key);
            var node = &self.head;
            var tag = self.head_tag;
            var top = node;

            while (tag == .inode) {
                const inode = node.inode;
                const direction: u1 = if (inode.byte < bytes.len) blk: {
                    top = node;
                    break :blk @intCast((bytes[inode.byte] >> inode.bit) & 1);
                } else 0;

                node = &inode.child[direction];
                tag = inode.tags[direction];
            }

            const top_bytes = self.context.asBytes(&node.kv.key);
            const min_len = @min(top_bytes.len, bytes.len);
            if (std.mem.eql(u8, top_bytes[0..min_len], bytes[0..min_len])) {
                return top.inode;
            }
            return null;
        }

        pub const PutError = error{IsPrefix} || Allocator.Error;

        pub fn put(
            self: *Self,
            allocator: Allocator,
            key: K,
            value: V,
        ) PutError!void {
            if (self.head_tag == .none) {
                self.head = .{
                    .kv = .{
                        .key = key,
                        .value = value,
                    },
                };
                self.head_tag = .kv;
                return;
            }

            const bytes = self.context.asBytes(&key);
            const n = self.closest(key);

            const closest_bytes = self.context.asBytes(&n.key);
            const diff_byte = std.mem.indexOfDiff(u8, bytes, closest_bytes) orelse return;

            // key is a prefix of a key currently in the map
            if (diff_byte == bytes.len) return error.IsPrefix;

            // Existing entry is a prefix of this key - replace it
            if (diff_byte == closest_bytes.len) {
                n.* = .{
                    .key = key,
                    .value = value,
                };
                return;
            }

            const diff_bit: u3 = blk: {
                const diff: u8 = closest_bytes[diff_byte] ^ bytes[diff_byte];
                break :blk 7 - @as(u3, @intCast(@clz(diff)));
            };

            const new_dir: u1 = @intCast((bytes[diff_byte] >> diff_bit) & 1);

            const new_node = try allocator.create(Inode);
            new_node.* = .{
                .byte = @intCast(diff_byte),
                .bit = diff_bit,
                .child = undefined,
                .tags = undefined,
            };
            new_node.child[new_dir] = .{
                .kv = .{
                    .key = key,
                    .value = value,
                },
            };
            new_node.tags[new_dir] = .kv;

            var node = &self.head;
            var tag = &self.head_tag;
            while (tag.* == .inode) {
                const inode = node.inode;
                if (inode.byte > diff_byte) break;
                if (inode.byte == diff_byte and inode.bit < diff_bit) break;

                const direction: u1 = if (inode.byte < bytes.len)
                    @intCast((bytes[inode.byte] >> inode.bit) & 1)
                else
                    0;
                node = &inode.child[direction];
                tag = &inode.tags[direction];
            }

            new_node.child[new_dir ^ 1] = node.*;
            new_node.tags[new_dir ^ 1] = tag.*;
            node.* = .{ .inode = new_node };
            tag.* = .inode;
        }

        pub fn remove(self: *Self, allocator: Allocator, key: K) ?V {
            if (self.head_tag == .none) return null;

            const bytes = self.context.asBytes(&key);

            // Find closest node while keeping track of parent node
            var node = &self.head;
            var node_tag = self.head_tag;
            var parent: ?*Enode = null;
            var direction: u1 = undefined;
            while (node_tag == .inode) {
                parent = node;
                direction = getDirection(bytes, node.inode.*);
                node = &node.inode.child[direction];
                node_tag = node.inode.tags[direction];
            }

            // Key doesn't exist in map
            if (!self.context.eql(key, node.kv.key)) return null;

            const value = node.kv.value;

            if (parent) |p| {
                const old = p.inode;
                p.* = old.child[direction ^ 1];
                allocator.destroy(old);
            } else {
                self.head = .{ .none = {} };
            }

            return value;
        }

        inline fn getDirection(bytes: []const u8, inode: Inode) u1 {
            return if (inode.byte < bytes.len)
                @intCast((bytes[inode.byte] >> inode.bit) & 1)
            else
                0;
        }

        fn closest(self: *Self, key: K) *KV {
            const bytes = self.context.asBytes(&key);

            var node = &self.head;
            var tag = self.head_tag;
            while (tag == .inode) {
                const inode = node.inode;
                const direction = getDirection(bytes, inode.*);

                node = &inode.child[direction];
                tag = inode.tags[direction];
            }

            return &node.kv;
        }

        fn closestConst(self: *const Self, key: K) KV {
            const bytes = self.context.asBytes(&key);

            var node = &self.head;
            var tag = self.head_tag;
            while (tag == .inode) {
                const inode = node.inode;
                const direction = getDirection(bytes, inode.*);

                node = &inode.child[direction];
                tag = inode.tags[direction];
            }

            return node.kv;
        }

        // If a prefix of `key` or `key` itself is contained in the map, return it, otherwise null.
        pub fn getPrefix(self: *Self, key: K) ?*KV {
            const bytes = self.context.asBytes(&key);

            var node = &self.head;
            var tag = self.head_tag;
            while (tag == .inode) {
                const inode = node.inode;
                if (inode.byte >= bytes.len) return null;

                const direction: u1 = @intCast((bytes[inode.byte] >> inode.bit) & 1);
                node = &inode.child[direction];
                tag = inode.tags[direction];
            }

            return if (std.mem.startsWith(u8, node.kv.key, key)) &node.kv else null;
        }

        pub fn traverse(self: *const Self, context: anytype) !void {
            try self.traverseNode(&self.head, self.head_tag, context);
        }

        pub fn traverseNode(self: *const Self, node: *const Enode, tag: Tag, context: anytype) !void {
            switch (tag) {
                .kv => {
                    try context.apply(node.kv);
                },
                .inode => {
                    try self.traverseNode(&node.inode.child[0], node.inode.tags[0], context);
                    try self.traverseNode(&node.inode.child[1], node.inode.tags[1], context);
                },
                .none => {},
            }
        }
    };
}

test "critbit1" {
    const Map = CritBitMap([]const u8, u32, StringContext);

    const t = std.testing;
    var map = Map.init();
    defer map.deinit(t.allocator);

    try map.put(t.allocator, "umm \x01", 20); // 0b0001
    try map.put(t.allocator, "umm \x02", 30); // 0b0010
    try map.put(t.allocator, "umm \x03", 40); // 0b0011
    try map.put(t.allocator, "umm \x04", 50); // 0b0100

    try t.expectEqual(@as(usize, 4), map.head.inode.byte);
    try t.expectEqual(@as(u3, 2), map.head.inode.bit); // First differing bit should be 0b0100

    const kv = &map.head.inode.child[1].kv;
    try t.expectEqualStrings("umm \x04", kv.key);
    try t.expectEqual(@as(u32, 50), kv.value);

    var node = map.head.inode.child[0].inode;
    try t.expectEqual(@as(usize, 4), node.byte);
    try t.expectEqual(@as(u3, 1), node.bit);

    try t.expectEqualStrings("umm \x01", node.child[0].kv.key);
    try t.expectEqual(@as(u32, 20), node.child[0].kv.value);

    node = node.child[1].inode;
    try t.expectEqualStrings("umm \x02", node.child[0].kv.key);
    try t.expectEqual(@as(u32, 30), node.child[0].kv.value);

    try t.expectEqualStrings("umm \x03", node.child[1].kv.key);
    try t.expectEqual(@as(u32, 40), node.child[1].kv.value);

    try t.expectEqual(true, map.contains("") != null);
    try t.expectEqual(true, map.contains("u") != null);
    try t.expectEqual(true, map.contains("um") != null);
    try t.expectEqual(true, map.contains("umm") != null);
    try t.expectEqual(true, map.contains("umm ") != null);
    try t.expectEqual(true, map.contains("umm \x01") != null);
    try t.expectEqual(true, map.contains("umm \x04") != null);
    try t.expectEqual(false, map.contains("something else") != null);
    try t.expectEqual(false, map.contains("ummm") != null);
    try t.expectEqual(false, map.contains("umm \x05") != null);
}

test "critbit2" {
    const t = std.testing;
    const Map = CritBitMap([]const u8, u32, StringContext);
    var map = Map.init();
    defer map.deinit(t.allocator);

    try map.put(t.allocator, "This is epic", 5);
    try t.expectError(error.IsPrefix, map.put(t.allocator, "This is", 10));
    try map.put(t.allocator, "This is epic and nice", 10);
    try t.expectEqual(Map.Tag.kv, map.head_tag);
    try t.expectEqualStrings("This is epic and nice", map.head.kv.key);
    try t.expectEqual(@as(usize, 10), map.head.kv.value);
}

test {
    std.testing.refAllDeclsRecursive(@This());
    std.testing.refAllDeclsRecursive(CritBitMap([]const u8, u32, StringContext));
}
