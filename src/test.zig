const std = @import("std");
const tabeles = @import("tabeles.zig");
const types = @import("types.zig");
const attacks = @import("attacks.zig");
const bitboard = @import("bitboard.zig");
const util = @import("util.zig");
const eval = @import("evaluation.zig");
const move_gen = @import("move.zig");
const movegen = @import("movegen.zig");
const lists = @import("lists.zig");
const zobrist = @import("zobrist.zig");
const nnue = @import("nnue.zig");
const datagen = @import("datagen.zig");
const clock = @import("clock.zig");
const tm = @import("time_management.zig");
const tt = @import("tt.zig");
const search = @import("search.zig");
const bench = @import("bench.zig");
const print = std.debug.print;
const expect = std.testing.expect;

comptime {
    _ = @import("memops");
}

test "time management budget matches reference vectors" {
    // Vectors from an independent model of the budget arithmetic (overhead 10 ms, default tm_* params, increments counted in full).
    const V = struct { time: u64, inc: u64, movestogo: ?u64, soft: u64, hard: u64 };
    const vectors = [_]V{
        .{ .time = 60000, .inc = 0, .movestogo = null, .soft = 1989, .hard = 27595 },
        .{ .time = 60000, .inc = 1000, .movestogo = null, .soft = 3656, .hard = 27595 },
        .{ .time = 180000, .inc = 2000, .movestogo = null, .soft = 9322, .hard = 82795 },
        .{ .time = 1500, .inc = 0, .movestogo = null, .soft = 39, .hard = 685 },
        .{ .time = 500, .inc = 0, .movestogo = null, .soft = 9, .hard = 225 },
        .{ .time = 100, .inc = 0, .movestogo = null, .soft = 6, .hard = 41 },
        .{ .time = 30, .inc = 0, .movestogo = null, .soft = 5, .hard = 9 },
        .{ .time = 8, .inc = 0, .movestogo = null, .soft = 2, .hard = 2 },
        .{ .time = 3, .inc = 0, .movestogo = null, .soft = 1, .hard = 1 },
        .{ .time = 60000, .inc = 0, .movestogo = 30, .soft = 1400, .hard = 27595 },
        .{ .time = 120000, .inc = 2000, .movestogo = 40, .soft = 3500, .hard = 55195 },
        .{ .time = 2000, .inc = 50, .movestogo = 80, .soft = 63, .hard = 915 },
        .{ .time = 60000, .inc = 10, .movestogo = null, .soft = 2006, .hard = 27595 },
        .{ .time = 60000, .inc = 11, .movestogo = null, .soft = 2007, .hard = 27595 },
    };
    for (vectors) |v| {
        const b = tm.time_management(v.time, v.inc, v.movestogo, 10);
        try std.testing.expectEqual(v.soft, b.soft);
        try std.testing.expectEqual(v.hard, b.hard);
    }
    // go-level shortcuts and side selection
    try std.testing.expectEqual(tm.Budget{ .soft = 1000, .hard = 1000 }, tm.budget(.{ .movetime = 1000, .wtime = 5 }, .White, 10));
    try std.testing.expectEqual(tm.Budget{}, tm.budget(.{ .infinite = true, .wtime = 60000 }, .White, 10));
    try std.testing.expectEqual(tm.Budget{}, tm.budget(.{ .depth = 5, .wtime = 60000 }, .White, 10));
    try std.testing.expectEqual(tm.Budget{ .soft = 1989, .hard = 27595 }, tm.budget(.{ .wtime = 60000, .btime = 1 }, .White, 10));
    try std.testing.expectEqual(tm.Budget{ .soft = 1989, .hard = 27595 }, tm.budget(.{ .wtime = 1, .btime = 60000 }, .Black, 10));
}

test "clock: timer accuracy (cycle-counter path if available)" {
    clock.init();
    print("clock: cycle-counter path active = {}\n", .{clock.usingCycleCounter()});
    // A 50ms sleep must measure at least 50ms and not much more.
    var t: clock.Timer = .start();
    try clock.io.sleep(.fromMilliseconds(50), .awake);
    const ns = t.read();
    try expect(ns >= 49 * std.time.ns_per_ms);
    try expect(ns <= 250 * std.time.ns_per_ms);
    // Reads never go backwards.
    var t2: clock.Timer = .start();
    var prev: u64 = 0;
    for (0..50_000) |_| {
        const v = t2.read();
        try expect(v >= prev);
        prev = v;
    }
    // Deadline: not expired fresh, expired after its window passes.
    const dl: clock.Deadline = .afterMs(30);
    try expect(!dl.expired());
    try clock.io.sleep(.fromMilliseconds(40), .awake);
    try expect(dl.expired());
    const dl_never: clock.Deadline = .never;
    try expect(!dl_never.expired());
}

test "test print bitboard" {
    bitboard.print_board(0x382838);
    bitboard.print_board(0x30203);
    bitboard.print_board(0x40C0000000000000);
}

test "test print bitboard unicode" {
    // Black to move, all castling rights and an ep square, so every FEN field is printed.
    var b = types.Board.new();
    try bitboard.parse_fen("rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR b KQkq e3 0 1", &b);
    bitboard.print_unicode_board(b);
}

