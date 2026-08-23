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
pub var global_tt: ?tt_mod.TT = null;
// When true, suppress all UCI info/bestmove output (used by datagen, which reads
// global_search.best_move / best_score directly instead of the printed bestmove).
pub var silent: bool = false;

pub fn search_position(board: *types.Board, max_depth: ?u8, soft_limit: u64, hard_limit: u64, comptime color: types.Color) void {
    global_search.search_position(board, max_depth, soft_limit, hard_limit, color);
}

pub fn init_search() void {
    global_search = Search.new();
    clear_corrhist();
}

var stdout_buf: [1024]u8 = undefined;
var stdout_fw: ?std.Io.File.Writer = null;

fn print(comptime fmt: []const u8, args: anytype) void {
    if (silent) return;
    if (stdout_fw == null)
        stdout_fw = std.Io.File.stdout().writerStreaming(clock.io, &stdout_buf);
    const w = &stdout_fw.?.interface;
    w.print(fmt, args) catch return;
    // Flush per call: UCI GUIs need each info/bestmove line delivered
    // immediately (matches the old unbuffered getStdOut writer).
    w.flush() catch {};
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

// Mate scores must survive the i16 TT score field: |MATE_VALUE| + MAX_PLY
// (score_to_tt adds the ply) has to stay <= 32767, else stored mates get
// clamped to 32767 and read back as huge *non-mate* evals (bogus cutoffs).
const INFINITY: i32 = 32500;
const MATE_VALUE: i32 = 32000;
const MATE_THRESHOLD: i32 = MATE_VALUE - @as(i32, MAX_PLY); // |score| above => a mate
const MAX_PLY: usize = 128;
const MAX_QUIESCENCE_DEPTH: i8 = 16;
// Qsearch delta-pruning piece values (P, N, B, R, Q, K).
const QS_PIECE_VALUES = [_]i32{ 100, 320, 330, 500, 900, 10000 };

// ===========================================================================
// Pawn correction history: a table of how much the static eval has historically
// differed from the search result, keyed by pawn structure x side-to-move. The
// static eval is nudged toward what search actually returns, which is worth
// ~+20-40 Elo in most engines (per NNUE-engine devlogs). Stored as cp*GRAIN.
// ===========================================================================
const CORRHIST_ON: bool = false;
const CORR_BITS: usize = 11;
const CORR_SIZE: usize = 1 << CORR_BITS; // 2048 buckets (16KB table, L1-resident)
const CORR_GRAIN: i32 = 256; // fixed-point: stored value = cp * 256
const CORR_MAX: i32 = 64 * CORR_GRAIN; // each table's correction capped <= 64 cp
const CORR_DELTA_CLAMP: i32 = 192; // single-update (best-raw) delta clamp, cp
// Two stacked correction histories: pawn structure + non-pawn piece placement.
// Pawn-only was neutral for our learned NNUE; stacking the non-pawn table is how
// engines reach the full corrhist gain.
var pawn_corrhist: [2][CORR_SIZE]i32 = std.mem.zeroes([2][CORR_SIZE]i32);
var nonpawn_corrhist: [2][CORR_SIZE]i32 = std.mem.zeroes([2][CORR_SIZE]i32);

pub fn clear_corrhist() void {
    pawn_corrhist = std.mem.zeroes([2][CORR_SIZE]i32);
    nonpawn_corrhist = std.mem.zeroes([2][CORR_SIZE]i32);
}

inline fn mix2(a: u64, b: u64) u64 {
    var h: u64 = a *% 0x9E3779B97F4A7C15;
    h = (h ^ b) *% 0xBF58476D1CE4E5B9;
    h ^= h >> 31;
    return h;
}

/// O(1) structure keys from bitboards — placement IS the bitboards, no per-node
/// loop, no incremental maintenance.
inline fn pawn_idx(board: *const types.Board) usize {
    const wp = board.pieces[types.Piece.WHITE_PAWN.toU4()];
    const bp = board.pieces[types.Piece.BLACK_PAWN.toU4()];
    return @as(usize, @intCast(mix2(wp, bp) & (CORR_SIZE - 1)));
}
inline fn nonpawn_idx(board: *const types.Board) usize {
    const p = &board.pieces;
    const wnp = p[1] | p[2] | p[3] | p[4] | p[5]; // white N,B,R,Q,K placement
    const bnp = p[9] | p[10] | p[11] | p[12] | p[13];
    return @as(usize, @intCast(mix2(wnp, bnp) & (CORR_SIZE - 1)));
}

/// Combined correction (cp) = pawn-structure + non-pawn-placement tables.
inline fn corr_value(board: *const types.Board, comptime color: types.Color) i32 {
    const side: usize = if (color == .White) 0 else 1;
    const sum = pawn_corrhist[side][pawn_idx(board)] + nonpawn_corrhist[side][nonpawn_idx(board)];
    return @divTrunc(sum, CORR_GRAIN);
}

inline fn corr_blend(v: *i32, delta: i32, w: i32) void {
    v.* = @divTrunc(v.* * (256 - w) + delta * w, 256);
    v.* = std.math.clamp(v.*, -CORR_MAX, CORR_MAX);
}

/// Blend both tables toward (best_score - raw_static), depth-weighted EMA.
inline fn corr_update(board: *const types.Board, comptime color: types.Color, raw_static: i32, best_score: i32, depth: u8) void {
    const side: usize = if (color == .White) 0 else 1;
    const raw_delta: i32 = std.math.clamp(best_score - raw_static, -CORR_DELTA_CLAMP, CORR_DELTA_CLAMP);
    const delta: i32 = raw_delta * CORR_GRAIN; // clamped target, in cp*GRAIN
    const w: i32 = @min(@as(i32, depth) + 1, 16); // weight grows with depth, cap 16
    corr_blend(&pawn_corrhist[side][pawn_idx(board)], delta, w);
    corr_blend(&nonpawn_corrhist[side][nonpawn_idx(board)], delta, w);
}

// ===========================================================================
// Tunable search parameters (SPSA at the target TC). Defaults reproduce the
// previous hardcoded constants exactly — with no setoption calls the engine
// is bench-identical. Names are exposed 1:1 as UCI spin options.
// ===========================================================================
pub var params: Params = .{};
pub const Params = struct {
    rfp_base: i32 = 70, // RFP margin slope (improving)
    rfp_impr: i32 = 20, // extra slope when not improving
    rfp_depth: i32 = 8, // RFP max depth
    razor_base: i32 = 150,
    razor_impr: i32 = 75,
    nmp_base: i32 = 3, // NMP R = base + depth/div
    nmp_div: i32 = 6,
    fut_base: i32 = 200, // futility margin = base*depth (depth 1-3)
    fut_impr: i32 = 80, // extra margin when not improving
    lmp_mult: i32 = 100, // % multiplier on the LMP thresholds
    lmr_base: i32 = 100, // LMR = base/100 + ln*ln/(div/100)
    lmr_div: i32 = 200,
    lmr_hist_div: i32 = 4000,
    lmr_evald_div: i32 = 350,
    lmr_movegate: i32 = 4, // first N legal moves exempt from LMR
    histprune_mult: i32 = 2000, // skip quiets with hist < -mult*depth
    asp_delta: i32 = 25, // first aspiration half-window
    tm_gate_pct: i32 = 60, // start next iteration only if elapsed < pct% of soft
    tm_stab_coef: i32 = 4, // soft-limit factor: 1 - coef/100*stability ...
    tm_impr_coef: i32 = 4, // ... - coef/100*score-trend
    // --- Ultrabullet TM package v1 (verified field values, see thesis research doc) ---
    tm_hard_pct: i32 = 46, // hard limit = pct% of (clock - overhead); field: Eth 20, Viri 46, SPX 65, SF 81
    tm_collapse_ms: i32 = 1000, // clock below this → move horizon collapses (Stockfish-style)
    tm_collapse_div: i32 = 20, // collapsed horizon = clock/div (400ms→20 moves, 100ms→5), min 2
    tm_win_cp: i32 = 1000, // |score| beyond this = decided position
    tm_win_pct: i32 = 60, // budget % when clearly winning (Stormphrax 0.6)
    tm_loss_pct: i32 = 50, // budget % when clearly losing (Stormphrax 0.5)
    qs_delta: i32 = 150, // qsearch delta-pruning margin
    se_depth: i32 = 8, // singular-extension min depth (LTC-scaler: bullet test)
    iir_depth: i32 = 4, // IIR min depth (LTC-scaler: bullet test)
    // Ablation toggles for the thesis component tests (0 = feature ON =
    // default behaviour, bit-identical; 1 = component disabled). Exposed as
    // UCI spin options like every other Params field.
    dis_pvs: i32 = 0, // 1: search every move with a full window (no scout)
    dis_qsearch: i32 = 0, // 1: static eval at the horizon instead of qsearch
    dis_nmp: i32 = 0, // 1: no null-move pruning
    dis_ordhist: i32 = 0, // 1: no killer/history terms in move ordering
    dis_counter: i32 = 0, // 1: no countermove term in move ordering
    dis_conthist: i32 = 0, // 1: no continuation-history term in move ordering
};

// Late Move Reduction table. Comptime-initialized with the default formula
// (base 1.0, div 2.0 — matching Params defaults) so no init-order hazard;
// rebuild_tables() overwrites it when params change via setoption.
var lmr_reductions: [64][64]u8 = init: {
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

pub fn rebuild_tables() void {
    const base: f64 = @as(f64, @floatFromInt(params.lmr_base)) / 100.0;
    const div: f64 = @as(f64, @floatFromInt(params.lmr_div)) / 100.0;
    for (0..64) |d| {
        for (0..64) |m| {
            if (d == 0 or m == 0) {
                lmr_reductions[d][m] = 0;
                continue;
            }
            const df: f64 = @floatFromInt(d);
            const mf: f64 = @floatFromInt(m);
            const r: f64 = base + @log(df) * @log(mf) / div;
            lmr_reductions[d][m] = @intFromFloat(@min(@max(r, 0.0), 63.0));
        }
    }
}

// Late Move Pruning thresholds: lmp_table[improving][depth]
// not-improving row: fewer quiets searched; improving row: more quiets allowed
const lmp_table = [2][11]u32{
    .{ 0, 2, 3, 5, 9, 13, 18, 25, 34, 45, 55 }, // not improving
    .{ 0, 5, 6, 9, 14, 21, 30, 41, 55, 69, 84 }, // improving
};

pub const Search = struct {
    best_move: Move = undefined,
    best_score: i32 = 0, // stm-relative cp of the deepest completed iteration (for datagen)
    stop_on_time: bool = false,
    stop: bool = false,
    timer: clock.Timer = undefined,
    hard_deadline: clock.Deadline = .never,
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

    // Game history: hashes of positions from start of game up to root (for repetition detection)
    game_hashes: [512]u64 = undefined,
    game_count: u16 = 0,

    // Search path hashes: one per ply, for intra-search repetition detection
    search_hashes: [MAX_PLY]u64 = undefined,

    // Time management
    soft_limit: u64 = 0, // Target time
    hard_limit: u64 = 0, // Absolute limit

    // Node limits (datagen soft-node search; 0 = disabled). Soft is only
    // checked between ID iterations, hard aborts mid-search like a time-out.
    soft_nodes: u64 = 0,
    hard_nodes: u64 = 0,
    hard_node_hit: bool = false, // current search aborted on hard_nodes

    // Eval stack for improving heuristic: static eval at each ply
    // -INFINITY sentinel means this ply was in check (no static eval computed)
    eval_stack: [MAX_PLY]i32 = [_]i32{0} ** MAX_PLY,

    // Move/piece stack for continuation history: tracks what piece made the move at each ply
    // stack_pieces sentinel 6 = "no piece" (used for null moves and uninitialized plies)
    stack_moves: [MAX_PLY]Move = undefined,
    stack_pieces: [MAX_PLY]u4 = undefined,

    // Continuation history: response-to-previous-move (counter) and follow-up-2-plies-ago (follow)
    // Indexed by [prev_piece_type][prev_to][cur_piece_type][cur_to]
    sc_counter_table: [6][64][6][64]i32 = undefined,
    sc_follow_table: [6][64][6][64]i32 = undefined,

    // Singular extensions: excluded move at each ply (empty = no exclusion)
    // Set before a singular search so that the TT move is skipped in the reduced search
    excluded: [MAX_PLY]Move = undefined,

    pub fn new() Search {
        var search = Search{};
        search.clear_pv_table();
        search.clear_killer_moves();
        for (&search.history_moves) |*row| {
            @memset(row, 0);
        }
        const empty_move = move_gen.Move.empty();
        for (&search.countermoves) |*row| {
            @memset(row, empty_move);
        }
        search.game_count = 0;
        // Init move/piece stack with sentinels
        @memset(&search.stack_moves, empty_move);
        @memset(&search.stack_pieces, 6);
        // Zero-init continuation history tables
        for (&search.sc_counter_table) |*a| for (a) |*b| for (b) |*c| @memset(c, 0);
        for (&search.sc_follow_table) |*a| for (a) |*b| for (b) |*c| @memset(c, 0);
        // Init excluded move array to empty (no exclusion at any ply)
        @memset(&search.excluded, empty_move);
        return search;
    }

    inline fn clear_killer_moves(self: *Search) void {
        const empty = move_gen.Move.empty();
        for (0..MAX_PLY) |i| {
            self.killer_moves[0][i] = empty;
            self.killer_moves[1][i] = empty;
        }
    }

    inline fn clear_pv_table(self: *Search) void {
        for (0..MAX_PLY) |i| {
            for (0..MAX_PLY) |j| {
                self.pv_table[i][j] = move_gen.Move.new(0, 0, types.MoveFlags.QUIET);
            }
            self.pv_length[i] = 0;
        }
    }

    inline fn update_pv(self: *Search, move: move_gen.Move) void {
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
        // 1023 mask ≈ 0.7ms at 1.4M NPS (Stormphrax polls every 1024 nodes);
        // 2047 overshot sub-5ms hard limits near the flag at 15+0.
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

    // Apply a history bonus (or malus if negative) to both continuation history tables
    // for the move described by (piece_type, to_square), using stack entries for parent/grandparent.
    // Called while self.ply == current node ply (after ply was decremented back).
    inline fn cont_hist_update(self: *Search, piece: u4, to: u6, bonus: i32) void {
        if (piece >= 6) return;
        if (self.ply >= 1) {
            const sm = self.stack_moves[self.ply - 1];
            if (!sm.is_empty()) {
                const pp = self.stack_pieces[self.ply - 1];
                if (pp < 6) {
                    const entry = &self.sc_counter_table[pp][sm.to][piece][to];
                    entry.* += bonus - @divTrunc(entry.* * bonus, 16384);
                }
            }
        }
        if (self.ply >= 2) {
            const sm2 = self.stack_moves[self.ply - 2];
            if (!sm2.is_empty()) {
                const gpp = self.stack_pieces[self.ply - 2];
                if (gpp < 6) {
                    const entry = &self.sc_follow_table[gpp][sm2.to][piece][to];
                    entry.* += bonus - @divTrunc(entry.* * bonus, 16384);
                }
            }
        }
    }

    // Quiescence search
    pub fn quiescence(self: *Search, board: *types.Board, mut_alpha: i32, beta: i32, depth: i8, comptime color: types.Color) i32 {
        if (self.ply < MAX_PLY) {
            self.pv_length[self.ply] = 0;
        }

        if (depth < -MAX_QUIESCENCE_DEPTH) {
            return eval.global_evaluator.eval(board, color, mut_alpha, beta);
        }

        self.nodes += 1;
        self.check_time();

        if (self.stop) return 0;

        if (self.ply >= MAX_PLY - 1) {
            return eval.global_evaluator.eval(board, color, mut_alpha, beta);
        }

        var alpha = mut_alpha;
        const opponent = if (color == types.Color.White) types.Color.Black else types.Color.White;

        // Mate distance pruning
        alpha = @max(alpha, -MATE_VALUE + @as(i32, @intCast(self.ply)));
        const adj_beta = @min(beta, MATE_VALUE - @as(i32, @intCast(self.ply)) - 1);

        if (alpha >= adj_beta) return alpha;

        const is_pv = (adj_beta - alpha) > 1;

        // TT probe: any stored depth suffices for a qsearch cutoff, and the TT
        // move replaces the (provably dead) PV-table ordering fallback.
        var tt_move: Move = Move.empty();
        var tt_static: i16 = tt_mod.NO_EVAL;
        if (global_tt) |*tt| {
            if (tt.probe(board.hash)) |entry| {
                tt_move = entry.best_move;
                tt_static = entry.static_eval;
                if (!is_pv) {
                    const tts = score_from_tt(entry.score, self.ply);
                    switch (entry.flag) {
                        .EXACT => return tts,
                        .LOWER => if (tts >= adj_beta) return tts,
                        .UPPER => if (tts <= alpha) return tts,
                        .NONE => {},
                    }
                }
            }
        }

        // Check if king is in check
        const in_check = self.is_king_in_check(board, color);

        var best_score: i32 = undefined;
        var static_for_tt: i16 = tt_mod.NO_EVAL;

        if (in_check) {
            // If in check, we must search all moves to escape check
            best_score = -MATE_VALUE + @as(i32, @intCast(self.ply));
        } else {
            // Standing pat - current position evaluation as lower bound
            // (reuse the TT-cached static eval; NNUE eval is position-pure)
            if (nnue.use_nnue and tt_static != tt_mod.NO_EVAL) {
                best_score = tt_static;
            } else {
                best_score = eval.global_evaluator.eval(board, color, alpha, adj_beta);
            }
            static_for_tt = @intCast(std.math.clamp(best_score, -30000, 30000));

            // Standing pat cutoff
            if (best_score >= adj_beta) {
                if (global_tt) |*tt| {
                    tt.store(board.hash, 0, score_to_tt(best_score, self.ply), .LOWER, Move.empty(), static_for_tt);
                }
                return best_score;
            }

            // Update alpha with standing pat score
            if (best_score > alpha) {
                alpha = best_score;
            }
        }

        // Generate legal moves if in check, only legal captures otherwise
        var move_list: lists.MoveList = .{};
        if (in_check) {
            movegen.generate_legal_moves(board, &move_list, color);
        } else {
            movegen.generate_legal_captures(board, &move_list, color);
        }

        if (move_list.count == 0 and in_check) {
            return -MATE_VALUE + @as(i32, @intCast(self.ply));
        }

        // Score moves for move ordering (TT move first when available)
        var score_list: lists.ScoreList = .{};
        move_scores.score_move(board, &move_list, &score_list, tt_move, Move.empty());

        const piece_values = QS_PIECE_VALUES; // P, N, B, R, Q, K

        var best_move_q: Move = Move.empty();
        for (0..move_list.count) |i| {
            const move = move_scores.get_next_best_move(&move_list, &score_list, i);
            // Ordering score of `move` (post-swap, slot i) — carries the SEE
            // classification computed once in score_move.
            const mscore = score_list.scores[i];

            // Capture pruning (only when not in check, and not for promotions which are
            // rare and important enough to always search).
            if (!in_check and move.is_capture() and !move.is_promotion()) {
                // Delta pruning: if the optimistic gain (victim value + margin) on top of
                // the current best score still can't reach alpha, this capture is hopeless.
                if (move.flags != types.MoveFlags.EN_PASSANT) {
                    const victim_type = board.get_piece_type_at(move.to);
                    if (victim_type) |vt| {
                        const victim_value = piece_values[@intFromEnum(vt)];
                        if (best_score + victim_value + params.qs_delta < alpha) {
                            continue;
                        }
                    }
                    // SEE pruning via ordering class: skip losing captures
                    // (EP excluded above; promos excluded by the outer guard).
                    if (mscore <= move_scores.SCORE_BAD_CAPTURE + 3000) {
                        continue;
                    }
                }
            }

            self.ply += 1;

            // Legal movegen guarantees all moves are legal
            const undo = move_gen.make_move_search(board, move, color);

            // Hide the child's TT-probe cache miss behind its entry work.
            if (global_tt) |*tt| tt.prefetch(board.hash);

            const score = -self.quiescence(board, -adj_beta, -alpha, depth - 1, opponent);

            self.ply -= 1;
            move_gen.unmake_move_search(board, move, undo, color);

            if (self.stop) return 0;

            // Update best score
            if (score > best_score) {
                best_score = score;
                best_move_q = move;

                if (score > alpha) {
                    alpha = score;

                    if (self.ply < MAX_PLY) {
                        self.update_pv(move);
                    }

                    if (alpha >= adj_beta) {
                        if (global_tt) |*tt| {
                            tt.store(board.hash, 0, score_to_tt(score, self.ply), .LOWER, move, static_for_tt);
                        }
                        return alpha;
                    }
                }
            }
        }

        // Store the qsearch result (depth 0): EXACT if alpha was raised, else UPPER.
        if (global_tt) |*tt| {
            const flag: tt_mod.TTFlag = if (best_score > mut_alpha) .EXACT else .UPPER;
            tt.store(board.hash, 0, score_to_tt(best_score, self.ply), flag, best_move_q, static_for_tt);
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
    pub fn negamax(self: *Search, board: *types.Board, depth_in: u8, mut_alpha: i32, beta: i32, do_null: bool, prev_move: Move, comptime color: types.Color) i32 {
        // Clear PV length for this ply
        if (self.ply < MAX_PLY) {
            self.pv_length[self.ply] = 0;
        }

        // Quiescence search
        if (depth_in == 0) {
            // Ablation: raw static eval at the horizon (no capture resolution).
            if (params.dis_qsearch != 0) return eval.global_evaluator.eval(board, color, mut_alpha, beta);
            return self.quiescence(board, mut_alpha, beta, 0, color);
        }

        // Hard ply ceiling (mirrors qsearch): bounds the NNUE accumulator stack
        // and all per-ply arrays even under repeated check/singular extensions.
        if (self.ply >= MAX_PLY - 1) {
            return eval.global_evaluator.eval(board, color, mut_alpha, beta);
        }

        self.nodes += 1;
        self.check_time();

        if (self.stop) return 0;

        // Allow depth to be adjusted locally (for IIR)
        var depth = depth_in;

        // Singular extension: are we in a reduced search with one move excluded?
        const skip_move = self.ply < MAX_PLY and !self.excluded[self.ply].is_empty();

        var alpha = mut_alpha;
        var adj_beta = beta;
        const is_root = (self.ply == 0);
        const is_pv_node = (adj_beta - alpha > 1);

        // Record current hash in the search path for repetition detection
        if (self.ply < MAX_PLY) {
            self.search_hashes[self.ply] = board.hash;
        }

        // Draw detection (non-root only)
        if (!is_root) {
            // 50-move rule
            if (board.halfmove >= 100) return 0;

            // 2-fold repetition in search path (same side to move = step by 2)
            var j: i32 = @as(i32, self.ply) - 2;
            while (j >= 0) : (j -= 2) {
                if (self.search_hashes[@intCast(j)] == board.hash) return 0;
            }

            // Repetition against game history (positions before the root)
            if (self.game_count > 0) {
                const scan_limit = @min(@as(u32, self.game_count), @as(u32, board.halfmove) + 1);
                var gi: u32 = 0;
                while (gi < scan_limit) : (gi += 1) {
                    const idx = @as(u32, self.game_count) - 1 - gi;
                    if (self.game_hashes[idx] == board.hash) return 0;
                }
            }
        }

        // Mate distance pruning: if we already found a shorter mate, prune
        if (!is_root) {
            alpha = @max(alpha, -MATE_VALUE + @as(i32, @intCast(self.ply)));
            adj_beta = @min(adj_beta, MATE_VALUE - @as(i32, @intCast(self.ply)) - 1);
            if (alpha >= adj_beta) return alpha;
        }

        // TT probe — skipped during singular extension searches (skip_move = true)
        var tt_move: Move = Move.empty();
        var tt_hit: bool = false;
        var tt_score_se: i32 = 0; // TT score saved for singular extension
        var tt_depth_se: u8 = 0; // TT depth saved for singular extension
        var tt_bound_se: tt_mod.TTFlag = .NONE; // TT bound saved for singular extension
        var tt_static_eval: i16 = tt_mod.NO_EVAL; // cached static eval from TT
        if (!skip_move) {
            if (global_tt) |*tt| {
                if (tt.probe(board.hash)) |entry| {
                    tt_hit = true;
                    tt_move = entry.best_move;
                    tt_score_se = score_from_tt(entry.score, self.ply);
                    tt_depth_se = entry.depth;
                    tt_bound_se = entry.flag;
                    tt_static_eval = entry.static_eval;

                    // Use TT score for cutoffs at non-PV nodes with sufficient depth
                    if (!is_root and !is_pv_node and entry.depth >= depth) {
                        switch (entry.flag) {
                            .EXACT => return tt_score_se,
                            .LOWER => {
                                if (tt_score_se >= adj_beta) return tt_score_se;
                            },
                            .UPPER => {
                                if (tt_score_se <= alpha) return tt_score_se;
                            },
                            .NONE => {},
                        }
                    }
                }
            }
        }

        // Internal Iterative Reduction (IIR): reduce depth when no TT move
        // Avoids wasting time at high depths when move ordering is poor
        if (@as(i32, depth) >= params.iir_depth and !tt_hit and !is_root) {
            depth -= 1;
        }

        var legal_moves: u32 = 0;
        var best_so_far: move_gen.Move = Move.empty();
        var best_score: i32 = -INFINITY;
        const old_alpha = alpha;
        const in_check = self.is_king_in_check(board, color);
        const opponent = if (color == types.Color.White) types.Color.Black else types.Color.White;

        // Static eval and improving heuristic
        // Compute eval at all non-check nodes; store in eval_stack for improving detection
        var static_eval: i32 = 0;
        var raw_static_eval: i32 = 0; // uncorrected — stored in TT and the corrhist baseline
        var improving: u1 = 0;
        if (!in_check) {
            // Reuse the TT-cached static eval when possible. NNUE eval is a pure
            // function of the position so this is bit-identical; HCE's lazy
            // alpha/beta cutoff makes its value window-dependent, so skip there.
            if (nnue.use_nnue and tt_static_eval != tt_mod.NO_EVAL) {
                static_eval = tt_static_eval;
            } else {
                static_eval = eval.global_evaluator.eval(board, color, alpha, adj_beta);
            }
            raw_static_eval = static_eval;
            // Pawn correction history: nudge the NNUE static eval toward what
            // search historically returned for this pawn structure. Clamp so the
            // correction can never push the eval into mate-score territory.
            if (CORRHIST_ON and nnue.use_nnue) {
                static_eval = std.math.clamp(static_eval + corr_value(board, color), -MATE_THRESHOLD + 1, MATE_THRESHOLD - 1);
            }
            if (self.ply < MAX_PLY) self.eval_stack[self.ply] = static_eval;

            // Improving: are we doing better than 2 or 4 plies ago (same side to move)?
            // Check ply-4 first to avoid null-move distortion, then fall back to ply-2
            if (self.ply >= 4 and self.eval_stack[self.ply - 4] != -INFINITY) {
                improving = if (static_eval > self.eval_stack[self.ply - 4]) 1 else 0;
            } else if (self.ply >= 2 and self.eval_stack[self.ply - 2] != -INFINITY) {
                improving = if (static_eval > self.eval_stack[self.ply - 2]) 1 else 0;
            }
        } else {
            // In check: store sentinel so children at ply+2 don't use this as baseline
            if (self.ply < MAX_PLY) self.eval_stack[self.ply] = -INFINITY;
        }

        // Static eval as stored into the TT (sentinel when in check). Evals are
        // a few hundred cp in practice; the clamp can't bite, it only guards i16.
        const se_for_tt: i16 = if (in_check)
            tt_mod.NO_EVAL
        else
            @intCast(std.math.clamp(raw_static_eval, -30000, 30000));

        const can_static_prune = !is_pv_node and !in_check and !skip_move;
        const impr: i32 = @intCast(improving);
        if (can_static_prune) {
            // Reverse Futility Pruning (RFP): improving-aware margins
            if (depth <= params.rfp_depth) {
                const rfp_margin: i32 = (params.rfp_base + params.rfp_impr * (1 - impr)) * @as(i32, depth);
                if (static_eval - rfp_margin >= adj_beta) {
                    return static_eval;
                }
            }

            // Razoring: at very shallow depth, run qsearch to verify we can beat alpha
            if (depth <= 2) {
                const razor_margin: i32 = params.razor_base + impr * params.razor_impr;
                if (static_eval + razor_margin <= alpha) {
                    const razor_score = self.quiescence(board, alpha - 1, alpha, 0, color);
                    if (razor_score <= alpha) return razor_score;
                }
            }
        }

        // Null Move Pruning (NMP)
        if (do_null and params.dis_nmp == 0 and !is_pv_node and !in_check and !skip_move and depth >= 3) {
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
                // Save minimal state for null move
                const nm_hash = board.hash;
                const nm_ep = board.enpassant;

                // Make null move: clear en passant, flip side, update hash
                if (board.enpassant != types.square.NO_SQUARE) {
                    board.hash ^= zobrist.ep_keys[@intFromEnum(board.enpassant) % 8];
                }
                board.enpassant = types.square.NO_SQUARE;
                board.hash ^= zobrist.side_key;
                board.side = opponent;

                // Store null-move sentinel in stack so cont hist lookups skip this ply
                if (self.ply < MAX_PLY) {
                    self.stack_moves[self.ply] = Move.empty();
                    self.stack_pieces[self.ply] = 6;
                }
                self.ply += 1;

                // Adaptive reduction: R = base + depth/div
                const R: u8 = @intCast(params.nmp_base + @divTrunc(@as(i32, depth), params.nmp_div));
                const null_depth: u8 = if (depth > R) depth - R else 0;

                const null_score = -self.negamax(board, null_depth, -adj_beta, -adj_beta + 1, false, Move.empty(), opponent);

                self.ply -= 1;
                // Restore null move: only hash, ep, and side changed
                board.hash = nm_hash;
                board.enpassant = nm_ep;
                board.side = color;

                if (self.stop) return 0;

                if (null_score >= adj_beta) {
                    return adj_beta;
                }
            }
        }

        // Futility pruning flag: at shallow depths, skip quiet moves
        // Non-improving positions get extra margin (search more carefully when behind)
        const futility_pruning = can_static_prune and depth >= 1 and depth <= 3 and
            static_eval + params.fut_base * @as(i32, depth) + (1 - impr) * params.fut_impr < alpha;

        // Generate legal moves (no need for legality check in make_move)
        var move_list: lists.MoveList = .{};
        movegen.generate_legal_moves(board, &move_list, color);

        // Use TT move for ordering if available, otherwise PV move
        const order_move = if (!tt_move.is_empty())
            tt_move
        else if (self.pv_length[self.ply] > 0)
            self.pv_table[self.ply][0]
        else
            move_gen.Move.empty();

        // Look up countermove for the previous move
        const countermove = if (!prev_move.is_empty())
            self.countermoves[prev_move.from][prev_move.to]
        else
            Move.empty();

        // Generate move scores
        var score_list: lists.ScoreList = .{};
        move_scores.score_move(board, &move_list, &score_list, order_move, countermove);

        // loop over moves within a movelist
        var quiet_count: u32 = 0;
        // Track quiet moves actually searched (for history malus on beta cutoff)
        var quiets_tried: [64]Move = undefined;
        var quiet_pieces: [64]u4 = undefined; // piece type of each tried quiet
        var n_quiets: u32 = 0;
        for (0..move_list.count) |i| {
            const move = move_scores.get_next_best_move(&move_list, &score_list, i);
            const mscore = score_list.scores[i]; // ordering score (SEE class)

            // Skip the excluded move during singular extension searches
            if (skip_move and move.from == self.excluded[self.ply].from and
                move.to == self.excluded[self.ply].to) continue;

            // SEE pruning: at shallow non-PV nodes, skip captures that lose
            // serious, depth-scaled material. The boolean ordering class
            // (SEE<0) preselects candidates; the precise threshold check runs
            // only for those, and the skip happens BEFORE make_move_search.
            // Small SEE losses stay searched — they often carry tactics.
            if (!in_check and !is_pv_node and depth <= 6 and legal_moves >= 1 and
                move.is_capture() and !move.is_promotion() and
                move.flags != types.MoveFlags.EN_PASSANT and
                mscore <= move_scores.SCORE_BAD_CAPTURE + 3000 and
                !move_scores.see(board, move, -60 * @as(i32, depth)))
            {
                continue;
            }

            // Singular Extension (C2): check if TT move is the only good move
            // We search all other moves at reduced depth to verify the TT move is "singular".
            // Condition: non-root, no exclusion active, sufficient depth, TT hit with LOWER bound.
            var se_extension: u8 = 0;
            const is_tt_move = !tt_move.is_empty() and
                move.from == tt_move.from and move.to == tt_move.to;
            if (!is_root and !skip_move and @as(i32, depth) >= params.se_depth and is_tt_move and
                tt_depth_se + 3 >= depth and tt_bound_se == .LOWER and
                @abs(tt_score_se) < MATE_VALUE - 100)
            {
                // Reduced beta: if all other moves score below this, extend the TT move
                const singular_beta: i32 = @max(
                    tt_score_se - @as(i32, depth),
                    -MATE_VALUE + 100,
                );
                // Run a reduced search excluding this move (via self.excluded[ply])
                if (self.ply < MAX_PLY) self.excluded[self.ply] = move;
                const se_score = self.negamax(
                    board,
                    (depth - 1) / 2,
                    singular_beta - 1,
                    singular_beta,
                    false,
                    prev_move,
                    color,
                );
                if (self.ply < MAX_PLY) self.excluded[self.ply] = Move.empty();

                if (se_score < singular_beta) {
                    // TT move is singular — extend it
                    se_extension = 1;
                } else if (singular_beta >= adj_beta) {
                    // Multi-cut: other moves also beat beta, skip this node
                    return singular_beta;
                }
            }

            // Store move and piece type in stack before incrementing ply (for continuation history)
            if (self.ply < MAX_PLY) {
                self.stack_moves[self.ply] = move;
                const pt = board.get_piece_type_at(move.from);
                self.stack_pieces[self.ply] = if (pt) |p| @intCast(@intFromEnum(p)) else 6;
            }
            self.ply += 1;

            // Legal movegen guarantees all moves are legal
            const undo = move_gen.make_move_search(board, move, color);
            legal_moves += 1;

            // Hide the child's TT-probe cache miss behind its entry work.
            if (global_tt) |*tt| tt.prefetch(board.hash);

            // Compute gives_check once for all pruning decisions and the check extension
            const gives_check = self.is_king_in_check(board, opponent);
            const extension: u8 = @max(se_extension, @as(u8, if (gives_check) 1 else 0));
            const new_depth = depth - 1 + extension;

            const is_quiet = !move.is_capture() and !move.is_promotion();

            // Futility pruning: skip quiet non-check moves that can't raise alpha
            if (futility_pruning and legal_moves > 1 and is_quiet and !gives_check) {
                self.ply -= 1;
                move_gen.unmake_move_search(board, move, undo, color);
                continue;
            }

            // Late Move Pruning: skip late quiet non-check moves at shallow depths
            if (!in_check and !is_pv_node and depth <= 8 and legal_moves > 1 and
                is_quiet and !gives_check)
            {
                quiet_count += 1;
                const lmp_threshold = @as(u32, @intCast(@divTrunc(
                    @as(i32, @intCast(lmp_table[@intCast(improving)][@min(@as(usize, depth), 10)])) * params.lmp_mult,
                    100,
                )));
                if (quiet_count > lmp_threshold) {
                    self.ply -= 1;
                    move_gen.unmake_move_search(board, move, undo, color);
                    continue;
                }
            }

            // Compute combined history for quiet moves: history + counter_hist + follow_hist
            // Used for history-based pruning (C5) and LMR adjustments (C3)
            var full_hist: i32 = 0;
            if (is_quiet) {
                const cur_pt_h: u4 = self.stack_pieces[self.ply - 1];
                full_hist = self.history_moves[move.from][move.to];
                if (self.ply >= 2) {
                    const pm_h = self.stack_moves[self.ply - 2];
                    if (!pm_h.is_empty()) {
                        const pp_h = self.stack_pieces[self.ply - 2];
                        if (pp_h < 6 and cur_pt_h < 6) {
                            full_hist += self.sc_counter_table[pp_h][pm_h.to][cur_pt_h][move.to];
                        }
                    }
                }
                if (self.ply >= 3) {
                    const gm_h = self.stack_moves[self.ply - 3];
                    if (!gm_h.is_empty()) {
                        const gpp_h = self.stack_pieces[self.ply - 3];
                        if (gpp_h < 6 and cur_pt_h < 6) {
                            full_hist += self.sc_follow_table[gpp_h][gm_h.to][cur_pt_h][move.to];
                        }
                    }
                }

                // History-based pruning: skip quiets with terrible combined history
                if (!in_check and !is_pv_node and depth <= 4 and
                    full_hist < -params.histprune_mult * @as(i32, depth))
                {
                    self.ply -= 1;
                    move_gen.unmake_move_search(board, move, undo, color);
                    continue;
                }
            }

            // Track searched quiet moves for history malus and continuation history
            if (is_quiet and n_quiets < 64) {
                quiets_tried[n_quiets] = move;
                // Piece was stored in stack before ply++ (stack_pieces[ply-1] after increment)
                quiet_pieces[n_quiets] = self.stack_pieces[self.ply - 1];
                n_quiets += 1;
            }

            // PVS + LMR (Late Move Reductions)
            var score: i32 = undefined;

            if (legal_moves == 1) {
                // First legal move: always full depth, full window
                score = -self.negamax(board, new_depth, -adj_beta, -alpha, true, move, opponent);
            } else {
                // Determine LMR reduction for non-first moves
                var reduction: u8 = 0;
                const is_capture_move = move.is_capture();
                const is_promotion_move = move.is_promotion();

                if (depth >= 3 and legal_moves >= params.lmr_movegate and !in_check and !is_capture_move and !is_promotion_move) {
                    // Check if move is a killer at the parent ply
                    const parent_ply = self.ply - 1;
                    const is_killer = (move.from == self.killer_moves[0][parent_ply].from and
                        move.to == self.killer_moves[0][parent_ply].to) or
                        (move.from == self.killer_moves[1][parent_ply].from and
                            move.to == self.killer_moves[1][parent_ply].to);

                    if (!gives_check and !is_killer) {
                        var r: i16 = @intCast(lmr_reductions[@min(@as(usize, depth), 63)][@min(legal_moves, 63)]);
                        // Reduce less in PV nodes
                        if (is_pv_node and r > 0) r -= 1;
                        // C3: not improving → reduce more
                        if (improving == 0) r += 1;
                        // C3: history-based adjustment (good history = less reduction, bad = more)
                        r -= @as(i16, @intCast(@max(-4, @min(4, @divTrunc(full_hist, params.lmr_hist_div)))));
                        // C3: eval-distance adjustment (far from alpha = more reduction)
                        const eval_dist: i32 = if (static_eval >= alpha) static_eval - alpha else alpha - static_eval;
                        r += @as(i16, @intCast(@min(@as(i32, 2), @divTrunc(eval_dist, params.lmr_evald_div))));
                        // Clamp: [0, new_depth - 1]
                        r = @max(0, @min(r, @as(i16, @intCast(new_depth)) - 1));
                        reduction = @intCast(r);
                    }
                }

                if (params.dis_pvs != 0) {
                    // Ablation: no scout windows — every move gets a full
                    // window (LMR depth reduction kept, verified full-depth).
                    score = -self.negamax(board, new_depth - reduction, -adj_beta, -alpha, true, move, opponent);
                    if (reduction > 0 and score > alpha) {
                        score = -self.negamax(board, new_depth, -adj_beta, -alpha, true, move, opponent);
                    }
                } else {
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
            }

            self.ply -= 1;

            move_gen.unmake_move_search(board, move, undo, color);

            if (self.stop) return 0;

            // Track best score and move
            if (score > best_score) {
                best_score = score;
                best_so_far = move;
            }

            // fail-hard beta cutoff
            if (score >= adj_beta) {
                if (!move.is_capture()) {
                    self.killer_moves[1][self.ply] = self.killer_moves[0][self.ply];
                    self.killer_moves[0][self.ply] = move;

                    // Gravity-style history update: prevents overflow and ages old entries
                    const bonus: i32 = @as(i32, depth) * @as(i32, depth);
                    const entry = &self.history_moves[move.from][move.to];
                    entry.* += bonus - @divTrunc(entry.* * bonus, 16384);

                    // Continuation history bonus for the cutoff move
                    self.cont_hist_update(self.stack_pieces[self.ply], move.to, bonus);

                    // Countermove heuristic: this move refutes the previous move
                    if (!prev_move.is_empty()) {
                        self.countermoves[prev_move.from][prev_move.to] = move;
                    }
                }

                // History malus + cont hist malus: penalize quiet moves searched before this cutoff
                // If cutoff is quiet, exclude it from malus (it already gets the bonus above)
                // If cutoff is a capture/promo, apply malus to all tried quiets
                const n_malus: u32 = if (is_quiet and n_quiets > 0) n_quiets - 1 else n_quiets;
                if (n_malus > 0) {
                    const malus: i32 = -@as(i32, depth) * @as(i32, depth);
                    for (0..n_malus) |qi| {
                        const q_entry = &self.history_moves[quiets_tried[qi].from][quiets_tried[qi].to];
                        q_entry.* += malus - @divTrunc(q_entry.* * malus, 16384);
                        self.cont_hist_update(quiet_pieces[qi], quiets_tried[qi].to, malus);
                    }
                }

                // Store in TT as lower bound (beta cutoff) — not during singular searches
                if (!skip_move) {
                    if (global_tt) |*tt| {
                        tt.store(
                            board.hash,
                            depth,
                            score_to_tt(score, self.ply),
                            .LOWER,
                            move,
                            se_for_tt,
                        );
                    }
                }

                // Correction history (fail-high = LOWER bound): only a POSITIVE
                // correction is valid here — the static eval under-predicted.
                if (CORRHIST_ON and nnue.use_nnue and !in_check and !skip_move and !move.is_capture() and best_score > raw_static_eval and best_score < MATE_THRESHOLD and best_score > -MATE_THRESHOLD) {
                    corr_update(board, color, raw_static_eval, best_score, depth);
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

        // Store in TT — not during singular extension searches
        if (!skip_move) {
            if (global_tt) |*tt| {
                const tt_flag: tt_mod.TTFlag = if (alpha > old_alpha) .EXACT else .UPPER;
                tt.store(
                    board.hash,
                    depth,
                    score_to_tt(alpha, self.ply),
                    tt_flag,
                    best_so_far,
                    se_for_tt,
                );
            }
        }

        // Correction history at a non-cutoff node: an EXACT node (alpha raised)
        // gives the true value -> update either way; a FAIL-LOW node is an UPPER
        // bound -> only a NEGATIVE correction (best_score below static) is valid.
        const corr_dir_ok = (alpha > old_alpha) or (best_score < raw_static_eval);
        if (CORRHIST_ON and nnue.use_nnue and !in_check and !skip_move and corr_dir_ok and !best_so_far.is_empty() and !best_so_far.is_capture() and best_score < MATE_THRESHOLD and best_score > -MATE_THRESHOLD) {
            corr_update(board, color, raw_static_eval, best_score, depth);
        }

        // node fails low
        return alpha;
    }

    // Main search function
    pub fn search_position(self: *Search, board: *types.Board, max_depth: ?u8, soft_limit_ms: u64, hard_limit_ms: u64, comptime color: types.Color) void {
        self.nodes = 0;
        self.stop = false;
        self.hard_node_hit = false;
        self.timer = .start();
        self.soft_limit = soft_limit_ms;
        self.hard_limit = hard_limit_ms;
        self.hard_deadline = if (hard_limit_ms > 0) .afterMs(hard_limit_ms) else .never;
        self.ply = 0; // Reset ply counter
        self.clear_pv_table();
        self.best_move = Move.empty();
        var best_move_found: ?move_gen.Move = null;
        var best_completed_depth: u8 = 0;

        // Root accumulator for incremental NNUE updates during this search.
        // (Datagen runs with use_nnue=false, so its searches skip all of this.)
        if (nnue.use_nnue) nnue.stack_init(board);
        defer nnue.stack_stop();

        // Forced move: with a single legal reply, searching can't change the
        // move — play it as soon as the first iteration completes and bank the
        // clock (Viridithas sets opt_time=0; Berserk caps at 250ms).
        var single_reply = false;
        if (self.soft_limit > 0) {
            var root_moves: lists.MoveList = .{};
            if (board.side == types.Color.White) {
                movegen.generate_legal_moves(board, &root_moves, types.Color.White);
            } else {
                movegen.generate_legal_moves(board, &root_moves, types.Color.Black);
            }
            if (root_moves.count == 1) {
                single_reply = true;
            }
        }

        // Signal new search to TT for age-based replacement
        if (global_tt) |*tt| {
            tt.new_search();
        }

        const depth_limit = max_depth orelse 64;

        // Stability tracking for time management
        var prev_best_move: Move = Move.empty();
        var stability_counter: u8 = 0; // 0-10, increments when best move stays same

        // Iterative deepening with aspiration windows
        var current_depth: u8 = 1;
        var prev_score: i32 = 0;
        var improving: i16 = 0; // score trend at ID level
        while (current_depth <= depth_limit) : (current_depth += 1) {
            // Reset ply for each iteration
            self.ply = 0;

            var score: i32 = undefined;

            if (current_depth >= 4) {
                // Aspiration windows: search with narrow window around previous score
                // Widening sequence: ±d → ±4d → ±16d → full window
                var delta: i32 = params.asp_delta;
                var asp_alpha: i32 = @max(prev_score - delta, -INFINITY);
                var asp_beta: i32 = @min(prev_score + delta, INFINITY);

                while (true) {
                    self.ply = 0;
                    score = self.negamax(board, current_depth, asp_alpha, asp_beta, true, Move.empty(), color);
                    if (self.stop) break;

                    if (score <= asp_alpha) {
                        // Fail low: widen alpha
                        delta = if (delta >= params.asp_delta * 16) INFINITY else delta * 4;
                        asp_alpha = if (delta >= INFINITY) -INFINITY else @max(prev_score - delta, -INFINITY);
                    } else if (score >= asp_beta) {
                        // Fail high: widen beta
                        delta = if (delta >= params.asp_delta * 16) INFINITY else delta * 4;
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

                // Persist deepest-completed result for programmatic readers (datagen)
                self.best_move = iter_best;
                self.best_score = score;

                // Track move stability: continuous counter 0-10
                if (prev_best_move.from == iter_best.from and prev_best_move.to == iter_best.to) {
                    stability_counter = @min(10, stability_counter + 1);
                } else {
                    stability_counter = 0;
                }
                prev_best_move = iter_best;
            }

            // Soft node limit (datagen): don't start another iteration once hit.
            if (self.soft_nodes > 0 and self.nodes >= self.soft_nodes) break;

            // Single legal reply: the move is forced — instamove.
            if (single_reply and self.pv_length[0] > 0) break;

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

                    if (pv_move.is_promotion()) {
                        const promo = pv_move.promotion_char();
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

            // Update score trend for time management
            if (current_depth >= 3) {
                if (score > prev_score + 20) {
                    improving += 1;
                    if (score > prev_score + 60) improving += 1;
                } else if (score < prev_score - 20) {
                    improving -= 1;
                    if (score < prev_score - 60) improving -= 1;
                }
                improving = @max(-4, @min(4, improving));
            }
            prev_score = score;

            // Time management: adjust soft limit by stability and score trend
            // - high stability (same best move) → stop earlier
            // - improving score → stop earlier; declining score → take more time
            if (self.soft_limit > 0) {
                const stab_f: f32 = @floatFromInt(stability_counter);
                const impr_f: f32 = @floatFromInt(improving);
                const stab_c: f32 = @as(f32, @floatFromInt(params.tm_stab_coef)) / 100.0;
                const impr_c: f32 = @as(f32, @floatFromInt(params.tm_impr_coef)) / 100.0;
                var factor: f32 = 1.0 - stab_c * stab_f - impr_c * impr_f;
                factor = @max(0.5, @min(1.5, factor));

                // Decided positions: any sane move preserves the result — the
                // clock is the real opponent, bank time (Stormphrax 0.6/0.5).
                if (score >= params.tm_win_cp) {
                    factor *= @as(f32, @floatFromInt(params.tm_win_pct)) / 100.0;
                } else if (score <= -params.tm_win_cp) {
                    factor *= @as(f32, @floatFromInt(params.tm_loss_pct)) / 100.0;
                }
                // Floor after the win/loss scaling: negative tm_win_pct/tm_loss_pct
                // (reachable via the unclamped SPSA setoption path) would make the
                // factor negative and @intFromFloat into u64 below is UB. Never
                // binds at the defaults (60/50 keep factor in [0.15, 1.5]).
                factor = @max(0.01, factor);

                const adjusted_limit: u64 = @intFromFloat(@as(f32, @floatFromInt(self.soft_limit)) * factor);
                const effective_limit = @min(adjusted_limit, self.hard_limit);

                // Predictive gate: the next iteration costs a multiple of this
                // one, so starting it near the soft limit mostly burns clock.
                // Only start if under tm_gate_pct% of the (adjusted) budget.
                if (elapsed * 100 >= effective_limit * @as(u64, @intCast(params.tm_gate_pct))) {
                    break;
                }
            }
        }

        // Output best move. Prefer self.best_move: it equals the deepest
        // completed iteration's move, plus any root improvement found during a
        // partially completed (interrupted) iteration — most bullet moves end
        // mid-iteration, so discarding partial root results wastes real Elo.
        const final_move: ?move_gen.Move = if (!self.best_move.is_empty())
            self.best_move
        else
            best_move_found;
        if (final_move) |best_move| {
            const from = types.SquareString.getSquareToString(@enumFromInt(best_move.from));
            const to = types.SquareString.getSquareToString(@enumFromInt(best_move.to));

            print("info string Using best move from completed depth {}\n", .{best_completed_depth});

            if (best_move.is_promotion()) {
                const promo = best_move.promotion_char();
                print("bestmove {s}{s}{c}\n", .{ from, to, promo });
            } else {
                print("bestmove {s}{s}\n", .{ from, to });
            }
        } else {
            // Fallback - find any legal move
            print("info string Using fallback move - no completed iterations\n", .{});
            var move_list: lists.MoveList = .{};
            movegen.generate_legal_moves(board, &move_list, color);
            if (move_list.count > 0) {
                const fallback_move = move_list.moves[0];
                const from = types.SquareString.getSquareToString(@enumFromInt(fallback_move.from));
                const to = types.SquareString.getSquareToString(@enumFromInt(fallback_move.to));
                print("bestmove {s}{s}\n", .{ from, to });
            }
        }
    }
};
