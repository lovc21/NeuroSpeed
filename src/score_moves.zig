const std = @import("std");
const types = @import("types.zig");
const attacks = @import("attacks.zig");
const lists = @import("lists.zig");
const util = @import("util.zig");
const bitboard = @import("bitboard.zig");
const eval = @import("evaluation.zig");
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

const SEE_THRESHOLD = -98;

// Piece values for SEE
const PIECE_VALUES = [7]i32{ 100, 320, 330, 500, 900, 20000, 0 };

// Score constants
const SCORE_PROMOTION_QUEEN_CAPTURE = 9000000;
const SCORE_PROMOTION_CAPTURE = 8000000;
const SCORE_GOOD_CAPTURE = 7000000;
const SCORE_PROMOTION_QUEEN = 6000000;
const SCORE_PROMOTION = 5000000;
const SCORE_EQUAL_CAPTURE = 4000000;
const SCORE_QUIET = 0;
const SCORE_BAD_CAPTURE = -1000000;
const SCORE_KILLER = 90000;
const SCORE_KILLER_2 = 80000;
const SCORE_COUNTERMOVE = 50000;
const MAX_LOOP_COUNT = 32;
const SCORE_PV_MOVE = 10000000;

//TODO this can be optimized with a scored move list
pub inline fn get_next_best_move(move_list: *lists.MoveList, score_list: *lists.ScoreList, i: usize) move_gen.Move {
    const count = score_list.count;
    if (i + 1 >= count) return move_list.moves[i];
    
    var best_j = i;
    var max_score = score_list.scores[i];
    
    if (max_score >= 9000000) {
        return move_list.moves[i];
    }

    const start = i + 1;
    const end = count;
    
    for (start..end) |j| {
        const score = score_list.scores[j];
        if (score > max_score) {
            best_j = j;
            max_score = score;
            
            if (score >= 9000000) break;
        }
    }
    
    if (best_j != i) {
        const temp_move = move_list.moves[i];
        const temp_score = score_list.scores[i];
        
        move_list.moves[i] = move_list.moves[best_j];
        score_list.scores[i] = score_list.scores[best_j];
        
        move_list.moves[best_j] = temp_move;
        score_list.scores[best_j] = temp_score;
    }
    
    return move_list.moves[i];
}

