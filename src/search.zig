const std = @import("std");
const lists = @import("lists.zig");
const eval = @import("evaluation.zig");
const move_generation = @import("move_generation.zig");
const types = @import("types.zig");
const bitboard = @import("bitboard.zig");
const util = @import("util.zig");
const move_scores = @import("score_moves.zig");
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

inline fn is_king_in_check(board: *types.Board, color: types.Color, opponent: types.Color) bool {
    const king_piece = if (color == types.Color.White) types.Piece.WHITE_KING else types.Piece.BLACK_KING;
    const king_square: u6 = @intCast(util.lsb_index(board.pieces[@intFromEnum(king_piece)]));
    return bitboard.is_square_attacked(board, king_square, opponent);
}

inline fn is_good_capture_eval(board: *types.Board, move: move_generation.Move, comptime color: types.Color) bool {
    if (board.board[move.to] == types.Piece.NO_PIECE) return false;

    // Evaluate position before the capture
    const eval_before = eval.global_evaluator.eval(board.*, color);

    // Make the move
    const board_state = board.save_state();
    const saved_eval = eval.global_evaluator;

    var is_good = false;
    if (move_generation.make_move(board, move)) {
        const eval_after = eval.global_evaluator.eval(board.*, color);

        // Good capture if we improve our position
        const safety_margin = 50;
        is_good = eval_after >= eval_before - safety_margin;
    }

    // Restore position
    board.restore_state(board_state);
    eval.global_evaluator = saved_eval;

    return is_good;
}

// quiescence search_stopped
fn quiescence(board: *types.Board, alpha_: i32, beta_: i32, comptime color: types.Color, qs_depth: u8) i32 {
    print("QUIESCENCE: Enter alpha={}, beta={}, nodes={}\n", .{ alpha_, beta_, search_nodes });

    const them = if (color == types.Color.White) types.Color.Black else types.Color.White;
    var alpha = alpha_;
    const beta = beta_;

    search_nodes += 1;

    // Check for time limit and stop search
    check_time();
    if (search_stopped) {
        print("QUIESCENCE: Time stopped\n", .{});
        return 0;
    }

    if (search_stopped) return 0;
    print("QUIESCENCE: Enter qs_depth={}\n", .{qs_depth});
    if (qs_depth >= 4) { // Limit quiescence to 4 ply
        return eval.global_evaluator.eval(board.*, color);
    }

    // Check if we are in check
    const in_check = is_king_in_check(board, color, them);

    // Stand pat evaluation
    var best_score: i32 = 0;
    if (!in_check) {
        const stand_pat = eval.global_evaluator.eval(board.*, color);
        best_score = stand_pat;
        // Beta cutoff
        if (stand_pat >= beta) {
            return beta;
        }

        // Update alpha
        if (stand_pat > alpha) {
            alpha = stand_pat;
        }

        // Delta pruning
        const delta_margin = 900; // queen value
        if (stand_pat + delta_margin < alpha) {
            return alpha;
        }
    } else {
        // search all moves if not in check
        best_score = -INFINITY;
    }

    var move_list: lists.MoveList = .{};

    if (in_check) {
        // generate all mves if in check
        move_generation.generate_moves(board, &move_list, color);
    } else {
        // generate only captures if not in check
        move_generation.generate_capture_moves(board, &move_list, color);
    }

    // if no moves
    if (move_list.count == 0) {
        if (in_check) {
            // Checkmate
            return -MATE_VALUE + @as(i32, @intCast(search_nodes & 0xFF));
        } else {
            // Stand pat evaluation
            return best_score;
        }
    }

    var score_list: lists.ScoreList = .{};
    move_scores.score_move(board, &move_list, &score_list);

    // search all moves
    for (0..move_list.count) |i| {
        const move = move_scores.get_next_best_move(&move_list, &score_list, i);

        if (!in_check) {
            if (!move_generation.Print_move_list.is_capture(move) and
                !move_generation.Print_move_list.is_promotion(move))
            {
                continue;
            }
        }

        const board_state = board.save_state();
        const saved_eval = eval.global_evaluator;

        if (move_generation.make_move(board, move)) {
            const score: i32 = -quiescence(board, -beta, -alpha, them, qs_depth + 1);

            // Unmake move
            board.restore_state(board_state);
            eval.global_evaluator = saved_eval;

            if (search_stopped) return 0;

            if (score > best_score) {
                best_score = score;

                if (score > alpha) {
                    alpha = score;

                    // Beta cutoff
                    if (alpha >= beta) {
                        return beta;
                    }
                }
            }
        } else {
            board.restore_state(board_state);
            eval.global_evaluator = saved_eval;
        }
    }
    print("QUIESCENCE: Exit best_score={}\n", .{best_score});

    return best_score;
}

