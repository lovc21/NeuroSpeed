const types = @import("types.zig");

pub inline fn pawn_attacks_from_bitboard(comptime color: types.Color, bitboard: types.Bitboard) types.Bitboard {
    return if (color == types.Color.White) {} else {};
}
