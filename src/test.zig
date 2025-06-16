const std = @import("std");
const tabele = @import("tabeles.zig");
const types = @import("types.zig");
const attacks = @import("attacks.zig");
const bitboard = @import("bitboard.zig");
const util = @import("util.zig");
const print = std.debug.print;
const expect = std.testing.expect;

test "test print bitboard" {
    bitboard.print_board(0x382838);
    bitboard.print_board(0x30203);
    bitboard.print_board(0x40C0000000000000);
}

test "test print bitboard unicode" {
    var b: types.Board = .{
        .pieces = [_]types.Bitboard{0} ** types.Board.PieceCount,
        .side = types.Color.Black,
        .enpassant = types.square.e3,
        .castle = @intFromEnum(types.Castle.WK) | @intFromEnum(types.Castle.WQ) | @intFromEnum(types.Castle.BK) | @intFromEnum(types.Castle.BQ),
    };

    // White pieces
    // pawns
    b.pieces[@intFromEnum(types.Piece.WHITE_PAWN)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.WHITE_PAWN)], types.square.a2);
    b.pieces[@intFromEnum(types.Piece.WHITE_PAWN)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.WHITE_PAWN)], types.square.b2);
    b.pieces[@intFromEnum(types.Piece.WHITE_PAWN)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.WHITE_PAWN)], types.square.c2);
    b.pieces[@intFromEnum(types.Piece.WHITE_PAWN)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.WHITE_PAWN)], types.square.d2);
    b.pieces[@intFromEnum(types.Piece.WHITE_PAWN)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.WHITE_PAWN)], types.square.e2);
    b.pieces[@intFromEnum(types.Piece.WHITE_PAWN)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.WHITE_PAWN)], types.square.f2);
    b.pieces[@intFromEnum(types.Piece.WHITE_PAWN)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.WHITE_PAWN)], types.square.g2);
    b.pieces[@intFromEnum(types.Piece.WHITE_PAWN)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.WHITE_PAWN)], types.square.h2);
    // knights
    b.pieces[@intFromEnum(types.Piece.WHITE_KNIGHT)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.WHITE_KNIGHT)], types.square.b1);
    b.pieces[@intFromEnum(types.Piece.WHITE_KNIGHT)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.WHITE_KNIGHT)], types.square.g1);
    // bishops
    b.pieces[@intFromEnum(types.Piece.WHITE_BISHOP)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.WHITE_BISHOP)], types.square.c1);
    b.pieces[@intFromEnum(types.Piece.WHITE_BISHOP)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.WHITE_BISHOP)], types.square.f1);
    // rooks
    b.pieces[@intFromEnum(types.Piece.WHITE_ROOK)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.WHITE_ROOK)], types.square.a1);
    b.pieces[@intFromEnum(types.Piece.WHITE_ROOK)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.WHITE_ROOK)], types.square.h1);
    // queen  king
    b.pieces[@intFromEnum(types.Piece.WHITE_QUEEN)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.WHITE_QUEEN)], types.square.d1);
    b.pieces[@intFromEnum(types.Piece.WHITE_KING)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.WHITE_KING)], types.square.e1);

    // Black pieces
    // pawns
    b.pieces[@intFromEnum(types.Piece.BLACK_PAWN)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.BLACK_PAWN)], types.square.a7);
    b.pieces[@intFromEnum(types.Piece.BLACK_PAWN)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.BLACK_PAWN)], types.square.b7);
    b.pieces[@intFromEnum(types.Piece.BLACK_PAWN)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.BLACK_PAWN)], types.square.c7);
    b.pieces[@intFromEnum(types.Piece.BLACK_PAWN)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.BLACK_PAWN)], types.square.d7);
    b.pieces[@intFromEnum(types.Piece.BLACK_PAWN)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.BLACK_PAWN)], types.square.e7);
    b.pieces[@intFromEnum(types.Piece.BLACK_PAWN)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.BLACK_PAWN)], types.square.f7);
    b.pieces[@intFromEnum(types.Piece.BLACK_PAWN)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.BLACK_PAWN)], types.square.g7);
    b.pieces[@intFromEnum(types.Piece.BLACK_PAWN)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.BLACK_PAWN)], types.square.h7);
    // knights
    b.pieces[@intFromEnum(types.Piece.BLACK_KNIGHT)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.BLACK_KNIGHT)], types.square.b8);
    b.pieces[@intFromEnum(types.Piece.BLACK_KNIGHT)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.BLACK_KNIGHT)], types.square.g8);
    // bishops
    b.pieces[@intFromEnum(types.Piece.BLACK_BISHOP)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.BLACK_BISHOP)], types.square.c8);
    b.pieces[@intFromEnum(types.Piece.BLACK_BISHOP)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.BLACK_BISHOP)], types.square.f8);
    // rooks
    b.pieces[@intFromEnum(types.Piece.BLACK_ROOK)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.BLACK_ROOK)], types.square.a8);
    b.pieces[@intFromEnum(types.Piece.BLACK_ROOK)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.BLACK_ROOK)], types.square.h8);
    // queen  king
    b.pieces[@intFromEnum(types.Piece.BLACK_QUEEN)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.BLACK_QUEEN)], types.square.d8);
    b.pieces[@intFromEnum(types.Piece.BLACK_KING)] = util.set_bit(b.pieces[@intFromEnum(types.Piece.BLACK_KING)], types.square.e8);

    bitboard.print_unicode_board(b);
}

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

