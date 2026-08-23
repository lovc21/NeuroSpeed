const std = @import("std");
const print = std.debug.print;
const uci = @import("uci.zig");
const nnue = @import("nnue.zig");
const clock = @import("clock.zig");

comptime {
    _ = @import("memops.zig");
}

pub fn main(init: std.process.Init) !void {
    clock.io = init.io;
    clock.init();
    const allocator = init.gpa;

    try nnue.load_embedded();
    nnue.use_nnue = true;

    var game = uci.UCI.new(allocator);
    try game.uci_loop();
}
