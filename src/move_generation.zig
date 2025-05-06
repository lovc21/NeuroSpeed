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

    // ---- Pawn moves & en-passant ----
    const pawn_piece = if (us == types.Color.White) types.Piece.WHITE_PAWN else types.Piece.BLACK_PAWN;
    var b: u64 = board.pieces[@intFromEnum(pawn_piece)];
    while (b != 0) {
        const from_idx = util.lsb_index(b);
        const from: u6 = @intCast(from_idx);
        b &= b - 1;
        const from_bb = types.squar_bb_rotated[from];

        // single push
        const dir: u64 = if (us == types.Color.White) from_bb << 32 else from_bb >> 32;
        if ((dir & occ) == 0) {
            const to_idx = util.lsb_index(dir);
            const to: u6 = @intCast(to_idx);
            // promotion rank
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
                    const dir2 = if (us == types.Color.White) from_bb << 24 else from_bb >> 24;
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
            if ((types.squar_bb_rotated[to] & types.mask_rank[if (us == types.Color.White) 6 else 1]) != 0) {
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
            if ((attacks.pawn_attacks_from_bitboard(us, from_bb) & ep_bb) != 0) {
                list.append(Move.new(from, ep_sq, types.MoveFlags.EN_PASSANT));
            }
        }
    }
}
