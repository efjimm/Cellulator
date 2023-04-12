const std = @import("std");
const utils = @import("utils.zig");
const spoon = @import("spoon");

pub fn TextInput(comptime size: usize) type {
	return struct {
		const Self = @This();
		const Array = std.BoundedArray(u8, size);

		pub const Status = union(enum) {
			waiting,
			cancelled,
			string: Array,
		};

		array: Array = .{},

		pub fn handleInput(self: *Self, buf: []const u8) !Status {
			var iter = spoon.inputParser(buf);

			while (iter.next()) |in| {
				if (in.mod_ctrl) switch (in.content) {
					.codepoint => |cp| switch (cp) {
						'j', 'm', '\r', '\n' => return .{ .string = self.finish() },
						'h', 127 => self.array.len -|= 1,
						else => {},
					},
					else => {},
				} else switch (in.content) {
					.escape => {
						self.reset();
						return .cancelled;
					},
					.codepoint => |cp| switch (cp) {
						'\n', '\r' => return .{ .string = self.finish() },
						127 => self.array.len -|= 1,

						// ignore control codes
						0...'\n'-1, '\n'+1...'\r'-1, '\r'+1...31 => {},

						else => {
							const array_writer = self.array.writer();
							utils.writeCodepoint(cp, array_writer) catch {};
						},
					},
					else => {},
				}
			}

			return .waiting;
		}

		fn finish(self: *Self) Array {
			defer self.reset();
			return self.array;
		}

		pub fn writer(self: *Self) Array.Writer {
			return self.array.writer();
		}

		pub fn reset(self: *Self) void {
			self.array.len = 0;
		}

		pub fn slice(self: *Self) []const u8 {
			return self.array.slice();
		}
	};
}
