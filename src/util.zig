const std = @import("std");
const types = @import("types.zig");
const lists = @import("lists.zig");
const move_gen = @import("move_generation.zig");
const attacks = @import("attacks.zig");
const Bitboard = @import("bitboard.zig");

const print = std.debug.print;
pub inline fn set_bit(bitboard: u64, s: types.square) u64 {
    return (bitboard | (@as(u64, 1) << @intCast(@intFromEnum(s))));
}

pub inline fn get_bit(bitboard: u64, square: usize) bool {
    return (bitboard & @as(u64, 1) << @intCast(square)) != 0;
}

pub inline fn clear_bit(bitboard: u64, s: types.square) u64 {
    return (bitboard & ~(@as(u64, 1) << @intCast(@intFromEnum(s))));
}

// bit counting routine
/// Fastest population count, using hardware acceleration if available
pub inline fn popcount(n: u64) u7 {
    return @popCount(n);
}

// get the last bit
pub inline fn lsb_index(n: u64) u7 {
    return @ctz(n);
}

// Pseudorandom number generator https://en.wikipedia.org/wiki/Xorshift#xoroshiro
pub const PRNG = struct {
    seed: u64,

    pub fn init(seed: u64) PRNG {
        return PRNG{ .seed = seed };
    }

    pub fn rand64(self: *PRNG) u64 {
        var x = self.seed;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.seed = x;
        return x *% 0x2545F4914F6CDD1D;
    }
};

// flip bitboard vertically (rank 1 <-> rank 8)
pub fn flip_bitboard_vertically(bb: u64) u64 {
    return @byteSwap(bb);
}

// performance test (PERFT)
pub inline fn perft(comptime color: types.Color, board: *types.Board, depth: u8) u64 {
    // Exit condition
    if (depth == 0) return 1;

    var nodes: u64 = 0;

    const oponent_side = if (color == types.Color.White) types.Color.Black else types.Color.White;

    // Generate all moves

    var move_list: lists.MoveList = .{};
    move_gen.generate_moves(board, &move_list, color);

    for (0..move_list.count) |i| {
        const move = move_list.moves[i];

        // Make the move
        const original_state = board.save_state();
        if (move_gen.make_move(board, move)) {
            const result = perft(oponent_side, board, depth - 1);
            board.restore_state(original_state);
            nodes += result;
        }
    }

    return nodes;
}

pub inline fn perft_test(board: *types.Board, depth: u8) void {
    print("Running perft test with depth {d}\n", .{depth});

    var timer = std.time.Timer.start() catch unreachable;
    var nodes: usize = 0;

    if (board.side == types.Color.White) {
        nodes = perft(types.Color.White, board, depth);
    } else {
        nodes = perft(types.Color.Black, board, depth);
    }

    const elapsed = timer.read();
    print("Perft test took {d} ms\n", .{elapsed / std.time.ns_per_ms});
    print("Nodes: {d}\n", .{nodes});
}

pub fn perft_div(comptime color: types.Color, board: *types.Board, depth: u8) void {
    var nodes: usize = 0;
    var branch: usize = 0;

    var move_list: lists.MoveList = .{};
    move_gen.generate_moves(board, &move_list, color);

    for (0..move_list.count) |i| {
        const move = move_list.moves[i];

        // Make the move
        const original_state = board.save_state();
        if (move_gen.make_move(board, move)) {
            if (branch == 0) {
                nodes += perft(color, board, depth - 1);
            } else {
                nodes += perft(color, board, depth);
            }
            board.restore_state(original_state);
        }

        branch += 1;
    }
    print("Nodes: {d}\n", .{nodes});
    print("Branches: {d}\n", .{branch});
}

pub const PerftStats = struct {
    nodes: u64,
    captures: u64,
    en_passant: u64,
    castles: u64,
    promotions: u64,
    checks: u64,
    discovery_checks: u64,
    double_checks: u64,
    checkmates: u64,

    pub fn init() PerftStats {
        return PerftStats{
            .nodes = 0,
            .captures = 0,
            .en_passant = 0,
            .castles = 0,
            .promotions = 0,
            .checks = 0,
            .discovery_checks = 0,
            .double_checks = 0,
            .checkmates = 0,
        };
    }

    pub fn add(self: *PerftStats, other: PerftStats) void {
        self.nodes += other.nodes;
        self.captures += other.captures;
        self.en_passant += other.en_passant;
        self.castles += other.castles;
        self.promotions += other.promotions;
        self.checks += other.checks;
        self.discovery_checks += other.discovery_checks;
        self.double_checks += other.double_checks;
        self.checkmates += other.checkmates;
    }

    pub fn display(self: PerftStats, depth: u8) void {
        print("\n=== Perft Results (Depth {d}) ===\n", .{depth});
        print("Nodes:           {d:>12}\n", .{self.nodes});
        print("Captures:        {d:>12}\n", .{self.captures});
        print("En passant:      {d:>12}\n", .{self.en_passant});
        print("Castles:         {d:>12}\n", .{self.castles});
        print("Promotions:      {d:>12}\n", .{self.promotions});
        print("Checks:          {d:>12}\n", .{self.checks});
        print("Discovery+:      {d:>12}\n", .{self.discovery_checks});
        print("Double checks:   {d:>12}\n", .{self.double_checks});
        print("Checkmates:      {d:>12}\n", .{self.checkmates});
        print("==============================\n", .{});
    }
};

