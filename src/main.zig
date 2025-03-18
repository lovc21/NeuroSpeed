const std = @import("std");
const print = std.debug.print;
const bitboard = @import("bitboard.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const table_attacks = @import("table_attacks.zig");
pub fn main() !void {
    var stdout = std.io.getStdOut().writer();
    // test bitbord print funcion
    // var bitboard_1: u64 = 0;
    // bitboard_1 = util.set_bit(bitboard_1, types.square.e4);
    // bitboard_1 = util.set_bit(bitboard_1, types.square.e6);
    // bitboard_1 = util.set_bit(bitboard_1, types.square.e2);
    //
    // bitboard_1 = util.clear_bit(bitboard_1, types.square.e6);
    //
    // print("bit on bitbord {d}\n", .{bitboard_1});
    // try bitboard.print_board(bitboard_1);
    //
    // // print  attackes for pawns
    // try stdout.print("White Pawn Attacks:\n", .{});
    // for (0..types.number_of_squares) |i| {
    //     const sq: types.square = @enumFromInt(i);
    //     var bb: types.Bitboard = 0;
    //     bb = util.set_bit(bb, sq);
    //     const white_attacks = table_attacks.pawn_attacks_from_bitboard(types.Color.White, bb);
    //     try stdout.print("Square {d}: 0x{x}\n", .{ i, white_attacks });
    // }
    //
    // try stdout.print("\nBlack Pawn Attacks:\n", .{});
    // for (0..types.number_of_squares) |i| {
    //     const sq: types.square = @enumFromInt(i);
    //     var bb: types.Bitboard = 0;
    //     bb = util.set_bit(bb, sq);
    //     const black_attacks = table_attacks.pawn_attacks_from_bitboard(types.Color.Black, bb);
    //     try stdout.print("Square {d}: 0x{x}\n", .{ i, black_attacks });
    // }

    // print attackes for King
    // try stdout.print("\nKing Attacks:\n", .{});
    // for (0..types.number_of_squares) |i| {
    //     const sq: types.square = @enumFromInt(i);
    //     var bb: types.Bitboard = 0;
    //     bb = util.set_bit(bb, sq);
    //     const king_attacks = table_attacks.king_attacks_from_bitboard(bb);
    //     try bitboard.print_board(king_attacks);
    //     try stdout.print("Square {d}: 0x{x}\n", .{ i, king_attacks });
    // }

    try stdout.print("\nKnight Attacks:\n", .{});
    for (0..types.number_of_squares) |i| {
        const sq: types.square = @enumFromInt(i);
        var bb: types.Bitboard = 0;
        bb = util.set_bit(bb, sq);
        const knight_attacks = table_attacks.knight_attacks_from_bitboard(bb);
        //try bitboard.print_board(knight_attacks);
        try stdout.print("Square {d}: 0x{x}\n", .{ i, knight_attacks });
    }
}
