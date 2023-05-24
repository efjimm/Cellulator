// Crit-bit tree. Implementation taken from vis.
// Copyright © 2023 Evan Bonner <ebonner@airmail.cc>
//
// Copyright © 2014-2020 Marc André Tanner, et al.
// 
// Permission to use, copy, modify, and/or distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
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
		pub const ENode = union {
			kv: KV,
			inode: *INode,
			none: void,
		};

		pub const Tag = enum(u2) {
			kv,
			inode,
			none,
		};

		pub const INode = struct {
			child: [2]ENode,
			tags: [2]Tag,
			byte: u32,
			bit: u3,
		};

		pub const KV = struct {
			key: K,
			value: V,
		};

		const Self = @This();

		head: ENode = .{ .none = {} },
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

		fn clear(allocator: Allocator, node: *ENode, tag: Tag) void {
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

		pub fn get(self: Self, key: K) ?V {
			if (self.head_tag == .none) return null;

			const kv = self.closestConst(key);
			if (self.context.eql(kv.key, key)) return kv.value;

			return null;
		}

		pub fn prefix(self: Self, key: K) ?*const ENode {
			const bytes = self.context.asBytes(&key);
			var node = &self.head;
			var tag = self.head_tag;
			var top = node;

			while (tag == .inode) {
				const inode = node.inode;
				const direction: u1 = if (inode.byte < bytes.len) blk: {
					top = node;
					break :blk @intCast(u1, (bytes[inode.byte] >> inode.bit) & 1);
				} else 0;

				node = &inode.child[direction];
				tag = inode.tags[direction];
			}

			const top_bytes = self.context.asBytes(&node.kv.key);
			const min_len = @min(top_bytes.len, bytes.len);
			return if (std.mem.eql(u8, top_bytes[0..min_len], bytes[0..min_len])) top else null;
		}

		pub fn contains(self: Self, key: K) bool {
			if (self.head_tag == .none) return false;
			return self.prefix(key) != null;
		}

		pub const PutError = error{ IsPrefix } || Allocator.Error;

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
				break :blk 7 - @intCast(u3, @clz(diff));
			};

			const new_dir: u1 = @intCast(u1, (bytes[diff_byte] >> diff_bit) & 1);

			const new_node = try allocator.create(INode);
			new_node.* = .{
				.byte = @intCast(u32, diff_byte),
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
						@intCast(u1, (bytes[inode.byte] >> inode.bit) & 1)
					else 0;
				node = &inode.child[direction];
				tag = &inode.tags[direction];
			}

			new_node.child[new_dir ^ 1] = node.*;
			new_node.tags[new_dir ^ 1] = tag.*;
			node.* = .{
				.inode = new_node,
			};
			tag.* = .inode;
		}

		pub fn remove(self: *Self, allocator: Allocator, key: K) ?V {
			if (self.head == .none) return null;

			const bytes = self.context.asBytes(&key);

			// Find closest node while keeping track of parent node
			var node = &self.head;
			var parent: ?*ENode = null;
			var direction: u1 = undefined;
			while (node.* == .inode) {
				parent = node;
				direction = getDirection(bytes, node.inode.*);
				node = &node.inode.child[direction];
			}

			// Key doesn't exist in map
			if (!self.context.eql(key, node.kv.key)) return null;

			const value = node.kv.value;

			if (parent) |p| {
				const old = p.inode;
				p.* = old.child[direction ^ 1];
				allocator.destroy(old);
			} else {
				self.head = .none;
			}

			return value;
		}

		inline fn getDirection(bytes: []const u8, inode: INode) u1 {
			return if (inode.byte < bytes.len)
					@intCast(u1, (bytes[inode.byte] >> inode.bit) & 1)
				else 0;
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

		fn closestConst(self: Self, key: K) KV {
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
	};
}

test {
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

	var kv = &map.head.inode.child[1].kv;
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

	try t.expectEqual(true, map.contains(""));
	try t.expectEqual(true, map.contains("u"));
	try t.expectEqual(true, map.contains("um"));
	try t.expectEqual(true, map.contains("umm"));
	try t.expectEqual(true, map.contains("umm "));
	try t.expectEqual(true, map.contains("umm \x01"));
	try t.expectEqual(true, map.contains("umm \x04"));
	try t.expectEqual(false, map.contains("something else"));
	try t.expectEqual(false, map.contains("ummm"));
	try t.expectEqual(false, map.contains("umm \x05"));
}

test {
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
