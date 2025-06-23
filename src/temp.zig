const std = @import("std");
const types = @import("types.zig");
const attacks = @import("attacks.zig");
const lists = @import("lists.zig");
const util = @import("util.zig");

pub const Move = struct {
    from: u6,
    to: u6,
    flags: types.MoveFlags,

    pub inline fn new(from: u6, to: u6, flags: types.MoveFlags) Move {
        return Move{ .from = from, .to = to, .flags = flags };
    }
};

pub fn generate_moves(board: *types.Board, list: *lists.MoveList, comptime color: types.Color) void {
    const us = color;
    const them = if (us == types.Color.White) types.Color.Black else types.Color.White;

    const us_bb: u64 = board.set_pieces(us);
    const them_bb: u64 = board.set_pieces(them);
    const all_bb = us_bb | them_bb;

    // Find our king and their king
    const our_king_bb = board.pieces[if (us == types.Color.White) @intFromEnum(types.Piece.WHITE_KING) else @intFromEnum(types.Piece.BLACK_KING)];
    const their_king_bb = board.pieces[if (them == types.Color.White) @intFromEnum(types.Piece.WHITE_KING) else @intFromEnum(types.Piece.BLACK_KING)];

    const our_king_sq: u6 = @intCast(util.lsb_index(our_king_bb));
    const their_king_sq: u6 = @intCast(util.lsb_index(their_king_bb));

    // Calculate sliders for both sides
    const their_diag_sliders = board.pieces[if (them == types.Color.White) @intFromEnum(types.Piece.WHITE_BISHOP) else @intFromEnum(types.Piece.BLACK_BISHOP)] |
        board.pieces[if (them == types.Color.White) @intFromEnum(types.Piece.WHITE_QUEEN) else @intFromEnum(types.Piece.BLACK_QUEEN)];

    const their_ortho_sliders = board.pieces[if (them == types.Color.White) @intFromEnum(types.Piece.WHITE_ROOK) else @intFromEnum(types.Piece.BLACK_ROOK)] |
        board.pieces[if (them == types.Color.White) @intFromEnum(types.Piece.WHITE_QUEEN) else @intFromEnum(types.Piece.BLACK_QUEEN)];

    // Direction helpers
    const rel_north: i8 = if (us == types.Color.White) 8 else -8;
    const rel_south: i8 = if (us == types.Color.White) -8 else 8;
    const rel_northwest: i8 = if (us == types.Color.White) 7 else -9;
    const rel_northeast: i8 = if (us == types.Color.White) 9 else -7;

    // Bitboards for temp storage
    var b1: u64 = 0;

    // 1. CALCULATE DANGER SQUARES (squares king cannot move to)
    var danger: u64 = 0;

    // Pawn attacks
    const their_pawns = board.pieces[if (them == types.Color.White) @intFromEnum(types.Piece.WHITE_PAWN) else @intFromEnum(types.Piece.BLACK_PAWN)];
    if (them == types.Color.White) {
        danger |= ((their_pawns & ~types.mask_file[0]) << 7) | ((their_pawns & ~types.mask_file[7]) << 9);
    } else {
        danger |= ((their_pawns & ~types.mask_file[0]) >> 9) | ((their_pawns & ~types.mask_file[7]) >> 7);
    }

    // Their king attacks
    danger |= attacks.piece_attacks(their_king_sq, all_bb, types.PieceType.King);

    // Knight attacks
    b1 = board.pieces[if (them == types.Color.White) @intFromEnum(types.Piece.WHITE_KNIGHT) else @intFromEnum(types.Piece.BLACK_KNIGHT)];
    while (b1 != 0) {
        const sq: u6 = @intCast(util.lsb_index(b1));
        danger |= attacks.piece_attacks(sq, all_bb, types.PieceType.Knight);
        b1 &= b1 - 1;
    }

    // Sliding piece attacks (without our king to see through)
    const occ_without_our_king = all_bb & ~our_king_bb;

    b1 = their_diag_sliders;
    while (b1 != 0) {
        const sq: u6 = @intCast(util.lsb_index(b1));
        danger |= attacks.get_bishop_attacks(sq, occ_without_our_king);
        b1 &= b1 - 1;
    }

    b1 = their_ortho_sliders;
    while (b1 != 0) {
        const sq: u6 = @intCast(util.lsb_index(b1));
        danger |= attacks.get_rook_attacks(sq, occ_without_our_king);
        b1 &= b1 - 1;
    }

    // 2. GENERATE KING MOVES (avoiding danger squares)
    const king_attacks = attacks.piece_attacks(our_king_sq, all_bb, types.PieceType.King) & ~(us_bb | danger);

    // King quiet moves
    b1 = king_attacks & ~them_bb;
    while (b1 != 0) {
        const to: u6 = @intCast(util.lsb_index(b1));
        list.append(Move.new(our_king_sq, to, types.MoveFlags.QUIET));
        b1 &= b1 - 1;
    }

    // King captures
    b1 = king_attacks & them_bb;
    while (b1 != 0) {
        const to: u6 = @intCast(util.lsb_index(b1));
        list.append(Move.new(our_king_sq, to, types.MoveFlags.CAPTURE));
        b1 &= b1 - 1;
    }

    // 3. FIND CHECKERS AND PINNED PIECES
    var checkers: u64 = 0;
    var pinned: u64 = 0;

    // Direct attacks on king (knights and pawns)
    checkers |= attacks.piece_attacks(our_king_sq, all_bb, types.PieceType.Knight) &
        board.pieces[if (them == types.Color.White) @intFromEnum(types.Piece.WHITE_KNIGHT) else @intFromEnum(types.Piece.BLACK_KNIGHT)];

    checkers |= attacks.pawn_attacks_from_square(our_king_sq, us) & their_pawns;

    // Sliding attacks (find checkers and pinned pieces)
    var candidates = attacks.get_rook_attacks(our_king_sq, them_bb) & their_ortho_sliders;
    candidates |= attacks.get_bishop_attacks(our_king_sq, them_bb) & their_diag_sliders;

    while (candidates != 0) {
        const sq: u6 = @intCast(util.lsb_index(candidates));
        candidates &= candidates - 1;

        // Find pieces between king and this slider
        const between = getSquaresBetween(our_king_sq, sq) & us_bb;

        if (between == 0) {
            // No piece between: this is a checker
            checkers |= types.squar_bb[sq];
        } else if ((between & (between - 1)) == 0) {
            // Exactly one piece between: it's pinned
            pinned |= between;
        }
    }

    const not_pinned = ~pinned;
    var capture_mask: u64 = 0;
    var quiet_mask: u64 = 0;

    // 4. HANDLE THE THREE SCENARIOS
    const checker_count = util.popcount(checkers);

    if (checker_count == 2) {
        // DOUBLE CHECK: Only king moves are legal (already generated)
        return;
    } else if (checker_count == 1) {
        // SINGLE CHECK: Can capture checker, block, or move king
        const checker_sq: u6 = @intCast(util.lsb_index(checkers));
        capture_mask = checkers;
        quiet_mask = getSquaresBetween(our_king_sq, checker_sq);

        // Special case: if checker is pawn and we can capture en passant
        if (board.enpassant != types.square.NO_SQUARE) {
            const ep_sq: u6 = @intCast(@intFromEnum(board.enpassant));
            const ep_target_sq: u6 = @intCast(@as(i16, ep_sq) + rel_south);

            if (checkers == types.squar_bb[ep_target_sq]) {
                b1 = attacks.pawn_attacks_from_square(ep_sq, them) &
                    board.pieces[if (us == types.Color.White) @intFromEnum(types.Piece.WHITE_PAWN) else @intFromEnum(types.Piece.BLACK_PAWN)] &
                    not_pinned;

                while (b1 != 0) {
                    const from: u6 = @intCast(util.lsb_index(b1));
                    list.append(Move.new(from, ep_sq, types.MoveFlags.EN_PASSANT));
                    b1 &= b1 - 1;
                }
            }
        }
    } else {
        // NO CHECK: All moves allowed
        capture_mask = them_bb;
        quiet_mask = ~all_bb;

        // Generate castling moves (only when not in check)
        generateCastlingMoves(board, list, us, all_bb, danger);

        // Generate en passant moves (only when not in check)
        generateEnPassantMoves(board, list, us, all_bb, our_king_sq, their_ortho_sliders, not_pinned, rel_south);

        // Handle pinned sliding pieces (can only move along pin line)
        generatePinnedSliderMoves(board, list, us, all_bb, our_king_sq, pinned, capture_mask, quiet_mask);

        // Handle pinned pawns
        generatePinnedPawnMoves(board, list, us, all_bb, our_king_sq, pinned, them_bb, rel_north, rel_northwest, rel_northeast);
    }

    // 5. GENERATE MOVES FOR NON-PINNED PIECES

    // Knights (cannot move when pinned)
    b1 = board.pieces[if (us == types.Color.White) @intFromEnum(types.Piece.WHITE_KNIGHT) else @intFromEnum(types.Piece.BLACK_KNIGHT)] & not_pinned;
    while (b1 != 0) {
        const from: u6 = @intCast(util.lsb_index(b1));
        b1 &= b1 - 1;

        const attacks_bb = attacks.piece_attacks(from, all_bb, types.PieceType.Knight);

        generateMovesFromBitboard(list, from, attacks_bb & quiet_mask, types.MoveFlags.QUIET);
        generateMovesFromBitboard(list, from, attacks_bb & capture_mask, types.MoveFlags.CAPTURE);
    }

    // Bishops
    b1 = board.pieces[if (us == types.Color.White) @intFromEnum(types.Piece.WHITE_BISHOP) else @intFromEnum(types.Piece.BLACK_BISHOP)] & not_pinned;
    while (b1 != 0) {
        const from: u6 = @intCast(util.lsb_index(b1));
        b1 &= b1 - 1;

        const attacks_bb = attacks.get_bishop_attacks(from, all_bb);

        generateMovesFromBitboard(list, from, attacks_bb & quiet_mask, types.MoveFlags.QUIET);
        generateMovesFromBitboard(list, from, attacks_bb & capture_mask, types.MoveFlags.CAPTURE);
    }

    // Rooks
    b1 = board.pieces[if (us == types.Color.White) @intFromEnum(types.Piece.WHITE_ROOK) else @intFromEnum(types.Piece.BLACK_ROOK)] & not_pinned;
    while (b1 != 0) {
        const from: u6 = @intCast(util.lsb_index(b1));
        b1 &= b1 - 1;

        const attacks_bb = attacks.get_rook_attacks(from, all_bb);

        generateMovesFromBitboard(list, from, attacks_bb & quiet_mask, types.MoveFlags.QUIET);
        generateMovesFromBitboard(list, from, attacks_bb & capture_mask, types.MoveFlags.CAPTURE);
    }

    // Queens
    b1 = board.pieces[if (us == types.Color.White) @intFromEnum(types.Piece.WHITE_QUEEN) else @intFromEnum(types.Piece.BLACK_QUEEN)] & not_pinned;
    while (b1 != 0) {
        const from: u6 = @intCast(util.lsb_index(b1));
        b1 &= b1 - 1;

        const attacks_bb = attacks.get_queen_attacks(from, all_bb);

        generateMovesFromBitboard(list, from, attacks_bb & quiet_mask, types.MoveFlags.QUIET);
        generateMovesFromBitboard(list, from, attacks_bb & capture_mask, types.MoveFlags.CAPTURE);
    }

    // Pawns (non-pinned)
    generatePawnMoves(board, list, us, them_bb, all_bb, not_pinned, capture_mask, quiet_mask, rel_north);
}

