const std = @import("std");
const print = std.debug.print;
const bitboard = @import("bitboard.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const attacks = @import("attacks.zig");
const lists = @import("lists.zig");
const move_gen = @import("move_generation.zig");
const stdout = std.io.getStdOut().writer();

pub fn main() !void {
    attacks.init_attacks();

    var b = types.Board.new();
    try bitboard.fan_pars(types.start_position, &b);

    const bb = b.pieces_combined();
    print("Occupancy (hex): 0x{x}\n", .{bb});

    b.side = types.Color.White;
    bitboard.print_unicode_board(b);

    var moves: lists.MoveList = .{};
    move_gen.generate_moves(&b, &moves, types.Color.Black);

    //print("{any}", .{moves});

    for (0..moves.count) |i| {
        const m = moves.moves[i];
        // convert the raw u6 back into a square enum
        const from_sq: types.square = @enumFromInt(m.from);
        const to_sq: types.square = @enumFromInt(m.to);

        const from_str = types.SquareString.getSquareToString(from_sq);
        const to_str = types.SquareString.getSquareToString(to_sq);
        // flags is just a small integer

        try stdout.print("{s}->{s} flags={any}\n", .{ from_str, to_str, m.flags });
    }

    bitboard.print_attacked_squares(&b);
    bitboard.print_attacked_squares_new(&b);
}
