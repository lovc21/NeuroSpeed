const std = @import("std");
const types = @import("types.zig");
const bitboard = @import("bitboard.zig");
const movegen = @import("movegen.zig");
const move_gen = @import("move.zig");
const lists = @import("lists.zig");
const search = @import("search.zig");
const attacks = @import("attacks.zig");

// Search reports forced mates as |score| > MATE_VALUE-100 (MATE_VALUE = 49000).
const MATE_THRESHOLD: i32 = 48900;

pub const Config = struct {
    depth: u8 = 8, // fixed search depth per move (reproducible labels)
    games: u64 = 1000,
    out_path: []const u8 = "gen0.txt",
    seed: u64 = 0xC0FFEE,
    opening_plies: u8 = 8, // random plies from startpos for variety
    max_plies: u16 = 320, // hard cap → adjudicate draw
    adj_win_cp: i32 = 1000, // |white_cp| over this for adj_win_plies → decisive
    adj_win_plies: u8 = 4,
    extreme_cp: i32 = 10000, // drop positions with |white_cp| ≥ this
    tt_mb: usize = 16,
    verbose: bool = false,
};

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

// One recorded position, FEN stored inline to avoid per-position heap churn.
const Sample = struct {
    buf: [128]u8 = undefined,
    len: usize = 0,
    cp: i32 = 0, // white-relative centipawns
};

/// Serialize `board` to a standard 6-field FEN into `buf`; returns the written slice.
pub fn board_to_fen(board: *const types.Board, fullmove: u32, buf: []u8) []u8 {
    var fbs = std.io.fixedBufferStream(buf);
    const w = fbs.writer();

    // Piece placement: rank 8 (index 7) down to rank 1 (index 0), files a..h.
    var rank: usize = 8;
    while (rank > 0) {
        rank -= 1;
        var empties: u8 = 0;
        var file: usize = 0;
        while (file < 8) : (file += 1) {
            const pc = board.board[rank * 8 + file];
            if (pc == types.Piece.NO_PIECE) {
                empties += 1;
            } else {
                if (empties > 0) {
                    w.print("{d}", .{empties}) catch {};
                    empties = 0;
                }
                w.writeByte(types.PieceString[@intFromEnum(pc)]) catch {};
            }
        }
        if (empties > 0) w.print("{d}", .{empties}) catch {};
        if (rank > 0) w.writeByte('/') catch {};
    }

    // Side to move
    w.writeByte(' ') catch {};
    w.writeByte(if (board.side == types.Color.White) 'w' else 'b') catch {};

    // Castling rights (K Q k q order)
    w.writeByte(' ') catch {};
    if (board.castle == 0) {
        w.writeByte('-') catch {};
    } else {
        if (board.castle & @intFromEnum(types.Castle.WK) != 0) w.writeByte('K') catch {};
        if (board.castle & @intFromEnum(types.Castle.WQ) != 0) w.writeByte('Q') catch {};
        if (board.castle & @intFromEnum(types.Castle.BK) != 0) w.writeByte('k') catch {};
        if (board.castle & @intFromEnum(types.Castle.BQ) != 0) w.writeByte('q') catch {};
    }

    // En passant target
    w.writeByte(' ') catch {};
    if (board.enpassant == types.square.NO_SQUARE) {
        w.writeByte('-') catch {};
    } else {
        w.writeAll(types.SquareString.getSquareToString(board.enpassant)) catch {};
    }

    // Halfmove clock + fullmove number
    w.print(" {d} {d}", .{ board.halfmove, fullmove }) catch {};

    return fbs.getWritten();
}

// Fill `list` with legal moves and return whether the side to move is in check,
// computing the legal info exactly once. `board.side` (runtime) is turned into a
// comptime color via an inline switch prong.
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

fn run_fixed_search(board: *types.Board, depth: u8) void {
    switch (board.side) {
        inline .White, .Black => |c| search.search_position(board, depth, 0, 0, c),
        .both => unreachable,
    }
}

fn count_hash(history: []const u64, hash: u64) usize {
    var c: usize = 0;
    for (history) |h| {
        if (h == hash) c += 1;
    }
    return c;
}

