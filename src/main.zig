const std = @import("std");
const print = std.debug.print;
const bitboard = @import("bitboard.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const attacks = @import("attacks.zig");
const lists = @import("lists.zig");
const move_gen = @import("move_generation.zig");
const uci = @import("uci.zig");
const eval = @import("evaluation.zig");

pub fn main() !void {
    const debug = 1;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    if (debug == 1) {
        attacks.init_attacks();
    } else {
        var game = uci.UCI.new(allocator);
        try game.uci_loop();
    }
}
