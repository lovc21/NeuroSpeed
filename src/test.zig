const std = @import("std");
const types = @import("types.zig");
const attacks = @import("attacks.zig");
const bitboard = @import("bitboard.zig");
const util = @import("util.zig");
const print = std.debug.print;
const expect = std.testing.expect;

test "white pawn attacks" {
    print("White pawn attacks from e2 : 0x280000\n", .{});
    try expect(attacks.pawn_attacks_from_bitboard(types.Color.White, util.set_bit(types.empty_Bitboard, types.square.e2)) == 0x280000);

    print("White pawn attacks from a2 : 0x20000\n", .{});
    try expect(attacks.pawn_attacks_from_bitboard(types.Color.White, util.set_bit(types.empty_Bitboard, types.square.a2)) == 0x20000);

    print("White pawn attacks from h2 : 0x400000\n", .{});
    try expect(attacks.pawn_attacks_from_bitboard(types.Color.White, util.set_bit(types.empty_Bitboard, types.square.h2)) == 0x400000);

    print("White pawn attacks from d4 : 0x1400000000\n", .{});
    try expect(attacks.pawn_attacks_from_bitboard(types.Color.White, util.set_bit(types.empty_Bitboard, types.square.d4)) == 0x1400000000);

    print("White pawn attacks from f7 : 0x5000000000000000\n", .{});
    try expect(attacks.pawn_attacks_from_bitboard(types.Color.White, util.set_bit(types.empty_Bitboard, types.square.f7)) == 0x5000000000000000);
}

test "black pawn attacks" {
    print("Black pawn attacks form e7 : 0x280000000000\n", .{});
    try expect(attacks.pawn_attacks_from_bitboard(types.Color.Black, util.set_bit(types.empty_Bitboard, types.square.e7)) == 0x280000000000);

    print("Black pawn attacks from a7 : 0x20000000000\n", .{});
    try expect(attacks.pawn_attacks_from_bitboard(types.Color.Black, util.set_bit(types.empty_Bitboard, types.square.a7)) == 0x20000000000);

    print("Black pawn attacks from h7 : 0x400000000000\n", .{});
    try expect(attacks.pawn_attacks_from_bitboard(types.Color.Black, util.set_bit(types.empty_Bitboard, types.square.h7)) == 0x400000000000);

    print("Black pawn attacks from d5 : 0x14000000\n", .{});
    try expect(attacks.pawn_attacks_from_bitboard(types.Color.Black, util.set_bit(types.empty_Bitboard, types.square.d5)) == 0x14000000);

    print("Black pawn attacks from f2 : 0x50\n", .{});
    try expect(attacks.pawn_attacks_from_bitboard(types.Color.Black, util.set_bit(types.empty_Bitboard, types.square.f2)) == 0x50);
}

test "King attacks" {
    print("King attacks from e2 : 0x382838\n", .{});
    try expect(attacks.king_attacks_from_bitboard(util.set_bit(types.empty_Bitboard, types.square.e2)) == 0x382838);

    print("King attacks from h1 : 0xC040\n", .{});
    try expect(attacks.king_attacks_from_bitboard(util.set_bit(types.empty_Bitboard, types.square.h1)) == 0xC040);

    print("King attacks from a8 : 0x203000000000000\n", .{});
    try expect(attacks.king_attacks_from_bitboard(util.set_bit(types.empty_Bitboard, types.square.a8)) == 0x203000000000000);

    print("King attacks from d4 : 0x1D41C0000\n", .{});
    try expect(attacks.king_attacks_from_bitboard(util.set_bit(types.empty_Bitboard, types.square.d4)) == 0x1c141c0000);

    print("King attacks from b1 : 0x705\n", .{});
    try expect(attacks.king_attacks_from_bitboard(util.set_bit(types.empty_Bitboard, types.square.b1)) == 0x705);

    print("King attacks from g1 : 0xE0A0\n", .{});
    try expect(attacks.king_attacks_from_bitboard(util.set_bit(types.empty_Bitboard, types.square.g1)) == 0xE0A0);

    print("King attacks from a2 : 0x30203\n", .{});
    try expect(attacks.king_attacks_from_bitboard(util.set_bit(types.empty_Bitboard, types.square.a2)) == 0x30203);

    print("King attacks from h8 : 0x40C0000000000000\n", .{});
    try expect(attacks.king_attacks_from_bitboard(util.set_bit(types.empty_Bitboard, types.square.h8)) == 0x40C0000000000000);

    print("King attacks from e5 : 0x382838000000\n", .{});
    try expect(attacks.king_attacks_from_bitboard(util.set_bit(types.empty_Bitboard, types.square.e5)) == 0x382838000000);
}

test "Knight attacks" {
    print("Knight attacks from e2 : 0x28441000\n", .{});
    try expect(attacks.knight_attacks_from_bitboard(util.set_bit(types.empty_Bitboard, types.square.e2)) == 0x28440044);

    print("Knight attacks from e2 : 0x28440044\n", .{});
    try expect(attacks.knight_attacks_from_bitboard(util.set_bit(types.empty_Bitboard, types.square.e2)) == 0x28440044);

    print("Knight attacks from a1 : 0x20400\n", .{});
    try expect(attacks.knight_attacks_from_bitboard(util.set_bit(types.empty_Bitboard, types.square.a1)) == 0x20400);

    print("Knight attacks from h1 : 0x402000\n", .{});
    try expect(attacks.knight_attacks_from_bitboard(util.set_bit(types.empty_Bitboard, types.square.h1)) == 0x402000);

    print("Knight attacks from a8 : 0x402000000000\n", .{});
    try expect(attacks.knight_attacks_from_bitboard(util.set_bit(types.empty_Bitboard, types.square.a8)) == 0x4020000000000);

    print("Knight attacks from h8 : 0x20400000000000\n", .{});
    try expect(attacks.knight_attacks_from_bitboard(util.set_bit(types.empty_Bitboard, types.square.h8)) == 0x20400000000000);

    print("Knight attacks from d4 : 0x142200221400\n", .{});
    try expect(attacks.knight_attacks_from_bitboard(util.set_bit(types.empty_Bitboard, types.square.d4)) == 0x142200221400);
}

test "PRNG produces expected first value for seed 0x123456789ABCDEF" {
    var prng = util.PRNG.init(0x123456789ABCDEF);
    const first = prng.rand64();
    std.debug.print("First output: {d}\n", .{first});
    try expect(first == 8976943199460683916);
}