/// Play one self-play game; write labeled lines to `out`. Returns positions written.
fn play_one_game(
    cfg: Config,
    rng: std.Random,
    out: anytype,
    samples: *std.ArrayList(Sample),
) !u64 {
    samples.clearRetainingCapacity();

    var board = types.Board.new();

    // Random opening: replay from startpos until we get a non-terminal line.
    open: while (true) {
        bitboard.parse_fen(types.start_position, &board) catch unreachable;
        var i: u8 = 0;
        while (i < cfg.opening_plies) : (i += 1) {
            var list: lists.MoveList = .{};
            _ = gen_and_check(&board, &list);
            if (list.count == 0) continue :open; // terminal mid-opening, restart
            const idx = rng.uintLessThan(usize, list.count);
            _ = move_gen.make_move_search(&board, list.moves[idx]);
        }
        break;
    }

    // Fresh search heuristics + TT per game for cleaner, less history-dependent labels.
    search.init_search();
    if (search.global_tt) |*tt| tt.clear();

    var history: [2048]u64 = undefined;
    var hist_len: usize = 0;

    var ply: u32 = cfg.opening_plies;
    var white_streak: u8 = 0;
    var black_streak: u8 = 0;
    var outcome: Outcome = .draw;

    game: while (true) {
        // Terminal / draw detection before searching.
        var list: lists.MoveList = .{};
        const checked = gen_and_check(&board, &list);

        if (list.count == 0) {
            // Checkmate: side to move loses. Stalemate: draw.
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
        if (count_hash(history[0..hist_len], board.hash) >= 2) {
            outcome = .draw; // threefold repetition
            break :game;
        }
        if (ply >= cfg.max_plies) {
            outcome = .draw; // length cap
            break :game;
        }

        // Fixed-depth search → stm-relative label + best move.
        run_fixed_search(&board, cfg.depth);
        const score = search.global_search.best_score;
        const best = search.global_search.best_move;

        const white_cp: i32 = if (board.side == types.Color.White) score else -score;

        // Win/loss adjudication streaks.
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

        // Record (filter out noisy / in-check / mate / extreme positions).
        const is_mate = score > MATE_THRESHOLD or score < -MATE_THRESHOLD;
        const noisy = best.is_capture() or best.is_promotion();
        const extreme = white_cp >= cfg.extreme_cp or white_cp <= -cfg.extreme_cp;
        if (!checked and !noisy and !is_mate and !extreme) {
            var s = Sample{};
            const fen = board_to_fen(&board, ply / 2 + 1, s.buf[0..]);
            s.len = fen.len;
            s.cp = white_cp;
            try samples.append(s);
        }

        if (white_streak >= cfg.adj_win_plies) {
            outcome = .white_win;
            break :game;
        }
        if (black_streak >= cfg.adj_win_plies) {
            outcome = .black_win;
            break :game;
        }

        // Advance to the next position.
        if (hist_len < history.len) {
            history[hist_len] = board.hash;
            hist_len += 1;
        }
        _ = move_gen.make_move_search(&board, best);
        ply += 1;
    }

    // Flush this game's samples with its white-relative result.
    const res = outcome.str();
    for (samples.items) |s| {
        try out.print("{s} | {d} | {s}\n", .{ s.buf[0..s.len], s.cp, res });
    }
    return samples.items.len;
}

pub fn run(allocator: std.mem.Allocator, cfg: Config) !void {
    search.silent = true; // suppress per-move UCI info/bestmove spam
    attacks.init_attacks();
    search.init_search();
    search.init_tt(allocator, cfg.tt_mb);
    defer search.deinit_tt();

    var out_file = try std.fs.cwd().createFile(cfg.out_path, .{});
    defer out_file.close();
    var bw = std.io.bufferedWriter(out_file.writer());
    const out = bw.writer();

    var prng = std.Random.DefaultPrng.init(cfg.seed);
    const rng = prng.random();

    var samples = std.ArrayList(Sample).init(allocator);
    defer samples.deinit();

    const start_ms = std.time.milliTimestamp();
    var total: u64 = 0;
    var g: u64 = 0;
    while (g < cfg.games) : (g += 1) {
        total += try play_one_game(cfg, rng, out, &samples);
        if (cfg.verbose or (g + 1) % 100 == 0) {
            const el = std.time.milliTimestamp() - start_ms;
            std.debug.print("datagen: game {}/{} positions={} elapsed={}ms\n", .{ g + 1, cfg.games, total, el });
        }
    }
    try bw.flush();

    const el = std.time.milliTimestamp() - start_ms;
    std.debug.print("datagen done: games={} positions={} out={s} elapsed={}ms\n", .{ cfg.games, total, cfg.out_path, el });
}

fn printUsage() void {
    std.debug.print(
        \\Usage: NeuroSpeed datagen [options]
        \\  --depth N          fixed search depth per move (default 8)
        \\  --games N          number of self-play games (default 1000)
        \\  --out FILE         output text file (default gen0.txt)
        \\  --seed N           PRNG seed for random openings (default 12648430)
        \\  --opening-plies N  random opening plies from startpos (default 8)
        \\  --max-plies N      hard cap on game length (default 320)
        \\  --adj-cp N         |cp| win-adjudication threshold (default 1000)
        \\  --tt N             transposition table size in MB (default 16)
        \\  --verbose          per-game progress to stderr
        \\
    , .{});
}

pub fn parse_args(args: []const [:0]u8) !Config {
    var cfg = Config{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--verbose") or std.mem.eql(u8, a, "-v")) {
            cfg.verbose = true;
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