inline fn is_capture_move_perft(flags: types.MoveFlags) bool {
    return switch (flags) {
        types.MoveFlags.CAPTURE, types.MoveFlags.EN_PASSANT, types.MoveFlags.PC_QUEEN, types.MoveFlags.PC_ROOK, types.MoveFlags.PC_BISHOP, types.MoveFlags.PC_KNIGHT => true,
        else => false,
    };
}

inline fn is_promotion_move_perft(flags: types.MoveFlags) bool {
    return switch (flags) {
        types.MoveFlags.PR_QUEEN, types.MoveFlags.PR_ROOK, types.MoveFlags.PR_BISHOP, types.MoveFlags.PR_KNIGHT, types.MoveFlags.PC_QUEEN, types.MoveFlags.PC_ROOK, types.MoveFlags.PC_BISHOP, types.MoveFlags.PC_KNIGHT => true,
        else => false,
    };
}

inline fn is_castling_move_perft(flags: types.MoveFlags) bool {
    return flags == types.MoveFlags.OO or flags == types.MoveFlags.OOO;
}

fn count_attackers_to_square(board: *types.Board, square: u6, by_side: types.Color) u8 {
    var count: u8 = 0;
    const occ = board.pieces_combined();
    const bbs = board.pieces;

    // Check pawns
    if ((attacks.pawn_attacks_from_square(square, if (by_side == types.Color.White) types.Color.Black else types.Color.White) &
        bbs[if (by_side == types.Color.White) @intFromEnum(types.Piece.WHITE_PAWN) else @intFromEnum(types.Piece.BLACK_PAWN)]) != 0)
    {
        count += popcount(attacks.pawn_attacks_from_square(square, if (by_side == types.Color.White) types.Color.Black else types.Color.White) &
            bbs[if (by_side == types.Color.White) @intFromEnum(types.Piece.WHITE_PAWN) else @intFromEnum(types.Piece.BLACK_PAWN)]);
    }

    // Check knights
    const knight_attacks = attacks.piece_attacks(square, occ, types.PieceType.Knight);
    if ((knight_attacks & bbs[if (by_side == types.Color.White) @intFromEnum(types.Piece.WHITE_KNIGHT) else @intFromEnum(types.Piece.BLACK_KNIGHT)]) != 0) {
        count += popcount(knight_attacks & bbs[if (by_side == types.Color.White) @intFromEnum(types.Piece.WHITE_KNIGHT) else @intFromEnum(types.Piece.BLACK_KNIGHT)]);
    }

    // Check bishops and queens (diagonal)
    const bishop_attacks_bb = attacks.piece_attacks(square, occ, types.PieceType.Bishop);
    const diag_pieces = if (by_side == types.Color.White)
        (bbs[@intFromEnum(types.Piece.WHITE_BISHOP)] | bbs[@intFromEnum(types.Piece.WHITE_QUEEN)])
    else
        (bbs[@intFromEnum(types.Piece.BLACK_BISHOP)] | bbs[@intFromEnum(types.Piece.BLACK_QUEEN)]);

    if ((bishop_attacks_bb & diag_pieces) != 0) {
        count += popcount(bishop_attacks_bb & diag_pieces);
    }

    // Check rooks and queens (orthogonal)
    const rook_attacks_bb = attacks.piece_attacks(square, occ, types.PieceType.Rook);
    const ortho_pieces = if (by_side == types.Color.White)
        (bbs[@intFromEnum(types.Piece.WHITE_ROOK)] | bbs[@intFromEnum(types.Piece.WHITE_QUEEN)])
    else
        (bbs[@intFromEnum(types.Piece.BLACK_ROOK)] | bbs[@intFromEnum(types.Piece.BLACK_QUEEN)]);

    if ((rook_attacks_bb & ortho_pieces) != 0) {
        count += popcount(rook_attacks_bb & ortho_pieces);
    }

    // Check king
    if ((attacks.piece_attacks(square, occ, types.PieceType.King) &
        bbs[if (by_side == types.Color.White) @intFromEnum(types.Piece.WHITE_KING) else @intFromEnum(types.Piece.BLACK_KING)]) != 0)
    {
        count += 1;
    }

    return count;
}
pub fn perft_detailed(comptime color: types.Color, board: *types.Board, depth: u8) PerftStats {
    var stats = PerftStats.init();

    if (depth == 0) {
        stats.nodes = 1;
        return stats;
    }

    const opponent_side = if (color == types.Color.White) types.Color.Black else types.Color.White;
    var move_list: lists.MoveList = .{};
    move_gen.generate_moves(board, &move_list, color);

    if (depth == 1) {
        // At depth 1, we just count the moves and their properties
        for (0..move_list.count) |i| {
            const move = move_list.moves[i];
            const original_state = board.save_state();

            if (move_gen.make_move(board, move)) {
                stats.nodes += 1;

                // Count move types
                if (is_capture_move_perft(move.flags)) {
                    stats.captures += 1;
                }
                if (move.flags == types.MoveFlags.EN_PASSANT) {
                    stats.en_passant += 1;
                }
                if (is_castling_move_perft(move.flags)) {
                    stats.castles += 1;
                }
                if (is_promotion_move_perft(move.flags)) {
                    stats.promotions += 1;
                }

                // Check for checks
                const opponent_king_piece = if (opponent_side == types.Color.White) types.Piece.WHITE_KING else types.Piece.BLACK_KING;
                const opponent_king_square: u6 = @intCast(lsb_index(board.pieces[@intFromEnum(opponent_king_piece)]));

                if (Bitboard.is_square_attacked(board, opponent_king_square, color)) {
                    stats.checks += 1;

                    // Count the number of attackers to determine if it's a double check
                    const attacker_count = count_attackers_to_square(board, opponent_king_square, color);
                    if (attacker_count >= 2) {
                        stats.double_checks += 1;
                    }

                    // Check for checkmate
                    var opponent_moves: lists.MoveList = .{};
                    move_gen.generate_moves(board, &opponent_moves, opponent_side);

                    var has_legal_move = false;
                    for (0..opponent_moves.count) |j| {
                        const opponent_move = opponent_moves.moves[j];
                        const opponent_state = board.save_state();
                        if (move_gen.make_move(board, opponent_move)) {
                            has_legal_move = true;
                            board.restore_state(opponent_state);
                            break;
                        }
                        board.restore_state(opponent_state);
                    }

                    if (!has_legal_move) {
                        stats.checkmates += 1;
                    }
                }

                board.restore_state(original_state);
            }
        }
    } else {
        // Recursive case
        for (0..move_list.count) |i| {
            const move = move_list.moves[i];
            const original_state = board.save_state();

            if (move_gen.make_move(board, move)) {
                const sub_stats = perft_detailed(opponent_side, board, depth - 1);
                stats.add(sub_stats);

                board.restore_state(original_state);
            }
        }
    }

    return stats;
}

