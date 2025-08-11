const std = @import("std");
const lists = @import("lists.zig");
const eval = @import("evaluation.zig");
const move_generation = @import("move_generation.zig");
const types = @import("types.zig");
const bitboard = @import("bitboard.zig");
const util = @import("util.zig");
const print = std.debug.print;

const INFINITY: i32 = 30000;
const MATE_VALUE: i32 = 29000;

// Search state
var search_nodes: u64 = 0;
var search_stopped: bool = false;
var search_timer: std.time.Timer = undefined;
var search_time_limit: u64 = 0;
var best_move: move_generation.Move = undefined;
var best_move_found: bool = false;
var root_depth: u8 = 0;

inline fn check_time() void {
    if (search_time_limit > 0 and (search_nodes & 2047) == 0) {
        const elapsed = search_timer.read() / std.time.ns_per_ms;
        if (elapsed >= search_time_limit) {
            search_stopped = true;
        }
    }
}

// negamax alpha beta search
pub fn negamax(board: *types.Board, depth: u8, mut_alpha: i32, beta: i32, comptime color: types.Color) i32 {
    search_nodes += 1;
    check_time();

    if (search_stopped) return 0;

    // Terminal node
    if (depth == 0) {
        return eval.global_evaluator.eval(board.*, color);
    }

    var alpha = mut_alpha;
    var best_score: i32 = -INFINITY;
    var legal_moves: u32 = 0;
    var best_move_in_position: move_generation.Move = undefined;

    // Generate moves
    var move_list: lists.MoveList = .{};
    move_generation.generate_moves(board, &move_list, color);

    const opponent = if (color == types.Color.White) types.Color.Black else types.Color.White;

    for (0..move_list.count) |i| {
        const move = move_list.moves[i];

        const board_state = board.save_state();
        const saved_eval = eval.global_evaluator;

        if (move_generation.make_move(board, move)) {
            legal_moves += 1;

            const score = -negamax(board, depth - 1, -beta, -alpha, opponent);

            // Unmake move
            board.restore_state(board_state);
            eval.global_evaluator = saved_eval;

            if (search_stopped) return 0;

            if (score > best_score) {
                best_score = score;
                best_move_in_position = move;

                if (score > alpha) {
                    alpha = score;

                    // Beta cutoff
                    if (alpha >= beta) {
                        if (depth == root_depth) {
                            best_move = move;
                            best_move_found = true;
                        }
                        return beta;
                    }
                }
            }
        } else {
            board.restore_state(board_state);
            eval.global_evaluator = saved_eval;
        }
    }

    // Store best move at root
    if (depth == root_depth and legal_moves > 0) {
        best_move = best_move_in_position;
        best_move_found = true;
    }

    // Checkmate/stalemate detection
    if (legal_moves == 0) {
        const king_piece = if (color == types.Color.White) types.Piece.WHITE_KING else types.Piece.BLACK_KING;
        const king_sq: u6 = @intCast(util.lsb_index(board.pieces[@intFromEnum(king_piece)]));

        if (bitboard.is_square_attacked(board, king_sq, opponent)) {
            return -MATE_VALUE + @as(i32, depth);
        }
        return 0;
    }

    return best_score;
}

// Main search function
pub fn search_position(board: *types.Board, max_depth: ?u8, time_ms: u64, comptime color: types.Color) void {
    search_nodes = 0;
    search_stopped = false;
    search_timer = std.time.Timer.start() catch unreachable;
    search_time_limit = time_ms;
    best_move_found = false;

    const depth_limit = max_depth orelse 10;

    // Iterative deepening
    var current_depth: u8 = 1;
    while (current_depth <= depth_limit) : (current_depth += 1) {
        root_depth = current_depth;

        const score = negamax(board, current_depth, -INFINITY, INFINITY, color);

        if (search_stopped) break;

        const elapsed = search_timer.read() / std.time.ns_per_ms;

        print("info depth {} score cp {} nodes {} time {} ", .{
            current_depth,
            score,
            search_nodes,
            elapsed,
        });

        if (best_move_found) {
            const from = types.SquareString.getSquareToString(@enumFromInt(best_move.from));
            const to = types.SquareString.getSquareToString(@enumFromInt(best_move.to));
            print("pv {s}{s}", .{ from, to });
        }
        print("\n", .{});
    }

    if (best_move_found) {
        const from = types.SquareString.getSquareToString(@enumFromInt(best_move.from));
        const to = types.SquareString.getSquareToString(@enumFromInt(best_move.to));

        if (move_generation.Print_move_list.is_promotion(best_move)) {
            const promo = move_generation.Print_move_list.get_promotion_char(best_move);
            print("bestmove {s}{s}{c}\n", .{ from, to, promo });
        } else {
            print("bestmove {s}{s}\n", .{ from, to });
        }
    }
}
