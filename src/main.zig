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
        var b = types.Board.new();
        try bitboard.fan_pars("4k3/2ppp3/8/8/8/8/2P5/4K3 w KQkq - 0 1", &b);
        bitboard.print_unicode_board(b);

        const game_eval = eval.evaluat_material(b);
        print("Eval: {d}\n", .{game_eval});
    } else {
        var game = uci.UCI.new(allocator);
        try game.uci_loop();
    }
}
