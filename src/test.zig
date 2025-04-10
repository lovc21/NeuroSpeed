const std = @import("std");
const types = @import("types.zig");
const attacks = @import("attacks.zig");
const bitboard = @import("bitboard.zig");
const util = @import("util.zig");
const print = std.debug.print;
const assert = std.debug.assert;
const expect = std.testing.expect;

test "white pawn attacks from e2" {
    var pawn_bb: types.Bitboard = 0;
    pawn_bb |= util.set_bit(pawn_bb, types.square.e2);

    const pawn_attacks = attacks.pawn_attacks_from_bitboard(types.Color.White, pawn_bb);
    print("White pawn attacks:\n", .{});
    try bitboard.print_board(pawn_bb);
    print("White pawn attacks:\n", .{});
    try bitboard.print_board(pawn_attacks);
}

test "black pawn attacks from e7" {
    var pawn_bb: types.Bitboard = 0;
    pawn_bb |= util.set_bit(pawn_bb, types.square.e7);

    const pawn_attacks = attacks.pawn_attacks_from_bitboard(types.Color.Black, pawn_bb);
    print("Black pawn start:\n", .{});
    try bitboard.print_board(pawn_bb);
    print("Black pawn attacks:\n", .{});
    try bitboard.print_board(pawn_attacks);
    print("{d} \n", .{pawn_attacks});
}

test "white pawn attacks from a2 (edge case: A-file)" {
    var pawn_bb: types.Bitboard = 0;
    pawn_bb |= util.set_bit(pawn_bb, types.square.a2);

    const pawn_attacks = attacks.pawn_attacks_from_bitboard(types.Color.White, pawn_bb);

    std.debug.print("White pawn from a2 start:\n", .{});
    try bitboard.print_board(pawn_bb);
    std.debug.print("White pawn from a2 attacks:\n", .{});
    try bitboard.print_board(pawn_attacks);

    print("{d} \n", .{pawn_attacks});
}

test "white pawn attacks from h2 (edge case: H-file)" {
    var pawn_bb: types.Bitboard = 0;
    pawn_bb |= util.set_bit(pawn_bb, types.square.h2);

    const pawn_attacks = attacks.pawn_attacks_from_bitboard(types.Color.White, pawn_bb);
    std.debug.print("White pawn from h2 start:\n", .{});
    try bitboard.print_board(pawn_bb);
    std.debug.print("White pawn from h2 attacks:\n", .{});
    try bitboard.print_board(pawn_attacks);

    print("{d} \n", .{pawn_attacks});
}

test "black pawn attacks from a7 (edge case: A-file)" {
    var pawn_bb: types.Bitboard = 0;
    pawn_bb |= util.set_bit(pawn_bb, types.square.a7);

    const pawn_attacks = attacks.pawn_attacks_from_bitboard(types.Color.Black, pawn_bb);
    std.debug.print("Black pawn from a7 start:\n", .{});
    try bitboard.print_board(pawn_bb);
    std.debug.print("Black pawn from a7 attacks:\n", .{});
    try bitboard.print_board(pawn_attacks);

    print("{d} \n", .{pawn_attacks});
}

test "black pawn attacks from h7 (edge case: H-file)" {
    var pawn_bb: types.Bitboard = 0;
    pawn_bb = util.set_bit(pawn_bb, types.square.h7);

    const pawn_attacks = attacks.pawn_attacks_from_bitboard(types.Color.Black, pawn_bb);
    std.debug.print("Black pawn from h7 start:\n", .{});
    try bitboard.print_board(pawn_bb);
    std.debug.print("Black pawn from h7 attacks:\n", .{});
    try bitboard.print_board(pawn_attacks);

    print("{d} \n", .{pawn_attacks});
}
