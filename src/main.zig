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

        // Test with starting position
        var board = types.Board.new();
        try bitboard.fan_pars("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", &board);
        print("Starting position phase: White={}, Black={}\n", .{ eval.phase[0], eval.phase[1] });
        // Should print: White=11, Black=11

        // Test with endgame position
        try bitboard.fan_pars("8/8/8/8/8/8/8/K7 w - - 0 1", &board);
        print("King vs King phase: White={}, Black={}\n", .{ eval.phase[0], eval.phase[1] });
        // Should print: White=0, Black=0

    } else {
        var game = uci.UCI.new(allocator);
        try game.uci_loop();
    }
}
