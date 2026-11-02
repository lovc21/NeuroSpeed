const std = @import("std");
const types = @import("types.zig");
const attacks = @import("attacks.zig");
const util = @import("util.zig");

/// Squares strictly between two aligned squares, 0 if they are not on a line.
pub const between_table: [64][64]u64 = blk: {
    @setEvalBranchQuota(2_000_000);
    var t: [64][64]u64 = undefined;
    for (0..64) |sq1| {
        for (0..64) |sq2| {
            t[sq1][sq2] = compute_between(@intCast(sq1), @intCast(sq2));
        }
    }
    break :blk t;
};

/// Full rays from each square, used to skip slider lookups early.
pub const rook_full_mask: [64]u64 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [64]u64 = undefined;
    for (0..64) |sq| {
        var m = types.mask_rank[types.rank_of(sq)] | types.mask_file[types.file_of(sq)];
        m &= ~(@as(u64, 1) << @intCast(sq)); // remove the square itself
        t[sq] = m;
    }
    break :blk t;
};
pub const bishop_full_mask: [64]u64 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [64]u64 = undefined;
    for (0..64) |sq| {
        const rank = types.rank_of(sq);
        const file = types.file_of(sq);
        const diag = @as(i8, @intCast(rank)) - @as(i8, @intCast(file)) + 7;
        const adiag = @as(i8, @intCast(rank)) + @as(i8, @intCast(file));
        var m = types.mask_diagonal_nw_se[@intCast(diag)] |
            types.mask_anti_diagonal_ne_sw[@intCast(adiag)];
        m &= ~(@as(u64, 1) << @intCast(sq));
        t[sq] = m;
    }
    break :blk t;
};

fn compute_between(sq1: u6, sq2: u6) u64 {
    const r1: i8 = @intCast(types.rank_of(@as(u8, sq1)));
    const f1: i8 = @intCast(types.file_of(@as(u8, sq1)));
    const r2: i8 = @intCast(types.rank_of(@as(u8, sq2)));
    const f2: i8 = @intCast(types.file_of(@as(u8, sq2)));

    const dr = std.math.sign(r2 - r1);
    const df = std.math.sign(f2 - f1);

    // Must be on same rank, file, or diagonal
    if (dr == 0 and df == 0) return 0; // same square
    if (dr != 0 and df != 0 and @abs(r2 - r1) != @abs(f2 - f1)) return 0; // not on diagonal
    if (dr == 0 and r1 != r2) return 0;
    if (df == 0 and f1 != f2) return 0;

    var result: u64 = 0;
    var r = r1 + dr;
    var f = f1 + df;
    while (r != r2 or f != f2) {
        result |= @as(u64, 1) << @intCast(r * 8 + f);
        r += dr;
        f += df;
    }
    return result;
}

// Check and pin masks

pub const LegalInfo = struct {
    checkmask: u64,
    pin_hv: u64,
    pin_d12: u64,
    king_ban: u64, // squares attacked by enemy (king cannot go here)
    us_bb: u64, // our occupancy
    them_bb: u64, // their occupancy
    num_checkers: u2, // 0, 1, or 2+
};

