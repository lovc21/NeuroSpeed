const std = @import("std");
const types = @import("types.zig");
const bitboard = @import("bitboard.zig");
const movegen = @import("movegen.zig");
const move_gen = @import("move.zig");
const lists = @import("lists.zig");
const search = @import("search.zig");
const tt_mod = @import("tt.zig");
const attacks = @import("attacks.zig");
const nnue = @import("nnue.zig");
const clock = @import("clock.zig");

// Mate scores are beyond this.
const MATE_THRESHOLD: i32 = types.MATE_BOUND;

pub const Config = struct {
    // depth > 0 uses fixed-depth search and skips node limits and opening verification.
    depth: u8 = 0,
    soft_nodes: u64 = 5000,
    hard_nodes: u64 = 40000, // aborts mid-search; soft is checked between iterations
    verif_nodes: u64 = 50000, // opening check search
    verif_hard_nodes: u64 = 400000,
    verif_max_cp: i32 = 800, // discard openings evaluated beyond this
    games: u64 = 1000,
    out_path: []const u8 = "gen0.txt",
    seed: u64 = 0xC0FFEE,
    opening_plies: u8 = 8, // random plies, plus 1 half the time
    max_plies: u16 = 320, // draw after this many plies
    adj_win_cp: i32 = 2000, // win if beyond this for adj_win_plies
    adj_win_plies: u8 = 4,
    adj_draw_cp: i32 = 8, // draw if within this for adj_draw_plies
    adj_draw_plies: u8 = 12,
    adj_draw_min_ply: u16 = 70, // no draw adjudication before this ply
    min_record_ply: u16 = 16, // skip positions up to this ply
    max_hard_hits: u8 = 3, // drop the game after this many hard limit hits
    extreme_cp: i32 = 10000, // skip positions beyond this
    tt_mb: usize = 16,
    verbose: bool = false,
    use_nnue: bool = false, // label with NNUE instead of HCE
};

// Run stats.
var stat_openings_discarded: u64 = 0;
var stat_games_dropped: u64 = 0;
var stat_adj_wins: u64 = 0;
var stat_adj_draws: u64 = 0;

// White-relative game result.
const Outcome = enum {
    white_win,
    draw,
    black_win,

    fn str(self: Outcome) []const u8 {
        return switch (self) {
            .white_win => "1.0",
            .draw => "0.5",
            .black_win => "0.0",
        };
    }
};

// Recorded position with an inline FEN.
const Sample = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,
    cp: i32 = 0, // white-relative centipawns
};

// Generate legal moves into `list` and return whether the side to move is in check.
fn gen_and_check(board: *const types.Board, list: *lists.MoveList) bool {
    return switch (board.side) {
        inline .White, .Black => |c| blk: {
            const info = movegen.compute_legal_info(board, c);
            movegen.generate_legal_moves_with_info(board, list, c, info);
            break :blk info.num_checkers != 0;
        },
        .both => unreachable,
    };
}

// Search the position with node limits, or to cfg.depth if set.
fn run_search(board: *types.Board, cfg: Config, soft: u64, hard: u64) void {
    search.global_search.soft_nodes = if (cfg.depth > 0) 0 else soft;
    search.global_search.hard_nodes = if (cfg.depth > 0) 0 else hard;
    const depth: ?u8 = if (cfg.depth > 0) cfg.depth else null;
    switch (board.side) {
        inline .White, .Black => |c| search.search_position(board, depth, 0, 0, c),
        .both => unreachable,
    }
}