test "test the get attacks bishop/rook/queen" {
    var occ: types.Bitboard = 0;

    occ = 0;
    print("\nOCC = 0x{x} (empty)\n", .{occ});
    const bishopEmpty = attacks.get_bishop_attacks(types.square.toU6(types.square.d4), occ);
    const rookEmpty = attacks.get_rook_attacks(types.square.toU6(types.square.d4), occ);
    const queenEmpty = attacks.get_queen_attacks(types.square.toU6(types.square.d4), occ);
    print(" bishop(d4) → 0x{x}\n", .{bishopEmpty});
    print("  rook(d4) → 0x{x}\n", .{rookEmpty});
    print("  queen(d4) → 0x{x}\n", .{queenEmpty});
    try std.testing.expectEqual(0x8041221400142241, bishopEmpty);
    try std.testing.expectEqual(0x8080808f7080808, rookEmpty);
    try std.testing.expectEqual(0x88492a1cf71c2a49, queenEmpty);

    occ = ((1 << @intFromEnum(types.square.e7)) | (1 << @intFromEnum(types.square.f6)));
    print("\nOCC = 0x{x} (blockers on b4,f6)\n", .{occ});
    const bishopBlocked = attacks.get_bishop_attacks(types.square.toU6(types.square.b4), occ);
    print(" bishop(d4) → 0x{x}\n", .{bishopBlocked});
    try std.testing.expectEqual(0x10080500050810, bishopBlocked);

    occ = ((1 << @intFromEnum(types.square.b4)) | (1 << @intFromEnum(types.square.d6)));
    print("\nOCC = 0x{x} (blockers on b4,d6)\n", .{occ});
    const rookBlocked = attacks.get_rook_attacks(types.square.toU6(types.square.d4), occ);
    print("  rook(d4) → 0x{x}\n", .{rookBlocked});
    try std.testing.expectEqual(0x808f6080808, rookBlocked);

    occ = ((1 << @intFromEnum(types.square.b4)) | (1 << @intFromEnum(types.square.d6)) | (1 << @intFromEnum(types.square.e7)) | (1 << @intFromEnum(types.square.f6)));
    print("\nOCC = 0x{x} (blockers on b4,d6)\n", .{occ});
    const queenBlocked = attacks.get_queen_attacks(types.square.toU6(types.square.d4), occ);
    print("  queen(d4) → 0x{x}\n", .{queenBlocked});
    try std.testing.expectEqual(0x12a1cf61c2a49, queenBlocked);
}