/// Compute the checkmask, pinmasks and the squares the king can't go to.
pub inline fn compute_legal_info(board: *const types.Board, comptime color: types.Color) LegalInfo {
    const us = color;
    const them = comptime us.other();

    const us_bb = board.set_pieces(us);
    const them_bb = board.set_pieces(them);
    const occ = us_bb | them_bb;

    // Find our king
    const king_piece = if (us == types.Color.White) types.Piece.WHITE_KING else types.Piece.BLACK_KING;
    const king_bb = board.pieces[@intFromEnum(king_piece)];
    const king_sq: u6 = @intCast(@ctz(king_bb));

    // Enemy pieces
    const enemy_pawns = board.pieces[@intFromEnum(if (them == types.Color.White) types.Piece.WHITE_PAWN else types.Piece.BLACK_PAWN)];
    const enemy_knights = board.pieces[@intFromEnum(if (them == types.Color.White) types.Piece.WHITE_KNIGHT else types.Piece.BLACK_KNIGHT)];
    const enemy_bishops = board.pieces[@intFromEnum(if (them == types.Color.White) types.Piece.WHITE_BISHOP else types.Piece.BLACK_BISHOP)];
    const enemy_rooks = board.pieces[@intFromEnum(if (them == types.Color.White) types.Piece.WHITE_ROOK else types.Piece.BLACK_ROOK)];
    const enemy_queens = board.pieces[@intFromEnum(if (them == types.Color.White) types.Piece.WHITE_QUEEN else types.Piece.BLACK_QUEEN)];
    const enemy_king = board.pieces[@intFromEnum(if (them == types.Color.White) types.Piece.WHITE_KING else types.Piece.BLACK_KING)];

    const enemy_rook_queen = enemy_rooks | enemy_queens;
    const enemy_bishop_queen = enemy_bishops | enemy_queens;

    var checkmask: u64 = 0;
    var num_checkers: u2 = 0;
    var pin_hv: u64 = 0;
    var pin_d12: u64 = 0;

    // Pawn checks
    const pawn_atk = attacks.pawn_attacks_from_square(king_sq, us);
    const pawn_checkers = pawn_atk & enemy_pawns;
    if (pawn_checkers != 0) {
        checkmask |= pawn_checkers;
        num_checkers += 1;
    }

    // Knight checks
    const knight_atk = attacks.piece_attacks(king_sq, 0, types.PieceType.Knight);
    const knight_checkers = knight_atk & enemy_knights;
    if (knight_checkers != 0) {
        checkmask |= knight_checkers;
        num_checkers +|= 1; // saturates at 2
    }

    // Rook and queen checks and pins
    if (rook_full_mask[king_sq] & enemy_rook_queen != 0) {
        const rook_atk = attacks.get_rook_attacks(king_sq, occ);
        // Direct checks by rook/queen
        const checkers = rook_atk & enemy_rook_queen;
        var temp = checkers;
        while (temp != 0) {
            const checker_sq: u6 = @intCast(@ctz(temp));
            temp &= temp - 1;
            // Checkmask = between(king, checker) | checker itself
            checkmask |= between_table[king_sq][checker_sq] | (@as(u64, 1) << checker_sq);
            num_checkers +|= 1;
        }

        // X-ray through our pieces to find pinners
        const occ_without_us = occ & ~us_bb; // remove our pieces to see through them
        const xray_atk = attacks.get_rook_attacks(king_sq, occ_without_us);
        // Pinners = enemy rook/queen that are seen through one of our pieces
        var pinners = (xray_atk & ~rook_atk) & enemy_rook_queen;
        while (pinners != 0) {
            const pinner_sq: u6 = @intCast(@ctz(pinners));
            pinners &= pinners - 1;
            // The pin ray includes all squares between king and pinner, plus the pinner
            const pin_ray = between_table[king_sq][pinner_sq] | (@as(u64, 1) << pinner_sq);
            // A pin needs exactly one of our pieces on the ray.
            if (@popCount(pin_ray & us_bb) == 1) {
                pin_hv |= pin_ray;
            }
        }
    }

    // Bishop and queen checks and pins
    if (bishop_full_mask[king_sq] & enemy_bishop_queen != 0) {
        const bishop_atk = attacks.get_bishop_attacks(king_sq, occ);
        // Direct checks
        const checkers = bishop_atk & enemy_bishop_queen;
        var temp = checkers;
        while (temp != 0) {
            const checker_sq: u6 = @intCast(@ctz(temp));
            temp &= temp - 1;
            checkmask |= between_table[king_sq][checker_sq] | (@as(u64, 1) << checker_sq);
            num_checkers +|= 1;
        }

        // X-ray for diagonal pins
        const occ_without_us = occ & ~us_bb;
        const xray_atk = attacks.get_bishop_attacks(king_sq, occ_without_us);
        var pinners = (xray_atk & ~bishop_atk) & enemy_bishop_queen;
        while (pinners != 0) {
            const pinner_sq: u6 = @intCast(@ctz(pinners));
            pinners &= pinners - 1;
            const pin_ray = between_table[king_sq][pinner_sq] | (@as(u64, 1) << pinner_sq);
            // A pin needs exactly one of our pieces on the ray.
            if (@popCount(pin_ray & us_bb) == 1) {
                pin_d12 |= pin_ray;
            }
        }
    }

    // If no checkers, set checkmask to all 1s (no restriction)
    if (num_checkers == 0) {
        checkmask = ~@as(u64, 0);
    }

    // Squares the enemy attacks, with our king removed so sliders see through it
    const occ_no_king = occ ^ king_bb;
    var king_ban: u64 = 0;

    // Enemy pawn attacks
    if (them == types.Color.White) {
        king_ban |= attacks.pawn_attacks_from_bitboard(types.Color.White, enemy_pawns);
    } else {
        king_ban |= attacks.pawn_attacks_from_bitboard(types.Color.Black, enemy_pawns);
    }

    // Enemy knight attacks
    {
        var knights = enemy_knights;
        while (knights != 0) {
            const sq: u6 = @intCast(@ctz(knights));
            knights &= knights - 1;
            king_ban |= attacks.piece_attacks(sq, 0, types.PieceType.Knight);
        }
    }

    // Enemy bishop/queen attacks (diagonal)
    {
        var bq = enemy_bishop_queen;
        while (bq != 0) {
            const sq: u6 = @intCast(@ctz(bq));
            bq &= bq - 1;
            king_ban |= attacks.get_bishop_attacks(sq, occ_no_king);
        }
    }

    // Enemy rook/queen attacks (HV)
    {
        var rq = enemy_rook_queen;
        while (rq != 0) {
            const sq: u6 = @intCast(@ctz(rq));
            rq &= rq - 1;
            king_ban |= attacks.get_rook_attacks(sq, occ_no_king);
        }
    }

    // Enemy king attacks
    {
        const ek_sq: u6 = @intCast(@ctz(enemy_king));
        king_ban |= attacks.piece_attacks(ek_sq, 0, types.PieceType.King);
    }

    return LegalInfo{
        .checkmask = checkmask,
        .pin_hv = pin_hv,
        .pin_d12 = pin_d12,
        .king_ban = king_ban,
        .us_bb = us_bb,
        .them_bb = them_bb,
        .num_checkers = num_checkers,
    };
}

// Legal move generation

const lists = @import("lists.zig");
const Move = @import("move.zig").Move;

/// Generate all legal moves for `color` using the check and pin masks.
pub inline fn generate_legal_moves(board: *const types.Board, list: *lists.MoveList, comptime color: types.Color) void {
    const info = compute_legal_info(board, color);
    generate_legal_moves_with_info(board, list, color, info);
}

/// `generate_legal_moves` for callers that only know the side at runtime.
pub fn generate_legal_moves_rt(board: *const types.Board, list: *lists.MoveList) void {
    switch (board.side) {
        inline .White, .Black => |c| generate_legal_moves(board, list, c),
        .both => unreachable,
    }
}

