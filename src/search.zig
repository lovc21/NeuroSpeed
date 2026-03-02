const std = @import("std");
const lists = @import("lists.zig");
const eval = @import("evaluation.zig");
const move_generation = @import("move_generation.zig");
const types = @import("types.zig");
const bitboard = @import("bitboard.zig");
const util = @import("util.zig");
const move_scores = @import("score_moves.zig");
const tt_mod = @import("tt.zig");
const zobrist = @import("zobrist.zig");
const Move = move_generation.Move;

pub var global_search: Search = undefined;
pub var global_tt: ?tt_mod.TT = null;

pub fn search_position(board: *types.Board, max_depth: ?u8, soft_limit: u64, hard_limit: u64, comptime color: types.Color) void {
    global_search.search_position(board, max_depth, soft_limit, hard_limit, color);
}

pub fn init_search() void {
    global_search = Search.new();
}

fn print(comptime fmt: []const u8, args: anytype) void {
    const w = std.io.getStdOut().writer();
    w.print(fmt, args) catch {};
}

pub fn init_tt(allocator: std.mem.Allocator, size_mb: usize) void {
    if (global_tt) |*existing| {
        existing.deinit();
    }
    global_tt = tt_mod.TT.init(allocator, size_mb) catch {
        print("info string Failed to allocate TT ({} MB)\n", .{size_mb});
        global_tt = null;
        return;
    };
}

pub fn deinit_tt() void {
    if (global_tt) |*existing| {
        existing.deinit();
        global_tt = null;
    }
}

const INFINITY: i32 = 50000;
const MATE_VALUE: i32 = 49000;
const MAX_PLY: usize = 128;
const MAX_QUIESCENCE_DEPTH: i8 = 16;