// Helper function to generate moves from a bitboard
inline fn generateMovesFromBitboard(list: *lists.MoveList, from: u6, targets: u64, flag: types.MoveFlags) void {
    var bb = targets;
    while (bb != 0) {
        const to: u6 = @intCast(util.lsb_index(bb));
        list.append(Move.new(from, to, flag));
        bb &= bb - 1;
    }
}

// Get squares between two squares (simplified version)
inline fn getSquaresBetween(sq1: u6, sq2: u6) u64 {
    const sq1_rank = sq1 / 8;
    const sq1_file = sq1 % 8;
    const sq2_rank = sq2 / 8;
    const sq2_file = sq2 % 8;

    // Same rank (horizontal)
    if (sq1_rank == sq2_rank) {
        const start = @min(sq1_file, sq2_file) + 1;
        const end = @max(sq1_file, sq2_file);
        var result: u64 = 0;
        var i = start;
        while (i < end) : (i += 1) {
            result |= types.squar_bb[sq1_rank * 8 + i];
        }
        return result;
    }

    // Same file (vertical)
    if (sq1_file == sq2_file) {
        const start = @min(sq1_rank, sq2_rank) + 1;
        const end = @max(sq1_rank, sq2_rank);
        var result: u64 = 0;
        var i = start;
        while (i < end) : (i += 1) {
            result |= types.squar_bb[i * 8 + sq1_file];
        }
        return result;
    }

    // Diagonal
    const rank_diff: i8 = @intCast(@as(i16, sq2_rank) - @as(i16, sq1_rank));
    const file_diff: i8 = @intCast(@as(i16, sq2_file) - @as(i16, sq1_file));

    if (@abs(rank_diff) == @abs(file_diff)) {
        const rank_step: i8 = if (rank_diff > 0) 1 else -1;
        const file_step: i8 = if (file_diff > 0) 1 else -1;

        var result: u64 = 0;
        var r: i8 = @intCast(sq1_rank + rank_step);
        var f: i8 = @intCast(sq1_file + file_step);

        while (r != sq2_rank and f != sq2_file) {
            result |= types.squar_bb[@intCast(r * 8 + f)];
            r += rank_step;
            f += file_step;
        }
        return result;
    }

    return 0;
}