pub inline fn generate_legal_moves_with_info(board: *const types.Board, list: *lists.MoveList, comptime color: types.Color, info: LegalInfo) void {
    const us = color;
    const them = comptime us.other();

    // Occupancy from compute_legal_info
    const us_bb = info.us_bb;
    const them_bb = info.them_bb;
    const occ = us_bb | them_bb;

    const king_piece = if (us == types.Color.White) types.Piece.WHITE_KING else types.Piece.BLACK_KING;
    const king_bb = board.pieces[@intFromEnum(king_piece)];
    const king_sq: u6 = @intCast(@ctz(king_bb));

    const checkmask = info.checkmask;
    const pin_hv = info.pin_hv;
    const pin_d12 = info.pin_d12;
    const king_ban = info.king_ban;

    // King moves
    {
        const king_atk = attacks.piece_attacks(king_sq, occ, types.PieceType.King);
        // King can go to: attacked squares & not own pieces & not attacked by enemy
        var king_moves = king_atk & ~us_bb & ~king_ban;
        while (king_moves != 0) {
            const to: u6 = @intCast(@ctz(king_moves));
            king_moves &= king_moves - 1;
            const flag = if ((@as(u64, 1) << to) & them_bb != 0) types.MoveFlags.CAPTURE else types.MoveFlags.QUIET;
            list.append(Move.new(king_sq, to, flag));
        }
    }

    // In double check, only king moves are legal
    if (info.num_checkers >= 2) return;

    // Castling, only when not in check
    if (info.num_checkers == 0) {
        if (us == types.Color.White) {
            // White kingside
            if ((board.castle & @intFromEnum(types.Castle.WK)) != 0) {
                if ((occ & 0x60) == 0) { // f1 and g1 empty
                    if ((king_ban & 0x60) == 0) { // f1 and g1 not attacked
                        list.append(Move.new(@intFromEnum(types.square.e1), @intFromEnum(types.square.g1), types.MoveFlags.OO));
                    }
                }
            }
            // White queenside
            if ((board.castle & @intFromEnum(types.Castle.WQ)) != 0) {
                if ((occ & 0xe) == 0) { // b1, c1, d1 empty
                    if ((king_ban & 0xc) == 0) { // c1 and d1 not attacked (b1 doesn't need to be safe)
                        list.append(Move.new(@intFromEnum(types.square.e1), @intFromEnum(types.square.c1), types.MoveFlags.OOO));
                    }
                }
            }
        } else {
            // Black kingside
            if ((board.castle & @intFromEnum(types.Castle.BK)) != 0) {
                if ((occ & 0x6000000000000000) == 0) {
                    if ((king_ban & 0x6000000000000000) == 0) {
                        list.append(Move.new(@intFromEnum(types.square.e8), @intFromEnum(types.square.g8), types.MoveFlags.OO));
                    }
                }
            }
            // Black queenside
            if ((board.castle & @intFromEnum(types.Castle.BQ)) != 0) {
                if ((occ & 0xe00000000000000) == 0) {
                    if ((king_ban & 0xc00000000000000) == 0) {
                        list.append(Move.new(@intFromEnum(types.square.e8), @intFromEnum(types.square.c8), types.MoveFlags.OOO));
                    }
                }
            }
        }
    }

    // Pawns: non-pinned ones with bulk shifts, pinned ones separately
    {
        const pawn_piece = if (us == types.Color.White) types.Piece.WHITE_PAWN else types.Piece.BLACK_PAWN;
        const our_pawns = board.pieces[@intFromEnum(pawn_piece)];

        const empty = ~occ;
        const promo_rank: u64 = if (us == types.Color.White) types.mask_rank[7] else types.mask_rank[0];
        const start_rank: u64 = if (us == types.Color.White) types.mask_rank[1] else types.mask_rank[6];
        const rank3_mask: u64 = if (us == types.Color.White) types.mask_rank[2] else types.mask_rank[5];
        const file_a: u64 = types.mask_file[0];
        const file_h: u64 = types.mask_file[7];

        // Non-pinned pawns
        const free_pawns = our_pawns & ~(pin_hv | pin_d12);

        // Single pushes (non-promo)
        const single_push = if (us == types.Color.White) (free_pawns << 8) & empty else (free_pawns >> 8) & empty;
        var np_pushes = single_push & ~promo_rank & checkmask;
        while (np_pushes != 0) {
            const to: u6 = @intCast(@ctz(np_pushes));
            np_pushes &= np_pushes - 1;
            const from: u6 = if (us == types.Color.White) to - 8 else to + 8;
            list.append(Move.new(from, to, types.MoveFlags.QUIET));
        }

        // Promotion pushes
        var p_pushes = single_push & promo_rank & checkmask;
        while (p_pushes != 0) {
            const to: u6 = @intCast(@ctz(p_pushes));
            p_pushes &= p_pushes - 1;
            const from: u6 = if (us == types.Color.White) to - 8 else to + 8;
            list.append(Move.new(from, to, types.MoveFlags.PR_QUEEN));
            list.append(Move.new(from, to, types.MoveFlags.PR_ROOK));
            list.append(Move.new(from, to, types.MoveFlags.PR_BISHOP));
            list.append(Move.new(from, to, types.MoveFlags.PR_KNIGHT));
        }

        // Double pushes
        var double_push = if (us == types.Color.White)
            ((single_push & rank3_mask) << 8) & empty & checkmask
        else
            ((single_push & rank3_mask) >> 8) & empty & checkmask;
        while (double_push != 0) {
            const to: u6 = @intCast(@ctz(double_push));
            double_push &= double_push - 1;
            const from: u6 = if (us == types.Color.White) to - 16 else to + 16;
            list.append(Move.new(from, to, types.MoveFlags.DOUBLE_PUSH));
        }

        // Left captures
        const left_cap = if (us == types.Color.White)
            ((free_pawns & ~file_a) << 7) & them_bb & checkmask
        else
            ((free_pawns & ~file_h) >> 7) & them_bb & checkmask;
        var np_lcaps = left_cap & ~promo_rank;
        while (np_lcaps != 0) {
            const to: u6 = @intCast(@ctz(np_lcaps));
            np_lcaps &= np_lcaps - 1;
            const from: u6 = if (us == types.Color.White) to - 7 else to + 7;
            list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
        }
        var p_lcaps = left_cap & promo_rank;
        while (p_lcaps != 0) {
            const to: u6 = @intCast(@ctz(p_lcaps));
            p_lcaps &= p_lcaps - 1;
            const from: u6 = if (us == types.Color.White) to - 7 else to + 7;
            list.append(Move.new(from, to, types.MoveFlags.PC_QUEEN));
            list.append(Move.new(from, to, types.MoveFlags.PC_ROOK));
            list.append(Move.new(from, to, types.MoveFlags.PC_BISHOP));
            list.append(Move.new(from, to, types.MoveFlags.PC_KNIGHT));
        }

        // Right captures
        const right_cap = if (us == types.Color.White)
            ((free_pawns & ~file_h) << 9) & them_bb & checkmask
        else
            ((free_pawns & ~file_a) >> 9) & them_bb & checkmask;
        var np_rcaps = right_cap & ~promo_rank;
        while (np_rcaps != 0) {
            const to: u6 = @intCast(@ctz(np_rcaps));
            np_rcaps &= np_rcaps - 1;
            const from: u6 = if (us == types.Color.White) to - 9 else to + 9;
            list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
        }
        var p_rcaps = right_cap & promo_rank;
        while (p_rcaps != 0) {
            const to: u6 = @intCast(@ctz(p_rcaps));
            p_rcaps &= p_rcaps - 1;
            const from: u6 = if (us == types.Color.White) to - 9 else to + 9;
            list.append(Move.new(from, to, types.MoveFlags.PC_QUEEN));
            list.append(Move.new(from, to, types.MoveFlags.PC_ROOK));
            list.append(Move.new(from, to, types.MoveFlags.PC_BISHOP));
            list.append(Move.new(from, to, types.MoveFlags.PC_KNIGHT));
        }

        // Rank/file-pinned pawns can only push along the pin
        {
            const hv_pawns = our_pawns & pin_hv;
            // Push targets must also be on pin_hv (vertically pinned = OK, horizontally = blocked)
            const hv_push = if (us == types.Color.White)
                (hv_pawns << 8) & empty & pin_hv & checkmask
            else
                (hv_pawns >> 8) & empty & pin_hv & checkmask;

            var np_hp = hv_push & ~promo_rank;
            while (np_hp != 0) {
                const to: u6 = @intCast(@ctz(np_hp));
                np_hp &= np_hp - 1;
                const from: u6 = if (us == types.Color.White) to - 8 else to + 8;
                list.append(Move.new(from, to, types.MoveFlags.QUIET));
            }
            var p_hp = hv_push & promo_rank;
            while (p_hp != 0) {
                const to: u6 = @intCast(@ctz(p_hp));
                p_hp &= p_hp - 1;
                const from: u6 = if (us == types.Color.White) to - 8 else to + 8;
                list.append(Move.new(from, to, types.MoveFlags.PR_QUEEN));
                list.append(Move.new(from, to, types.MoveFlags.PR_ROOK));
                list.append(Move.new(from, to, types.MoveFlags.PR_BISHOP));
                list.append(Move.new(from, to, types.MoveFlags.PR_KNIGHT));
            }

            // Double pushes for HV-pinned pawns on start rank
            const hv_start = hv_pawns & start_rank;
            const hv_single = if (us == types.Color.White)
                (hv_start << 8) & empty & pin_hv
            else
                (hv_start >> 8) & empty & pin_hv;
            var hv_double = if (us == types.Color.White)
                (hv_single << 8) & empty & pin_hv & checkmask
            else
                (hv_single >> 8) & empty & pin_hv & checkmask;
            while (hv_double != 0) {
                const to: u6 = @intCast(@ctz(hv_double));
                hv_double &= hv_double - 1;
                const from: u6 = if (us == types.Color.White) to - 16 else to + 16;
                list.append(Move.new(from, to, types.MoveFlags.DOUBLE_PUSH));
            }
        }

        // Diagonally pinned pawns can only capture along the pin
        {
            const d12_pawns = our_pawns & pin_d12;

            // Left captures along pin ray
            const d12_lcap = if (us == types.Color.White)
                ((d12_pawns & ~file_a) << 7) & them_bb & checkmask & pin_d12
            else
                ((d12_pawns & ~file_h) >> 7) & them_bb & checkmask & pin_d12;
            var np_dl = d12_lcap & ~promo_rank;
            while (np_dl != 0) {
                const to: u6 = @intCast(@ctz(np_dl));
                np_dl &= np_dl - 1;
                const from: u6 = if (us == types.Color.White) to - 7 else to + 7;
                list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
            }
            var p_dl = d12_lcap & promo_rank;
            while (p_dl != 0) {
                const to: u6 = @intCast(@ctz(p_dl));
                p_dl &= p_dl - 1;
                const from: u6 = if (us == types.Color.White) to - 7 else to + 7;
                list.append(Move.new(from, to, types.MoveFlags.PC_QUEEN));
                list.append(Move.new(from, to, types.MoveFlags.PC_ROOK));
                list.append(Move.new(from, to, types.MoveFlags.PC_BISHOP));
                list.append(Move.new(from, to, types.MoveFlags.PC_KNIGHT));
            }

            // Right captures along pin ray
            const d12_rcap = if (us == types.Color.White)
                ((d12_pawns & ~file_h) << 9) & them_bb & checkmask & pin_d12
            else
                ((d12_pawns & ~file_a) >> 9) & them_bb & checkmask & pin_d12;
            var np_dr = d12_rcap & ~promo_rank;
            while (np_dr != 0) {
                const to: u6 = @intCast(@ctz(np_dr));
                np_dr &= np_dr - 1;
                const from: u6 = if (us == types.Color.White) to - 9 else to + 9;
                list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
            }
            var p_dr = d12_rcap & promo_rank;
            while (p_dr != 0) {
                const to: u6 = @intCast(@ctz(p_dr));
                p_dr &= p_dr - 1;
                const from: u6 = if (us == types.Color.White) to - 9 else to + 9;
                list.append(Move.new(from, to, types.MoveFlags.PC_QUEEN));
                list.append(Move.new(from, to, types.MoveFlags.PC_ROOK));
                list.append(Move.new(from, to, types.MoveFlags.PC_BISHOP));
                list.append(Move.new(from, to, types.MoveFlags.PC_KNIGHT));
            }
        }

        // En passant
        if (board.enpassant != types.square.NO_SQUARE) {
            const ep_sq: u6 = @intCast(@intFromEnum(board.enpassant));
            const ep_bb = @as(u64, 1) << ep_sq;

            // The captured pawn square (one rank behind the EP target)
            const captured_sq: u6 = if (us == types.Color.White) ep_sq - 8 else ep_sq + 8;
            const captured_bb = @as(u64, 1) << captured_sq;

            // The captured pawn may be the checker, so its square counts for the checkmask
            const ep_checkmask_ok = (ep_bb & checkmask != 0) or (captured_bb & checkmask != 0);

            if (ep_checkmask_ok or info.num_checkers == 0) {
                // Pawns that can capture en passant
                const ep_attackers = attacks.pawn_attacks_from_square(ep_sq, them) & our_pawns;

                var ep_from = ep_attackers;
                while (ep_from != 0) {
                    const from: u6 = @intCast(@ctz(ep_from));
                    ep_from &= ep_from - 1;
                    const from_bb = @as(u64, 1) << from;

                    // Pin check: if the pawn is diagonally pinned, it can only EP along the pin ray
                    if (from_bb & pin_d12 != 0) {
                        if (ep_bb & pin_d12 == 0) continue; // EP target not on pin ray
                    }
                    // If the pawn is HV pinned, it can never capture (diagonal move)
                    if (from_bb & pin_hv != 0) continue;

                    // Removing both pawns from the rank can expose the king to a rook or queen
                    const ep_rank = if (us == types.Color.White) types.mask_rank[4] else types.mask_rank[3];
                    if (king_bb & ep_rank != 0) {
                        const enemy_rq = board.pieces[@intFromEnum(if (them == types.Color.White) types.Piece.WHITE_ROOK else types.Piece.BLACK_ROOK)] |
                            board.pieces[@intFromEnum(if (them == types.Color.White) types.Piece.WHITE_QUEEN else types.Piece.BLACK_QUEEN)];
                        if (enemy_rq & ep_rank != 0) {
                            // Temporarily remove both pawns and check if king sees enemy rook/queen
                            const temp_occ = occ ^ from_bb ^ captured_bb;
                            const king_rook_atk = attacks.get_rook_attacks(king_sq, temp_occ);
                            if (king_rook_atk & enemy_rq & ep_rank != 0) continue;
                        }
                    }

                    list.append(Move.new(from, ep_sq, types.MoveFlags.EN_PASSANT));
                }
            }
        }
    }

    const movable = ~us_bb & checkmask;
    const not_pinned = ~(pin_hv | pin_d12);

    // Knight moves, pinned knights can't move
    {
        const knight_piece = if (us == types.Color.White) types.Piece.WHITE_KNIGHT else types.Piece.BLACK_KNIGHT;
        var our_knights = board.pieces[@intFromEnum(knight_piece)] & not_pinned;

        while (our_knights != 0) {
            const from: u6 = @intCast(@ctz(our_knights));
            our_knights &= our_knights - 1;

            var targets = attacks.piece_attacks(from, 0, types.PieceType.Knight) & movable;
            while (targets != 0) {
                const to: u6 = @intCast(@ctz(targets));
                targets &= targets - 1;
                const flag = if ((@as(u64, 1) << to) & them_bb != 0) types.MoveFlags.CAPTURE else types.MoveFlags.QUIET;
                list.append(Move.new(from, to, flag));
            }
        }
    }

    // Pinned sliders can only move along their pin ray
    {
        const bishop_piece = if (us == types.Color.White) types.Piece.WHITE_BISHOP else types.Piece.BLACK_BISHOP;
        const rook_piece = if (us == types.Color.White) types.Piece.WHITE_ROOK else types.Piece.BLACK_ROOK;
        const queen_piece = if (us == types.Color.White) types.Piece.WHITE_QUEEN else types.Piece.BLACK_QUEEN;

        // Rooks and queens pinned on a rank or file
        var hv_pinned = (board.pieces[@intFromEnum(rook_piece)] | board.pieces[@intFromEnum(queen_piece)]) & pin_hv;
        while (hv_pinned != 0) {
            const from: u6 = @intCast(@ctz(hv_pinned));
            hv_pinned &= hv_pinned - 1;
            var targets = attacks.get_rook_attacks(from, occ) & movable & pin_hv;
            while (targets != 0) {
                const to: u6 = @intCast(@ctz(targets));
                targets &= targets - 1;
                const flag = if ((@as(u64, 1) << to) & them_bb != 0) types.MoveFlags.CAPTURE else types.MoveFlags.QUIET;
                list.append(Move.new(from, to, flag));
            }
        }

        // Bishops and queens pinned on a diagonal
        var d12_pinned = (board.pieces[@intFromEnum(bishop_piece)] | board.pieces[@intFromEnum(queen_piece)]) & pin_d12;
        while (d12_pinned != 0) {
            const from: u6 = @intCast(@ctz(d12_pinned));
            d12_pinned &= d12_pinned - 1;
            var targets = attacks.get_bishop_attacks(from, occ) & movable & pin_d12;
            while (targets != 0) {
                const to: u6 = @intCast(@ctz(targets));
                targets &= targets - 1;
                const flag = if ((@as(u64, 1) << to) & them_bb != 0) types.MoveFlags.CAPTURE else types.MoveFlags.QUIET;
                list.append(Move.new(from, to, flag));
            }
        }
    }

    // Non-pinned bishops and queens
    {
        const bishop_piece = if (us == types.Color.White) types.Piece.WHITE_BISHOP else types.Piece.BLACK_BISHOP;
        const queen_piece = if (us == types.Color.White) types.Piece.WHITE_QUEEN else types.Piece.BLACK_QUEEN;
        var diag_sliders = (board.pieces[@intFromEnum(bishop_piece)] | board.pieces[@intFromEnum(queen_piece)]) & not_pinned;
        while (diag_sliders != 0) {
            const from: u6 = @intCast(@ctz(diag_sliders));
            diag_sliders &= diag_sliders - 1;
            var targets = attacks.get_bishop_attacks(from, occ) & movable;
            while (targets != 0) {
                const to: u6 = @intCast(@ctz(targets));
                targets &= targets - 1;
                const flag = if ((@as(u64, 1) << to) & them_bb != 0) types.MoveFlags.CAPTURE else types.MoveFlags.QUIET;
                list.append(Move.new(from, to, flag));
            }
        }
    }

    // Non-pinned rooks and queens
    {
        const rook_piece = if (us == types.Color.White) types.Piece.WHITE_ROOK else types.Piece.BLACK_ROOK;
        const queen_piece = if (us == types.Color.White) types.Piece.WHITE_QUEEN else types.Piece.BLACK_QUEEN;
        var orth_sliders = (board.pieces[@intFromEnum(rook_piece)] | board.pieces[@intFromEnum(queen_piece)]) & not_pinned;
        while (orth_sliders != 0) {
            const from: u6 = @intCast(@ctz(orth_sliders));
            orth_sliders &= orth_sliders - 1;
            var targets = attacks.get_rook_attacks(from, occ) & movable;
            while (targets != 0) {
                const to: u6 = @intCast(@ctz(targets));
                targets &= targets - 1;
                const flag = if ((@as(u64, 1) << to) & them_bb != 0) types.MoveFlags.CAPTURE else types.MoveFlags.QUIET;
                list.append(Move.new(from, to, flag));
            }
        }
    }
}