/// Play one self-play game; write labeled lines to `out`. Returns positions written.
fn play_one_game(
    allocator: std.mem.Allocator,
    cfg: Config,
    rng: std.Random,
    out: *std.Io.Writer,
    samples: *std.ArrayList(Sample),
) !u64 {
    samples.clearRetainingCapacity();

    var board = types.Board.new();
    var opening_len: u8 = 0;

    // Play random opening moves, retry if the result is too unbalanced.
    open: while (true) {
        bitboard.parse_fen(types.start_position, &board) catch unreachable;
        opening_len = cfg.opening_plies + @as(u8, if (rng.boolean()) 1 else 0);
        var i: u8 = 0;
        while (i < opening_len) : (i += 1) {
            var list: lists.MoveList = .{};
            _ = gen_and_check(&board, &list);
            if (list.count == 0) continue :open; // game ended, retry
            const idx = rng.uintLessThan(usize, list.count);
            _ = move_gen.make_move_search_rt(&board, list.moves[idx]);
        }

        // Reset history and TT so each game starts clean.
        search.init_search();
        if (tt_mod.global) |*tt| tt.clear();

        if (cfg.depth == 0) {
            run_search(&board, cfg, cfg.verif_nodes, cfg.verif_hard_nodes);
            const vs = search.global_search.best_score;
            const v_white: i32 = if (board.side == types.Color.White) vs else -vs;
            if (v_white > cfg.verif_max_cp or v_white < -cfg.verif_max_cp) {
                stat_openings_discarded += 1;
                continue :open;
            }
        }
        break;
    }

    var history: [2048]u64 = undefined;
    var hist_len: usize = 0;

    var ply: u32 = opening_len;
    var white_streak: u8 = 0;
    var black_streak: u8 = 0;
    var draw_streak: u8 = 0;
    var hard_hits: u8 = 0;
    var outcome: Outcome = .draw;

    game: while (true) {
        // Check for game end.
        var list: lists.MoveList = .{};
        const checked = gen_and_check(&board, &list);

        if (list.count == 0) {
            if (checked) {
                outcome = if (board.side == types.Color.White) .black_win else .white_win;
            } else {
                outcome = .draw;
            }
            break :game;
        }
        if (board.halfmove >= 100) {
            outcome = .draw; // 50-move rule
            break :game;
        }
        if (std.mem.count(u64, history[0..hist_len], &.{board.hash}) >= 2) {
            outcome = .draw; // threefold repetition
            break :game;
        }
        if (ply >= cfg.max_plies) {
            outcome = .draw; // length cap
            break :game;
        }

        run_search(&board, cfg, cfg.soft_nodes, cfg.hard_nodes);

        // Drop games that keep hitting the hard node limit.
        if (search.global_search.hard_node_hit) {
            hard_hits += 1;
            if (hard_hits >= cfg.max_hard_hits) {
                stat_games_dropped += 1;
                return 0;
            }
        }

        const score = search.global_search.best_score;
        const best = search.global_search.best_move;

        const white_cp: i32 = if (board.side == types.Color.White) score else -score;

        // Win adjudication.
        if (white_cp >= cfg.adj_win_cp) {
            white_streak += 1;
            black_streak = 0;
        } else if (white_cp <= -cfg.adj_win_cp) {
            black_streak += 1;
            white_streak = 0;
        } else {
            white_streak = 0;
            black_streak = 0;
        }

        // Draw adjudication.
        if (ply >= cfg.adj_draw_min_ply and white_cp <= cfg.adj_draw_cp and white_cp >= -cfg.adj_draw_cp) {
            draw_streak += 1;
        } else {
            draw_streak = 0;
        }

        // Skip early, in-check, noisy, mate and extreme positions.
        const is_mate = score > MATE_THRESHOLD or score < -MATE_THRESHOLD;
        const noisy = best.is_capture() or best.is_promotion();
        const extreme = white_cp >= cfg.extreme_cp or white_cp <= -cfg.extreme_cp;
        if (ply > cfg.min_record_ply and !checked and !noisy and !is_mate and !extreme) {
            var s = Sample{};
            const fen = bitboard.board_to_fen(&board, ply / 2 + 1, s.buf[0..]);
            s.len = fen.len;
            // Round tiny scores to 0.
            s.cp = if (white_cp >= -2 and white_cp <= 2) 0 else white_cp;
            try samples.append(allocator, s);
        }

        if (white_streak >= cfg.adj_win_plies) {
            outcome = .white_win;
            stat_adj_wins += 1;
            break :game;
        }
        if (black_streak >= cfg.adj_win_plies) {
            outcome = .black_win;
            stat_adj_wins += 1;
            break :game;
        }
        if (draw_streak >= cfg.adj_draw_plies) {
            outcome = .draw;
            stat_adj_draws += 1;
            break :game;
        }

        if (hist_len < history.len) {
            history[hist_len] = board.hash;
            hist_len += 1;
        }
        _ = move_gen.make_move_search_rt(&board, best);
        ply += 1;
    }

    // Write the samples with the game result.
    const res = outcome.str();
    for (samples.items) |s| {
        try out.print("{s} | {d} | {s}\n", .{ s.buf[0..s.len], s.cp, res });
    }
    return samples.items.len;
}

pub fn run(allocator: std.mem.Allocator, cfg: Config) !void {
    search.silent = true; // no UCI output
    attacks.init_attacks();
    search.init_search();
    tt_mod.init_global(allocator, cfg.tt_mb) catch {}; // runs without a TT if allocation fails
    defer tt_mod.deinit_global();

    if (cfg.use_nnue) {
        try nnue.load_embedded();
        nnue.use_nnue = true;
        std.debug.print("datagen: labeling with embedded NNUE net\n", .{});
    }

    var out_file = try std.Io.Dir.cwd().createFile(clock.io, cfg.out_path, .{});
    defer out_file.close(clock.io);
    var out_buf: [64 * 1024]u8 = undefined;
    var out_fw = out_file.writer(clock.io, &out_buf);
    const out = &out_fw.interface;

    var prng = std.Random.DefaultPrng.init(cfg.seed);
    const rng = prng.random();

    var samples: std.ArrayList(Sample) = .empty;
    defer samples.deinit(allocator);

    const start_ms = clock.nowMs();
    var total: u64 = 0;
    var g: u64 = 0;
    while (g < cfg.games) : (g += 1) {
        total += try play_one_game(allocator, cfg, rng, out, &samples);
        if (cfg.verbose or (g + 1) % 100 == 0) {
            const el = clock.nowMs() - start_ms;
            const pps: u64 = if (el > 0) total * 1000 / @as(u64, @intCast(el)) else 0;
            std.debug.print("datagen: game {}/{} positions={} pos/s={} elapsed={}ms\n", .{ g + 1, cfg.games, total, pps, el });
        }
    }
    try out.flush();

    const el = clock.nowMs() - start_ms;
    std.debug.print("datagen done: games={} positions={} out={s} elapsed={}ms openings_discarded={} games_dropped={} adj_wins={} adj_draws={}\n", .{ cfg.games, total, cfg.out_path, el, stat_openings_discarded, stat_games_dropped, stat_adj_wins, stat_adj_draws });
}

