const std = @import("std");
const lists = @import("lists.zig");
const eval = @import("evaluation.zig");
const move_gen = @import("move.zig");
const types = @import("types.zig");
const bitboard = @import("bitboard.zig");
const util = @import("util.zig");
const move_scores = @import("score_moves.zig");
const tt_mod = @import("tt.zig");
const zobrist = @import("zobrist.zig");
const movegen = @import("movegen.zig");
const nnue = @import("nnue.zig");
const clock = @import("clock.zig");
const Move = move_gen.Move;

pub var global_search: Search = undefined;
// Mute all UCI output (datagen reads best_move / best_score directly)
pub var silent: bool = false;

pub fn search_position(board: *types.Board, max_depth: ?u8, soft_limit: u64, hard_limit: u64, comptime color: types.Color) void {
    global_search.search_position(board, max_depth, soft_limit, hard_limit, color);
}

// search_position for callers that only know the side at runtime
pub fn search_position_rt(board: *types.Board, max_depth: ?u8, soft_limit: u64, hard_limit: u64) void {
    switch (board.side) {
        inline .White, .Black => |c| search_position(board, max_depth, soft_limit, hard_limit, c),
        .both => unreachable,
    }
}

pub fn init_search() void {
    global_search = Search.new();
}

var stdout_buf: [1024]u8 = undefined;
var stdout_fw: ?std.Io.File.Writer = null;

fn print(comptime fmt: []const u8, args: anytype) void {
    if (silent) return;
    if (stdout_fw == null)
        stdout_fw = std.Io.File.stdout().writerStreaming(clock.io, &stdout_buf);
    const w = &stdout_fw.?.interface;
    w.print(fmt, args) catch return;
    // Flush every call so the GUI gets each line at once
    w.flush() catch {};
}

// Store into the TT if one is allocated
inline fn tt_store(hash: u64, depth: u8, score: i32, flag: tt_mod.TTFlag, move: Move, static_eval: i16, pv: bool) void {
    if (tt_mod.global) |*tt| tt.store(hash, depth, score, flag, move, static_eval, pv);
}

// Start loading the TT entry the child will probe
inline fn tt_prefetch(hash: u64) void {
    if (tt_mod.global) |*tt| tt.prefetch(hash);
}

const INFINITY: i32 = 32500;
const MATE_VALUE = types.MATE_VALUE;
const MATE_BOUND = types.MATE_BOUND; // |score| above = mate
const MAX_PLY: usize = 128;
const MAX_QUIESCENCE_DEPTH: i8 = 16;
// Qsearch delta-pruning piece values (P, N, B, R, Q, K)
const QS_PIECE_VALUES = [_]i32{ 100, 320, 330, 500, 900, 10000 };

// Tunable search parameters, exposed 1:1 as UCI spin options for SPSA
pub var params: Params = .{};
pub const Params = struct {
    rfp_base: i32 = 70, // RFP margin per depth (improving)
    rfp_impr: i32 = 20, // extra RFP margin when not improving
    rfp_depth: i32 = 8, // RFP max depth
    razor_base: i32 = 150,
    razor_impr: i32 = 75,
    nmp_base: i32 = 5, // NMP R = base + depth/div
    nmp_div: i32 = 5, // NMP depth divisor
    fut_base: i32 = 200, // futility margin = base*depth (depth 1-3)
    fut_impr: i32 = 80, // extra futility margin when not improving
    lmp_mult: i32 = 100, // % multiplier on the LMP limits
    lmr_base: i32 = 100, // LMR = base/100 + ln(d)*ln(m)/(div/100)
    lmr_div: i32 = 200,
    lmr_hist_div: i32 = 4000,
    lmr_evald_div: i32 = 350,
    lmr_movegate: i32 = 4, // first N legal moves are never reduced
    histprune_mult: i32 = 2000, // prune quiets with history < -mult*depth
    asp_delta: i32 = 25, // first aspiration half-window
    tm_gate_pct: i32 = 60, // start a new iteration only below pct% of the soft limit
    tm_stab_coef: i32 = 4, // soft limit -coef% per stable iteration
    tm_impr_coef: i32 = 4, // soft limit -coef% per score-trend step
    tm_hard_pct: i32 = 46, // hard limit = pct% of (clock - overhead)
    tm_collapse_ms: i32 = 1000, // below this clock the move horizon collapses
    tm_collapse_div: i32 = 20, // collapsed horizon = clock/div moves, min 2
    tm_win_cp: i32 = 1000, // |score| above this counts as decided
    tm_win_pct: i32 = 60, // time budget % when clearly winning
    tm_loss_pct: i32 = 50, // time budget % when clearly losing
    qs_delta: i32 = 1000000, // qsearch delta margin; 1000000 = off
    se_depth: i32 = 8, // singular-extension min depth
    iir_depth: i32 = 4, // IIR min depth
    // Thesis ablation switches: 0 = feature on (default), 1 = feature off
    dis_pvs: i32 = 0, // full window for every move (no scout)
    dis_qsearch: i32 = 0, // static eval at the horizon instead of qsearch
    dis_nmp: i32 = 0, // no null-move pruning
    dis_ordhist: i32 = 0, // no killer/history terms in move ordering
    dis_counter: i32 = 0, // no countermove term in move ordering
    dis_conthist: i32 = 0, // no continuation-history term in move ordering
};