test "white pawn attacks" {
    print("White pawn attacks from e2 : 0x280000\n", .{});
    try expect(attacks.pawn_attacks_from_bitboard(types.Color.White, util.set_bit(types.empty_bitboard, types.square.e2)) == 0x280000);

    print("White pawn attacks from a2 : 0x20000\n", .{});
    try expect(attacks.pawn_attacks_from_bitboard(types.Color.White, util.set_bit(types.empty_bitboard, types.square.a2)) == 0x20000);

    print("White pawn attacks from h2 : 0x400000\n", .{});
    try expect(attacks.pawn_attacks_from_bitboard(types.Color.White, util.set_bit(types.empty_bitboard, types.square.h2)) == 0x400000);

    print("White pawn attacks from d4 : 0x1400000000\n", .{});
    try expect(attacks.pawn_attacks_from_bitboard(types.Color.White, util.set_bit(types.empty_bitboard, types.square.d4)) == 0x1400000000);

    print("White pawn attacks from f7 : 0x5000000000000000\n", .{});
    try expect(attacks.pawn_attacks_from_bitboard(types.Color.White, util.set_bit(types.empty_bitboard, types.square.f7)) == 0x5000000000000000);
}

test "black pawn attacks" {
    print("Black pawn attacks form e7 : 0x280000000000\n", .{});
    try expect(attacks.pawn_attacks_from_bitboard(types.Color.Black, util.set_bit(types.empty_bitboard, types.square.e7)) == 0x280000000000);

    print("Black pawn attacks from a7 : 0x20000000000\n", .{});
    try expect(attacks.pawn_attacks_from_bitboard(types.Color.Black, util.set_bit(types.empty_bitboard, types.square.a7)) == 0x20000000000);

    print("Black pawn attacks from h7 : 0x400000000000\n", .{});
    try expect(attacks.pawn_attacks_from_bitboard(types.Color.Black, util.set_bit(types.empty_bitboard, types.square.h7)) == 0x400000000000);

    print("Black pawn attacks from d5 : 0x14000000\n", .{});
    try expect(attacks.pawn_attacks_from_bitboard(types.Color.Black, util.set_bit(types.empty_bitboard, types.square.d5)) == 0x14000000);

    print("Black pawn attacks from f2 : 0x50\n", .{});
    try expect(attacks.pawn_attacks_from_bitboard(types.Color.Black, util.set_bit(types.empty_bitboard, types.square.f2)) == 0x50);
}

test "King attacks" {
    print("King attacks from e2 : 0x382838\n", .{});
    try expect(attacks.king_attacks_from_bitboard(util.set_bit(types.empty_bitboard, types.square.e2)) == 0x382838);

    print("King attacks from h1 : 0xC040\n", .{});
    try expect(attacks.king_attacks_from_bitboard(util.set_bit(types.empty_bitboard, types.square.h1)) == 0xC040);

    print("King attacks from a8 : 0x203000000000000\n", .{});
    try expect(attacks.king_attacks_from_bitboard(util.set_bit(types.empty_bitboard, types.square.a8)) == 0x203000000000000);

    print("King attacks from d4 : 0x1D41C0000\n", .{});
    try expect(attacks.king_attacks_from_bitboard(util.set_bit(types.empty_bitboard, types.square.d4)) == 0x1c141c0000);

    print("King attacks from b1 : 0x705\n", .{});
    try expect(attacks.king_attacks_from_bitboard(util.set_bit(types.empty_bitboard, types.square.b1)) == 0x705);

    print("King attacks from g1 : 0xE0A0\n", .{});
    try expect(attacks.king_attacks_from_bitboard(util.set_bit(types.empty_bitboard, types.square.g1)) == 0xE0A0);

    print("King attacks from a2 : 0x30203\n", .{});
    try expect(attacks.king_attacks_from_bitboard(util.set_bit(types.empty_bitboard, types.square.a2)) == 0x30203);

    print("King attacks from h8 : 0x40C0000000000000\n", .{});
    try expect(attacks.king_attacks_from_bitboard(util.set_bit(types.empty_bitboard, types.square.h8)) == 0x40C0000000000000);

    print("King attacks from e5 : 0x382838000000\n", .{});
    try expect(attacks.king_attacks_from_bitboard(util.set_bit(types.empty_bitboard, types.square.e5)) == 0x382838000000);
}

test "Knight attacks" {
    print("Knight attacks from e2 : 0x28441000\n", .{});
    try expect(attacks.knight_attacks_from_bitboard(util.set_bit(types.empty_bitboard, types.square.e2)) == 0x28440044);

    print("Knight attacks from e2 : 0x28440044\n", .{});
    try expect(attacks.knight_attacks_from_bitboard(util.set_bit(types.empty_bitboard, types.square.e2)) == 0x28440044);

    print("Knight attacks from a1 : 0x20400\n", .{});
    try expect(attacks.knight_attacks_from_bitboard(util.set_bit(types.empty_bitboard, types.square.a1)) == 0x20400);

    print("Knight attacks from h1 : 0x402000\n", .{});
    try expect(attacks.knight_attacks_from_bitboard(util.set_bit(types.empty_bitboard, types.square.h1)) == 0x402000);

    print("Knight attacks from a8 : 0x402000000000\n", .{});
    try expect(attacks.knight_attacks_from_bitboard(util.set_bit(types.empty_bitboard, types.square.a8)) == 0x4020000000000);

    print("Knight attacks from h8 : 0x20400000000000\n", .{});
    try expect(attacks.knight_attacks_from_bitboard(util.set_bit(types.empty_bitboard, types.square.h8)) == 0x20400000000000);

    print("Knight attacks from d4 : 0x142200221400\n", .{});
    try expect(attacks.knight_attacks_from_bitboard(util.set_bit(types.empty_bitboard, types.square.d4)) == 0x142200221400);
}

