const std = @import("std");
const types = @import("types.zig");
const attacks = @import("attacks.zig");
const lists = @import("lists.zig");
const util = @import("util.zig");
const bitboard = @import("bitboard.zig");
const move_gen = @import("move.zig");
const search = @import("search.zig");
const print = std.debug.print;

// MVV_LVA table - victim_value[attacker_type]
pub const MVV_LVA = [6][6]i32{
    // zig fmt: off
    //  P    N    B    R    Q    K
    .{ 105, 104, 103, 102, 101, 100 }, // Pawn victim
    .{ 305, 304, 303, 302, 301, 300 }, // Knight victim
    .{ 305, 304, 303, 302, 301, 300 }, // Bishop victim
    .{ 505, 504, 503, 502, 501, 500 }, // Rook victim
    .{ 905, 904, 903, 902, 901, 900 }, // Queen victim
    .{2005,2004,2003,2002,2001,2000 }, // King victim
    // zig fmt: on
};

// Piece values for SEE
const PIECE_VALUES = [7]i32{ 100, 320, 330, 500, 900, 20000, 0 };

// Score constants
const SCORE_PROMOTION_QUEEN_CAPTURE = 9000000;
const SCORE_PROMOTION_CAPTURE = 8000000;
const SCORE_GOOD_CAPTURE = 7000000;
const SCORE_PROMOTION_QUEEN = 6000000;
const SCORE_PROMOTION = 5000000;
pub const SCORE_BAD_CAPTURE = -1000000;
const SCORE_KILLER = 90000;
const SCORE_KILLER_2 = 80000;
const SCORE_COUNTERMOVE = 50000;
const MAX_LOOP_COUNT = 32;
const SCORE_PV_MOVE = 10000000;

const VL = lists.VL;
const ScoreVec = @Vector(VL, i32);
const LaneMask = std.meta.Int(.unsigned, VL);
// Scores at or above this tie: the first such move in list order is picked (TT move or queen promo capture).
const SCORE_FORCED: ScoreVec = @splat(SCORE_PROMOTION_QUEEN_CAPTURE);

// Swap the best remaining move into slot i: vector max over the tail, then the first lane that hits it.
pub inline fn get_next_best_move(move_list: *lists.MoveList, score_list: *lists.ScoreList, i: usize) move_gen.Move {
    const count = score_list.count;
    const scores = &score_list.scores;
    if (i + 1 >= count or scores[i] >= SCORE_PROMOTION_QUEEN_CAPTURE) return move_list.moves[i];

    var vmax: ScoreVec = @splat(std.math.minInt(i32));
    var j = i;
    while (j < count) : (j += VL) vmax = @max(vmax, @min(@as(ScoreVec, scores[j..][0..VL].*), SCORE_FORCED));
    const best: ScoreVec = @splat(@reduce(.Max, vmax));

    var best_j = i;
    while (true) : (best_j += VL) {
        const hit: LaneMask = @bitCast(@min(@as(ScoreVec, scores[best_j..][0..VL].*), SCORE_FORCED) == best);
        if (hit != 0) {
            best_j += @ctz(hit);
            break;
        }
    }

    if (best_j != i) {
        std.mem.swap(move_gen.Move, &move_list.moves[i], &move_list.moves[best_j]);
        std.mem.swap(i32, &scores[i], &scores[best_j]);
    }
    return move_list.moves[i];
}