/// Generate legal captures and promotions for qsearch.
pub fn generate_legal_captures(board: *const types.Board, list: *lists.MoveList, comptime color: types.Color) void {
    const info = compute_legal_info(board, color);
    const us = color;
    const them = comptime us.other();

    // Occupancy from compute_legal_info
    const us_bb = info.us_bb;
    const them_bb = info.them_bb;
    const occ = us_bb | them_bb;

    const king_piece = if (us == types.Color.White) types.Piece.WHITE_KING else types.Piece.BLACK_KING;
    const king_bb = board.pieces[@intFromEnum(king_piece)];
    const king_sq: u6 = @intCast(@ctz(king_bb));

    const checkmask = info.checkmask;
    const pin_hv = info.pin_hv;
    const pin_d12 = info.pin_d12;
    const king_ban = info.king_ban;

    // King captures
    {
        const king_atk = attacks.piece_attacks(king_sq, occ, types.PieceType.King);
        var king_caps = king_atk & them_bb & ~king_ban;
        while (king_caps != 0) {
            const to: u6 = @intCast(@ctz(king_caps));
            king_caps &= king_caps - 1;
            list.append(Move.new(king_sq, to, types.MoveFlags.CAPTURE));
        }
    }

    if (info.num_checkers >= 2) return;

    const movable_captures = them_bb & checkmask;

    // Pawn captures and promotions
    {
        const pawn_piece = if (us == types.Color.White) types.Piece.WHITE_PAWN else types.Piece.BLACK_PAWN;
        const our_pawns = board.pieces[@intFromEnum(pawn_piece)];
        const file_a: u64 = types.mask_file[0];
        const file_h: u64 = types.mask_file[7];
        const promo_rank: u64 = if (us == types.Color.White) types.mask_rank[7] else types.mask_rank[0];
        const empty = ~occ;

        // Non-pinned pawn captures
        const free_pawns = our_pawns & ~(pin_hv | pin_d12);

        // Left captures
        const left_cap = if (us == types.Color.White)
            ((free_pawns & ~file_a) << 7) & movable_captures
        else
            ((free_pawns & ~file_h) >> 7) & movable_captures;
        var np_lcaps = left_cap & ~promo_rank;
        while (np_lcaps != 0) {
            const to: u6 = @intCast(@ctz(np_lcaps));
            np_lcaps &= np_lcaps - 1;
            const from: u6 = if (us == types.Color.White) to - 7 else to + 7;
            list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
        }
        var p_lcaps = left_cap & promo_rank;
        while (p_lcaps != 0) {
            const to: u6 = @intCast(@ctz(p_lcaps));
            p_lcaps &= p_lcaps - 1;
            const from: u6 = if (us == types.Color.White) to - 7 else to + 7;
            list.append(Move.new(from, to, types.MoveFlags.PC_QUEEN));
            list.append(Move.new(from, to, types.MoveFlags.PC_ROOK));
            list.append(Move.new(from, to, types.MoveFlags.PC_BISHOP));
            list.append(Move.new(from, to, types.MoveFlags.PC_KNIGHT));
        }

        // Right captures
        const right_cap = if (us == types.Color.White)
            ((free_pawns & ~file_h) << 9) & movable_captures
        else
            ((free_pawns & ~file_a) >> 9) & movable_captures;
        var np_rcaps = right_cap & ~promo_rank;
        while (np_rcaps != 0) {
            const to: u6 = @intCast(@ctz(np_rcaps));
            np_rcaps &= np_rcaps - 1;
            const from: u6 = if (us == types.Color.White) to - 9 else to + 9;
            list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
        }
        var p_rcaps = right_cap & promo_rank;
        while (p_rcaps != 0) {
            const to: u6 = @intCast(@ctz(p_rcaps));
            p_rcaps &= p_rcaps - 1;
            const from: u6 = if (us == types.Color.White) to - 9 else to + 9;
            list.append(Move.new(from, to, types.MoveFlags.PC_QUEEN));
            list.append(Move.new(from, to, types.MoveFlags.PC_ROOK));
            list.append(Move.new(from, to, types.MoveFlags.PC_BISHOP));
            list.append(Move.new(from, to, types.MoveFlags.PC_KNIGHT));
        }

        // D12-pinned pawn captures along pin ray
        {
            const d12_pawns = our_pawns & pin_d12;
            const d12_lcap = if (us == types.Color.White)
                ((d12_pawns & ~file_a) << 7) & movable_captures & pin_d12
            else
                ((d12_pawns & ~file_h) >> 7) & movable_captures & pin_d12;
            var np_dl = d12_lcap & ~promo_rank;
            while (np_dl != 0) {
                const to: u6 = @intCast(@ctz(np_dl));
                np_dl &= np_dl - 1;
                const from: u6 = if (us == types.Color.White) to - 7 else to + 7;
                list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
            }
            var p_dl = d12_lcap & promo_rank;
            while (p_dl != 0) {
                const to: u6 = @intCast(@ctz(p_dl));
                p_dl &= p_dl - 1;
                const from: u6 = if (us == types.Color.White) to - 7 else to + 7;
                list.append(Move.new(from, to, types.MoveFlags.PC_QUEEN));
                list.append(Move.new(from, to, types.MoveFlags.PC_ROOK));
                list.append(Move.new(from, to, types.MoveFlags.PC_BISHOP));
                list.append(Move.new(from, to, types.MoveFlags.PC_KNIGHT));
            }

            const d12_rcap = if (us == types.Color.White)
                ((d12_pawns & ~file_h) << 9) & movable_captures & pin_d12
            else
                ((d12_pawns & ~file_a) >> 9) & movable_captures & pin_d12;
            var np_dr = d12_rcap & ~promo_rank;
            while (np_dr != 0) {
                const to: u6 = @intCast(@ctz(np_dr));
                np_dr &= np_dr - 1;
                const from: u6 = if (us == types.Color.White) to - 9 else to + 9;
                list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
            }
            var p_dr = d12_rcap & promo_rank;
            while (p_dr != 0) {
                const to: u6 = @intCast(@ctz(p_dr));
                p_dr &= p_dr - 1;
                const from: u6 = if (us == types.Color.White) to - 9 else to + 9;
                list.append(Move.new(from, to, types.MoveFlags.PC_QUEEN));
                list.append(Move.new(from, to, types.MoveFlags.PC_ROOK));
                list.append(Move.new(from, to, types.MoveFlags.PC_BISHOP));
                list.append(Move.new(from, to, types.MoveFlags.PC_KNIGHT));
            }
        }

        // Promotion pushes (non-capture promotions are tactical)
        {
            // Non-pinned promotion pushes
            const free_push = if (us == types.Color.White) (free_pawns << 8) & empty else (free_pawns >> 8) & empty;
            var promos = free_push & checkmask & promo_rank;
            while (promos != 0) {
                const to: u6 = @intCast(@ctz(promos));
                promos &= promos - 1;
                const from: u6 = if (us == types.Color.White) to - 8 else to + 8;
                list.append(Move.new(from, to, types.MoveFlags.PR_QUEEN));
                list.append(Move.new(from, to, types.MoveFlags.PR_ROOK));
                list.append(Move.new(from, to, types.MoveFlags.PR_BISHOP));
                list.append(Move.new(from, to, types.MoveFlags.PR_KNIGHT));
            }
            // HV-pinned promotion pushes (vertically pinned can push to promo rank)
            const hv_pawns = our_pawns & pin_hv;
            const hv_push = if (us == types.Color.White)
                (hv_pawns << 8) & empty & pin_hv & checkmask
            else
                (hv_pawns >> 8) & empty & pin_hv & checkmask;
            var hv_promos = hv_push & promo_rank;
            while (hv_promos != 0) {
                const to: u6 = @intCast(@ctz(hv_promos));
                hv_promos &= hv_promos - 1;
                const from: u6 = if (us == types.Color.White) to - 8 else to + 8;
                list.append(Move.new(from, to, types.MoveFlags.PR_QUEEN));
                list.append(Move.new(from, to, types.MoveFlags.PR_ROOK));
                list.append(Move.new(from, to, types.MoveFlags.PR_BISHOP));
                list.append(Move.new(from, to, types.MoveFlags.PR_KNIGHT));
            }
        }

        // En passant
        if (board.enpassant != types.square.NO_SQUARE) {
            const ep_sq: u6 = @intCast(@intFromEnum(board.enpassant));
            const ep_bb = @as(u64, 1) << ep_sq;
            const captured_sq: u6 = if (us == types.Color.White) ep_sq - 8 else ep_sq + 8;
            const captured_bb = @as(u64, 1) << captured_sq;

            const ep_checkmask_ok = (ep_bb & checkmask != 0) or (captured_bb & checkmask != 0);
            if (ep_checkmask_ok or info.num_checkers == 0) {
                const ep_attackers = attacks.pawn_attacks_from_square(ep_sq, them) & our_pawns;
                var ep_from = ep_attackers;
                while (ep_from != 0) {
                    const from: u6 = @intCast(@ctz(ep_from));
                    ep_from &= ep_from - 1;
                    const from_bb = @as(u64, 1) << from;

                    if (from_bb & pin_d12 != 0) {
                        if (ep_bb & pin_d12 == 0) continue;
                    }
                    if (from_bb & pin_hv != 0) continue;

                    const ep_rank = if (us == types.Color.White) types.mask_rank[4] else types.mask_rank[3];
                    if (king_bb & ep_rank != 0) {
                        const enemy_rq = board.pieces[@intFromEnum(if (them == types.Color.White) types.Piece.WHITE_ROOK else types.Piece.BLACK_ROOK)] |
                            board.pieces[@intFromEnum(if (them == types.Color.White) types.Piece.WHITE_QUEEN else types.Piece.BLACK_QUEEN)];
                        if (enemy_rq & ep_rank != 0) {
                            const temp_occ = occ ^ from_bb ^ captured_bb;
                            const king_rook_atk = attacks.get_rook_attacks(king_sq, temp_occ);
                            if (king_rook_atk & enemy_rq & ep_rank != 0) continue;
                        }
                    }
                    list.append(Move.new(from, ep_sq, types.MoveFlags.EN_PASSANT));
                }
            }
        }
    }

    const not_pinned = ~(pin_hv | pin_d12);

    // Knight captures
    {
        const knight_piece = if (us == types.Color.White) types.Piece.WHITE_KNIGHT else types.Piece.BLACK_KNIGHT;
        var our_knights = board.pieces[@intFromEnum(knight_piece)] & not_pinned;
        while (our_knights != 0) {
            const from: u6 = @intCast(@ctz(our_knights));
            our_knights &= our_knights - 1;
            var targets = attacks.piece_attacks(from, 0, types.PieceType.Knight) & movable_captures;
            while (targets != 0) {
                const to: u6 = @intCast(@ctz(targets));
                targets &= targets - 1;
                list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
            }
        }
    }

    // Pinned slider captures
    {
        const bishop_piece = if (us == types.Color.White) types.Piece.WHITE_BISHOP else types.Piece.BLACK_BISHOP;
        const rook_piece = if (us == types.Color.White) types.Piece.WHITE_ROOK else types.Piece.BLACK_ROOK;
        const queen_piece = if (us == types.Color.White) types.Piece.WHITE_QUEEN else types.Piece.BLACK_QUEEN;

        var hv_pinned = (board.pieces[@intFromEnum(rook_piece)] | board.pieces[@intFromEnum(queen_piece)]) & pin_hv;
        while (hv_pinned != 0) {
            const from: u6 = @intCast(@ctz(hv_pinned));
            hv_pinned &= hv_pinned - 1;
            var targets = attacks.get_rook_attacks(from, occ) & movable_captures & pin_hv;
            while (targets != 0) {
                const to: u6 = @intCast(@ctz(targets));
                targets &= targets - 1;
                list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
            }
        }
        var d12_pinned = (board.pieces[@intFromEnum(bishop_piece)] | board.pieces[@intFromEnum(queen_piece)]) & pin_d12;
        while (d12_pinned != 0) {
            const from: u6 = @intCast(@ctz(d12_pinned));
            d12_pinned &= d12_pinned - 1;
            var targets = attacks.get_bishop_attacks(from, occ) & movable_captures & pin_d12;
            while (targets != 0) {
                const to: u6 = @intCast(@ctz(targets));
                targets &= targets - 1;
                list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
            }
        }
    }

    // Non-pinned diagonal slider captures (bishops + queens)
    {
        const bishop_piece = if (us == types.Color.White) types.Piece.WHITE_BISHOP else types.Piece.BLACK_BISHOP;
        const queen_piece = if (us == types.Color.White) types.Piece.WHITE_QUEEN else types.Piece.BLACK_QUEEN;
        var diag_sliders = (board.pieces[@intFromEnum(bishop_piece)] | board.pieces[@intFromEnum(queen_piece)]) & not_pinned;
        while (diag_sliders != 0) {
            const from: u6 = @intCast(@ctz(diag_sliders));
            diag_sliders &= diag_sliders - 1;
            var targets = attacks.get_bishop_attacks(from, occ) & movable_captures;
            while (targets != 0) {
                const to: u6 = @intCast(@ctz(targets));
                targets &= targets - 1;
                list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
            }
        }
    }

    // Non-pinned orthogonal slider captures (rooks + queens)
    {
        const rook_piece = if (us == types.Color.White) types.Piece.WHITE_ROOK else types.Piece.BLACK_ROOK;
        const queen_piece = if (us == types.Color.White) types.Piece.WHITE_QUEEN else types.Piece.BLACK_QUEEN;
        var orth_sliders = (board.pieces[@intFromEnum(rook_piece)] | board.pieces[@intFromEnum(queen_piece)]) & not_pinned;
        while (orth_sliders != 0) {
            const from: u6 = @intCast(@ctz(orth_sliders));
            orth_sliders &= orth_sliders - 1;
            var targets = attacks.get_rook_attacks(from, occ) & movable_captures;
            while (targets != 0) {
                const to: u6 = @intCast(@ctz(targets));
                targets &= targets - 1;
                list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
            }
        }
    }
}