fn printUsage() void {
    std.debug.print(
        \\Usage: NeuroSpeed datagen [options]
        \\  --nnue             label with the embedded NNUE net (self-play)
        \\  --soft-nodes N     soft node limit per move (default 5000)
        \\  --hard-nodes N     hard node limit per move (default 40000)
        \\  --verif-nodes N    opening verification search budget (default 50000)
        \\  --verif-cp N       discard opening if |white_cp| > N (default 800)
        \\  --depth N          LEGACY fixed-depth mode (disables node limits + verification)
        \\  --games N          number of self-play games (default 1000)
        \\  --out FILE         output text file (default gen0.txt)
        \\  --seed N           PRNG seed for random openings (default 12648430)
        \\  --opening-plies N  base random opening plies, +1 coin-flip (default 8)
        \\  --max-plies N      hard cap on game length (default 320)
        \\  --adj-cp N         |cp| win-adjudication threshold (default 2000)
        \\  --adj-draw-cp N    |cp| draw-adjudication threshold (default 8)
        \\  --min-record-ply N record only positions with ply > N (default 16)
        \\  --tt N             transposition table size in MB (default 16)
        \\  --verbose          per-game progress to stderr
        \\
    , .{});
}

pub fn parse_args(args: []const [:0]const u8) !Config {
    var cfg = Config{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--verbose") or std.mem.eql(u8, a, "-v")) {
            cfg.verbose = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--nnue")) {
            cfg.use_nnue = true;
            continue;
        }
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            printUsage();
            return error.HelpRequested;
        }
        if (i + 1 >= args.len) {
            std.debug.print("datagen: missing value for '{s}'\n", .{a});
            return error.MissingValue;
        }
        const v = args[i + 1];
        i += 1;
        if (std.mem.eql(u8, a, "--depth")) {
            cfg.depth = try std.fmt.parseUnsigned(u8, v, 10);
        } else if (std.mem.eql(u8, a, "--soft-nodes")) {
            cfg.soft_nodes = try std.fmt.parseUnsigned(u64, v, 10);
        } else if (std.mem.eql(u8, a, "--hard-nodes")) {
            cfg.hard_nodes = try std.fmt.parseUnsigned(u64, v, 10);
        } else if (std.mem.eql(u8, a, "--verif-nodes")) {
            cfg.verif_nodes = try std.fmt.parseUnsigned(u64, v, 10);
            cfg.verif_hard_nodes = cfg.verif_nodes * 8;
        } else if (std.mem.eql(u8, a, "--verif-cp")) {
            cfg.verif_max_cp = try std.fmt.parseInt(i32, v, 10);
        } else if (std.mem.eql(u8, a, "--adj-draw-cp")) {
            cfg.adj_draw_cp = try std.fmt.parseInt(i32, v, 10);
        } else if (std.mem.eql(u8, a, "--min-record-ply")) {
            cfg.min_record_ply = try std.fmt.parseUnsigned(u16, v, 10);
        } else if (std.mem.eql(u8, a, "--games")) {
            cfg.games = try std.fmt.parseUnsigned(u64, v, 10);
        } else if (std.mem.eql(u8, a, "--out")) {
            cfg.out_path = v;
        } else if (std.mem.eql(u8, a, "--seed")) {
            cfg.seed = try std.fmt.parseUnsigned(u64, v, 10);
        } else if (std.mem.eql(u8, a, "--opening-plies")) {
            cfg.opening_plies = try std.fmt.parseUnsigned(u8, v, 10);
        } else if (std.mem.eql(u8, a, "--max-plies")) {
            cfg.max_plies = try std.fmt.parseUnsigned(u16, v, 10);
        } else if (std.mem.eql(u8, a, "--adj-cp")) {
            cfg.adj_win_cp = try std.fmt.parseInt(i32, v, 10);
        } else if (std.mem.eql(u8, a, "--tt")) {
            cfg.tt_mb = try std.fmt.parseUnsigned(usize, v, 10);
        } else {
            std.debug.print("datagen: unknown option '{s}'\n", .{a});
            return error.UnknownOption;
        }
    }
    return cfg;
}