test "PRNG produces expected first value for seed 0x123456789ABCDEF" {
    var prng = util.PRNG.init(0x123456789ABCDEF);
    const first = prng.rand64();
    std.debug.print("First output: {d}\n", .{first});
    try expect(first == 8976943199460683916);
}

test "rook attacks table with empty occupancy" {
    attacks.init_rook_attacks();
    for (0..64) |square| {
        const sq6: u6 = @truncate(square);
        const expected = attacks.get_rook_attacks_for_init(sq6, 0);
        const table_val = attacks.rook_attacks_table[square][0];
        print("Rook attacks for square {d} with empty occ: expected=0x{X}, got=0x{X}\n", .{ square, expected, table_val });
        try std.testing.expectEqual(@as(types.Bitboard, expected), table_val);
    }
}

test "rook attacks with one blocker" {
    attacks.init_rook_attacks();
    const sq_idx: u8 = 27;
    const occ_single: u64 = (@as(u64, 1) << (3 + 5 * 8)); // blocker on d6
    const occ_masked = occ_single & tabeles.Rook_attackes_tabele[sq_idx];
    const relevantBits = tabeles.Rook_index_bit[sq_idx];
    const magic = tabeles.rook_magics[sq_idx];
    const shift8: u8 = 64 - relevantBits;
    const shift: u6 = @truncate(shift8);
    const idx = (@as(u64, occ_masked) *% magic) >> shift;
    const table_attacks = attacks.rook_attacks_table[sq_idx][@intCast(idx)];
    const expected = attacks.get_rook_attacks_for_init(@as(u6, sq_idx), occ_single);
    print("Rook attacks with blocker on square {d}: occ=0x{X}, idx={d}, table=0x{X}, expected=0x{X}\n", .{ sq_idx, occ_single, idx, table_attacks, expected });
    try std.testing.expectEqual(@as(types.Bitboard, expected), table_attacks);
}

test "bishop attacks table with empty occupancy" {
    attacks.init_bishop_attacks();
    for (0..64) |square| {
        const sq6: u6 = @truncate(square);
        const expected = attacks.get_bishop_attacks_for_init(sq6, 0);
        const table_val = attacks.bishop_attacks_table[square][0];
        print("Bishop attacks for square {d} with empty occ: expected=0x{X}, got=0x{X}\n", .{ square, expected, table_val });
        try std.testing.expectEqual(@as(types.Bitboard, expected), table_val);
    }
}