pub inline fn score_move(board: *types.Board, move_list: *lists.MoveList, score_list: *lists.ScoreList, pv_move: move_gen.Move, countermove: move_gen.Move) void {
    score_list.count = 0;

    for (0..move_list.count) |i| {
        const move = move_list.moves[i];
        var score: i32 = 0;

        if (!pv_move.is_empty() and move.eql(pv_move)) {
            // Keep the TT/PV move first.
            score = SCORE_PV_MOVE;
            // Promotions with capture
        } else if (move.is_promotion() and move.is_capture()) {
            if (move.flags == types.MoveFlags.PC_QUEEN) {
                score = SCORE_PROMOTION_QUEEN_CAPTURE;
            } else {
                score = SCORE_PROMOTION_CAPTURE + @as(i32, @intFromEnum(move.flags));
            }
            // En passant
        } else if (move.flags == types.MoveFlags.EN_PASSANT) {
            score = SCORE_GOOD_CAPTURE + 105;

            // Captures
        } else if (move.is_capture()) {
            const victim_type: ?types.PieceType = types.Board.get_piece_type_at(board, move.to);
            const attacker_type: ?types.PieceType = types.Board.get_piece_type_at(board, move.from);
            if (attacker_type == null) {
                print("DEBUG: Board state when attacker is null:\n", .{});
                bitboard.print_unicode_board(board.*);
                print("Move: {} to {}, flags: {}\n", .{ move.from, move.to, move.flags });
            }

            if (victim_type != null and attacker_type != null) {
                // SEE >= 0 captures go above killers, losing ones below quiets.
                if (see(board, move, 0)) {
                    score = SCORE_GOOD_CAPTURE + MVV_LVA[@intFromEnum(victim_type.?)][@intFromEnum(attacker_type.?)];
                } else {
                    score = SCORE_BAD_CAPTURE + MVV_LVA[@intFromEnum(victim_type.?)][@intFromEnum(attacker_type.?)];
                }
            } else {
                print("ERROR: Unknown capture move type - victim: {?}, attacker: {?}, flags: {}\n", .{ victim_type, attacker_type, move.flags });
                score = SCORE_BAD_CAPTURE;
            }
        }
        // Quiet promotions
        else if (move.is_promotion()) {
            if (move.flags == types.MoveFlags.PR_QUEEN) {
                score = SCORE_PROMOTION_QUEEN;
            } else {
                score = SCORE_PROMOTION - (4 - @as(i32, @intFromEnum(move.flags))) * 100000;
            }
        }
        // Castling
        else if (move.flags == types.MoveFlags.OO or move.flags == types.MoveFlags.OOO) {
            // Better than quiet moves
            score = 100000;
        }

        // Quiet moves
        else {
            // dis_* are ablation switches, all 0 by default.
            // score first killer move
            if (search.params.dis_ordhist == 0 and
                move_list.moves[i].eql(search.global_search.killer_moves[0][search.global_search.ply]))
            {
                score = SCORE_KILLER;
                // score second killer move
            } else if (search.params.dis_ordhist == 0 and
                move_list.moves[i].eql(search.global_search.killer_moves[1][search.global_search.ply]))
            {
                score = SCORE_KILLER_2;
                // score countermove
            } else if (search.params.dis_counter == 0 and
                !countermove.is_empty() and move.eql(countermove))
            {
                score = SCORE_COUNTERMOVE;
                // score history + continuation history
            } else {
                if (search.params.dis_ordhist == 0) {
                    score = search.global_search.history_moves[move.from][move.to];
                }

                // Add continuation history (counter + follow) for move ordering
                if (search.params.dis_conthist == 0) {
                    const cur_pt_opt = board.get_piece_type_at(move.from);
                    if (cur_pt_opt) |cur_pt_enum| {
                        const cur_pt: u4 = @intCast(@intFromEnum(cur_pt_enum));
                        const ply = search.global_search.ply;
                        if (ply >= 1) {
                            const sm = search.global_search.stack_moves[ply - 1];
                            if (!sm.is_empty()) {
                                const pp = search.global_search.stack_pieces[ply - 1];
                                if (pp < 6) {
                                    score += search.global_search.sc_counter_table[pp][sm.to][cur_pt][move.to];
                                }
                            }
                        }
                        if (ply >= 2) {
                            const sm2 = search.global_search.stack_moves[ply - 2];
                            if (!sm2.is_empty()) {
                                const gpp = search.global_search.stack_pieces[ply - 2];
                                if (gpp < 6) {
                                    score += search.global_search.sc_follow_table[gpp][sm2.to][cur_pt][move.to];
                                }
                            }
                        }
                    }
                }
            }
        }
        score_list.append(score);
    }
    // One vector of -inf after the last score so the picker never needs a tail mask.
    score_list.scores[score_list.count..][0..VL].* = @splat(std.math.minInt(i32));
}