test "test fen parsing" {
    const TestExpect = struct {
        occupancy: u64,
        ep_str: []const u8,
        castle: u8,
    };

    var fenMap = std.StringHashMap(TestExpect).init(std.testing.allocator);
    defer fenMap.deinit();

    try fenMap.put(
        "8/8/8/8/8/8/8/8 w - - 0 1",
        TestExpect{ .occupancy = 0x0000000000000000, .ep_str = "-", .castle = 0b0000 },
    );
    try fenMap.put(
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        TestExpect{ .occupancy = 0xffff00000000ffff, .ep_str = "-", .castle = 0b1111 },
    );
    try fenMap.put(
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        TestExpect{ .occupancy = 0x91ffa41218737d91, .ep_str = "-", .castle = 0b1111 },
    );
    try fenMap.put(
        "rnbqkb1r/pp1p1pPp/8/2p1pP2/1P1P4/3P3P/P1P1P3/RNBQKBNR w KQkq e6 0 1",
        TestExpect{ .occupancy = 0xff15880a3400ebbf, .ep_str = "e6", .castle = 0b1111 },
    );
    try fenMap.put(
        "r2q1rk1/ppp2ppp/2n1bn2/2b1p3/3pP3/3P1NPP/PPP1NPB1/R1BQ1RK1 b - - 0 9",
        TestExpect{ .occupancy = 0x6d77e8181434e769, .ep_str = "-", .castle = 0b0000 },
    );
    try fenMap.put(
        "r3k2r/8/8/8/3pPp2/8/8/R3K1RR b KQkq e3 0 1",
        TestExpect{ .occupancy = 0xd100003800000091, .ep_str = "e3", .castle = 0b1111 },
    );
    try fenMap.put(
        "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
        TestExpect{ .occupancy = 0x69cb211703e2ef91, .ep_str = "-", .castle = 0b1100 },
    );
    try fenMap.put(
        "8/7p/p5pb/4k3/P1pPn3/8/P5PP/1rB2RK1 b - d3 0 28",
        TestExpect{ .occupancy = 0x66c1001d10c18000, .ep_str = "d3", .castle = 0b0000 },
    );
    try fenMap.put(
        "8/3K4/2p5/p2b2r1/5k2/8/8/1q6 b - - 1 67",
        TestExpect{ .occupancy = 0x0200002049040800, .ep_str = "-", .castle = 0b0000 },
    );
    try fenMap.put(
        "rnbqkb1r/ppppp1pp/7n/4Pp2/8/8/PPPP1PPP/RNBQKBNR w KQkq f6 0 3",
        TestExpect{ .occupancy = 0xffef00003080dfbf, .ep_str = "f6", .castle = 0b1111 },
    );
    try fenMap.put(
        "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
        TestExpect{ .occupancy = 0x91ffa41218737d91, .ep_str = "-", .castle = 0b1111 },
    );
    try fenMap.put(
        "n1n5/PPPk4/8/8/8/8/4Kppp/5N1N b - - 0 1",
        TestExpect{ .occupancy = 0xa0f0000000000f05, .ep_str = "-", .castle = 0b0000 },
    );
    try fenMap.put(
        "r3k2r/p6p/8/B7/1pp1p3/3b4/P6P/R3K2R w KQkq - 0 1",
        TestExpect{ .occupancy = 0x9181081601008191, .ep_str = "-", .castle = 0b1111 },
    );
    try fenMap.put(
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        TestExpect{ .occupancy = 0x005000a283080400, .ep_str = "-", .castle = 0b0000 },
    );
    try fenMap.put(
        "r6r/1b2k1bq/8/8/7B/8/8/R3K2R b KQ - 3 2",
        TestExpect{ .occupancy = 0x910000800000d281, .ep_str = "-", .castle = 0b0011 },
    );
    try fenMap.put(
        "8/8/8/2k5/2pP4/8/B7/4K3 b - d3 0 3",
        TestExpect{ .occupancy = 0x1001000c04000000, .ep_str = "d3", .castle = 0b0000 },
    );
    try fenMap.put(
        "r1bqkbnr/pppppppp/n7/8/8/P7/1PPPPPPP/RNBQKBNR w KQkq - 2 2",
        TestExpect{ .occupancy = 0xfffe01000001fffd, .ep_str = "-", .castle = 0b1111 },
    );
    try fenMap.put(
        "r3k2r/p1pp1pb1/bn2Qnp1/2qPN3/1p2P3/2N5/PPPBBPPP/R3K2R b KQkq - 3 2",
        TestExpect{ .occupancy = 0x91ff04121c736d91, .ep_str = "-", .castle = 0b1111 },
    );
    try fenMap.put(
        "2kr3r/p1ppqpb1/bn2Qnp1/3PN3/1p2P3/2N5/PPPBBPPP/R3K2R b KQ - 3 2",
        TestExpect{ .occupancy = 0x91ff041218737d8c, .ep_str = "-", .castle = 0b0011 },
    );
    try fenMap.put(
        "rnb2k1r/pp1Pbppp/2p5/q7/2B5/8/PPPQNnPP/RNB1K2R w KQ - 3 9",
        TestExpect{ .occupancy = 0x97ff00040104fba7, .ep_str = "-", .castle = 0b0011 },
    );

    var it = fenMap.iterator();
    while (it.next()) |entry| {
        const fen = entry.key_ptr.*;
        const expected = entry.value_ptr.*;

        var b = types.Board.new();
        try bitboard.fan_pars(fen, &b);
        print("\n=== Testing FEN: {s}\n", .{fen});
        print("  occupancy: expected=0x{x}, actual=0x{x}\n", .{ expected.occupancy, b.pieces_combined() });
        print("  en-passant: expected={s}, actual={s}\n", .{ expected.ep_str, if (b.enpassant == types.square.NO_SQUARE) "-" else types.SquareString.getSquareToString(b.enpassant) });
        print("  castling   : expected=0b{b:0>4}, actual=0b{b:0>4}\n\n", .{ expected.castle, b.castle });

        try std.testing.expectEqual(
            expected.occupancy,
            b.pieces_combined(),
        );

        const actual_ep = if (b.enpassant == types.square.NO_SQUARE)
            "-"
        else
            types.SquareString.getSquareToString(b.enpassant);
        try std.testing.expectEqualStrings(
            expected.ep_str,
            actual_ep,
        );

        try std.testing.expectEqual(
            expected.castle,
            b.castle,
        );
    }
}