// Generate castling moves
fn generateCastlingMoves(board: *types.Board, list: *lists.MoveList, us: types.Color, all_bb: u64, danger: u64) void {
    if (us == types.Color.White) {
        // White kingside
        if ((board.castle & @intFromEnum(types.Castle.WK)) != 0) {
            if ((all_bb & 0x60) == 0 and (danger & 0x70) == 0) { // f1, g1 empty and safe
                list.append(Move.new(@intFromEnum(types.square.e1), @intFromEnum(types.square.g1), types.MoveFlags.OO));
            }
        }

        // White queenside
        if ((board.castle & @intFromEnum(types.Castle.WQ)) != 0) {
            if ((all_bb & 0xe) == 0 and (danger & 0x1c) == 0) { // b1, c1, d1 empty and c1, d1, e1 safe
                list.append(Move.new(@intFromEnum(types.square.e1), @intFromEnum(types.square.c1), types.MoveFlags.OOO));
            }
        }
    } else {
        // Black kingside
        if ((board.castle & @intFromEnum(types.Castle.BK)) != 0) {
            if ((all_bb & 0x6000000000000000) == 0 and (danger & 0x7000000000000000) == 0) {
                list.append(Move.new(@intFromEnum(types.square.e8), @intFromEnum(types.square.g8), types.MoveFlags.OO));
            }
        }

        // Black queenside
        if ((board.castle & @intFromEnum(types.Castle.BQ)) != 0) {
            if ((all_bb & 0xe00000000000000) == 0 and (danger & 0x1c00000000000000) == 0) {
                list.append(Move.new(@intFromEnum(types.square.e8), @intFromEnum(types.square.c8), types.MoveFlags.OOO));
            }
        }
    }
}