// LMR table, built at compile time from the default params
var lmr_reductions: [64][64]u8 = lmr_table(1.0, 2.0);

// LMR reduction = base + ln(depth) * ln(move number) / div
fn lmr_table(base: f64, div: f64) [64][64]u8 {
    @setEvalBranchQuota(10000);
    var table: [64][64]u8 = .{[_]u8{0} ** 64} ** 64;
    for (1..64) |d| {
        for (1..64) |m| {
            const r = base + @log(@as(f64, @floatFromInt(d))) * @log(@as(f64, @floatFromInt(m))) / div;
            table[d][m] = @intFromFloat(@min(@max(r, 0.0), 63.0));
        }
    }
    return table;
}

// Rebuild the LMR table after a setoption
pub fn rebuild_tables() void {
    lmr_reductions = lmr_table(@as(f64, @floatFromInt(params.lmr_base)) / 100.0, @as(f64, @floatFromInt(params.lmr_div)) / 100.0);
}

// Quiets allowed before late-move pruning: lmp_table[improving][depth]
const lmp_table = [2][11]u32{
    .{ 0, 2, 3, 5, 9, 13, 18, 25, 34, 45, 55 },
    .{ 0, 5, 6, 9, 14, 21, 30, 41, 55, 69, 84 },
};

// Continuation history, indexed [prev_piece][prev_to][piece][to]
const ContHist = [6][64][6][64]i32;

// History gravity: add bonus while pulling the entry back from +-16384
inline fn gravity(entry: *i32, bonus: i32) void {
    entry.* += bonus - @divTrunc(entry.* * @as(i32, @intCast(@abs(bonus))), 16384);
}

