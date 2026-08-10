const std = @import("std");
const print = std.debug.print;
const uci = @import("uci.zig");
const nnue = @import("nnue.zig");
const globals = @import("globals.zig");

// Pull in the fast-memset override so its export is emitted.
comptime {
    _ = @import("memops.zig");
}

pub fn main(init: std.process.Init) !void {
    globals.io = init.io;
    const allocator = init.gpa;

    // Everything goes through the UCI loop — no CLI arguments. bench,
    // verify, datagen, rescore and dumpfen are all loop commands
    // (pipe for scripting: `printf 'bench 6\nquit\n' | NeuroSpeed`).
    try nnue.load_embedded();
    nnue.use_nnue = true;

    var game = uci.UCI.new(allocator);
    try game.uci_loop();
}

