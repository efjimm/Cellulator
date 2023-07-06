const std = @import("std");
const GapBuffer = @import("GapBuffer.zig");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// List of previous commands
history: std.ArrayListUnmanaged([]const u8) = .{},

/// Byte position of the cursor in the currently selected buffer.
cursor: u32 = 0,

/// The command currently being edited. May be a pointer to an older command,
/// which will have copy on write behaviour.
buffer: GapBuffer = .{},

/// What index of the `history` list the `current` buffer points to.
/// If none, this is equal to history.items.len
index: u32 = 0,

/// Copy-on-write. If true, we are using a history item, otherwise we are using
/// the `current` buffer.
cow: bool = false,

const Self = @This();
pub const ElementType = u8;

pub fn deinit(self: *Self, allocator: Allocator) void {
    for (self.history.items) |item| allocator.free(item);
    self.history.deinit(allocator);
    self.buffer.deinit(allocator);
}

/// Pushes the current command buffer to the history list and returns a slice
/// of its contents.
pub fn submit(self: *Self, allocator: Allocator) Allocator.Error![]const u8 {
    try self.history.ensureUnusedCapacity(allocator, 1);
    const items = try allocator.dupe(u8, self.buffer.items());
    self.history.appendAssumeCapacity(items);
    self.resetBuffer();
    return items;
}

pub fn resetBuffer(self: *Self) void {
    self.buffer.clearRetainingCapacity();
    self.cursor = 0;
    self.cow = false;
    self.index = @intCast(self.history.items.len);
}

/// Deep copies the contents of the history item at `index` into the buffer
fn copyToBuffer(self: *Self, allocator: Allocator, index: u32) Allocator.Error!void {
    const src = self.history.items[index];
    try self.buffer.ensureTotalCapacity(allocator, @intCast(src.len));
    self.buffer.clearRetainingCapacity();
    self.buffer.appendSliceAssumeCapacity(src);
}

/// Moves the current command up in the history. Does nothing if at the top.
pub fn prev(self: *Self, count: u32) void {
    if (self.index > 0) {
        self.index -|= count;
        self.cow = true;
        self.cursor = @intCast(self.history.items[self.index].len);
    }
}

/// Moves the current command down in the history. Does nothing if at the bottom.
pub fn next(self: *Self, count: u32) void {
    if (self.index < self.history.items.len) {
        self.index = @min(self.index + count, @as(u32, @intCast(self.history.items.len)));

        // Set copy-on-write if we are still referencing an existing history item.
        if (self.index != self.history.items.len) {
            self.cursor = @intCast(self.history.items[self.index].len);
            self.cow = true;
        } else {
            self.cursor = self.buffer.len;
            self.cow = false;
        }
    }
}

/// Writes `bytes` to the buffer and moves the cursor accordingly.
pub fn write(self: *Self, allocator: Allocator, bytes: []const u8) Allocator.Error!usize {
    try self.copyIfNeeded(allocator);
    try self.buffer.insertSlice(allocator, self.cursor, bytes);
    self.cursor += @intCast(bytes.len);
    return bytes.len;
}

pub fn replaceRange(
    self: *Self,
    allocator: Allocator,
    start: u32,
    len: u32,
    new_bytes: []const u8,
) Allocator.Error!void {
    try self.copyIfNeeded(allocator);
    try self.buffer.replaceRange(allocator, start, len, new_bytes);
}

/// Returns a writer that will write to the current cursor positon and advance the cursor
/// accordingly.
pub fn writer(self: *Self, allocator: Allocator) Writer {
    return .{ .context = .{
        .data = self,
        .allocator = allocator,
    } };
}

pub const Writer = std.io.Writer(WriterContext, Allocator.Error, WriterContext.ctxWrite);

pub const WriterContext = struct {
    data: *Self,
    allocator: Allocator,

    pub fn ctxWrite(ctx: @This(), bytes: []const u8) Allocator.Error!usize {
        return ctx.data.write(ctx.allocator, bytes);
    }
};

pub fn get(self: Self, index: u32) u8 {
    return if (self.cow)
        self.history.items[self.index][index]
    else
        self.buffer.get(index);
}

pub fn length(self: Self) u32 {
    return if (self.cow)
        @intCast(self.history.items[self.index].len)
    else
        self.buffer.len;
}

pub fn indexOfPos(self: Self, pos: u32, needle: []const u8) ?u32 {
    if (self.cow) {
        const res = std.mem.indexOfPos(u8, self.history.items[self.index], pos, needle);
        if (res) |r| return @intCast(r);
        return null;
    }
    return self.buffer.lastIndexOfPos(pos, needle);
}

pub fn lastIndexOfPos(self: Self, pos: u32, needle: []const u8) ?u32 {
    if (self.cow) {
        const res = std.mem.lastIndexOfLinear(u8, self.history.items[self.index][0..pos], needle);
        if (res) |r| return @intCast(r);
        return null;
    }
    return self.buffer.lastIndexOfPos(pos, needle);
}

pub fn setCursor(self: *Self, n: u32) void {
    assert(n <= self.length());
    self.cursor = n;
}

/// If currently pointing to a history item, copies it to the buffer. Call this if you
/// want to be able to safely modify `buffer` directly.
pub fn copyIfNeeded(self: *Self, allocator: Allocator) Allocator.Error!void {
    if (self.cow) {
        std.log.debug("Copying '{s}' to buffer", .{self.history.items[self.index]});
        try self.copyToBuffer(allocator, self.index);
        self.cow = false;
    }
}

/// Deletes `n` bytes backwards, from the current cursor position.
pub fn deleteBackwards(self: *Self, allocator: Allocator, n: u32) Allocator.Error!void {
    try self.copyIfNeeded(allocator);
    self.deleteBackwardsAssumeCopied(n);
}

pub fn deleteBackwardsAssumeCopied(self: *Self, n: u32) void {
    const new_cursor = self.cursor -| n;
    self.buffer.replaceRange(undefined, new_cursor, self.cursor - new_cursor, &.{}) catch unreachable;
    self.setCursor(new_cursor);
}

pub fn left(self: *const Self) []const u8 {
    return if (self.cow)
        self.history.items[self.index]
    else
        self.buffer.left();
}

pub fn right(self: *const Self) []const u8 {
    return if (self.cow)
        ""
    else
        self.buffer.right();
}

test {
    const t = std.testing;

    var self = Self{};
    defer self.deinit(t.allocator);

    const w = self.writer(t.allocator);
    try w.writeAll("This is epic!");

    try t.expectEqualStrings("This is epic!", self.buffer.items());
    try t.expectEqual(@as(usize, 0), self.history.items.len);
    try t.expect(!self.cow);

    var str = try self.submit(t.allocator);
    try t.expectEqual(@as(u32, 0), self.buffer.len);
    try t.expectEqualStrings("This is epic!", str);
    try t.expect(str.ptr == self.history.items[0].ptr);
    try t.expectEqual(@as(u32, 1), self.index);

    self.prev(1);
    try t.expectEqual(@as(u32, 0), self.index);
    try t.expect(self.cow);

    try w.writeAll(" ...");
    try w.writeAll(" Not!");
    try t.expectEqual(@as(u32, 0), self.index);
    try t.expect(!self.cow);
}