pub const Search = struct {
    best_move: Move = undefined,
    best_score: i32 = 0, // score of the last completed iteration (datagen)
    stop: bool = false,
    timer: clock.Timer = undefined,
    hard_deadline: clock.Deadline = .never,
    nodes: u64 = 0,
    ply: u16 = 0,

    // Principal variation per ply
    pv_length: [MAX_PLY]u16 = undefined,
    pv_table: [MAX_PLY][MAX_PLY]Move = undefined,

    // Move ordering: two killers per ply, butterfly history, refutation per previous move
    killer_moves: [2][MAX_PLY]Move = undefined,
    history_moves: [64][64]i32 = undefined,
    countermoves: [64][64]Move = undefined,

    // Hashes before the root and along the search path, for repetition detection
    game_hashes: [512]u64 = undefined,
    game_count: u16 = 0,
    search_hashes: [MAX_PLY]u64 = undefined,

    // Time limits in ms
    soft_limit: u64 = 0,
    hard_limit: u64 = 0,

    // Datagen node limits (0 = off); soft is checked only between iterations
    soft_nodes: u64 = 0,
    hard_nodes: u64 = 0,
    hard_node_hit: bool = false,

    // Static eval per ply for "improving"; -INFINITY = side was in check
    eval_stack: [MAX_PLY]i32 = [_]i32{0} ** MAX_PLY,

    // Move and piece type per ply for continuation history; piece 6 = none (null move)
    stack_moves: [MAX_PLY]Move = undefined,
    stack_pieces: [MAX_PLY]u4 = undefined,

    // Continuation history for the move 1 ply back (counter) and 2 plies back (follow)
    sc_counter_table: ContHist = undefined,
    sc_follow_table: ContHist = undefined,

    // Move skipped at each ply during a singular-extension search
    excluded: [MAX_PLY]Move = undefined,

    pub fn new() Search {
        var s = Search{};
        @memset(&s.pv_length, 0);
        for (&s.killer_moves) |*k| @memset(k, Move.empty());
        for (&s.history_moves) |*row| @memset(row, 0);
        for (&s.countermoves) |*row| @memset(row, Move.empty());
        @memset(&s.stack_moves, Move.empty());
        @memset(&s.stack_pieces, 6);
        @memset(std.mem.asBytes(&s.sc_counter_table), 0);
        @memset(std.mem.asBytes(&s.sc_follow_table), 0);
        @memset(&s.excluded, Move.empty());
        return s;
    }

    // Remember a game position before the root for repetition detection
    pub fn push_game_hash(self: *Search, hash: u64) void {
        if (self.game_count < self.game_hashes.len) {
            self.game_hashes[self.game_count] = hash;
            self.game_count += 1;
        }
    }

    // PV at this ply = move + the child's PV
    inline fn update_pv(self: *Search, move: Move) void {
        const n = self.pv_length[self.ply + 1];
        self.pv_table[self.ply][0] = move;
        @memcpy(self.pv_table[self.ply][1 .. n + 1], self.pv_table[self.ply + 1][0..n]);
        self.pv_length[self.ply] = n + 1;
    }

    // Poll the clock every 1024 nodes
    inline fn check_time(self: *Search) void {
        if ((self.nodes & 1023) == 0) {
            if (self.hard_limit > 0 and self.hard_deadline.expired()) {
                self.stop = true;
            }
            if (self.hard_nodes > 0 and self.nodes >= self.hard_nodes) {
                self.stop = true;
                self.hard_node_hit = true;
            }
        }
    }

    // Continuation-history slot of (piece, to) after the move `back` plies above `ply`, or null
    inline fn cont_entry(self: *Search, table: *ContHist, ply: u16, back: u16, piece: u4, to: u6) ?*i32 {
        if (ply < back or piece >= 6) return null;
        const prev = self.stack_moves[ply - back];
        const prev_piece = self.stack_pieces[ply - back];
        if (prev.is_empty() or prev_piece >= 6) return null;
        return &table[prev_piece][prev.to][piece][to];
    }

    // Add a bonus (or malus) to both continuation histories of a move at the current ply
    inline fn cont_hist_update(self: *Search, piece: u4, to: u6, bonus: i32) void {
        if (self.cont_entry(&self.sc_counter_table, self.ply, 1, piece, to)) |e| gravity(e, bonus);
        if (self.cont_entry(&self.sc_follow_table, self.ply, 2, piece, to)) |e| gravity(e, bonus);
    }

    // Butterfly + continuation history of a quiet move made at `ply`
    inline fn quiet_history(self: *Search, ply: u16, move: Move, piece: u4) i32 {
        var h = self.history_moves[move.from][move.to];
        if (self.cont_entry(&self.sc_counter_table, ply, 1, piece, move.to)) |e| h += e.*;
        if (self.cont_entry(&self.sc_follow_table, ply, 2, piece, move.to)) |e| h += e.*;
        return h;
    }

    // Beta cutoff: reward a non-capture cutoff move, penalize the quiets tried before it
    inline fn update_histories(self: *Search, move: Move, piece: u4, prev_move: Move, depth: u8, quiets: []const Move, pieces: []const u4) void {
        const bonus: i32 = @as(i32, depth) * @as(i32, depth);
        if (!move.is_capture()) {
            self.killer_moves[1][self.ply] = self.killer_moves[0][self.ply];
            self.killer_moves[0][self.ply] = move;
            gravity(&self.history_moves[move.from][move.to], bonus);
            self.cont_hist_update(piece, move.to, bonus);
            if (!prev_move.is_empty()) self.countermoves[prev_move.from][prev_move.to] = move;
        }
        for (quiets, pieces) |q, p| {
            gravity(&self.history_moves[q.from][q.to], -bonus);
            self.cont_hist_update(p, q.to, -bonus);
        }
    }

    // Quiescence search: captures only, or all moves when in check
    pub fn quiescence(self: *Search, board: *types.Board, mut_alpha: i32, beta: i32, depth: i8, comptime color: types.Color) i32 {
        self.pv_length[self.ply] = 0;
        if (depth < -MAX_QUIESCENCE_DEPTH) return eval.global_evaluator.eval(board, color, mut_alpha, beta);

        self.nodes += 1;
        self.check_time();
        if (self.stop) return 0;
        if (self.ply >= MAX_PLY - 1) return eval.global_evaluator.eval(board, color, mut_alpha, beta);

        const opponent = comptime color.other();
        const ply: i32 = self.ply;

        // Mate distance pruning
        var alpha = @max(mut_alpha, -MATE_VALUE + ply);
        const adj_beta = @min(beta, MATE_VALUE - ply - 1);
        if (alpha >= adj_beta) return alpha;
        const is_pv = adj_beta - alpha > 1;

        // TT probe: any stored depth is enough for a qsearch cutoff
        var tt_move = Move.empty();
        var tt_static: i16 = tt_mod.NO_EVAL;
        var tt_pv = is_pv; // PV now, or PV when stored
        if (tt_mod.global) |*tt| {
            if (tt.probe(board.hash)) |entry| {
                tt_move = entry.best_move;
                tt_static = entry.static_eval;
                tt_pv = tt_pv or entry.pv;
                const tts = tt_mod.score_from_tt(entry.score, self.ply);
                if (!is_pv and tt_mod.cutoff(entry.flag, tts, alpha, adj_beta)) return tts;
            }
        }

        const in_check = bitboard.king_attacked(board, color);
        var best_score: i32 = -MATE_VALUE + ply; // in check: mated unless a move escapes
        var static_for_tt: i16 = tt_mod.NO_EVAL;
        if (!in_check) {
            // Stand pat (the TT copy of an NNUE eval is exact)
            best_score = if (nnue.use_nnue and tt_static != tt_mod.NO_EVAL) tt_static else eval.global_evaluator.eval(board, color, alpha, adj_beta);
            static_for_tt = @intCast(std.math.clamp(best_score, -30000, 30000));
            if (best_score >= adj_beta) {
                tt_store(board.hash, 0, tt_mod.score_to_tt(best_score, self.ply), .LOWER, Move.empty(), static_for_tt, tt_pv);
                return best_score;
            }
            alpha = @max(alpha, best_score);
        }

        var move_list: lists.MoveList = .{};
        if (in_check) {
            movegen.generate_legal_moves(board, &move_list, color);
        } else {
            movegen.generate_legal_captures(board, &move_list, color);
        }
        if (in_check and move_list.count == 0) return -MATE_VALUE + ply;

        var score_list: lists.ScoreList = .{};
        move_scores.score_move(board, &move_list, &score_list, tt_move, Move.empty());

        var best_move_q = Move.empty();
        for (0..move_list.count) |i| {
            const move = move_scores.get_next_best_move(&move_list, &score_list, i);
            const mscore = score_list.scores[i]; // ordering score, carries the SEE class

            // Prune captures (not EP or promotions): delta pruning, then losing SEE
            if (!in_check and move.is_capture() and !move.is_promotion() and move.flags != types.MoveFlags.EN_PASSANT) {
                if (board.get_piece_type_at(move.to)) |victim| {
                    if (best_score + QS_PIECE_VALUES[@intFromEnum(victim)] + params.qs_delta < alpha) continue;
                }
                if (mscore <= move_scores.SCORE_BAD_CAPTURE + 3000) continue;
            }

            self.ply += 1;
            const undo = move_gen.make_move_search(board, move, color);
            tt_prefetch(board.hash);
            const score = -self.quiescence(board, -adj_beta, -alpha, depth - 1, opponent);
            self.ply -= 1;
            move_gen.unmake_move_search(board, move, undo, color);
            if (self.stop) return 0;

            if (score > best_score) {
                best_score = score;
                best_move_q = move;
                if (score > alpha) {
                    alpha = score;
                    self.update_pv(move);
                    if (alpha >= adj_beta) {
                        tt_store(board.hash, 0, tt_mod.score_to_tt(score, self.ply), .LOWER, move, static_for_tt, tt_pv);
                        return alpha;
                    }
                }
            }
        }

        // EXACT if alpha was raised, else UPPER
        tt_store(board.hash, 0, tt_mod.score_to_tt(best_score, self.ply), if (best_score > mut_alpha) .EXACT else .UPPER, best_move_q, static_for_tt, tt_pv);
        return best_score;
    }

    // Alpha-beta negamax with PVS, pruning, reductions and extensions
    pub fn negamax(self: *Search, board: *types.Board, depth_in: u8, mut_alpha: i32, beta: i32, do_null: bool, prev_move: Move, comptime color: types.Color) i32 {
        self.pv_length[self.ply] = 0;
        if (depth_in == 0) {
            // Ablation dis_qsearch: raw static eval at the horizon
            if (params.dis_qsearch != 0) return eval.global_evaluator.eval(board, color, mut_alpha, beta);
            return self.quiescence(board, mut_alpha, beta, 0, color);
        }
        // Ply ceiling: keeps every per-ply array below in bounds
        if (self.ply >= MAX_PLY - 1) return eval.global_evaluator.eval(board, color, mut_alpha, beta);

        self.nodes += 1;
        self.check_time();
        if (self.stop) return 0;

        var depth = depth_in; // IIR may lower it
        const ply: i32 = self.ply;
        const skip_move = !self.excluded[self.ply].is_empty(); // inside a singular-extension search
        var alpha = mut_alpha;
        var adj_beta = beta;
        const is_root = self.ply == 0;
        const is_pv_node = adj_beta - alpha > 1;

        self.search_hashes[self.ply] = board.hash;
        if (!is_root) {
            // Draw by 50-move rule, repetition in the search path, or repetition of a game position
            if (board.halfmove >= 100) return 0;
            var j: i32 = ply - 2;
            while (j >= 0) : (j -= 2) {
                if (self.search_hashes[@intCast(j)] == board.hash) return 0;
            }
            const scan_limit = @min(@as(u32, self.game_count), @as(u32, board.halfmove) + 1);
            for (0..scan_limit) |gi| {
                if (self.game_hashes[self.game_count - 1 - gi] == board.hash) return 0;
            }

            // Mate distance pruning
            alpha = @max(alpha, -MATE_VALUE + ply);
            adj_beta = @min(adj_beta, MATE_VALUE - ply - 1);
            if (alpha >= adj_beta) return alpha;
        }

        // TT probe (not inside singular searches); score, depth and bound are kept for SE
        var tt_move = Move.empty();
        var tt_hit = false;
        var tt_score: i32 = 0;
        var tt_depth: u8 = 0;
        var tt_bound: tt_mod.TTFlag = .NONE;
        var tt_static_eval: i16 = tt_mod.NO_EVAL;
        var tt_pv = is_pv_node; // PV now, or PV when stored
        if (!skip_move) {
            if (tt_mod.global) |*tt| {
                if (tt.probe(board.hash)) |entry| {
                    tt_hit = true;
                    tt_pv = tt_pv or entry.pv;
                    tt_move = entry.best_move;
                    tt_score = tt_mod.score_from_tt(entry.score, self.ply);
                    tt_depth = entry.depth;
                    tt_bound = entry.flag;
                    tt_static_eval = entry.static_eval;
                    if (!is_root and !is_pv_node and entry.depth >= depth and tt_mod.cutoff(entry.flag, tt_score, alpha, adj_beta)) return tt_score;
                }
            }
        }

        // IIR: no TT move means poor ordering, so search one ply shallower
        if (@as(i32, depth) >= params.iir_depth and !tt_hit and !is_root) depth -= 1;

        const in_check = bitboard.king_attacked(board, color);
        const opponent = comptime color.other();

        // Static eval, and "improving" = better than 4 (else 2) plies ago
        var static_eval: i32 = 0;
        var improving: u1 = 0;
        if (in_check) {
            self.eval_stack[self.ply] = -INFINITY;
        } else {
            // The TT copy of an NNUE eval is exact (HCE depends on the window)
            static_eval = if (nnue.use_nnue and tt_static_eval != tt_mod.NO_EVAL) tt_static_eval else eval.global_evaluator.eval(board, color, alpha, adj_beta);
            self.eval_stack[self.ply] = static_eval;
            if (self.ply >= 4 and self.eval_stack[self.ply - 4] != -INFINITY) {
                improving = @intFromBool(static_eval > self.eval_stack[self.ply - 4]);
            } else if (self.ply >= 2 and self.eval_stack[self.ply - 2] != -INFINITY) {
                improving = @intFromBool(static_eval > self.eval_stack[self.ply - 2]);
            }
        }
        const se_for_tt: i16 = if (in_check) tt_mod.NO_EVAL else @intCast(std.math.clamp(static_eval, -30000, 30000));

        const can_static_prune = !is_pv_node and !in_check and !skip_move;
        const impr: i32 = improving;
        if (can_static_prune) {
            // Reverse futility pruning: eval beats beta by a depth-scaled margin
            if (depth <= params.rfp_depth) {
                const rfp_margin: i32 = (params.rfp_base + params.rfp_impr * (1 - impr)) * @as(i32, depth);
                if (static_eval - rfp_margin >= adj_beta) return static_eval;
            }

            // Razoring: eval far below alpha at depth <= 2, confirm with qsearch
            if (depth <= 2) {
                const razor_margin: i32 = params.razor_base + impr * params.razor_impr;
                if (static_eval + razor_margin <= alpha) {
                    const razor_score = self.quiescence(board, alpha - 1, alpha, 0, color);
                    if (razor_score <= alpha) return razor_score;
                }
            }
        }

        // Null-move pruning: pass, and cut if a reduced search still beats beta
        if (do_null and params.dis_nmp == 0 and !is_pv_node and !in_check and !skip_move and depth >= 3 and board.has_non_pawn(color)) {
            const nm_hash = board.hash;
            const nm_ep = board.enpassant;
            if (board.enpassant != types.square.NO_SQUARE) {
                board.hash ^= zobrist.ep_keys[types.file_of(@intFromEnum(board.enpassant))];
            }
            board.enpassant = types.square.NO_SQUARE;
            board.hash ^= zobrist.side_key;
            board.side = opponent;
            self.stack_moves[self.ply] = Move.empty();
            self.stack_pieces[self.ply] = 6;
            self.ply += 1;

            const R: u8 = @intCast(params.nmp_base + @divTrunc(@as(i32, depth), params.nmp_div));
            const null_score = -self.negamax(board, if (depth > R) depth - R else 0, -adj_beta, -adj_beta + 1, false, Move.empty(), opponent);

            self.ply -= 1;
            board.hash = nm_hash;
            board.enpassant = nm_ep;
            board.side = color;
            if (self.stop) return 0;
            if (null_score >= adj_beta) return adj_beta;
        }

        // Futility: at depth 1-3 quiets can't lift an eval this far below alpha
        const futility_pruning = can_static_prune and depth >= 1 and depth <= 3 and
            static_eval + params.fut_base * @as(i32, depth) + (1 - impr) * params.fut_impr < alpha;

        var move_list: lists.MoveList = .{};
        movegen.generate_legal_moves(board, &move_list, color);

        // Order the TT move first, else a PV move a razoring qsearch left at this ply
        const order_move = if (!tt_move.is_empty()) tt_move else if (self.pv_length[self.ply] > 0) self.pv_table[self.ply][0] else Move.empty();
        const countermove = if (prev_move.is_empty()) Move.empty() else self.countermoves[prev_move.from][prev_move.to];
        var score_list: lists.ScoreList = .{};
        move_scores.score_move(board, &move_list, &score_list, order_move, countermove);

        const old_alpha = alpha;
        var best_score: i32 = -INFINITY;
        var best_so_far = Move.empty();
        var legal_moves: u32 = 0;
        var quiet_count: u32 = 0;
        // Quiets searched so far and their pieces, for the malus on a cutoff
        var quiets_tried: [64]Move = undefined;
        var quiet_pieces: [64]u4 = undefined;
        var n_quiets: u32 = 0;
        for (0..move_list.count) |i| {
            const move = move_scores.get_next_best_move(&move_list, &score_list, i);
            const mscore = score_list.scores[i]; // ordering score, carries the SEE class
            if (skip_move and move.same_squares(self.excluded[self.ply])) continue;

            // SEE pruning: skip captures losing more than 60cp per depth, before making them
            if (!in_check and !is_pv_node and depth <= 6 and legal_moves >= 1 and
                move.is_capture() and !move.is_promotion() and
                move.flags != types.MoveFlags.EN_PASSANT and
                mscore <= move_scores.SCORE_BAD_CAPTURE + 3000 and
                !move_scores.see(board, move, -60 * @as(i32, depth)))
            {
                continue;
            }

            // Singular extension: extend the TT move if all others fail below tt_score - depth
            var se_extension: u8 = 0;
            if (!is_root and !skip_move and @as(i32, depth) >= params.se_depth and
                !tt_move.is_empty() and move.same_squares(tt_move) and
                tt_depth + 3 >= depth and tt_bound == .LOWER and @abs(tt_score) < MATE_BOUND)
            {
                const singular_beta: i32 = @max(tt_score - @as(i32, depth), -MATE_BOUND);
                self.excluded[self.ply] = move;
                const se_score = self.negamax(board, (depth - 1) / 2, singular_beta - 1, singular_beta, false, prev_move, color);
                self.excluded[self.ply] = Move.empty();
                if (se_score < singular_beta) {
                    se_extension = 1;
                } else if (singular_beta >= adj_beta) {
                    return singular_beta; // multi-cut: another move beats beta too
                }
            }

            // Record move and piece for continuation history, then make the move
            const piece: u4 = if (board.get_piece_type_at(move.from)) |p| @intCast(@intFromEnum(p)) else 6;
            self.stack_moves[self.ply] = move;
            self.stack_pieces[self.ply] = piece;
            self.ply += 1;
            const undo = move_gen.make_move_search(board, move, color);
            legal_moves += 1;
            tt_prefetch(board.hash);

            const gives_check = bitboard.king_attacked(board, opponent);
            const extension: u8 = @max(se_extension, @as(u8, @intFromBool(gives_check)));
            const new_depth = depth - 1 + extension;
            const is_quiet = !move.is_capture() and !move.is_promotion();

            // Prune quiets: futility and late-move count (non-checks), then bad history
            var full_hist: i32 = 0;
            var prune = false;
            if (is_quiet) {
                if (legal_moves > 1 and !gives_check) {
                    if (futility_pruning) {
                        prune = true;
                    } else if (!in_check and !is_pv_node and depth <= 8) {
                        quiet_count += 1;
                        const lmp_limit: u32 = @intCast(util.pct(@as(i32, @intCast(lmp_table[improving][@min(depth, 10)])), params.lmp_mult));
                        prune = quiet_count > lmp_limit;
                    }
                }
                if (!prune) {
                    full_hist = self.quiet_history(self.ply - 1, move, piece);
                    prune = !in_check and !is_pv_node and depth <= 4 and full_hist < -params.histprune_mult * @as(i32, depth);
                }
            }
            if (prune) {
                self.ply -= 1;
                move_gen.unmake_move_search(board, move, undo, color);
                continue;
            }

            if (is_quiet and n_quiets < 64) {
                quiets_tried[n_quiets] = move;
                quiet_pieces[n_quiets] = piece;
                n_quiets += 1;
            }

            var score: i32 = undefined;
            if (legal_moves == 1) {
                // First move: full depth, full window
                score = -self.negamax(board, new_depth, -adj_beta, -alpha, true, move, opponent);
            } else {
                // LMR for late quiet moves that don't give check and aren't killers
                var reduction: u8 = 0;
                const node_ply = self.ply - 1;
                const is_killer = move.same_squares(self.killer_moves[0][node_ply]) or move.same_squares(self.killer_moves[1][node_ply]);
                if (depth >= 3 and legal_moves >= params.lmr_movegate and !in_check and is_quiet and !gives_check and !is_killer) {
                    var r: i16 = lmr_reductions[@min(depth, 63)][@min(legal_moves, 63)];
                    if (tt_pv and r > 0) r -= 1; // less in (former) PV nodes
                    if (improving == 0) r += 1; // more when not improving
                    r -= @as(i16, @intCast(std.math.clamp(@divTrunc(full_hist, params.lmr_hist_div), -4, 4))); // less with good history
                    const eval_dist: i32 = @intCast(@abs(static_eval - alpha));
                    r += @as(i16, @intCast(@min(@as(i32, 2), @divTrunc(eval_dist, params.lmr_evald_div)))); // more far from alpha
                    r = @max(0, @min(r, @as(i16, new_depth) - 1));
                    reduction = @intCast(r);
                }

                if (params.dis_pvs != 0) {
                    // Ablation dis_pvs: full window for every move, LMR kept
                    score = -self.negamax(board, new_depth - reduction, -adj_beta, -alpha, true, move, opponent);
                    if (reduction > 0 and score > alpha) score = -self.negamax(board, new_depth, -adj_beta, -alpha, true, move, opponent);
                } else {
                    // Null window at reduced depth, then at full depth, then full window
                    score = -self.negamax(board, new_depth - reduction, -alpha - 1, -alpha, true, move, opponent);
                    if (reduction > 0 and score > alpha) score = -self.negamax(board, new_depth, -alpha - 1, -alpha, true, move, opponent);
                    if (score > alpha and score < adj_beta) score = -self.negamax(board, new_depth, -adj_beta, -alpha, true, move, opponent);
                }
            }

            self.ply -= 1;
            move_gen.unmake_move_search(board, move, undo, color);
            if (self.stop) return 0;

            if (score > best_score) {
                best_score = score;
                best_so_far = move;
            }

            // Beta cutoff (fail-hard); a quiet cutoff move gets the bonus, not the malus
            if (score >= adj_beta) {
                const n_malus = if (is_quiet and n_quiets > 0) n_quiets - 1 else n_quiets;
                self.update_histories(move, piece, prev_move, depth, quiets_tried[0..n_malus], quiet_pieces[0..n_malus]);
                if (!skip_move) tt_store(board.hash, depth, tt_mod.score_to_tt(score, self.ply), .LOWER, move, se_for_tt, tt_pv);
                return adj_beta;
            }

            if (score > alpha) {
                alpha = score;
                self.update_pv(move);
                if (is_root) self.best_move = move;
            }
        }

        // No legal move: checkmate or stalemate
        if (legal_moves == 0) return if (in_check) -MATE_VALUE + ply else 0;

        // EXACT if alpha was raised, else UPPER (not inside singular searches)
        if (!skip_move) tt_store(board.hash, depth, tt_mod.score_to_tt(alpha, self.ply), if (alpha > old_alpha) .EXACT else .UPPER, best_so_far, se_for_tt, tt_pv);
        return alpha;
    }

    // One UCI info line for a completed iteration
    fn print_info(self: *Search, depth: u8, score: i32, elapsed: u64) void {
        print("info depth {} ", .{depth});
        if (score > MATE_BOUND) {
            print("score mate {} ", .{@divTrunc(MATE_VALUE - score + 1, 2)});
        } else if (score < -MATE_BOUND) {
            print("score mate -{} ", .{@divTrunc(MATE_VALUE + score + 1, 2)});
        } else {
            print("score cp {} ", .{score});
        }
        const nps: u64 = if (elapsed > 0) self.nodes * 1000 / elapsed else self.nodes;
        print("nodes {} time {} nps {} ", .{ self.nodes, elapsed, nps });
        // hashfull samples 1000 clusters, so skip it in fast games
        if (elapsed > 1000) {
            if (tt_mod.global) |*tt| print("hashfull {} ", .{tt.hashfull()});
        }
        if (self.pv_length[0] > 0) {
            print("pv ", .{});
            for (self.pv_table[0][0..self.pv_length[0]]) |m| {
                var mbuf: [5]u8 = undefined;
                print("{s} ", .{m.to_uci(&mbuf)});
            }
        }
        print("\n", .{});
    }

    // Iterative deepening with aspiration windows and time management, then print bestmove
    pub fn search_position(self: *Search, board: *types.Board, max_depth: ?u8, soft_limit_ms: u64, hard_limit_ms: u64, comptime color: types.Color) void {
        self.nodes = 0;
        self.stop = false;
        self.hard_node_hit = false;
        self.timer = .start();
        self.soft_limit = soft_limit_ms;
        self.hard_limit = hard_limit_ms;
        self.hard_deadline = if (hard_limit_ms > 0) .afterMs(hard_limit_ms) else .never;
        self.ply = 0;
        @memset(&self.pv_length, 0);
        self.best_move = Move.empty();
        var best_completed_depth: u8 = 0;

        // Root accumulator for incremental NNUE updates
        if (nnue.use_nnue) nnue.stack_init(board);
        defer nnue.stack_stop();

        // A single legal reply is played right after the first iteration
        var single_reply = false;
        if (self.soft_limit > 0) {
            var root_moves: lists.MoveList = .{};
            movegen.generate_legal_moves(board, &root_moves, color);
            single_reply = root_moves.count == 1;
        }

        if (tt_mod.global) |*tt| tt.new_search(); // ages entries for replacement

        const depth_limit = max_depth orelse 64;
        var prev_best_move = Move.empty();
        var stability: u8 = 0; // iterations with the same best move, max 10
        var prev_score: i32 = 0;
        var trend: i16 = 0; // score trend across iterations, -4..4
        var current_depth: u8 = 1;
        while (current_depth <= depth_limit) : (current_depth += 1) {
            self.ply = 0;
            var score: i32 = undefined;
            if (current_depth >= 4) {
                // Aspiration window around the last score; on a fail widen that side d, 4d, 16d, then fully
                var delta: i32 = params.asp_delta;
                var asp_alpha: i32 = @max(prev_score - delta, -INFINITY);
                var asp_beta: i32 = @min(prev_score + delta, INFINITY);
                while (true) {
                    self.ply = 0;
                    score = self.negamax(board, current_depth, asp_alpha, asp_beta, true, Move.empty(), color);
                    if (self.stop or (score > asp_alpha and score < asp_beta)) break;
                    delta = if (delta >= params.asp_delta * 16) INFINITY else delta * 4;
                    if (score <= asp_alpha) {
                        asp_alpha = if (delta >= INFINITY) -INFINITY else @max(prev_score - delta, -INFINITY);
                    } else {
                        asp_beta = if (delta >= INFINITY) INFINITY else @min(prev_score + delta, INFINITY);
                    }
                }
            } else {
                score = self.negamax(board, current_depth, -INFINITY, INFINITY, true, Move.empty(), color);
            }

            if (self.stop) {
                print("info string Search interrupted at depth {}\n", .{current_depth});
                break;
            }

            // Completed iteration: keep its move and score, track best-move stability
            if (self.pv_length[0] > 0) {
                const iter_best = self.pv_table[0][0];
                best_completed_depth = current_depth;
                self.best_move = iter_best;
                self.best_score = score;
                stability = if (prev_best_move.same_squares(iter_best)) @min(10, stability + 1) else 0;
                prev_best_move = iter_best;
            }

            if (self.soft_nodes > 0 and self.nodes >= self.soft_nodes) break; // datagen soft node limit
            if (single_reply and self.pv_length[0] > 0) break; // forced move

            const elapsed = self.timer.read() / std.time.ns_per_ms;
            self.print_info(current_depth, score, elapsed);
            if (score > MATE_BOUND or score < -MATE_BOUND) break; // mate found

            // Score trend: +-1 per 20cp change between iterations, +-2 per 60cp
            if (current_depth >= 3) {
                if (score > prev_score + 20) {
                    trend += 1;
                    if (score > prev_score + 60) trend += 1;
                } else if (score < prev_score - 20) {
                    trend -= 1;
                    if (score < prev_score - 60) trend -= 1;
                }
                trend = std.math.clamp(trend, -4, 4);
            }
            prev_score = score;

            // Soft limit shrinks with best-move stability and a rising score, grows with a falling one
            if (self.soft_limit > 0) {
                const stab_c: f32 = @as(f32, @floatFromInt(params.tm_stab_coef)) / 100.0;
                const trend_c: f32 = @as(f32, @floatFromInt(params.tm_impr_coef)) / 100.0;
                var factor: f32 = 1.0 - stab_c * @as(f32, @floatFromInt(stability)) - trend_c * @as(f32, @floatFromInt(trend));
                factor = std.math.clamp(factor, 0.5, 1.5);
                // Decided positions: bank time
                if (score >= params.tm_win_cp) {
                    factor *= @as(f32, @floatFromInt(params.tm_win_pct)) / 100.0;
                } else if (score <= -params.tm_win_cp) {
                    factor *= @as(f32, @floatFromInt(params.tm_loss_pct)) / 100.0;
                }
                factor = @max(0.01, factor); // negative SPSA percentages would break the u64 cast
                const adjusted_limit: u64 = @intFromFloat(@as(f32, @floatFromInt(self.soft_limit)) * factor);
                // Start the next iteration only below tm_gate_pct% of the budget
                if (elapsed * 100 >= @min(adjusted_limit, self.hard_limit) * @as(u64, @intCast(params.tm_gate_pct))) break;
            }
        }

        // best_move = last completed iteration's move, improved by any partial iteration
        if (!self.best_move.is_empty()) {
            print("info string Using best move from completed depth {}\n", .{best_completed_depth});
            var mbuf: [5]u8 = undefined;
            print("bestmove {s}\n", .{self.best_move.to_uci(&mbuf)});
        } else {
            // No iteration finished: play the first legal move
            print("info string Using fallback move - no completed iterations\n", .{});
            var move_list: lists.MoveList = .{};
            movegen.generate_legal_moves(board, &move_list, color);
            if (move_list.count > 0) {
                var mbuf: [5]u8 = undefined;
                print("bestmove {s}\n", .{move_list.moves[0].to_uci(&mbuf)});
            }
        }
    }
};