// Precomputed Late Move Reduction table
// Formula: R = 1 + ln(depth) * ln(moveNumber) / 2.0
const lmr_reductions: [64][64]u8 = init: {
    @setEvalBranchQuota(10000);
    var table: [64][64]u8 = .{[_]u8{0} ** 64} ** 64;
    for (1..64) |d| {
        for (1..64) |m| {
            const df: f64 = @floatFromInt(d);
            const mf: f64 = @floatFromInt(m);
            const r: f64 = 1.0 + @log(df) * @log(mf) / 2.0;
            table[d][m] = @intFromFloat(@min(@max(r, 0.0), 63.0));
        }
    }
    break :init table;
};

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

    // countermove heuristic: countermoves[prev_from][prev_to] = refutation move
    countermoves: [64][64]Move = undefined,

    // Time management
    soft_limit: u64 = 0, // Target time
    hard_limit: u64 = 0, // Absolute limit

    pub fn new() Search {
        var search = Search{};
        search.clear_pv_table();
        search.clear_killer_moves();
        for (&search.history_moves) |*row| {
            @memset(row, 0);
        }
        const empty_move = move_generation.Move.empty();
        for (&search.countermoves) |*row| {
            @memset(row, empty_move);
        }
        return search;
    }

    inline fn clear_killer_moves(self: *Search) void {
        const empty = move_generation.Move.empty();
        for (0..MAX_PLY) |i| {
            self.killer_moves[0][i] = empty;
            self.killer_moves[1][i] = empty;
        }
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
        if (self.hard_limit > 0 and (self.nodes & 2047) == 0) {
            const elapsed = self.timer.read() / std.time.ns_per_ms;
            if (elapsed >= self.hard_limit) {
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
            if (best_score >= adj_beta) {
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
        move_scores.score_move(board, &move_list, &score_list, pv_move, Move.empty());

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

    // Adjust mate score for TT storage: convert ply-relative to position-relative
    inline fn score_to_tt(score: i32, ply: u16) i32 {
        if (score > MATE_VALUE - 100) return score + @as(i32, @intCast(ply));
        if (score < -MATE_VALUE + 100) return score - @as(i32, @intCast(ply));
        return score;
    }

    // Adjust mate score from TT: convert position-relative to ply-relative
    inline fn score_from_tt(score: i16, ply: u16) i32 {
        const s: i32 = score;
        if (s > MATE_VALUE - 100) return s - @as(i32, @intCast(ply));
        if (s < -MATE_VALUE + 100) return s + @as(i32, @intCast(ply));
        return s;
    }

    // negamax alpha beta search with PVS (Principal Variation Search)
    // PVS optimizes search by using null-window searches for non-PV nodes
    pub fn negamax(self: *Search, board: *types.Board, depth: u8, mut_alpha: i32, beta: i32, do_null: bool, prev_move: Move, comptime color: types.Color) i32 {
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
        var adj_beta = beta;
        const is_root = (self.ply == 0);
        const is_pv_node = (adj_beta - alpha > 1);

        // Mate distance pruning: if we already found a shorter mate, prune
        if (!is_root) {
            alpha = @max(alpha, -MATE_VALUE + @as(i32, @intCast(self.ply)));
            adj_beta = @min(adj_beta, MATE_VALUE - @as(i32, @intCast(self.ply)) - 1);
            if (alpha >= adj_beta) return alpha;
        }

        // TT probe
        var tt_move: Move = Move.empty();
        if (!is_root) {
            if (global_tt) |*tt| {
                if (tt.probe(board.hash)) |entry| {
                    tt_move = entry.best_move;

                    // Use TT score for cutoffs at non-PV nodes with sufficient depth
                    if (!is_pv_node and entry.depth >= depth) {
                        const tt_score = score_from_tt(entry.score, self.ply);

                        switch (entry.flag) {
                            .EXACT => return tt_score,
                            .LOWER => {
                                if (tt_score >= adj_beta) return tt_score;
                            },
                            .UPPER => {
                                if (tt_score <= alpha) return tt_score;
                            },
                            .NONE => {},
                        }
                    }
                }
            }
        }

        var legal_moves: u32 = 0;
        var best_so_far: move_generation.Move = Move.empty();
        var best_score: i32 = -INFINITY;
        const old_alpha = alpha;
        const in_check = self.is_king_in_check(board, color);
        const opponent = if (color == types.Color.White) types.Color.Black else types.Color.White;

        // Static eval for pruning decisions (only when not in check, not PV)
        const can_static_prune = !is_pv_node and !in_check;
        var static_eval: i32 = 0;
        if (can_static_prune) {
            static_eval = eval.global_evaluator.eval(board.*, color);

            // Reverse Futility Pruning (RFP)
            // If static eval is far above beta, this node is likely to fail high
            if (depth <= 6) {
                if (static_eval - @as(i32, 80) * @as(i32, depth) >= adj_beta) {
                    return static_eval;
                }
            }
        }

        // Null Move Pruning (NMP)
        if (do_null and !is_pv_node and !in_check and depth >= 3) {
            const has_non_pawn = if (color == .White)
                (board.pieces[types.Piece.WHITE_KNIGHT.toU4()] |
                    board.pieces[types.Piece.WHITE_BISHOP.toU4()] |
                    board.pieces[types.Piece.WHITE_ROOK.toU4()] |
                    board.pieces[types.Piece.WHITE_QUEEN.toU4()]) != 0
            else
                (board.pieces[types.Piece.BLACK_KNIGHT.toU4()] |
                    board.pieces[types.Piece.BLACK_BISHOP.toU4()] |
                    board.pieces[types.Piece.BLACK_ROOK.toU4()] |
                    board.pieces[types.Piece.BLACK_QUEEN.toU4()]) != 0;

            if (has_non_pawn) {
                const nm_state = board.save_state();
                const nm_eval = eval.global_evaluator;

                // Make null move: clear en passant, flip side, update hash
                if (board.enpassant != types.square.NO_SQUARE) {
                    board.hash ^= zobrist.ep_keys[@intFromEnum(board.enpassant) % 8];
                }
                board.enpassant = types.square.NO_SQUARE;
                board.hash ^= zobrist.side_key;
                board.side = opponent;

                self.ply += 1;

                // Adaptive reduction: R = 3 + depth/6
                const R: u8 = 3 + depth / 6;
                const null_depth: u8 = if (depth > R) depth - R else 0;

                const null_score = -self.negamax(board, null_depth, -adj_beta, -adj_beta + 1, false, Move.empty(), opponent);

                self.ply -= 1;
                board.restore_state(nm_state);
                eval.global_evaluator = nm_eval;

                if (self.stop) return 0;

                if (null_score >= adj_beta) {
                    return adj_beta;
                }
            }
        }

        // Futility pruning flag: at shallow depths, skip quiet moves
        const futility_margins = [4]i32{ 0, 200, 400, 600 };
        const futility_pruning = can_static_prune and depth >= 1 and depth <= 3 and
            static_eval + futility_margins[@as(usize, depth)] < alpha;

        // Generate moves
        var move_list: lists.MoveList = .{};
        move_generation.generate_moves(board, &move_list, color);

        // Use TT move for ordering if available, otherwise PV move
        const order_move = if (!tt_move.is_empty())
            tt_move
        else if (self.pv_length[self.ply] > 0)
            self.pv_table[self.ply][0]
        else
            move_generation.Move.empty();

        // Look up countermove for the previous move
        const countermove = if (!prev_move.is_empty())
            self.countermoves[prev_move.from][prev_move.to]
        else
            Move.empty();

        // Generate move scores
        var score_list: lists.ScoreList = .{};
        move_scores.score_move(board, &move_list, &score_list, order_move, countermove);

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

            // Futility pruning: skip quiet moves that can't raise alpha
            if (futility_pruning and legal_moves > 1) {
                const is_capture_fp = move_generation.Print_move_list.is_capture(move);
                const is_promotion_fp = move_generation.Print_move_list.is_promotion(move);
                if (!is_capture_fp and !is_promotion_fp) {
                    const gives_check_fp = self.is_king_in_check(board, opponent);
                    if (!gives_check_fp) {
                        self.ply -= 1;
                        board.restore_state(board_state);
                        eval.global_evaluator = saved_eval;
                        continue;
                    }
                }
            }

            // Check extension: extend search by 1 ply when this move gives check
            const gives_check = self.is_king_in_check(board, opponent);
            const extension: u8 = if (gives_check) 1 else 0;
            const new_depth = depth - 1 + extension;

            // PVS + LMR (Late Move Reductions)
            var score: i32 = undefined;

            if (legal_moves == 1) {
                // First legal move: always full depth, full window
                score = -self.negamax(board, new_depth, -adj_beta, -alpha, true, move, opponent);
            } else {
                // Determine LMR reduction for non-first moves
                var reduction: u8 = 0;
                const is_capture_move = move_generation.Print_move_list.is_capture(move);
                const is_promotion_move = move_generation.Print_move_list.is_promotion(move);

                if (depth >= 3 and legal_moves >= 4 and !in_check and !is_capture_move and !is_promotion_move) {
                    // Check if move is a killer at the parent ply
                    const parent_ply = self.ply - 1;
                    const is_killer = (move.from == self.killer_moves[0][parent_ply].from and
                        move.to == self.killer_moves[0][parent_ply].to) or
                        (move.from == self.killer_moves[1][parent_ply].from and
                        move.to == self.killer_moves[1][parent_ply].to);

                    if (!gives_check and !is_killer) {
                        reduction = lmr_reductions[@min(@as(usize, depth), 63)][@min(legal_moves, 63)];
                        // Reduce less in PV nodes
                        if (is_pv_node and reduction > 0) reduction -= 1;
                        // Don't reduce below depth 1
                        if (reduction >= new_depth) reduction = if (new_depth >= 2) new_depth - 1 else 0;
                    }
                }

                // LMR or PVS null window search (possibly at reduced depth)
                score = -self.negamax(board, new_depth - reduction, -alpha - 1, -alpha, true, move, opponent);

                // If reduced search failed high, re-search at full depth null window
                if (reduction > 0 and score > alpha) {
                    score = -self.negamax(board, new_depth, -alpha - 1, -alpha, true, move, opponent);
                }

                // If null window failed high, re-search with full window (PVS)
                if (score > alpha and score < adj_beta) {
                    score = -self.negamax(board, new_depth, -adj_beta, -alpha, true, move, opponent);
                }
            }

            self.ply -= 1;

            board.restore_state(board_state);
            eval.global_evaluator = saved_eval;

            if (self.stop) return 0;

            // Track best score and move
            if (score > best_score) {
                best_score = score;
                best_so_far = move;
            }

            // fail-hard beta cutoff
            if (score >= adj_beta) {
                if (!move_generation.Print_move_list.is_capture(move)) {
                    self.killer_moves[1][self.ply] = self.killer_moves[0][self.ply];
                    self.killer_moves[0][self.ply] = move;

                    // Gravity-style history update: prevents overflow and ages old entries
                    const bonus: i32 = @as(i32, depth) * @as(i32, depth);
                    const entry = &self.history_moves[move.from][move.to];
                    entry.* += bonus - @divTrunc(entry.* * bonus, 16384);

                    // Countermove heuristic: this move refutes the previous move
                    if (!prev_move.is_empty()) {
                        self.countermoves[prev_move.from][prev_move.to] = move;
                    }
                }

                // Store in TT as lower bound (beta cutoff)
                if (global_tt) |*tt| {
                    tt.store(
                        board.hash,
                        depth,
                        score_to_tt(score, self.ply),
                        .LOWER,
                        move,
                    );
                }

                return adj_beta;
            }

            // found a better move
            if (score > alpha) {

                // PV node (move)
                alpha = score;

                // Update PV
                if (self.ply < MAX_PLY) {
                    self.update_pv(move);
                }

                // if root move
                if (is_root) {
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

        // Store in TT
        if (global_tt) |*tt| {
            const tt_flag: tt_mod.TTFlag = if (alpha > old_alpha) .EXACT else .UPPER;
            tt.store(
                board.hash,
                depth,
                score_to_tt(alpha, self.ply),
                tt_flag,
                best_so_far,
            );
        }

        // node fails low
        return alpha;
    }

    // Main search function
    pub fn search_position(self: *Search, board: *types.Board, max_depth: ?u8, soft_limit_ms: u64, hard_limit_ms: u64, comptime color: types.Color) void {
        self.nodes = 0;
        self.stop = false;
        self.timer = std.time.Timer.start() catch unreachable;
        self.soft_limit = soft_limit_ms;
        self.hard_limit = hard_limit_ms;
        self.ply = 0; // Reset ply counter
        self.clear_pv_table();
        var best_move_found: ?move_generation.Move = null;
        var best_completed_depth: u8 = 0;

        // Signal new search to TT for age-based replacement
        if (global_tt) |*tt| {
            tt.new_search();
        }

        const depth_limit = max_depth orelse 64;

        // Stability tracking for time management
        var prev_best_move: Move = Move.empty();
        var best_move_changes: u32 = 0;

        // Iterative deepening with aspiration windows
        var current_depth: u8 = 1;
        var prev_score: i32 = 0;
        while (current_depth <= depth_limit) : (current_depth += 1) {
            // Reset ply for each iteration
            self.ply = 0;

            var score: i32 = undefined;

            if (current_depth >= 4) {
                // Aspiration windows: search with narrow window around previous score
                // Widening sequence: ±25 → ±100 → ±400 → full window
                var delta: i32 = 25;
                var asp_alpha: i32 = @max(prev_score - delta, -INFINITY);
                var asp_beta: i32 = @min(prev_score + delta, INFINITY);

                while (true) {
                    self.ply = 0;
                    score = self.negamax(board, current_depth, asp_alpha, asp_beta, true, Move.empty(), color);
                    if (self.stop) break;

                    if (score <= asp_alpha) {
                        // Fail low: widen alpha
                        delta = if (delta <= 25) @as(i32, 100) else if (delta <= 100) @as(i32, 400) else INFINITY;
                        asp_alpha = if (delta >= INFINITY) -INFINITY else @max(prev_score - delta, -INFINITY);
                    } else if (score >= asp_beta) {
                        // Fail high: widen beta
                        delta = if (delta <= 25) @as(i32, 100) else if (delta <= 100) @as(i32, 400) else INFINITY;
                        asp_beta = if (delta >= INFINITY) INFINITY else @min(prev_score + delta, INFINITY);
                    } else {
                        break;
                    }
                }
            } else {
                score = self.negamax(board, current_depth, -INFINITY, INFINITY, true, Move.empty(), color);
            }

            // Check if search was interrupted
            if (self.stop) {
                print("info string Search interrupted at depth {}\n", .{current_depth});
                break;
            }

            // This iteration completed successfully - save the best move
            if (self.pv_length[0] > 0) {
                const iter_best = self.pv_table[0][0];
                best_move_found = iter_best;
                best_completed_depth = current_depth;

                // Track move stability: did the best move change?
                if (current_depth >= 2) {
                    if (prev_best_move.from != iter_best.from or prev_best_move.to != iter_best.to) {
                        best_move_changes += 1;
                    }
                }
                prev_best_move = iter_best;
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

            // NPS calculation
            const nps: u64 = if (elapsed > 0) self.nodes * 1000 / elapsed else self.nodes;
            print("nodes {} time {} nps {} ", .{ self.nodes, elapsed, nps });

            // Hashfull from TT
            if (global_tt) |*tt_ref| {
                print("hashfull {} ", .{tt_ref.hashfull()});
            }

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

            if (score > MATE_VALUE - 100 or score < -MATE_VALUE + 100) {
                break;
            }

            //time management
            if (self.soft_limit > 0) {
                var time_scale: u64 = 100;

                if (best_move_changes >= 3) {
                    time_scale = 180;
                } else if (best_move_changes >= 2) {
                    time_scale = 150;
                } else if (best_move_changes >= 1) {
                    time_scale = 130;
                }

                const score_diff = if (score > prev_score) score - prev_score else prev_score - score;
                if (current_depth >= 3 and score_diff > 50) {
                    time_scale = @min(time_scale + 30, 200);
                }

                const adjusted_limit = self.soft_limit * time_scale / 100;
                // Never exceed hard limit
                const effective_limit = @min(adjusted_limit, self.hard_limit);

                if (elapsed > effective_limit) {
                    print("info string Time management: stopping after depth {} ({}ms, soft={}ms, scale={}%)\n", .{ current_depth, elapsed, self.soft_limit, time_scale });
                    break;
                }
            }

            prev_score = score;
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
            print("info string Using fallback move - no completed iterations\n", .{});
            var move_list: lists.MoveList = .{};
            move_generation.generate_moves(board, &move_list, color);
            for (0..move_list.count) |fi| {
                const board_state = board.save_state();
                const saved_eval = eval.global_evaluator;
                if (move_generation.make_move(board, move_list.moves[fi])) {
                    board.restore_state(board_state);
                    eval.global_evaluator = saved_eval;
                    const fallback_move = move_list.moves[fi];
                    const from = types.SquareString.getSquareToString(@enumFromInt(fallback_move.from));
                    const to = types.SquareString.getSquareToString(@enumFromInt(fallback_move.to));
                    print("bestmove {s}{s}\n", .{ from, to });
                    break;
                } else {
                    board.restore_state(board_state);
                    eval.global_evaluator = saved_eval;
                }
            }
        }
    }
};