// Generate en passant moves (simplified)
fn generateEnPassantMoves(board: *types.Board, list: *lists.MoveList, us: types.Color, all_bb: u64, our_king_sq: u6, their_ortho_sliders: u64, not_pinned: u64, rel_south: i8) void {
    if (board.enpassant == types.square.NO_SQUARE) return;

    const ep_sq: u6 = @intCast(@intFromEnum(board.enpassant));
    const our_pawns = board.pieces[if (us == types.Color.White) @intFromEnum(types.Piece.WHITE_PAWN) else @intFromEnum(types.Piece.BLACK_PAWN)];
    const them = if (us == types.Color.White) types.Color.Black else types.Color.White;

    var attackers = attacks.pawn_attacks_from_square(ep_sq, them) & our_pawns & not_pinned;

    while (attackers != 0) {
        const from: u6 = @intCast(util.lsb_index(attackers));
        attackers &= attackers - 1;

        // Check for horizontal pin after en passant capture
        const ep_target_sq: u6 = @intCast(@as(i16, ep_sq) + rel_south);
        const test_occ = all_bb ^ types.squar_bb[from] ^ types.squar_bb[ep_target_sq];

        if ((attacks.get_rook_attacks(our_king_sq, test_occ) & their_ortho_sliders & types.mask_rank[our_king_sq / 8]) == 0) {
            list.append(Move.new(from, ep_sq, types.MoveFlags.EN_PASSANT));
        }
    }
}

