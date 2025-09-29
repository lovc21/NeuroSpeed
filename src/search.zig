const std = @import("std");
const lists = @import("lists.zig");
const eval = @import("evaluation.zig");
const move_generation = @import("move_generation.zig");
const types = @import("types.zig");
const bitboard = @import("bitboard.zig");
const util = @import("util.zig");
const print = std.debug.print;
const move_scores = @import("score_moves.zig");
const Move = move_generation.Move;

pub var global_search: Search = undefined;

pub fn search_position(board: *types.Board, max_depth: ?u8, time_ms: u64, comptime color: types.Color) void {
    global_search.search_position(board, max_depth, time_ms, color);
}

pub fn init_search() void {
    global_search = Search.new();
}

const INFINITY: i32 = 50000;
const MATE_VALUE: i32 = 49000;
const MAX_PLY: usize = 128;
const MAX_QUIESCENCE_DEPTH: i8 = 16;

pub const Search = struct {
    best_move: Move = undefined,
    stop_on_time: bool = false,
    stop: bool = false,
    timer: std.time.Timer = undefined,
    max_depth: u32 = 64,
    nodes: u64 = 0,
    ply: u16 = 0,

    // PV table
    pv_length: [MAX_PLY]u16 = undefined,
    pv_table: [MAX_PLY][MAX_PLY]Move = undefined,

    // killer moves
    killer_moves: [2][MAX_PLY]Move = undefined,

    // history moves
    history_moves: [64][64]i32 = undefined,

    time_limit: u64 = 0,

    pub fn new() Search {
        var search = Search{};
        search.clear_pv_table();
        @memset(&search.history_moves, 0);
        return search;
    }

    inline fn clear_pv_table(self: *Search) void {
        for (0..MAX_PLY) |i| {
            for (0..MAX_PLY) |j| {
                self.pv_table[i][j] = move_generation.Move.new(0, 0, types.MoveFlags.QUIET);
            }
            self.pv_length[i] = 0;
        }
    }

    inline fn update_pv(self: *Search, move: move_generation.Move) void {
        self.pv_table[self.ply][0] = move;
        const next_ply = self.ply + 1;
        if (next_ply < MAX_PLY) {
            for (0..self.pv_length[next_ply]) |i| {
                if (i + 1 < MAX_PLY) {
                    self.pv_table[self.ply][i + 1] = self.pv_table[next_ply][i];
                }
            }
            self.pv_length[self.ply] = self.pv_length[next_ply] + 1;
        } else {
            self.pv_length[self.ply] = 1;
        }
    }

    inline fn check_time(self: *Search) void {
        if (self.time_limit > 0 and (self.nodes & 2047) == 0) {
            const elapsed = self.timer.read() / std.time.ns_per_ms;
            if (elapsed >= self.time_limit) {
                self.stop = true;
            }
        }
    }

    // Check if king is in check
    inline fn is_king_in_check(self: *Search, board: *const types.Board, comptime color: types.Color) bool {
        _ = self;
        const king_piece = if (color == types.Color.White) types.Piece.WHITE_KING else types.Piece.BLACK_KING;
        const opponent = if (color == types.Color.White) types.Color.Black else types.Color.White;

        if (board.pieces[@intFromEnum(king_piece)] == 0) {
            return false;
        }
        const king_square: u6 = @intCast(util.lsb_index(board.pieces[@intFromEnum(king_piece)]));
        return bitboard.is_square_attacked(board, king_square, opponent);
    }

    // Quiescence search
    pub fn quiescence(self: *Search, board: *types.Board, mut_alpha: i32, beta: i32, depth: i8, comptime color: types.Color) i32 {
        if (self.ply < MAX_PLY) {
            self.pv_length[self.ply] = 0;
        }

        if (depth < -MAX_QUIESCENCE_DEPTH) {
            return eval.global_evaluator.eval(board.*, color);
        }

        self.nodes += 1;
        self.check_time();

        if (self.stop) return 0;

        if (self.ply >= MAX_PLY - 1) {
            return eval.global_evaluator.eval(board.*, color);
        }

        var alpha = mut_alpha;
        const opponent = if (color == types.Color.White) types.Color.Black else types.Color.White;

        // Mate distance pruning
        alpha = @max(alpha, -MATE_VALUE + @as(i32, @intCast(self.ply)));
        const adj_beta = @min(beta, MATE_VALUE - @as(i32, @intCast(self.ply)) - 1);

        if (alpha >= adj_beta) return alpha;

        // Check if king is in check
        const in_check = self.is_king_in_check(board, color);

        var best_score: i32 = undefined;

        if (in_check) {
            // If in check, we must search all moves to escape check
            best_score = -MATE_VALUE + @as(i32, @intCast(self.ply));
        } else {
            // Standing pat - current position evaluation as lower bound
            best_score = eval.global_evaluator.eval(board.*, color);

            // Standing pat cutoff
            if (best_score >= beta) {
                return best_score;
            }

            // Update alpha with standing pat score
            if (best_score > alpha) {
                alpha = best_score;
            }
        }

        // Generate moves all moves if in check, only captures otherwise
        var move_list: lists.MoveList = .{};
        if (in_check) {
            move_generation.generate_moves(board, &move_list, color);
        } else {
            move_generation.generate_capture_moves(board, &move_list, color);
        }

        if (move_list.count == 0 and in_check) {
            return -MATE_VALUE + @as(i32, @intCast(self.ply));
        }

        const pv_move = if (self.pv_length[self.ply] > 0)
            self.pv_table[self.ply][0]
        else
            move_generation.Move.empty();

        // Score moves for move ordering
        var score_list: lists.ScoreList = .{};
        move_scores.score_move(board, &move_list, &score_list, pv_move);

        const piece_values = [_]i32{ 100, 320, 330, 500, 900, 10000 }; // P, N, B, R, Q, K

        for (0..move_list.count) |i| {
            const move = move_scores.get_next_best_move(&move_list, &score_list, i);

            if (!in_check and move_generation.Print_move_list.is_capture(move) and
                move.flags != types.MoveFlags.EN_PASSANT)
            {
                const attacker_type = board.get_piece_type_at(move.from);
                const victim_type = board.get_piece_type_at(move.to);

                if (attacker_type != null and victim_type != null) {
                    const attacker_value = piece_values[@intFromEnum(attacker_type.?)];
                    const victim_value = piece_values[@intFromEnum(victim_type.?)];

                    // Skip if we're losing material in the most basic sense
                    // (This is very basic SEE - a proper implementation would be more complex)
                    if (victim_value < attacker_value - 200) {
                        continue;
                    }
                }
            }

            const board_state = board.save_state();
            const saved_eval = eval.global_evaluator;

            self.ply += 1;

            // illegal move - skip to next move
            if (!move_generation.make_move(board, move)) {
                self.ply -= 1;
                board.restore_state(board_state);
                eval.global_evaluator = saved_eval;
                continue;
            }

            const score = -self.quiescence(board, -adj_beta, -alpha, depth - 1, opponent);

            self.ply -= 1;
            board.restore_state(board_state);
            eval.global_evaluator = saved_eval;

            if (self.stop) return 0;

            // Update best score
            if (score > best_score) {
                best_score = score;

                if (score > alpha) {
                    alpha = score;

                    if (self.ply < MAX_PLY) {
                        self.update_pv(move);
                    }

                    if (alpha >= adj_beta) {
                        return alpha;
                    }
                }
            }
        }

        return best_score;
    }

    // negamax alpha beta search
    pub fn negamax(self: *Search, board: *types.Board, depth: u8, mut_alpha: i32, beta: i32, comptime color: types.Color) i32 {
        // Clear PV length for this ply
        if (self.ply < MAX_PLY) {
            self.pv_length[self.ply] = 0;
        }

        // Quiescence search
        if (depth == 0) {
            return self.quiescence(board, mut_alpha, beta, 0, color);
        }

        self.nodes += 1;
        self.check_time();

        if (self.stop) return 0;

        var alpha = mut_alpha;
        var legal_moves: u32 = 0;
        var best_so_far: move_generation.Move = undefined;
        const old_alpha = alpha;
        const is_root = (self.ply == 0);
        const in_check = self.is_king_in_check(board, color);
        const opponent = if (color == types.Color.White) types.Color.Black else types.Color.White;

        // Generate moves
        var move_list: lists.MoveList = .{};
        move_generation.generate_moves(board, &move_list, color);

        const pv_move = if (self.pv_length[self.ply] > 0)
            self.pv_table[self.ply][0]
        else
            move_generation.Move.empty();

        // Generate move scores
        var score_list: lists.ScoreList = .{};
        move_scores.score_move(board, &move_list, &score_list, pv_move);

        // loop over moves within a movelist
        for (0..move_list.count) |i| {
            const move = move_scores.get_next_best_move(&move_list, &score_list, i);

            const board_state = board.save_state();
            const saved_eval = eval.global_evaluator;

            self.ply += 1;

            // illegal move - skip to next move
            if (!move_generation.make_move(board, move)) {
                self.ply -= 1;
                board.restore_state(board_state);
                eval.global_evaluator = saved_eval;
                continue;
            }

            legal_moves += 1;

            const score = -self.negamax(board, depth - 1, -beta, -alpha, opponent);

            self.ply -= 1;

            board.restore_state(board_state);
            eval.global_evaluator = saved_eval;

            if (self.stop) return 0;

            // fail-hard beta cutoff
            if (score >= beta) {
                if (!move_generation.Print_move_list.is_capture(move)) {
                    self.killer_moves[1][self.ply] = self.killer_moves[0][self.ply];
                    self.killer_moves[0][self.ply] = move;

                    self.history_moves[move.from][move.to] += depth * depth;
                }
                return beta;
            }

            // found a better move
            if (score > alpha) {

                // PV node (move)
                alpha = score;
                best_so_far = move;

                // Update PV
                if (self.ply < MAX_PLY) {
                    self.update_pv(move);
                }

                // if root move
                if (is_root) {
                    print("DEBUG: Root level - best_so_far from={} to={}, alpha={}\n", .{ move.from, move.to, alpha });
                    print("DEBUG: PV[0][0] from={} to={}\n", .{ self.pv_table[0][0].from, self.pv_table[0][0].to });
                    self.best_move = move;
                }
            }
        }

        // we don't have any legal moves
        if (legal_moves == 0) {
            // king is in check
            if (in_check) {
                // return mating score
                return -MATE_VALUE + @as(i32, @intCast(self.ply));
            } else {
                // stalemate
                return 0;
            }
        }

        // found better move
        if (old_alpha != alpha and is_root) {
            self.best_move = best_so_far;
        }

        // node fails low
        return alpha;
    }

    // Main search function
    pub fn search_position(self: *Search, board: *types.Board, max_depth: ?u8, time_ms: u64, comptime color: types.Color) void {
        self.nodes = 0;
        self.stop = false;
        self.timer = std.time.Timer.start() catch unreachable;
        self.time_limit = time_ms;
        self.ply = 0; // Reset ply counter
        self.clear_pv_table();
        var best_move_found: ?move_generation.Move = null;
        var best_completed_depth: u8 = 0;

        const depth_limit = max_depth orelse 10;

        // Iterative deepening
        var current_depth: u8 = 1;
        while (current_depth <= depth_limit) : (current_depth += 1) {
            // Reset ply for each iteration
            self.ply = 0;

            const score = self.negamax(board, current_depth, -INFINITY, INFINITY, color);

            // Check if search was interrupted
            if (self.stop) {
                print("info string Search interrupted at depth {}\n", .{current_depth});
                break;
            }

            // This iteration completed successfully - save the best move
            if (self.pv_length[0] > 0) {
                best_move_found = self.pv_table[0][0];
                best_completed_depth = current_depth;
            }

            const elapsed = self.timer.read() / std.time.ns_per_ms;

            // Print search info
            print("info depth {} ", .{current_depth});

            // Format and print score
            if (score > MATE_VALUE - 100) {
                // Mate in N moves
                const mate_in = @divTrunc((MATE_VALUE - score + 1), 2);
                print("score mate {} ", .{mate_in});
            } else if (score < -MATE_VALUE + 100) {
                // Getting mated in N moves
                const mate_in = @divTrunc((MATE_VALUE + score + 1), 2);
                print("score mate -{} ", .{mate_in});
            } else {
                print("score cp {} ", .{score});
            }

            print("nodes {} time {} ", .{ self.nodes, elapsed });

            // Print principal variation
            if (self.pv_length[0] > 0) {
                print("pv ", .{});
                for (0..self.pv_length[0]) |pv_idx| {
                    if (pv_idx >= MAX_PLY) break;
                    const pv_move = self.pv_table[0][pv_idx];
                    const from = types.SquareString.getSquareToString(@enumFromInt(pv_move.from));
                    const to = types.SquareString.getSquareToString(@enumFromInt(pv_move.to));

                    if (move_generation.Print_move_list.is_promotion(pv_move)) {
                        const promo = move_generation.Print_move_list.get_promotion_char(pv_move);
                        print("{s}{s}{c} ", .{ from, to, promo });
                    } else {
                        print("{s}{s} ", .{ from, to });
                    }
                }
            }

            print("\n", .{});

            // Stop if we found a mate
            if (score > MATE_VALUE - 100 or score < -MATE_VALUE + 100) {
                break;
            }

            // Simple time management - don't start new iteration if we've used too much time
            if (self.time_limit > 0 and elapsed > self.time_limit / 2) {
                print("info string Time management: stopping after depth {} (used {}ms of {}ms)\n", .{ current_depth, elapsed, self.time_limit });
                break;
            }
        }

        // Output best move
        if (best_move_found) |best_move| {
            const from = types.SquareString.getSquareToString(@enumFromInt(best_move.from));
            const to = types.SquareString.getSquareToString(@enumFromInt(best_move.to));

            print("info string Using best move from completed depth {}\n", .{best_completed_depth});

            if (move_generation.Print_move_list.is_promotion(best_move)) {
                const promo = move_generation.Print_move_list.get_promotion_char(best_move);
                print("bestmove {s}{s}{c}\n", .{ from, to, promo });
            } else {
                print("bestmove {s}{s}\n", .{ from, to });
            }
        } else {
            // Fallback - find any legal move
            print("ERROR: Using fallback move - no completed iterations\n", .{});
            var move_list: lists.MoveList = .{};
            move_generation.generate_moves(board, &move_list, color);
            if (move_list.count > 0) {
                const fallback_move = move_list.moves[0];
                const from = types.SquareString.getSquareToString(@enumFromInt(fallback_move.from));
                const to = types.SquareString.getSquareToString(@enumFromInt(fallback_move.to));
                print("bestmove {s}{s}\n", .{ from, to });
            }
        }
    }
};