pub inline fn score_move(board: *types.Board, move_list: *lists.MoveList, score_list: *lists.ScoreList, pv_move: move_gen.Move, countermove: move_gen.Move) void {
    score_list.count = 0;
    
    for (0..move_list.count) |i| {
        const move = move_list.moves[i];
        var score: i32 = 0;
       
        if (!pv_move.is_empty() and moves_equal(move, pv_move)) {
            score = SCORE_PV_MOVE;
        }

        // 1. Promotions with capture
        if (move.is_promotion() and move.is_capture()) {
            if (move.flags == types.MoveFlags.PC_QUEEN) {
                score = SCORE_PROMOTION_QUEEN_CAPTURE;
            } else {
                score = SCORE_PROMOTION_CAPTURE + @as(i32, @intFromEnum(move.flags));
            }
        // 2. En passant Captures
        }else if (move.flags == types.MoveFlags.EN_PASSANT) {
            score = SCORE_GOOD_CAPTURE + 105;
        
        // 2. Captures
        }else if (move.is_capture()) {
            const victim_type: ?types.PieceType =  types.Board.get_piece_type_at(board, move.to);
            const attacker_type: ?types.PieceType =  types.Board.get_piece_type_at(board, move.from);
                if (attacker_type == null) {
                    print("DEBUG: Board state when attacker is null:\n",.{});
                    bitboard.print_unicode_board(board.*);
                    print("Move: {} to {}, flags: {}\n", .{move.from, move.to, move.flags});
                }

            if (victim_type != null and attacker_type != null) {
                
                if (see(board, move, SEE_THRESHOLD)) {
                    // Good capture
                    score = SCORE_GOOD_CAPTURE + MVV_LVA[@intFromEnum(victim_type.?)][@intFromEnum(attacker_type.?)];
                } else if (see(board, move, -100)) {
                    // Equal trade
                    score = SCORE_EQUAL_CAPTURE + MVV_LVA[@intFromEnum(victim_type.?)][@intFromEnum(attacker_type.?)];
                } else {
                    // Bad capture
                    score = SCORE_BAD_CAPTURE - MVV_LVA[@intFromEnum(victim_type.?)][@intFromEnum(attacker_type.?)];
                }
            // En passant capture
            }else {
                print("ERROR: Unknown capture move type - victim: {?}, attacker: {?}, flags: {}\n", 
                      .{victim_type, attacker_type, move.flags});
                score = SCORE_BAD_CAPTURE;
            }
        }
        // 3. Promotions without capture
        else if (move.is_promotion()) {
            if (move.flags == types.MoveFlags.PR_QUEEN) {
                score = SCORE_PROMOTION_QUEEN;
            } else {
                score = SCORE_PROMOTION - (4 - @as(i32, @intFromEnum(move.flags))) * 100000;
            }
        }
        // 4. Castling
        else if (move.flags == types.MoveFlags.OO or move.flags == types.MoveFlags.OOO) {
            // Better than quiet moves
            score = 100000;
        }
        
        //5. Quiet moves gets a score of 0
        else {
            // score first killer move
            if (std.meta.eql(move_list.moves[i] ,search.global_search.killer_moves[0][search.global_search.ply])) {
                score = SCORE_KILLER;
            // score second killer move
            } else if (std.meta.eql(move_list.moves[i],search.global_search.killer_moves[1][search.global_search.ply])) {
                score = SCORE_KILLER_2;
            // score countermove
            } else if (!countermove.is_empty() and moves_equal(move, countermove)) {
                score = SCORE_COUNTERMOVE;
            // score history + continuation history
            } else {
                score = search.global_search.history_moves[move.from][move.to];

                // Add continuation history (counter + follow) for move ordering
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
        score_list.append(score);
    }
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

    var side = if (board.get_piece_color_at(from) == types.Color.White) types.Color.Black else types.Color.White;
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

        // Find the least valuable attacker
        var attacker_sq: u6 = 0;
        var attacker_piece_val: i32 = PIECE_VALUES[5]; // Default to king value
        var found = false;

        // Check for pawns first (least valuable)
        const pawn_piece = if (side == types.Color.White) types.Piece.WHITE_PAWN else types.Piece.BLACK_PAWN;
        const pawn_attackers = my_attackers & board.pieces[@intFromEnum(pawn_piece)];
        if (pawn_attackers != 0) {
            attacker_sq = @intCast(util.lsb_index(pawn_attackers));
            attacker_piece_val = PIECE_VALUES[0];
            found = true;
        }

        if (!found) {
            // Check other pieces in order of value
            const piece_order = if (side == types.Color.White)
                [_]types.Piece{ .WHITE_KNIGHT, .WHITE_BISHOP, .WHITE_ROOK, .WHITE_QUEEN, .WHITE_KING }
            else
                [_]types.Piece{ .BLACK_KNIGHT, .BLACK_BISHOP, .BLACK_ROOK, .BLACK_QUEEN, .BLACK_KING };

            for (piece_order, 1..) |piece, piece_idx| {
                const piece_attackers = my_attackers & board.pieces[@intFromEnum(piece)];
                if (piece_attackers != 0) {
                    attacker_sq = @intCast(util.lsb_index(piece_attackers));
                    attacker_piece_val = PIECE_VALUES[piece_idx];
                    found = true;
                    break;
                }
            }
        }

        if (!found) {
            break;
        }

        // Switch sides
        side = if (side == types.Color.White) types.Color.Black else types.Color.White;

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

    // Return the final result
    return side != board.get_piece_color_at(move.from).?;
}

inline fn moves_equal(m1: move_gen.Move, m2: move_gen.Move) bool {
    return m1.from == m2.from and m1.to == m2.to and m1.flags == m2.flags;
}