// Generate moves for pinned sliding pieces
fn generatePinnedSliderMoves(board: *types.Board, list: *lists.MoveList, us: types.Color, all_bb: u64, our_king_sq: u6, pinned: u64, capture_mask: u64, quiet_mask: u64) void {
    // Pinned bishops/queens
    var pinned_diag = pinned & (board.pieces[if (us == types.Color.White) @intFromEnum(types.Piece.WHITE_BISHOP) else @intFromEnum(types.Piece.BLACK_BISHOP)] |
        board.pieces[if (us == types.Color.White) @intFromEnum(types.Piece.WHITE_QUEEN) else @intFromEnum(types.Piece.BLACK_QUEEN)]);

    while (pinned_diag != 0) {
        const from: u6 = @intCast(util.lsb_index(pinned_diag));
        pinned_diag &= pinned_diag - 1;

        const line = getLineBetween(our_king_sq, from);
        const piece_attacks = attacks.get_bishop_attacks(from, all_bb) & line;

        generateMovesFromBitboard(list, from, piece_attacks & quiet_mask, types.MoveFlags.QUIET);
        generateMovesFromBitboard(list, from, piece_attacks & capture_mask, types.MoveFlags.CAPTURE);
    }

    // Pinned rooks/queens
    var pinned_ortho = pinned & (board.pieces[if (us == types.Color.White) @intFromEnum(types.Piece.WHITE_ROOK) else @intFromEnum(types.Piece.BLACK_ROOK)] |
        board.pieces[if (us == types.Color.White) @intFromEnum(types.Piece.WHITE_QUEEN) else @intFromEnum(types.Piece.BLACK_QUEEN)]);

    while (pinned_ortho != 0) {
        const from: u6 = @intCast(util.lsb_index(pinned_ortho));
        pinned_ortho &= pinned_ortho - 1;

        const line = getLineBetween(our_king_sq, from);
        const piece_attacks = attacks.get_rook_attacks(from, all_bb) & line;

        generateMovesFromBitboard(list, from, piece_attacks & quiet_mask, types.MoveFlags.QUIET);
        generateMovesFromBitboard(list, from, piece_attacks & capture_mask, types.MoveFlags.CAPTURE);
    }
}

