const std = @import("std");
const ZC = @import("zc").ZC;

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .init;
    defer _ = gpa.deinit();

    var zc: ZC = undefined;
    try zc.init(gpa.allocator(), .{ .ui = false });
    try zc.updateCells();
    try zc.runCommand("fill a0:zz10_000 1");
    try zc.updateCells();
}
