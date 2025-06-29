const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");
const bitboard = @import("bitboard.zig");
const print = std.debug.print;

const VERSION: [*]const u8 = "0.1";

// UCI commands
pub const Command = enum {
    uci,
    isready,
    setoption,
    register,
    ucinewgame,
    position,
    go,
    stop,
    ponderhit,
    quit,
    unknown,
};

// main loop
pub fn uci_loop() void {
    var stdin = std.io.getStdIn().reader();
    var stdout = std.io.getStdOut().writer();
}