// Get line between two squares (including the squares)
inline fn getLineBetween(sq1: u6, sq2: u6) u64 {
    // This would use your existing attack tables to get the full line
    // For now, simplified version
    return getSquaresBetween(sq1, sq2) | types.squar_bb[sq1] | types.squar_bb[sq2];
}

// Generate moves for pinned pawns
fn generatePinnedPawnMoves(board: *types.Board, list: *lists.MoveList, comptime us: types.Color, all_bb: u64, our_king_sq: u6, pinned: u64, them_bb: u64, rel_north: i8, rel_northwest: i8, rel_northeast: i8) void {
    const our_pawns = board.pieces[if (us == types.Color.White) @intFromEnum(types.Piece.WHITE_PAWN) else @intFromEnum(types.Piece.BLACK_PAWN)];
    var pinned_pawns = pinned & our_pawns;

    while (pinned_pawns != 0) {
        const from: u6 = @intCast(util.lsb_index(pinned_pawns));
        pinned_pawns &= pinned_pawns - 1;

        const line = getLineBetween(our_king_sq, from);

        // Pawn pushes
        const push_sq: u6 = @intCast(@as(i16, from) + rel_north);
        if (push_sq < 64 and (types.squar_bb[push_sq] & line) != 0 and (all_bb & types.squar_bb[push_sq]) == 0) {
            if (push_sq >= 56 or push_sq <= 7) { // Promotion
                list.append(Move.new(from, push_sq, types.MoveFlags.PR_QUEEN));
                list.append(Move.new(from, push_sq, types.MoveFlags.PR_ROOK));
                list.append(Move.new(from, push_sq, types.MoveFlags.PR_BISHOP));
                list.append(Move.new(from, push_sq, types.MoveFlags.PR_KNIGHT));
            } else {
                list.append(Move.new(from, push_sq, types.MoveFlags.QUIET));

                // Double push
                const double_push_sq: u6 = @intCast(@as(i16, from) + rel_north * 2);
                if ((from >= 8 and from <= 15 and us == types.Color.White) or
                    (from >= 48 and from <= 55 and us == types.Color.Black))
                {
                    if ((all_bb & types.squar_bb[double_push_sq]) == 0 and (types.squar_bb[double_push_sq] & line) != 0) {
                        list.append(Move.new(from, double_push_sq, types.MoveFlags.DOUBLE_PUSH));
                    }
                }
            }
        }

        // Pawn captures
        const cap1_sq: u6 = @intCast(@as(i16, from) + rel_northwest);
        if (cap1_sq < 64 and (types.squar_bb[cap1_sq] & line) != 0 and (them_bb & types.squar_bb[cap1_sq]) != 0) {
            if (cap1_sq >= 56 or cap1_sq <= 7) { // Promotion capture
                list.append(Move.new(from, cap1_sq, types.MoveFlags.PC_QUEEN));
                list.append(Move.new(from, cap1_sq, types.MoveFlags.PC_ROOK));
                list.append(Move.new(from, cap1_sq, types.MoveFlags.PC_BISHOP));
                list.append(Move.new(from, cap1_sq, types.MoveFlags.PC_KNIGHT));
            } else {
                list.append(Move.new(from, cap1_sq, types.MoveFlags.CAPTURE));
            }
        }

        const cap2_sq: u6 = @intCast(@as(i16, from) + rel_northeast);
        if (cap2_sq < 64 and (types.squar_bb[cap2_sq] & line) != 0 and (them_bb & types.squar_bb[cap2_sq]) != 0) {
            if (cap2_sq >= 56 or cap2_sq <= 7) { // Promotion capture
                list.append(Move.new(from, cap2_sq, types.MoveFlags.PC_QUEEN));
                list.append(Move.new(from, cap2_sq, types.MoveFlags.PC_ROOK));
                list.append(Move.new(from, cap2_sq, types.MoveFlags.PC_BISHOP));
                list.append(Move.new(from, cap2_sq, types.MoveFlags.PC_KNIGHT));
            } else {
                list.append(Move.new(from, cap2_sq, types.MoveFlags.CAPTURE));
            }
        }
    }
}

