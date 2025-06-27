const std = @import("std");
const print = std.debug.print;
const bitboard = @import("bitboard.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const attacks = @import("attacks.zig");
const lists = @import("lists.zig");
const move_gen = @import("move_generation.zig");

pub fn main() !void {
    attacks.init_attacks();

    var b = types.Board.new();
    try bitboard.fan_pars(types.start_position, &b);

    bitboard.print_unicode_board(b);

    var movesWhite: lists.MoveList = .{};
    move_gen.generate_moves(&b, &movesWhite, types.Color.White);

    print("Number of moves: {d}\n\n", .{movesWhite.count});

    for (0..movesWhite.count) |i| {
        const move = movesWhite.moves[i];
        const original_state = b.save_state();

        if (move_gen.make_move(&b, move)) {
            print("Legal move made", .{});
            bitboard.print_unicode_board(b);
            bitboard.print_board(b.black_pieces());
            b.restore_state(original_state);
        } else {
            print("Illegal move made", .{});
        }
    }
}