pub fn perft_test_detailed(board: *types.Board, depth: u8) void {
    print("\n=== Starting Detailed Perft Test ===\n", .{});
    Bitboard.print_unicode_board(board.*);
    print("Depth: {d}\n", .{depth});
    print("Side to move: {s}\n", .{if (board.side == types.Color.White) "White" else "Black"});

    var timer = std.time.Timer.start() catch unreachable;

    const stats = if (board.side == types.Color.White)
        perft_detailed(types.Color.White, board, depth)
    else
        perft_detailed(types.Color.Black, board, depth);

    const elapsed = timer.read();

    stats.display(depth);

    const elapsed_ms = @as(f64, @floatFromInt(elapsed)) / @as(f64, std.time.ns_per_ms);
    const elapsed_s = elapsed_ms / 1000.0;
    print("Time elapsed: {d:.2} ms ({d:.6} seconds)\n", .{ elapsed_ms, elapsed_s });

    if (elapsed_s > 0) {
        const nps = @as(f64, @floatFromInt(stats.nodes)) / elapsed_s;
        print("Nodes per second: {d:.0}\n", .{nps});
    }
}

pub fn perft_divide_detailed(board: *types.Board, depth: u8) void {
    print("\n=== Perft Divide (Depth {d}) ===\n", .{depth});

    const color = board.side;

    const opponent_side = if (color == types.Color.White) types.Color.Black else types.Color.White;

    var move_list: lists.MoveList = .{};

    switch (color) {
        types.Color.White => move_gen.generate_moves(board, &move_list, types.Color.White),
        types.Color.Black => move_gen.generate_moves(board, &move_list, types.Color.Black),
        else => {},
    }
    var total_nodes: u64 = 0;

    for (0..move_list.count) |i| {
        const move = move_list.moves[i];
        const original_state = board.save_state();

        if (move_gen.make_move(board, move)) {
            const nodes = if (depth > 1)
                perft_detailed(opponent_side, board, depth - 1).nodes
            else
                1;

            total_nodes += nodes;

            // Print move in algebraic notation
            const from_str = types.SquareString.getSquareToString(@enumFromInt(move.from));
            const to_str = types.SquareString.getSquareToString(@enumFromInt(move.to));
            print("{s}{s}: {d}\n", .{ from_str, to_str, nodes });

            board.restore_state(original_state);
        }
    }

    print("\nTotal moves: {d}\n", .{move_list.count});
    print("Total nodes: {d}\n", .{total_nodes});
}