// negamax alpha beta search
pub fn negamax(board: *types.Board, depth_: u8, mut_alpha: i32, beta: i32, comptime color: types.Color) i32 {
    if (depth_ <= 3) {
        print("NEGAMAX: Enter depth={}, alpha={}, beta={}, color={}, nodes={}\n", .{ depth_, mut_alpha, beta, color, search_nodes });
    }

    var alpha = mut_alpha;
    var best_score: i32 = -INFINITY;
    var legal_moves: u32 = 0;
    var best_move_in_position: move_generation.Move = undefined;
    const depth = depth_;

    const opponent = if (color == types.Color.White) types.Color.Black else types.Color.White;

    check_time();

    if (search_stopped) {
        if (depth_ <= 3) print("NEGAMAX: Time stopped at depth {}\n", .{depth_});
        return 0;
    }
    if (search_stopped) return 0;

    search_nodes += 1;

    // chek if we are in check
    const in_check = is_king_in_check(board, color, opponent);

    if (depth_ <= 3) {
        print("NEGAMAX: In check: {}, depth: {}\n", .{ in_check, depth_ });
    }
    // search depper if we are in check
    var actual_depth = depth;
    if (depth > 0 and in_check) {
        actual_depth += 1;
        if (depth_ <= 3) print("NEGAMAX: Check extension! depth {} -> {}\n", .{ depth, actual_depth });
    }

    // Terminal node go to quiescence search
    if (actual_depth == 0) {
        if (depth_ <= 3) print("NEGAMAX: Going to quiescence\n", .{});
        return quiescence(board, alpha, beta, color, 0);
    }

    // Generate moves
    var move_list: lists.MoveList = .{};
    move_generation.generate_moves(board, &move_list, color);
    if (depth_ <= 3) print("NEGAMAX: Generated {} moves\n", .{move_list.count});

    // Generate scored moves
    var scored_moves: lists.ScoreList = .{};
    move_scores.score_move(board, &move_list, &scored_moves);

    if (depth_ <= 3) {
        print("NEGAMAX: Scored moves:\n", .{});
    }
    for (0..move_list.count) |i| {
        if (depth_ <= 3 and i % 5 == 0) {
            print("NEGAMAX: Processing move {}/{} at depth {}\n", .{ i + 1, move_list.count, depth_ });
        }

        const move = move_scores.get_next_best_move(&move_list, &scored_moves, i);

        const board_state = board.save_state();
        const saved_eval = eval.global_evaluator;

        if (move_generation.make_move(board, move)) {
            legal_moves += 1;

            if (depth_ <= 3) {
                print("NEGAMAX: Making recursive call for move {} at depth {}\n", .{ i + 1, depth_ });
            }

            const score = -negamax(board, actual_depth - 1, -beta, -alpha, opponent);

            if (depth_ <= 3) {
                print("NEGAMAX: Returned from recursive call, score={}\n", .{score});
            }
            // Unmake move
            board.restore_state(board_state);
            eval.global_evaluator = saved_eval;

            if (search_stopped) return 0;
            if (search_stopped) {
                if (depth_ <= 3) print("NEGAMAX: Search stopped during move loop\n", .{});
                return 0;
            }
            if (score > best_score) {
                best_score = score;
                best_move_in_position = move;

                if (score > alpha) {
                    alpha = score;

                    if (depth == root_depth) {
                        best_move = move;
                        best_move_found = true;
                    }

                    // Beta cutoff
                    if (alpha >= beta) {
                        if (depth_ <= 3) {
                            print("NEGAMAX: Beta cutoff at depth {}, move {}\n", .{ depth_, i + 1 });
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

    if (depth_ <= 3) {
        print("NEGAMAX: Finished move loop, legal_moves={}, best_score={}\n", .{ legal_moves, best_score });
    }

    // Store best move at root
    if (depth == root_depth and legal_moves > 0 and !best_move_found) {
        best_move = best_move_in_position;
        best_move_found = true;
    }

    // Checkmate/stalemate detection
    if (legal_moves == 0) {
        if (in_check) {
            if (depth_ <= 3) print("NEGAMAX: Checkmate detected\n", .{});
            // return mate score
            return -MATE_VALUE + @as(i32, @intCast(root_depth - depth));
        } else {
            if (depth_ <= 3) print("NEGAMAX: Stalemate detected\n", .{});
            // return draw score
            return 0;
        }
    }

    if (depth_ <= 3) {
        print("NEGAMAX: Exit depth={}, best_score={}\n", .{ depth_, best_score });
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
    var last_score: i32 = 0;

    const depth_limit = max_depth orelse 10;

    // Iterative deepening
    var current_depth: u8 = 1;
    while (current_depth <= depth_limit) : (current_depth += 1) {
        root_depth = current_depth;
        print("Starting depth {}\n", .{current_depth});

        const start_nodes = search_nodes;
        const score = negamax(board, current_depth, -INFINITY, INFINITY, color);
        last_score = score;

        print("=== Completed depth {}, nodes this depth: {} ===\n", .{ current_depth, search_nodes - start_nodes });

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

        // if we finde mate search deeper
        if (@abs(score) >= MATE_VALUE - 100) {
            break;
        }
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
    } else {
        // Fall back if we didn't find a best move
        // just fined a legal move
        var move_list: lists.MoveList = .{};
        move_generation.generate_moves(board, &move_list, color);

        for (0..move_list.count) |i| {
            const move = move_list.moves[i];

            const board_state = board.save_state();
            const saved_eval = eval.global_evaluator;

            if (move_generation.make_move(board, move)) {
                board.restore_state(board_state);
                eval.global_evaluator = saved_eval;

                const from = types.SquareString.getSquareToString(@enumFromInt(move.from));
                const to = types.SquareString.getSquareToString(@enumFromInt(move.to));

                if (move_generation.Print_move_list.is_promotion(move)) {
                    const promo = move_generation.Print_move_list.get_promotion_char(move);
                    print("bestmove {s}{s}{c}\n", .{ from, to, promo });
                } else {
                    print("bestmove {s}{s}\n", .{ from, to });
                }
                break;
            } else {
                board.restore_state(board_state);
                eval.global_evaluator = saved_eval;
            }
        }
    }
}