pub fn see(board: *const types.Board, move: move_gen.Move, threshold: i32) bool {
    // Promotions are always considered good
    if (move.is_promotion()) {
        return true;
    }

    const from = move.from;
    const to = move.to;

    // Get the piece being captured
    const target_piece_type: ?types.PieceType = board.get_piece_type_at(to);
    var value: i32 = 0;

    if (target_piece_type) |victim| {
        value = PIECE_VALUES[@intFromEnum(victim)] - threshold;
    } else if (move.flags == types.MoveFlags.EN_PASSANT) {
        value = PIECE_VALUES[0] - threshold; // Pawn value
    } else {
        return false; // No capture
    }

    if (value < 0) {
        return false;
    }

    // Get the attacking piece
    const attacker_piece_type = board.get_piece_type_at(from) orelse return false;
    value -= PIECE_VALUES[@intFromEnum(attacker_piece_type)];

    if (value >= 0) {
        return true;
    }

    // Set up the board state after the initial capture
    var occupied = board.pieces_combined() ^ types.square_bb[from];

    if (move.flags == types.MoveFlags.EN_PASSANT) {
        const ep_capture_sq: u6 = if (board.side == types.Color.White) to - 8 else to + 8;
        occupied ^= types.square_bb[ep_capture_sq];
    }

    // Get all attackers to the target square
    var attackers = bitboard.get_all_attackers(board, to, occupied);

    // Remove the initial attacker from the attackers list
    attackers &= ~types.square_bb[from];

    // Get diagonal and orthogonal sliders for x-ray attacks
    const bishops_queens = (board.pieces[@intFromEnum(types.Piece.WHITE_BISHOP)] |
        board.pieces[@intFromEnum(types.Piece.BLACK_BISHOP)] |
        board.pieces[@intFromEnum(types.Piece.WHITE_QUEEN)] |
        board.pieces[@intFromEnum(types.Piece.BLACK_QUEEN)]);

    const rooks_queens = (board.pieces[@intFromEnum(types.Piece.WHITE_ROOK)] |
        board.pieces[@intFromEnum(types.Piece.BLACK_ROOK)] |
        board.pieces[@intFromEnum(types.Piece.WHITE_QUEEN)] |
        board.pieces[@intFromEnum(types.Piece.BLACK_QUEEN)]);

    var side: types.Color = if (board.get_piece_color_at(from)) |c| c.other() else .Black;
    var loop_count: u8 = 0;

    // Exchange sequence
    while (attackers != 0 and loop_count < MAX_LOOP_COUNT) {
        loop_count += 1;

        attackers &= occupied;

        const side_mask = if (side == types.Color.White) board.set_pieces(.White) else board.set_pieces(.Black);
        const my_attackers = attackers & side_mask;

        if (my_attackers == 0) {
            break;
        }

        // Cheapest attacker: the first non-empty piece type in P N B R Q K order.
        var attacker_sq: u6 = 0;
        var attacker_piece_val: i32 = PIECE_VALUES[5];
        var found = false;
        const base: usize = @as(usize, side.toU4()) * 8;
        for (0..6) |t| {
            const piece_attackers = my_attackers & board.pieces[base + t];
            if (piece_attackers != 0) {
                attacker_sq = @intCast(@ctz(piece_attackers));
                attacker_piece_val = PIECE_VALUES[t];
                found = true;
                break;
            }
        }
        if (!found) break;

        // Switch sides
        side = side.other();

        // Update the value (negamax style)
        value = -value - 1 - attacker_piece_val;

        // Pruning - if this side can stand pat with value >= 0, the exchange is decided
        if (value >= 0) {
            return side != board.get_piece_color_at(move.from).?;
        }

        // Remove the attacker from occupied squares
        occupied ^= types.square_bb[attacker_sq];

        // Add x-ray attacks if necessary
        const piece_type = board.get_piece_type_at(attacker_sq);
        if (piece_type != null) {
            switch (piece_type.?) {
                .Pawn, .Bishop, .Queen => {
                    attackers |= attacks.get_bishop_attacks(to, occupied) & bishops_queens;
                },
                .Rook => {
                    attackers |= attacks.get_rook_attacks(to, occupied) & rooks_queens;
                },
                else => {},
            }

            if (piece_type.? == .Queen) {
                attackers |= attacks.get_rook_attacks(to, occupied) & rooks_queens;
            }
        }
    }

    return side != board.get_piece_color_at(move.from).?;
}
