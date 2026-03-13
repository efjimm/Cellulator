const std = @import("std");
const GapBuffer = @import("gap_buffer.zig").GapBuffer;
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// List of indices into the history buffer.
history_indices: std.ArrayList(u32) = .empty,

/// Append-only buffer of text, used for history items.
history_buf: std.ArrayList(u8) = .empty,

/// Byte position of the cursor in the currently selected buffer.
cursor: u32 = 0,

/// The command currently being edited. May be a pointer to an older command,
/// which will have copy on write behaviour.
buffer: GapBuffer(u8) = .empty,

/// What index of the `history` list the `current` buffer points to.
/// If none, this is equal to history.items.len
index: u32 = 0,

/// Copy-on-write. If true, we are using a history item, otherwise we are using
/// the `current` buffer.
cow: bool = false,

const Self = @This();
pub const ChildType = u8;

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.history_buf.deinit(allocator);
    self.history_indices.deinit(allocator);
    self.buffer.deinit(allocator);
}

/// Pushes the current command buffer to the history list and returns a slice
/// of its contents.
pub fn submit(self: *Self, allocator: Allocator) Allocator.Error![:0]const u8 {
    defer self.resetBuffer();
    try self.history_indices.ensureUnusedCapacity(allocator, 1);

    if (self.cow) {
        const index = self.history_indices.items[self.index];
        self.history_indices.appendAssumeCapacity(index);
        const ptr: [*:0]const u8 = @ptrCast(self.history_buf.items[index..].ptr);
        return std.mem.span(ptr);
    }

    try self.history_buf.ensureUnusedCapacity(allocator, self.buffer.len + 1);

    const start_index: u32 = @intCast(self.history_buf.items.len);
    self.history_buf.appendSliceAssumeCapacity(self.buffer.items());
    self.history_buf.appendAssumeCapacity(0);
    self.history_indices.appendAssumeCapacity(start_index);
    return self.history_buf.items[start_index .. self.history_buf.items.len - 1 :0];
}

pub fn getHistoryItem(self: *const Self, index: u32) [:0]const u8 {
    assert(self.cow);
    const i = self.history_indices.items[index];
    const ptr: [*:0]const u8 = @ptrCast(self.history_buf.items[i..].ptr);
    return std.mem.span(ptr);
}

pub fn resetBuffer(self: *Self) void {
    self.buffer.clearRetainingCapacity();
    self.cursor = 0;
    self.cow = false;
    self.index = @intCast(self.history_indices.items.len);
}

/// Deep copies the contents of the history item at `index` into the buffer
fn copyToBuffer(self: *Self, allocator: Allocator, index: u32) Allocator.Error!void {
    const src = self.getHistoryItem(index);
    try self.buffer.ensureTotalCapacity(allocator, @intCast(src.len));
    self.buffer.clearRetainingCapacity();
    self.buffer.appendSliceAssumeCapacity(src);
}

/// Moves the current command up in the history. Does nothing if at the top.
pub fn prev(self: *Self, count: u32) void {
    if (self.index > 0) {
        self.index -|= count;
        self.cow = true;
        const len = self.getHistoryItem(self.index).len;
        self.cursor = @intCast(len);
    }
}