// Generate regular pawn moves for non-pinned pawns
fn generatePawnMoves(board: *types.Board, list: *lists.MoveList, comptime us: types.Color, them_bb: u64, all_bb: u64, not_pinned: u64, capture_mask: u64, quiet_mask: u64, rel_north: i8) void {
    const our_pawns = board.pieces[if (us == types.Color.White) @intFromEnum(types.Piece.WHITE_PAWN) else @intFromEnum(types.Piece.BLACK_PAWN)];
    const promotion_rank = if (us == types.Color.White) 7 else 0;
    const start_rank = if (us == types.Color.White) 1 else 6;

    // Non-pinned pawns not on promotion rank
    var pawns = our_pawns & not_pinned & ~types.mask_rank[promotion_rank];

    // Single pushes
    var pawn_bb = pawns;
    while (pawn_bb != 0) {
        const from: u6 = @intCast(util.lsb_index(pawn_bb));
        pawn_bb &= pawn_bb - 1;

        const to: u6 = @intCast(@as(i16, from) + rel_north);
        if (to < 64 and (all_bb & types.squar_bb[to]) == 0) {
            if ((types.squar_bb[to] & quiet_mask) != 0) {
                list.append(Move.new(from, to, types.MoveFlags.QUIET));
            }

            // Double pushes
            if (from / 8 == start_rank) {
                const double_to: u6 = @intCast(@as(i16, from) + rel_north * 2);
                if ((all_bb & types.squar_bb[double_to]) == 0 and (types.squar_bb[double_to] & quiet_mask) != 0) {
                    list.append(Move.new(from, double_to, types.MoveFlags.DOUBLE_PUSH));
                }
            }
        }
    }

    // Captures
    pawn_bb = pawns;
    while (pawn_bb != 0) {
        const from: u6 = @intCast(util.lsb_index(pawn_bb));
        pawn_bb &= pawn_bb - 1;

        const cap_attacks = attacks.pawn_attacks_from_square(from, us) & them_bb & capture_mask;
        generateMovesFromBitboard(list, from, cap_attacks, types.MoveFlags.CAPTURE);
    }

    // Promotion moves
    pawns = our_pawns & not_pinned & types.mask_rank[promotion_rank];
    while (pawns != 0) {
        const from: u6 = @intCast(util.lsb_index(pawns));
        pawns &= pawns - 1;

        // Promotion pushes
        const to: u6 = @intCast(@as(i16, from) + rel_north);
        if (to < 64 and (all_bb & types.squar_bb[to]) == 0 and (types.squar_bb[to] & quiet_mask) != 0) {
            list.append(Move.new(from, to, types.MoveFlags.PR_QUEEN));
            list.append(Move.new(from, to, types.MoveFlags.PR_ROOK));
            list.append(Move.new(from, to, types.MoveFlags.PR_BISHOP));
            list.append(Move.new(from, to, types.MoveFlags.PR_KNIGHT));
        }

        // Promotion captures
        const cap_attacks = attacks.pawn_attacks_from_square(from, us) & them_bb & capture_mask;
        var caps = cap_attacks;
        while (caps != 0) {
            const cap_to: u6 = @intCast(util.lsb_index(caps));
            caps &= caps - 1;

            list.append(Move.new(from, cap_to, types.MoveFlags.PC_QUEEN));
            list.append(Move.new(from, cap_to, types.MoveFlags.PC_ROOK));
            list.append(Move.new(from, cap_to, types.MoveFlags.PC_BISHOP));
            list.append(Move.new(from, cap_to, types.MoveFlags.PC_KNIGHT));
        }
    }
}
