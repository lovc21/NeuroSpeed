const std = @import("std");
const types = @import("types.zig");
const lists = @import("lists.zig");
const move_gen = @import("move.zig");
const attacks = @import("attacks.zig");
const Bitboard = @import("bitboard.zig");
const movegen = @import("movegen.zig");
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

    // Check bishops and queens
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
    movegen.generate_legal_moves(board, &move_list, color);

    if (depth == 1) {
        for (0..move_list.count) |i| {
            const move = move_list.moves[i];
            const undo = move_gen.make_move_search(board, move);

            stats.nodes += 1;

            if (move.is_capture()) stats.captures += 1;
            if (move.flags == types.MoveFlags.EN_PASSANT) stats.en_passant += 1;
            if (move.is_castling()) stats.castles += 1;
            if (move.is_promotion()) stats.promotions += 1;

            // Check for checks
            const opponent_king_piece = if (opponent_side == types.Color.White) types.Piece.WHITE_KING else types.Piece.BLACK_KING;
            const opponent_king_square: u6 = @intCast(lsb_index(board.pieces[@intFromEnum(opponent_king_piece)]));

            if (Bitboard.is_square_attacked(board, opponent_king_square, color)) {
                stats.checks += 1;

                const attacker_count = count_attackers_to_square(board, opponent_king_square, color);
                if (attacker_count >= 2) stats.double_checks += 1;

                // Check for checkmate: legal movegen means count == 0 is checkmate
                var opponent_moves: lists.MoveList = .{};
                movegen.generate_legal_moves(board, &opponent_moves, opponent_side);
                if (opponent_moves.count == 0) stats.checkmates += 1;
            }

            move_gen.unmake_move_search(board, move, undo);
        }
    } else {
        for (0..move_list.count) |i| {
            const move = move_list.moves[i];
            const undo = move_gen.make_move_search(board, move);
            const sub_stats = perft_detailed(opponent_side, board, depth - 1);
            stats.add(sub_stats);
            move_gen.unmake_move_search(board, move, undo);
        }
    }

    return stats;
}

// Perft using legal move generation with fast play/undo (no zobrist, no eval)
pub fn perft_legal(comptime color: types.Color, board: *types.Board, depth: u8) u64 {
    if (depth == 0) return 1;

    const opponent_side = if (color == types.Color.White) types.Color.Black else types.Color.White;

    // Generate only legal moves
    var move_list: lists.MoveList = .{};
    movegen.generate_legal_moves(board, &move_list, color);

    // Bulk counting: at depth 1, just return the count of legal moves
    if (depth == 1) return move_list.count;

    var nodes: u64 = 0;
    for (0..move_list.count) |i| {
        const move = move_list.moves[i];

        // Fast play/undo: ~4 bytes of undo info instead of 200-byte board copy
        const undo = move_gen.make_move_perft(board, move);
        nodes += perft_legal(opponent_side, board, depth - 1);
        move_gen.unmake_move_perft(board, move, undo);
    }

    return nodes;
}