test "bishop attacks with one blocker" {
    attacks.init_bishop_attacks();
    const sq_idx: u8 = 27; // d4
    const occ_single: u64 = (@as(u64, 1) << 45); // blocker on f6
    const mask = tabeles.Bishops_attackes_tabele[sq_idx];
    const occ_masked = occ_single & mask;
    const relevantBits = tabeles.Bishop_index_bit[sq_idx];
    const magic = tabeles.bishop_magics[sq_idx];
    const shift: u6 = @truncate(64 - relevantBits);
    const idx64 = (@as(u64, occ_masked) *% magic) >> shift;
    const idx: usize = @intCast(idx64);
    const table_attacks = attacks.bishop_attacks_table[sq_idx][idx];
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
        try bitboard.parse_fen(fen, &b);
        print("\n=== Testing FEN: {s}\n", .{fen});
        print("  occupancy: expected=0x{x}, actual=0x{x}\n", .{ expected.occupancy, b.pieces_combined() });
        print("  en-passant: expected={s}, actual={s}\n", .{ expected.ep_str, if (b.enpassant == types.square.NO_SQUARE) "-" else types.SquareString.getSquareToString(b.enpassant) });
        print("  castling   : expected=0b{b:0>4}, actual=0b{b:0>4}\n\n", .{ expected.castle, b.castle });
        // The expected occupancies were written rank-8-first; @byteSwap flips rank 1 <-> rank 8.
        const flipped_occupancy: types.Bitboard = @byteSwap(b.pieces_combined());

        try std.testing.expectEqual(
            expected.occupancy,
            flipped_occupancy,
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

test "is square attacked" {
    attacks.init_attacks();

    const AttackTestVector = struct {
        fen: []const u8,
        white_attacks: u64,
        black_attacks: u64,
    };

    const test_vectors = [_]AttackTestVector{
        .{ .fen = "8/8/8/8/8/8/8/8 w - - ", .white_attacks = 0x0000000000000000, .black_attacks = 0x0000000000000000 },
        .{ .fen = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1", .white_attacks = 0x0000000000ffff7e, .black_attacks = 0x7effff0000000000 },
    };

    for (test_vectors) |vector| {
        var board = types.Board.new();
        try bitboard.parse_fen(vector.fen, &board);

        var generated_white_attacks: u64 = 0;
        var generated_black_attacks: u64 = 0;

        for (0..64) |sq_idx| {
            const sq: u6 = @intCast(sq_idx);
            if (bitboard.is_square_attacked(&board, sq, .White)) {
                generated_white_attacks |= (@as(u64, 1) << sq);
            }
            if (bitboard.is_square_attacked(&board, sq, .Black)) {
                generated_black_attacks |= (@as(u64, 1) << sq);
            }
        }

        // Use if-statements to provide more context on failure
        if (vector.white_attacks != generated_white_attacks) {
            std.debug.print("\n\nWhite attack mismatch for FEN: {s}\n", .{vector.fen});
            std.debug.print("Expected: 0x{x}\n", .{vector.white_attacks});
            bitboard.print_board(vector.white_attacks);
            std.debug.print("Got: 0x{x}\n", .{generated_white_attacks});
            bitboard.print_board(generated_white_attacks);
        }
        try std.testing.expectEqual(vector.white_attacks, generated_white_attacks);

        if (vector.black_attacks != generated_black_attacks) {
            std.debug.print("\n\nBlack attack mismatch for FEN: {s}\n", .{vector.fen});
            std.debug.print("Expected: 0x{x}\n", .{vector.black_attacks});
            bitboard.print_board(vector.black_attacks);
            std.debug.print("Got: 0x{x}\n", .{generated_black_attacks});
            bitboard.print_board(generated_black_attacks);
        }
        try std.testing.expectEqual(vector.black_attacks, generated_black_attacks);
    }
}

test "Perft Test the move generation start position" {
    attacks.init_attacks();
    const depth: u8 = 5;

    var b = types.Board.new();
    try bitboard.parse_fen(types.start_position, &b);

    const stats = if (b.side == types.Color.White)
        util.Perft.run(types.Color.White, &b, depth, true)
    else
        util.Perft.run(types.Color.Black, &b, depth, true);

    try std.testing.expectEqual(stats.nodes, 4865609);
    try std.testing.expectEqual(stats.captures, 82719);
    try std.testing.expectEqual(stats.promotions, 0);
    try std.testing.expectEqual(stats.checks, 27351);
    try std.testing.expectEqual(stats.en_passant, 258);
    try std.testing.expectEqual(stats.castles, 0);
    try std.testing.expectEqual(stats.double_checks, 0);
    try std.testing.expectEqual(stats.checkmates, 347);
    print("\n=== Testing FEN: {s}\n", .{types.start_position});
    print("Perft test for the start position done\n", .{});
}

test "Perft Test the move generation tricky position" {
    attacks.init_attacks();
    const depth: u8 = 4;

    var b = types.Board.new();
    try bitboard.parse_fen(types.tricky_position, &b);

    const stats = if (b.side == types.Color.White)
        util.Perft.run(types.Color.White, &b, depth, true)
    else
        util.Perft.run(types.Color.Black, &b, depth, true);

    try std.testing.expectEqual(stats.nodes, 4085603);
    try std.testing.expectEqual(stats.captures, 757163);
    try std.testing.expectEqual(stats.promotions, 15172);
    try std.testing.expectEqual(stats.checks, 25523);
    try std.testing.expectEqual(stats.en_passant, 1929);
    try std.testing.expectEqual(stats.castles, 128013);
    try std.testing.expectEqual(stats.double_checks, 6);
    try std.testing.expectEqual(stats.checkmates, 43);

    print("\n=== Testing FEN: {s}\n", .{types.tricky_position});
    print("Perft test for the tricky position done\n", .{});
}

test "test phase calculation" {
    attacks.init_attacks();

    print("\n--- Test 1: Starting Position ---\n", .{});
    var board = types.Board.new();
    try bitboard.parse_fen(types.start_position, &board);
    print("FEN: {s}\n", .{types.start_position});
    print("Expected: White=16, Black=16 (P=0, N=1, B=1, R=3, Q=6, K=0 → 0+2+2+6+6+0=16 per side)\n", .{});
    try std.testing.expectEqual(eval.global_evaluator.phase[0], 16);
    try std.testing.expectEqual(eval.global_evaluator.phase[1], 16);

    print("\n--- Test 2: Empty Board ---\n", .{});
    try bitboard.parse_fen(types.empty_board, &board);
    print("FEN: {s}\n", .{types.empty_board});
    print("Expected: White=0, Black=0 (no pieces)\n", .{});
    try std.testing.expectEqual(eval.global_evaluator.phase[0], 0);
    try std.testing.expectEqual(eval.global_evaluator.phase[1], 0);

    print("\n--- Test 3: King vs King ---\n", .{});
    try bitboard.parse_fen("8/8/8/8/8/8/8/K6k w - - 0 1", &board);
    print("FEN: 8/8/8/8/8/8/8/K6k w - - 0 1\n", .{});
    print("Expected: White=0, Black=0 (only kings, K=0 phase)\n", .{});
    try std.testing.expectEqual(eval.global_evaluator.phase[0], 0);
    try std.testing.expectEqual(eval.global_evaluator.phase[1], 0);

    print("\n--- Test 4: Queen Endgame ---\n", .{});
    try bitboard.parse_fen("8/8/8/8/8/8/8/KQ5k w - - 0 1", &board);
    print("FEN: 8/8/8/8/8/8/8/KQ5k w - - 0 1\n", .{});
    print("Expected: White=6, Black=0 (white queen=6 phase)\n", .{});
    try std.testing.expectEqual(eval.global_evaluator.phase[0], 6); // white
    try std.testing.expectEqual(eval.global_evaluator.phase[1], 0); // black

    print("\n--- Test 5: Complex Middlegame ---\n", .{});
    try bitboard.parse_fen(types.tricky_position, &board);
    print("FEN: {s}\n", .{types.tricky_position});
    print("Expected: Count all pieces - complex position\n", .{});
    try std.testing.expectEqual(eval.global_evaluator.phase[0], 16);
    try std.testing.expectEqual(eval.global_evaluator.phase[1], 16);

    print("\n--- Test 7: Move Making and Phase Updates ---\n", .{});
    try bitboard.parse_fen(types.start_position, &board);
    print("Starting position phases: White={}, Black={}\n", .{ eval.global_evaluator.phase[0], eval.global_evaluator.phase[1] });

    var move_list: lists.MoveList = .{};

    try bitboard.parse_fen("rnbqkb1r/pppp1ppp/5n2/4p1B1/4P3/8/PPPP1PPP/RNBQK1NR w KQkq e6 0 2", &board);
    print("\nAfter 1.e4 e5 - phases: White={}, Black={}\n", .{ eval.global_evaluator.phase[0], eval.global_evaluator.phase[1] });

    movegen.generate_legal_moves(&board, &move_list, types.Color.White);

    var capture_made = false;
    for (0..move_list.count) |i| {
        const move = move_list.moves[i];
        if (move.is_capture()) {
            print("Making capture move: {s}{s}\n", .{ types.SquareString.getSquareToString(@enumFromInt(move.from)), types.SquareString.getSquareToString(@enumFromInt(move.to)) });
            const old_phase_w = eval.global_evaluator.phase[0];
            const old_phase_b = eval.global_evaluator.phase[1];

            _ = move_gen.make_move_search_rt(&board, move);
            print("Phases before capture: White={}, Black={}\n", .{ old_phase_w, old_phase_b });
            print("Phases after capture:  White={}, Black={}\n", .{ eval.global_evaluator.phase[0], eval.global_evaluator.phase[1] });
            capture_made = true;
            try std.testing.expectEqual(eval.global_evaluator.phase[0], 16);
            try std.testing.expectEqual(eval.global_evaluator.phase[1], 15);
            break;
        }
    }

    if (!capture_made) {
        print("No captures available in this position\n", .{});
    }

    print("\n--- Test 8: Promotion Test ---\n", .{});
    try bitboard.parse_fen("8/P7/8/8/8/8/8/K6k w - - 0 1", &board);
    print("Pawn promotion setup - phases: White={}, Black={}\n", .{ eval.global_evaluator.phase[0], eval.global_evaluator.phase[1] });

    move_list = .{};
    movegen.generate_legal_moves(&board, &move_list, types.Color.White);

    // Find and make a promotion
    for (0..move_list.count) |i| {
        const move = move_list.moves[i];
        if (move.is_promotion() and move.flags == types.MoveFlags.PR_QUEEN) {
            print("Making promotion to queen: {s}{s}\n", .{ types.SquareString.getSquareToString(@enumFromInt(move.from)), types.SquareString.getSquareToString(@enumFromInt(move.to)) });
            const old_phase_w = eval.global_evaluator.phase[0];
            const old_phase_b = eval.global_evaluator.phase[1];

            _ = move_gen.make_move_search_rt(&board, move);
            print("Phases before promotion: White={}, Black={}\n", .{ old_phase_w, old_phase_b });
            print("Phases after promotion:  White={}, Black={}\n", .{ eval.global_evaluator.phase[0], eval.global_evaluator.phase[1] });
            print("Expected change: -0 (pawn) +6 (queen) = +6 for white\n", .{});
            try std.testing.expectEqual(eval.global_evaluator.phase[0], 6);
            try std.testing.expectEqual(eval.global_evaluator.phase[1], 0);
            break;
        }
    }
}

test "TT entry is 16 bytes and a cluster is one 64-byte cache line" {
    // One probe must touch one cache line: 4 entries of 16 bytes.
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(tt.TTEntry));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(tt.Cluster));
    try std.testing.expectEqual(@as(usize, 4), tt.CLUSTER_SIZE);
}

test "TT hashfull stays within 0..1000 per mille" {
    // Regression: @min(len, 1000) narrowed to u10 and sample * CLUSTER_SIZE overflowed.
    var table = try tt.TT.init(std.testing.allocator, 1);
    defer table.deinit();
    try std.testing.expectEqual(@as(u32, 0), table.hashfull());
    table.new_search();
    var prng = std.Random.DefaultPrng.init(7);
    const r = prng.random();
    for (0..50_000) |_| table.store(r.int(u64), 1, 0, .EXACT, move_gen.Move.empty(), 0, false);
    const hf = table.hashfull();
    try expect(hf > 0);
    try expect(hf <= 1000);
    // Another search generation: nothing from the old one counts as "in use".
    table.new_search();
    try std.testing.expectEqual(@as(u32, 0), table.hashfull());
}

test "Zobrist keys are nonzero and pairwise distinct" {
    // A zero key hides a piece from the hash, a duplicate makes positions collide.
    var seen = std.AutoHashMap(u64, void).init(std.testing.allocator);
    defer seen.deinit();
    var count: usize = 0;
    const add = struct {
        fn f(set: *std.AutoHashMap(u64, void), n: *usize, key: u64) !void {
            try expect(key != 0);
            try expect(!set.contains(key));
            try set.put(key, {});
            n.* += 1;
        }
    }.f;
    for (zobrist.piece_keys, 0..) |row, slot| {
        if (slot == 6 or slot == 7 or slot == @intFromEnum(types.Piece.NO_PIECE)) continue; // padding rows
        for (row) |k| try add(&seen, &count, k);
    }
    try add(&seen, &count, zobrist.side_key);
    for ([_]u8{ 1, 2, 4, 8 }) |bit| try add(&seen, &count, zobrist.castle_hash[bit]); // single-right masks = raw keys
    for (zobrist.ep_keys) |k| try add(&seen, &count, k);
    try std.testing.expectEqual(@as(usize, 12 * 64 + 1 + 4 + 8), count);
}

test "Zobrist hash consistency after moves" {
    attacks.init_attacks();

    const test_fens = [_][]const u8{
        types.start_position,
        types.tricky_position,
        "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "rnbqkb1r/pp1p1pPp/8/2p1pP2/1P1P4/3P3P/P1P1P3/RNBQKBNR w KQkq e6 0 1",
    };

    for (test_fens) |fen| {
        var board = types.Board.new();
        try bitboard.parse_fen(fen, &board);

        // Verify initial hash matches full computation
        const initial_hash = zobrist.compute_hash(&board);
        try std.testing.expectEqual(initial_hash, board.hash);

        // Generate all legal moves and verify hash after each
        var move_list: lists.MoveList = .{};
        if (board.side == types.Color.White) {
            movegen.generate_legal_moves(&board, &move_list, types.Color.White);
        } else {
            movegen.generate_legal_moves(&board, &move_list, types.Color.Black);
        }

        for (0..move_list.count) |i| {
            const move = move_list.moves[i];

            const undo = move_gen.make_move_search_rt(&board, move);
            const expected_hash = zobrist.compute_hash(&board);
            if (board.hash != expected_hash) {
                const from_str = types.SquareString.getSquareToString(@enumFromInt(move.from));
                const to_str = types.SquareString.getSquareToString(@enumFromInt(move.to));
                print("Hash mismatch after move {s}{s} (flags={}) in FEN: {s}\n", .{
                    from_str, to_str, @intFromEnum(move.flags), fen,
                });
                print("  Incremental: 0x{x}\n  Recomputed:  0x{x}\n", .{ board.hash, expected_hash });
            }
            try std.testing.expectEqual(expected_hash, board.hash);

            move_gen.unmake_move_search_rt(&board, move, undo);
            try std.testing.expectEqual(initial_hash, board.hash);
        }
    }
}

fn run_perft_legal_bench(fen: []const u8, name: []const u8, depth: u8, expected: u64) !void {
    var board = types.Board.new();
    const m = try bench.measure_movegen(&board, fen, depth);
    print("{s}: {d} nodes, {d}ms, {d:.2} MNodes/s\n", .{ name, m.nodes, m.ns / std.time.ns_per_ms, m.mps() });
    try std.testing.expectEqual(expected, m.nodes);
}

test "Legal perft startpos d5" {
    attacks.init_attacks();
    print("\n=== LEGAL PERFT BENCHMARK ===\n", .{});
    try run_perft_legal_bench(types.start_position, "legal startpos d5", 5, 4865609);
}

test "Legal perft kiwipete d4" {
    attacks.init_attacks();
    try run_perft_legal_bench(types.tricky_position, "legal kiwipete d4", 4, 4085603);
}

test "Legal perft edwards d4" {
    attacks.init_attacks();
    try run_perft_legal_bench("r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/P1NP1N2/1PP1QPPP/R4RK1 w - - 0 10", "legal edwards d4", 4, 3894594);
}

test "Legal perft ep_tricky d5" {
    attacks.init_attacks();
    try run_perft_legal_bench("8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1", "legal ep_tricky d5", 5, 674624);
}

test "Legal perft promo d5" {
    attacks.init_attacks();
    try run_perft_legal_bench(types.killer_position, "legal promo d5", 5, 36112837);
}

fn bench_eval_one(fen: []const u8, name: []const u8, iters: u64) !void {
    var board = types.Board.new();
    const m = try bench.measure_eval(&board, fen, iters);
    print("{s:<14}: {d:>10.2} M eval/s\n", .{ name, m.mps() });
}

test "Eval speed benchmark" {
    attacks.init_attacks();
    search.init_search();
    print("\n=== EVAL SPEED BENCHMARK (M klicev/s) ===\n", .{});
    for (types.standard_perft_positions, types.standard_perft_names) |fen, name| {
        try bench_eval_one(fen, name, 20_000_000);
    }
}

test "MoveGen speed benchmark" {
    attacks.init_attacks();
    print("\n=== MOVEGEN SPEED BENCHMARK (perft d6, MNodes/s) ===\n", .{});
    for (types.standard_perft_positions, types.standard_perft_names) |fen, name| {
        var board = types.Board.new();
        const m = try bench.measure_movegen(&board, fen, 6);
        print("{s:<14}: {d:>12} nodes, {d:>8.2} MNodes/s\n", .{ name, m.nodes, m.mps() });
    }
}

test "test evaluation end games" {
    attacks.init_attacks();

    print("\n=== TESTING EVALUATION FUNCTION ===\n", .{});
    const EndgameTest = struct {
        fen: []const u8,
        description: []const u8,
        expected_result: []const u8,
        expected_range: [2]i32,
    };

    const tests = [_]EndgameTest{
        .{ .fen = "8/8/8/8/8/8/8/K6k w - - 0 1", .description = "King vs King", .expected_result = "Draw", .expected_range = .{ -10, 10 } },
        .{ .fen = "8/8/8/8/8/8/8/KB5k w - - 0 1", .description = "Bishop vs King", .expected_result = "Draw", .expected_range = .{ -50, 50 } },
        .{ .fen = "8/8/8/8/8/8/8/KN5k w - - 0 1", .description = "Knight vs King", .expected_result = "Draw", .expected_range = .{ -50, 50 } },
        .{ .fen = "8/8/8/8/8/8/Q7/K6k w - - 0 1", .description = "Queen vs King", .expected_result = "White wins", .expected_range = .{ 800, 1200 } },
        .{ .fen = "8/8/8/8/8/8/R7/K6k w - - 0 1", .description = "Rook vs King", .expected_result = "White wins", .expected_range = .{ 400, 600 } },
        .{ .fen = "8/8/8/8/8/8/8/KBN4k w - - 0 1", .description = "Bishop + Knight vs King", .expected_result = "White wins (difficult)", .expected_range = .{ 300, 700 } },
        .{ .fen = "8/8/8/8/8/8/8/KRR4k w - - 0 1", .description = "Two Rooks vs King", .expected_result = "White wins easily", .expected_range = .{ 900, 1200 } },
        // Lone rook pawn with the defending king outside the square: HCE scores it low (~83cp), so the floor is 50.
        .{ .fen = "8/8/8/8/8/8/P7/K6k w - - 0 1", .description = "King + Pawn vs King", .expected_result = "Usually wins", .expected_range = .{ 50, 300 } },
    };

    for (tests, 0..) |test_case, i| {
        var board = types.Board.new();
        try bitboard.parse_fen(test_case.fen, &board);

        const evaluation = eval.global_evaluator.eval_full(&board, types.Color.White);
        const min_expected = test_case.expected_range[0];
        const max_expected = test_case.expected_range[1];

        print("Test {}: {s} ({s}) → {d} centipawns\n", .{
            i + 1,
            test_case.description,
            test_case.expected_result,
            evaluation,
        });

        if (!(evaluation >= min_expected and evaluation <= max_expected)) {
            try std.testing.expectFmt("error", "expected value in range {}–{}, but got {}\n", .{ min_expected, max_expected, evaluation });
        }
    }
}

test "nnue feature_index matches bullet Chess768 encoding (mirror=false)" {
    // White pawn (ord 0) on a1 (sq 0): friendly, no flip, bucket 0 -> 0
    try std.testing.expectEqual(@as(usize, 0), nnue.feature_index(true, 0, 0, false, 0));
    // ...from black's perspective: enemy + rank-flip -> 384 + 0 + (0^56)
    try std.testing.expectEqual(@as(usize, 440), nnue.feature_index(false, 0, 0, false, 0));
    // White king (ord 5) on e1 (sq 4), white perspective -> 5*64 + 4
    try std.testing.expectEqual(@as(usize, 324), nnue.feature_index(true, 5, 4, false, 0));
    // Black king (ord 13) on h8 (sq 63), white perspective -> 384 + 5*64 + 63
    try std.testing.expectEqual(@as(usize, 767), nnue.feature_index(true, 13, 63, false, 0));
    // ...black perspective -> 0 + 5*64 + (63^56)
    try std.testing.expectEqual(@as(usize, 327), nnue.feature_index(false, 13, 63, false, 0));
    // mirror=true flips the file: white pawn a1 -> file h -> 0^7 = 7
    try std.testing.expectEqual(@as(usize, 7), nnue.feature_index(true, 0, 0, true, 0));
    // bucket offset: bucket 2 adds 768*2 = 1536
    try std.testing.expectEqual(@as(usize, 1536), nnue.feature_index(true, 0, 0, false, 2));
}

test "nnue evaluate is mirror-symmetric (encoding + eval are correct)" {
    const buf = try std.testing.allocator.alloc(u8, nnue.NET_BYTES);
    defer std.testing.allocator.free(buf);
    // deterministic little-endian i16 weights in [-8, 7] so eval cannot overflow
    var i: usize = 0;
    while (i + 1 < buf.len) : (i += 2) {
        const v: i16 = @as(i16, @intCast((i / 2) % 16)) - 8;
        std.mem.writeInt(i16, buf[i..][0..2], v, .little);
    }
    try nnue.load_bytes(buf);

    // p: WK e1, BK e8, WQ d1, BN b8, WP e2 with white to move
    // m: p mirrored vertically (sq ^ 56) with colours swapped (piece ^ 8) and black to move
    const pieces = [_][2]u8{ .{ 5, 4 }, .{ 13, 60 }, .{ 4, 3 }, .{ 9, 57 }, .{ 0, 12 } };
    var p = types.Board.new();
    var m = types.Board.new();
    for (pieces) |e| {
        const pc: usize = e[0];
        const sq: u6 = @intCast(e[1]);
        p.pieces[pc] |= @as(u64, 1) << sq;
        p.board[sq] = @enumFromInt(pc);
        m.pieces[pc ^ 8] |= @as(u64, 1) << (sq ^ 56);
        m.board[sq ^ 56] = @enumFromInt(pc ^ 8);
    }
    p.side = .White;
    m.side = .Black;

    // Same stm-relative score for any weights iff the perspective encoding is right.
    try std.testing.expectEqual(nnue.evaluate(&p), nnue.evaluate(&m));
}

// Every output bucket and side to move must score the same with the SIMD small head on and off.
fn expect_small_heads_agree(acc: *const nnue.AccumulatorS) !void {
    for ([_]types.Color{ .White, .Black }) |stm| {
        for (0..nnue.OUTPUT_BUCKETS) |b| {
            nnue.small_head_simd = true;
            const simd = nnue.evaluate_acc_s(acc, stm, b);
            nnue.small_head_simd = false;
            try std.testing.expectEqual(nnue.evaluate_acc_s(acc, stm, b), simd);
        }
    }
}

// The routed eval (small net forced by the caller) plus all heads of the board's small accumulator.
fn expect_small_heads_agree_board(board: *const types.Board) !void {
    nnue.small_head_simd = true;
    const simd = nnue.evaluate(board);
    nnue.small_head_simd = false;
    try std.testing.expectEqual(nnue.evaluate(board), simd);
    var acc: nnue.AccumulatorS = undefined;
    acc.refresh(board);
    try expect_small_heads_agree(&acc);
}

test "nnue small-net SIMD head matches the scalar head" {
    attacks.init_attacks();
    try nnue.load_embedded();
    // the shipped small net must pass the load-time |w| <= 128 check, else the SIMD head never runs
    try expect(nnue.small_head_simd);
    const saved_simd = nnue.small_head_simd;
    const saved_guard = nnue.small_guard;
    const saved_want = nnue.want_small;
    defer {
        nnue.small_head_simd = saved_simd;
        nnue.small_guard = saved_guard;
        nnue.want_small = saved_want;
    }
    // force the small net: no big-net re-eval in the guard band
    nnue.want_small = true;
    nnue.small_guard = 0;

    // a saturated accumulator gives the largest head sums
    var sat: nnue.AccumulatorS = .{};
    for (&sat.vals) |*v| @memset(v, std.math.maxInt(i16));
    try expect_small_heads_agree(&sat);

    // the bench positions and all their legal children
    for (bench.positions) |fen| {
        var board = types.Board.new();
        try bitboard.parse_fen(fen, &board);
        try expect_small_heads_agree_board(&board);
        var moves: lists.MoveList = .{};
        if (board.side == types.Color.White) {
            movegen.generate_legal_moves(&board, &moves, types.Color.White);
        } else {
            movegen.generate_legal_moves(&board, &moves, types.Color.Black);
        }
        for (moves.moves[0..moves.count]) |move| {
            const undo = move_gen.make_move_search_rt(&board, move);
            try expect_small_heads_agree_board(&board);
            move_gen.unmake_move_search_rt(&board, move, undo);
        }
    }
}

test "board_to_fen round-trips through parse_fen" {
    // Parse, serialize and re-parse; the board state must be identical.
    const fens = [_][]const u8{
        types.start_position,
        types.tricky_position,
        types.killer_position,
        "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
        "rnbqkb1r/pp1p1pPp/8/2p1pP2/1P1P4/3P3P/P1P1P3/RNBQKBNR w KQkq e6 0 1",
        "r2q1rk1/ppp2ppp/2n1bn2/2b1p3/3pP3/3P1NPP/PPP1NPB1/R1BQ1RK1 b - - 0 9",
        "8/8/8/2k5/2pP4/8/B7/4K3 b - d3 0 3",
        "4k3/8/8/8/8/8/8/4K3 w - - 13 47",
    };

    var buf: [128]u8 = undefined;
    for (fens) |fen| {
        var b1 = types.Board.new();
        try bitboard.parse_fen(fen, &b1);

        // fullmove is not stored on the board, so it cannot affect round-trip state.
        const out = bitboard.board_to_fen(&b1, 1, buf[0..]);

        var b2 = types.Board.new();
        try bitboard.parse_fen(out, &b2);

        if (b1.hash != b2.hash) {
            print("round-trip mismatch: {s}\n  -> {s}\n", .{ fen, out });
        }
        try std.testing.expectEqual(b1.side, b2.side);
        try std.testing.expectEqual(b1.castle, b2.castle);
        try std.testing.expectEqual(b1.enpassant, b2.enpassant);
        try std.testing.expectEqual(b1.halfmove, b2.halfmove);
        try std.testing.expectEqual(b1.hash, b2.hash);
        for (b1.pieces, b2.pieces) |p1, p2| {
            try std.testing.expectEqual(p1, p2);
        }
    }
}

test "board_to_fen exact start-position string" {
    var board = types.Board.new();
    try bitboard.parse_fen(types.start_position, &board);

    var buf: [128]u8 = undefined;
    const fen = bitboard.board_to_fen(&board, 1, buf[0..]);
    try std.testing.expectEqualStrings(
        "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        fen,
    );
}

test "bench is deterministic and nonzero" {
    attacks.init_attacks();
    search.init_search();
    try tt.init_global(std.heap.page_allocator, 8);
    try nnue.load_embedded();
    nnue.use_nnue = true;

    var board = types.Board.new();
    const first = bench.run_nodes(&board, 5, 3);
    const second = bench.run_nodes(&board, 5, 3);
    try expect(first > 0);
    try expect(first == second);
}
