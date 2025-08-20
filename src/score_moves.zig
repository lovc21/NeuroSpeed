const std = @import("std");
const types = @import("types.zig");
const attacks = @import("attacks.zig");
const lists = @import("lists.zig");
const util = @import("util.zig");
const bitboard = @import("bitboard.zig");
const eval = @import("evaluation.zig");
const move_generation = @import("move_generation.zig");
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

//TODO this can be optimized by using a ScoredMoveList
pub inline fn get_next_best_move(move_list: *lists.MoveList, score_list: *lists.ScoreList, i: usize) move_generation.Move {
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

pub inline fn score_move(board: *types.Board, move_list: *lists.MoveList, score_list: *lists.ScoreList) void {
    score_list.count = 0;
    
    for (0..move_list.count) |i| {
        const move = move_list.moves[i];
        var score: i32 = 0;
        
        // 1. Promotions with capture
        if (move_generation.Print_move_list.is_promotion(move) and move_generation.Print_move_list.is_capture(move)) {
            if (move.flags == types.MoveFlags.PC_QUEEN) {
                score = SCORE_PROMOTION_QUEEN_CAPTURE;
            } else {
                score = SCORE_PROMOTION_CAPTURE + @as(i32, @intFromEnum(move.flags));
            }
        // 2. En passant Captures
        }else if (move.flags == types.MoveFlags.EN_PASSANT) {
            score = SCORE_GOOD_CAPTURE + 105;
        
        // 2. Captures
        }else if (move_generation.Print_move_list.is_capture(move)) {
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
        else if (move_generation.Print_move_list.is_promotion(move)) {
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
            score = SCORE_QUIET; 
        }
        score_list.append(score);
    }
}


pub fn see(board: *const types.Board, move: move_generation.Move, threshold: i32) bool {
    const from = move.from;
    const to = move.to;
    var side_to_move = if (board.side == types.Color.White) types.Color.Black else types.Color.White;

    // Promotions are always good
    if (move_generation.Print_move_list.is_promotion(move)) {
        return true;
    }
    
    // Get initial material balance
    var value: i32 = 0;
    const captured_piece_type = board.get_piece_type_at(to);
    if (captured_piece_type) |victim| {
        value = PIECE_VALUES[@intFromEnum(victim)];
    } else if (move.flags == types.MoveFlags.EN_PASSANT) {
        value = PIECE_VALUES[0]; 
    }
    
    value -= threshold;
    if (value < 0) return false;
    
    // Subtract value of attacking piece
    const attacker_type = board.get_piece_type_at(from) orelse return false;
    value -= PIECE_VALUES[@intFromEnum(attacker_type)];
    
    if (value >= 0) return true;
    
    // Exchange sequence
    const occ_initial = board.pieces_combined();
    var occupied = occ_initial ^ types.squar_bb[from]; 
    if (move.flags == types.MoveFlags.EN_PASSANT) {
        const ep_capture_sq = if (board.side == types.Color.White) to - 8 else to + 8;
        occupied ^= types.squar_bb[ep_capture_sq];
    }
    
    var attackers = bitboard.get_all_attackers(board, to, occupied);
    
    // Remove the initial attacker
    attackers &= ~types.squar_bb[from];
    
    
    while (attackers != 0) {

        // Get attackers for side to move
        const side_mask = if (side_to_move == types.Color.White) board.set_white() else board.set_black(); 
        const side_attackers = attackers & side_mask;
        if (side_attackers == 0) break;      
        
        // Find least valuable attacker
        var attacker_sq: u6 = undefined;
        // King value as default
        var attacker_value: i32 = PIECE_VALUES[5];
        var found = false;
        
        const pawn_mask = if (side_to_move == types.Color.White)
            board.pieces[@intFromEnum(types.Piece.WHITE_PAWN)]
        else
            board.pieces[@intFromEnum(types.Piece.BLACK_PAWN)];
            
        if ((side_attackers & pawn_mask) != 0) {
            attacker_sq = @intCast(util.lsb_index(side_attackers & pawn_mask));
            attacker_value = PIECE_VALUES[0];
            found = true;
        } else {
            const pieces = if (side_to_move == types.Color.White)
                [_]types.Piece{ .WHITE_KNIGHT, .WHITE_BISHOP, .WHITE_ROOK, .WHITE_QUEEN, .WHITE_KING }
            else
                [_]types.Piece{ .BLACK_KNIGHT, .BLACK_BISHOP, .BLACK_ROOK, .BLACK_QUEEN, .BLACK_KING }; 
            for (pieces, 1..) |piece, piece_val_idx| {
                if ((side_attackers & board.pieces[@intFromEnum(piece)]) != 0) {
                    attacker_sq = @intCast(util.lsb_index(side_attackers & board.pieces[@intFromEnum(piece)]));
                    attacker_value = PIECE_VALUES[piece_val_idx];
                    found = true;
                    break;
                }
            }
        }
        
        if (!found) break;
        
        // Make the capture
        occupied ^= types.squar_bb[attacker_sq];
        
        // Update value (flip perspective)
        value = -value - 1 - attacker_value;
        
        // Prune if this capture wins material
        if (value >= 0) {
            // Check for king capture
            const opp_side_mask = if (side_to_move == types.Color.White)
                board.set_black()
            else
                board.set_white();
                
            if ((attackers & opp_side_mask) != 0) {
                return side_to_move == board.side;
            }
            return side_to_move != board.side;
        }
        
        // Update attackers with x-ray attacks
        attackers = bitboard.get_all_attackers(board, to, occupied);
        
        // Switch sides
        side_to_move = if (side_to_move == types.Color.White) types.Color.Black else types.Color.White;
    }
    
    // Return true if the final balance favors the initial side
    return side_to_move == board.side;
}
