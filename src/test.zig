const std = @import("std");
const tabele = @import("tabeles.zig");
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

test "rook attacks table with empty occupancy" {
    attacks.init_rook_attackes();
    for (types.square_number) |square| {
        const sq6: u6 = @truncate(square);
        const expected = attacks.get_rook_attacks_for_init(sq6, 0);
        const table_val = attacks.Rook_attacks[square][0];
        print("Rook attacks for square {d} with empty occ: expected=0x{X}, got=0x{X}\n", .{ square, expected, table_val });
        try std.testing.expectEqual(@as(types.Bitboard, expected), table_val);
    }
}

test "rook attacks with one blocker" {
    attacks.init_rook_attackes();
    const sq_idx: u8 = 27;
    const occ_single: u64 = (@as(u64, 1) << (3 + 5 * 8)); // blocker on d6
    const occ_masked = occ_single & tabele.Rook_attackes_tabele[sq_idx];
    const relevantBits = tabele.Rook_index_bit[sq_idx];
    const magic = tabele.rook_magics[sq_idx];
    const shift8: u8 = 64 - relevantBits;
    const shift: u6 = @truncate(shift8);
    const idx = (@as(u64, occ_masked) *% magic) >> shift;
    const table_attacks = attacks.Rook_attacks[sq_idx][@intCast(idx)];
    const expected = attacks.get_rook_attacks_for_init(@as(u6, sq_idx), occ_single);
    print("Rook attacks with blocker on square {d}: occ=0x{X}, idx={d}, table=0x{X}, expected=0x{X}\n", .{ sq_idx, occ_single, idx, table_attacks, expected });
    try std.testing.expectEqual(@as(types.Bitboard, expected), table_attacks);
}

test "bishop attacks table with empty occupancy" {
    attacks.init_bishop_attackes();
    for (types.square_number) |square| {
        const sq6: u6 = @truncate(square);
        const expected = attacks.get_bishop_attacks_for_init(sq6, 0);
        const table_val = attacks.Bishop_attacks[square][0];
        print("Bishop attacks for square {d} with empty occ: expected=0x{X}, got=0x{X}\n", .{ square, expected, table_val });
        try std.testing.expectEqual(@as(types.Bitboard, expected), table_val);
    }
}

test "bishop attacks with one blocker" {
    attacks.init_bishop_attackes();
    const sq_idx: u8 = 27; // d4
    const occ_single: u64 = (@as(u64, 1) << 45); // blocker on f6
    const mask = tabele.Bishops_attackes_tabele[sq_idx];
    const occ_masked = occ_single & mask;
    const relevantBits = tabele.Bishop_index_bit[sq_idx];
    const magic = tabele.bishop_magics[sq_idx];
    const shift: u6 = @truncate(64 - relevantBits);
    const idx64 = (@as(u64, occ_masked) *% magic) >> shift;
    const idx: usize = @intCast(idx64);
    const table_attacks = attacks.Bishop_attacks[sq_idx][idx];
    const expected = attacks.get_bishop_attacks_for_init(@as(u6, sq_idx), occ_single);
    print("Bishop attacks with blocker on square {d}: occ=0x{X}, idx={d}, table=0x{X}, expected=0x{X}\n", .{ sq_idx, occ_single, idx, table_attacks, expected });
    try std.testing.expectEqual(@as(types.Bitboard, expected), table_attacks);
}
