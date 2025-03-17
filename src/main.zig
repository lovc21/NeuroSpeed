const std = @import("std");
const print = std.debug.print;
const bitboard = @import("bitboard.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const table_attacks = @import("table_attacks.zig");
pub fn main() !void {
    print("Hello NeroSpeed.\n", .{});
    var bitboard_1: u64 = 0;
    bitboard_1 = util.set_bit(bitboard_1, types.square.e4);
    bitboard_1 = util.set_bit(bitboard_1, types.square.e6);
    bitboard_1 = util.set_bit(bitboard_1, types.square.e2);

    bitboard_1 = util.clear_bit(bitboard_1, types.square.e6);

    print("bit on bitbord {d}\n", .{bitboard_1});
    try bitboard.print_board(bitboard_1);

    var stdout = std.io.getStdOut().writer();
    try stdout.print("White Pawn Attacks:\n", .{});
    for (0..types.number_of_squares) |i| {
        const sq: types.square = @enumFromInt(i);
        var bb: types.Bitboard = 0;
        bb = util.set_bit(bb, sq);
        const white_attacks = table_attacks.pawn_attacks_from_bitboard(types.Color.White, bb);
        try stdout.print("Square {d}: 0x{x}\n", .{ i, white_attacks });
    }

    try stdout.print("\nBlack Pawn Attacks:\n", .{});
    for (0..types.number_of_squares) |i| {
        const sq: types.square = @enumFromInt(i);
        var bb: types.Bitboard = 0;
        bb = util.set_bit(bb, sq);
        const black_attacks = table_attacks.pawn_attacks_from_bitboard(types.Color.Black, bb);
        try stdout.print("Square {d}: 0x{x}\n", .{ i, black_attacks });
    }
}