/// Moves the current command down in the history. Does nothing if at the bottom.
pub fn next(self: *Self, count: u32) void {
    if (self.index < self.history_indices.items.len) {
        self.index = @intCast(@min(self.index + count, self.history_indices.items.len));

        // Set copy-on-write if we are still referencing an existing history item.
        if (self.index != self.history_indices.items.len) {
            self.cursor = @intCast(self.getHistoryItem(self.index).len);
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
pub fn writer(self: *Self, allocator: Allocator, buffer: []u8) Writer {
    return .{
        .interface = .{
            .vtable = &.{
                .drain = Writer.drain,
            },
            .buffer = buffer,
            .end = 0,
        },
        .cmd = self,
        .allocator = allocator,
    };
}

pub const Writer = struct {
    interface: std.Io.Writer,
    cmd: *Self,
    allocator: std.mem.Allocator,

    pub fn drain(io_writer: *std.Io.Writer, data: []const []const u8, splat: usize) !usize {
        const w: *Writer = @fieldParentPtr("interface", io_writer);
        const buffered = w.interface.buffered();
        if (buffered.len > 0) {
            const bytes_written = w.cmd.write(w.allocator, buffered) catch
                return error.WriteFailed;

            const remaining = w.interface.consume(bytes_written);
            if (remaining != 0)
                return 0;
        }

        var total_written: usize = 0;
        for (data[0 .. data.len - 1]) |str| {
            const bytes_written = w.cmd.write(w.allocator, str) catch
                return error.WriteFailed;

            total_written += bytes_written;
            if (bytes_written < str.len) return total_written;
        }

        const pattern = data[data.len - 1];
        for (0..splat) |_| {
            const bytes_written = w.cmd.write(w.allocator, pattern) catch
                return error.WriteFailed;

            total_written += bytes_written;
            if (bytes_written < pattern.len) return total_written;
        }

        return total_written;
    }
};

pub fn get(self: *const Self, index: u32) u8 {
    return if (self.cow)
        self.getHistoryItem(self.index)[index]
    else
        self.buffer.get(index);
}

pub fn slice(self: *const Self, start: u32, len: u32) []const u8 {
    if (self.cow) {
        return self.getHistoryItem(self.index)[start..][0..len];
    }

    if (start < self.buffer.gap_start) {
        return self.buffer.left()[start..][0..len];
    } else {
        return self.buffer.right()[start - self.buffer.gap_start ..][0..len];
    }
}

pub fn length(self: *const Self) u32 {
    return if (self.cow)
        @intCast(self.getHistoryItem(self.index).len)
    else
        self.buffer.len;
}

pub fn indexOfPos(self: *const Self, pos: u32, needle: []const u8) ?u32 {
    if (self.cow) {
        const res = std.mem.indexOfPos(u8, self.getHistoryItem(self.index), pos, needle);
        if (res) |r| return @intCast(r);
        return null;
    }
    return self.buffer.lastIndexOfPos(pos, needle);
}

pub fn lastIndexOfPos(self: *const Self, pos: u32, needle: []const u8) ?u32 {
    if (self.cow) {
        const res = std.mem.lastIndexOfLinear(u8, self.getHistoryItem(self.index)[0..pos], needle);
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
        std.log.debug("Copying '{s}' to buffer", .{self.getHistoryItem(self.index)});
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
    self.buffer.deleteRange(new_cursor, self.cursor);
    self.setCursor(new_cursor);
}

pub fn left(self: *const Self) []const u8 {
    return if (self.cow)
        self.getHistoryItem(self.index)
    else
        self.buffer.left();
}

pub fn right(self: *const Self) []const u8 {
    return if (self.cow)
        ""
    else
        self.buffer.right();
}

pub fn reader(self: *Self, buffer: []u8) Reader {
    return .{
        .cmd = self,
        .gap_reader = self.buffer.reader(&.{}),
        .interface = .{
            .vtable = &.{
                .stream = Reader.stream,
            },
            .buffer = buffer,
            .seek = 0,
            .end = 0,
        },
        .i = 0,
    };
}

pub const Reader = struct {
    cmd: *const Self,
    gap_reader: GapBuffer(u8).Reader,
    i: u32,
    interface: std.Io.Reader,

    pub fn stream(io_reader: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) !usize {
        const r: *Reader = @fieldParentPtr("interface", io_reader);
        if (r.cmd.cow) {
            const bytes = r.cmd.getHistoryItem(r.cmd.index);
            if (r.i >= bytes.len) return error.EndOfStream;
            const limited = limit.sliceConst(bytes);
            const n = try w.write(limited);
            r.i += @intCast(n);
            return n;
        }

        return r.gap_reader.interface.stream(w, limit);
    }
};

const zg = @import("zg");

pub fn nextCharacter(self: *const Self, index: u32, count: u32) u32 {
    if (self.cow) {
        const str = self.getHistoryItem(self.index);
        var iter = zg.graphemes.iterator(str[index..]);
        var n: u32 = 0;
        for (0..count) |_| {
            const g = iter.next() orelse break;
            n += @intCast(g.len);
        }
        return n;
    }
    return self.buffer.nextCharacter(index, count);
}

pub fn prevCharacter(self: *const Self, index: u32, count: u32) u32 {
    if (self.cow) {
        const str = self.getHistoryItem(self.index);
        var iter = zg.graphemes.reverseIterator(str[0..index]);
        var n: u32 = index;
        for (0..count) |_| {
            const g = iter.prev() orelse break;
            n = @intCast(g.offset);
        }
        return index - n;
    }
    return self.buffer.prevCharacter(index, count);
}

test "Command" {
    const t = std.testing;

    var self = Self{};
    defer self.deinit(t.allocator);

    var w = self.writer(t.allocator, &.{});
    try w.interface.writeAll("This is epic!");

    try t.expectEqualStrings("This is epic!", self.buffer.items());
    try t.expectEqual(@as(usize, 0), self.history_indices.items.len);
    try t.expect(!self.cow);

    const str = try self.submit(t.allocator);
    try t.expectEqual(@as(u32, 0), self.buffer.len);
    try t.expectEqualStrings("This is epic!", str);
    try t.expectEqual(@as(u32, 1), self.index);

    self.prev(1);
    try t.expectEqual(@as(u32, 0), self.index);
    try t.expect(self.cow);

    try w.interface.writeAll(" ...");
    try w.interface.writeAll(" Not!");
    try t.expectEqual(@as(u32, 0), self.index);
    try t.expect(!self.cow);
}
