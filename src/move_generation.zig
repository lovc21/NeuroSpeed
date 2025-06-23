const std = @import("std");
const types = @import("types.zig");
const attacks = @import("attacks.zig");
const lists = @import("lists.zig");
const util = @import("util.zig");
const bitboard = @import("bitboard.zig");

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
    const occ = us_bb | them_bb;

    const pawn_piece = if (us == types.Color.White) types.Piece.WHITE_PAWN else types.Piece.BLACK_PAWN;
    var b: u64 = board.pieces[@intFromEnum(pawn_piece)];

    // Pawn moves
    while (b != 0) {
        const from_idx = util.lsb_index(b);
        const from: u6 = @intCast(from_idx);
        b &= b - 1;
        const from_bb = types.squar_bb[from]; // Use squar_bb instead of squar_bb_rotated

        // single push
        const dir: u64 = if (us == types.Color.White) from_bb << 8 else from_bb >> 8;
        if ((dir & occ) == 0) {
            const to_idx = util.lsb_index(dir);
            const to: u6 = @intCast(to_idx);

            // promotion rank check
            if ((dir & types.mask_rank[if (us == types.Color.White) 7 else 0]) != 0) {
                list.append(Move.new(from, to, types.MoveFlags.PR_QUEEN));
                list.append(Move.new(from, to, types.MoveFlags.PR_ROOK));
                list.append(Move.new(from, to, types.MoveFlags.PR_BISHOP));
                list.append(Move.new(from, to, types.MoveFlags.PR_KNIGHT));
            } else {
                list.append(Move.new(from, to, types.MoveFlags.QUIET));

                // double push
                const start_mask = types.mask_rank[if (us == types.Color.White) 1 else 6];
                if ((from_bb & start_mask) != 0) {
                    const dir2 = if (us == types.Color.White) from_bb << 16 else from_bb >> 16;
                    if ((dir2 & occ) == 0) {
                        const to2: u6 = @intCast(util.lsb_index(dir2));
                        list.append(Move.new(from, to2, types.MoveFlags.DOUBLE_PUSH));
                    }
                }
            }
        }

        // captures & promotions
        const cap_bb = attacks.pawn_attacks_from_square(from, us) & them_bb;
        var c: u64 = cap_bb;
        while (c != 0) {
            const to_idx = util.lsb_index(c);
            const to: u6 = @intCast(to_idx);
            c &= c - 1;

            // promotion rank check for captures
            if ((types.squar_bb[to] & types.mask_rank[if (us == types.Color.White) 7 else 0]) != 0) {
                list.append(Move.new(from, to, types.MoveFlags.PC_QUEEN));
                list.append(Move.new(from, to, types.MoveFlags.PC_ROOK));
                list.append(Move.new(from, to, types.MoveFlags.PC_BISHOP));
                list.append(Move.new(from, to, types.MoveFlags.PC_KNIGHT));
            } else {
                list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
            }
        }

        // en-passant
        if (board.enpassant != types.square.NO_SQUARE) {
            const ep_sq: u6 = @intCast(@intFromEnum(board.enpassant));
            const ep_bb = types.squar_bb[ep_sq];
            if ((attacks.pawn_attacks_from_square(from, us) & ep_bb) != 0) {
                list.append(Move.new(from, ep_sq, types.MoveFlags.EN_PASSANT));
            }
        }
    }

    // Knight moves
    const knight_piece = if (us == types.Color.White) types.Piece.WHITE_KNIGHT else types.Piece.BLACK_KNIGHT;
    b = board.pieces[@intFromEnum(knight_piece)];
    while (b != 0) {
        const from_idx = util.lsb_index(b);
        const from: u6 = @intCast(from_idx);
        b &= b - 1;

        const knight_attacks = attacks.piece_attacks(from, occ, types.PieceType.Knight);

        // Quiet moves
        var quiet_targets = knight_attacks & ~occ;
        while (quiet_targets != 0) {
            const to: u6 = @intCast(util.lsb_index(quiet_targets));
            list.append(Move.new(from, to, types.MoveFlags.QUIET));
            quiet_targets &= quiet_targets - 1;
        }

        // Captures
        var capture_targets = knight_attacks & them_bb;
        while (capture_targets != 0) {
            const to: u6 = @intCast(util.lsb_index(capture_targets));
            list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
            capture_targets &= capture_targets - 1;
        }
    }

    // Bishop moves
    const bishop_piece = if (us == types.Color.White) types.Piece.WHITE_BISHOP else types.Piece.BLACK_BISHOP;
    b = board.pieces[@intFromEnum(bishop_piece)];
    while (b != 0) {
        const from_idx = util.lsb_index(b);
        const from: u6 = @intCast(from_idx);
        b &= b - 1;

        const bishop_attacks_bb = attacks.get_bishop_attacks(from, occ);

        // Quiet moves
        var quiet_targets = bishop_attacks_bb & ~occ;
        while (quiet_targets != 0) {
            const to: u6 = @intCast(util.lsb_index(quiet_targets));
            list.append(Move.new(from, to, types.MoveFlags.QUIET));
            quiet_targets &= quiet_targets - 1;
        }

        // Captures
        var capture_targets = bishop_attacks_bb & them_bb;
        while (capture_targets != 0) {
            const to: u6 = @intCast(util.lsb_index(capture_targets));
            list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
            capture_targets &= capture_targets - 1;
        }
    }

    // Rook moves
    const rook_piece = if (us == types.Color.White) types.Piece.WHITE_ROOK else types.Piece.BLACK_ROOK;
    b = board.pieces[@intFromEnum(rook_piece)];
    while (b != 0) {
        const from_idx = util.lsb_index(b);
        const from: u6 = @intCast(from_idx);
        b &= b - 1;

        const rook_attacks_bb = attacks.get_rook_attacks(from, occ);

        // Quiet moves
        var quiet_targets = rook_attacks_bb & ~occ;
        while (quiet_targets != 0) {
            const to: u6 = @intCast(util.lsb_index(quiet_targets));
            list.append(Move.new(from, to, types.MoveFlags.QUIET));
            quiet_targets &= quiet_targets - 1;
        }

        // Captures
        var capture_targets = rook_attacks_bb & them_bb;
        while (capture_targets != 0) {
            const to: u6 = @intCast(util.lsb_index(capture_targets));
            list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
            capture_targets &= capture_targets - 1;
        }
    }

    // Queen moves
    const queen_piece = if (us == types.Color.White) types.Piece.WHITE_QUEEN else types.Piece.BLACK_QUEEN;
    b = board.pieces[@intFromEnum(queen_piece)];
    while (b != 0) {
        const from_idx = util.lsb_index(b);
        const from: u6 = @intCast(from_idx);
        b &= b - 1;

        const queen_attacks_bb = attacks.get_queen_attacks(from, occ);

        // Quiet moves
        var quiet_targets = queen_attacks_bb & ~occ;
        while (quiet_targets != 0) {
            const to: u6 = @intCast(util.lsb_index(quiet_targets));
            list.append(Move.new(from, to, types.MoveFlags.QUIET));
            quiet_targets &= quiet_targets - 1;
        }

        // Captures
        var capture_targets = queen_attacks_bb & them_bb;
        while (capture_targets != 0) {
            const to: u6 = @intCast(util.lsb_index(capture_targets));
            list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
            capture_targets &= capture_targets - 1;
        }
    }

    // Castling
    if (us == types.Color.White) {
        // White kingside castling
        if ((board.castle & @intFromEnum(types.Castle.WK)) != 0) {
            if ((occ & 0x60) == 0) { // f1 and g1 empty
                if (!bitboard.is_square_attacked(board, @intFromEnum(types.square.e1), them) and
                    !bitboard.is_square_attacked(board, @intFromEnum(types.square.f1), them) and
                    !bitboard.is_square_attacked(board, @intFromEnum(types.square.g1), them))
                {
                    list.append(Move.new(@intFromEnum(types.square.e1), @intFromEnum(types.square.g1), types.MoveFlags.OO));
                }
            }
        }

        // White queenside castling
        if ((board.castle & @intFromEnum(types.Castle.WQ)) != 0) {
            if ((occ & 0xe) == 0) { // b1, c1, d1 empty
                if (!bitboard.is_square_attacked(board, @intFromEnum(types.square.e1), them) and
                    !bitboard.is_square_attacked(board, @intFromEnum(types.square.d1), them) and
                    !bitboard.is_square_attacked(board, @intFromEnum(types.square.c1), them))
                {
                    list.append(Move.new(@intFromEnum(types.square.e1), @intFromEnum(types.square.c1), types.MoveFlags.OOO));
                }
            }
        }
    } else {
        // Black kingside castling
        if ((board.castle & @intFromEnum(types.Castle.BK)) != 0) {
            if ((occ & 0x6000000000000000) == 0) { // f8 and g8 empty
                if (!bitboard.is_square_attacked(board, @intFromEnum(types.square.e8), them) and
                    !bitboard.is_square_attacked(board, @intFromEnum(types.square.f8), them) and
                    !bitboard.is_square_attacked(board, @intFromEnum(types.square.g8), them))
                {
                    list.append(Move.new(@intFromEnum(types.square.e8), @intFromEnum(types.square.g8), types.MoveFlags.OO));
                }
            }
        }

        // Black queenside castling
        if ((board.castle & @intFromEnum(types.Castle.BQ)) != 0) {
            if ((occ & 0xe00000000000000) == 0) { // b8, c8, d8 empty
                if (!bitboard.is_square_attacked(board, @intFromEnum(types.square.e8), them) and
                    !bitboard.is_square_attacked(board, @intFromEnum(types.square.d8), them) and
                    !bitboard.is_square_attacked(board, @intFromEnum(types.square.c8), them))
                {
                    list.append(Move.new(@intFromEnum(types.square.e8), @intFromEnum(types.square.c8), types.MoveFlags.OOO));
                }
            }
        }
    }
}
