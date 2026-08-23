const std = @import("std");
const types = @import("types.zig");
const bitboard = @import("bitboard.zig");
const search = @import("search.zig");
const util = @import("util.zig");
const eval = @import("evaluation.zig");
const clock = @import("clock.zig");

pub const positions = [_][]const u8{
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
    "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
    "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
    "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
    "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/3P1N1P/PPP1NPP1/R2Q1RK1 w - - 0 10",
    "r1bqkbnr/pppppppp/2n5/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 1 2",
    "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4",
    "r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/2N2N2/PPPP1PPP/R1BQK2R w KQkq - 6 5",
    "r2q1rk1/ppp2ppp/2np1n2/2b1p1B1/2B1P1b1/2NP1N2/PPP2PPP/R2QR1K1 w - - 4 8",
    "r1bq1rk1/pp2ppbp/2np1np1/8/3NP3/2N1BP2/PPPQ2PP/R3KB1R w KQ - 3 8",
    "2r3k1/pp3ppp/2n1bn2/3pp3/4P3/2N2N2/PPP2PPP/R1B1R1K1 w - - 0 12",
    "r1bqkbnr/pp1ppppp/2n5/2p5/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq c6 0 3",
    "r1bqk2r/ppp2ppp/2n1pn2/3p4/1bPP4/2N2N2/PP2PPPP/R1BQKB1R w KQkq - 2 5",
    "rnbqk2r/pppp1ppp/4pn2/8/1bPP4/2N5/PP2PPPP/R1BQKBNR w KQkq - 2 4",
    "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3",
    "8/8/4kpp1/3p1b2/p6P/2B5/6P1/6K1 w - - 0 47",
    "8/5pk1/7p/3p1R2/p1p5/2P2PP1/1P4KP/3r4 w - - 0 38",
    "1r4k1/5ppp/p1qr1n2/3p4/NP1P4/P4Q2/5PPP/1RR3K1 w - - 0 23",
    "r2qk2r/ppp1bppp/5n2/3p4/3Pn3/3B1N2/PPP2PPP/RNBQ1RK1 w kq - 0 8",
};

pub fn run_nodes(board: *types.Board, count: usize, depth: u8) u64 {
    var total: u64 = 0;
    for (positions[0..count]) |fen| {
        board.* = types.Board.new();
        bitboard.parse_fen(fen, board) catch continue;

        search.init_search();
        if (search.global_tt) |*tt| tt.clear();

        if (board.side == types.Color.White) {
            search.search_position(board, depth, 0, 0, types.Color.White);
        } else {
            search.search_position(board, depth, 0, 0, types.Color.Black);
        }
        total += search.global_search.nodes;
    }
    return total;
}

/// Timed fingerprint bench: prints "<nodes> nodes <nps> nps". Bare UCI
/// `bench` uses (5, 11) — 311432 nodes for the champion config; `bench
/// <depth>` uses the full 20 positions (`bench 6` = 56024).
pub fn run(board: *types.Board, count: usize, depth: u8, out: *std.Io.Writer) !void {
    var timer: clock.Timer = .start();
    const total_nodes = run_nodes(board, count, depth);
    const elapsed_ns = @max(1, timer.read());
    const nps = @as(u128, total_nodes) * std.time.ns_per_s / elapsed_ns;
    try out.print("{d} nodes {d} nps\n", .{ total_nodes, nps });
}

/// One component measurement: node/call count plus elapsed nanoseconds.
pub const Measure = struct {
    nodes: u64,
    ns: u64,

    /// Millions per second (movegen MN/s, eval M calls/s).
    pub fn mps(m: Measure) f64 {
        return @as(f64, @floatFromInt(m.nodes)) / @as(f64, @floatFromInt(m.ns)) * 1000.0;
    }

    /// Plain per-second rate (search NPS).
    pub fn per_sec(m: Measure) f64 {
        return @as(f64, @floatFromInt(m.nodes)) * std.time.ns_per_s / @as(f64, @floatFromInt(m.ns));
    }
};

/// Move generator speed on the current position: legal perft to `depth` —
/// fast play/undo, no zobrist/eval. Backs the UCI `perft` command.
pub fn measure_movegen_pos(board: *types.Board, depth: u8) Measure {
    var timer: clock.Timer = .start();
    const nodes: u64 = if (board.side == types.Color.White)
        util.perft_legal(types.Color.White, board, depth)
    else
        util.perft_legal(types.Color.Black, board, depth);
    return .{ .nodes = nodes, .ns = @max(1, timer.read()) };
}

pub fn measure_movegen(board: *types.Board, fen: []const u8, depth: u8) !Measure {
    try bitboard.parse_fen(fen, board);
    return measure_movegen_pos(board, depth);
}

/// Evaluation speed on the current position: `iters` repeated full
/// static-eval calls (no lazy cutoff). Backs the UCI `evalspeed` command.
pub fn measure_eval_pos(board: *types.Board, iters: u64) Measure {
    const white = board.side == types.Color.White;
    var sink: i64 = 0;
    var timer: clock.Timer = .start();
    var i: u64 = 0;
    while (i < iters) : (i += 1) {
        const s = if (white)
            eval.global_evaluator.eval_full(board, types.Color.White)
        else
            eval.global_evaluator.eval_full(board, types.Color.Black);
        sink +%= s; // keep the optimizer from deleting the eval call
    }
    const ns = @max(1, timer.read());
    std.mem.doNotOptimizeAway(sink);
    return .{ .nodes = iters, .ns = ns };
}

pub fn measure_eval(board: *types.Board, fen: []const u8, iters: u64) !Measure {
    try bitboard.parse_fen(fen, board);
    return measure_eval_pos(board, iters);
}

/// Full-engine speed: search to `depth` from a clean TT.
pub fn measure_search(board: *types.Board, fen: []const u8, depth: u8) !Measure {
    try bitboard.parse_fen(fen, board);
    search.init_search();
    if (search.global_tt) |*tt| tt.clear();
    var timer: clock.Timer = .start();
    if (board.side == types.Color.White)
        search.search_position(board, depth, 0, 0, types.Color.White)
    else
        search.search_position(board, depth, 0, 0, types.Color.Black);
    const ns = @max(1, timer.read());
    return .{ .nodes = search.global_search.nodes, .ns = ns };
}

/// Component speed benchmark for the thesis methodology (tab:perft_positions).
/// Over the six standard PERFT positions, measures all three component speeds:
///   1. move generator  -> perft to `depth`, pure movegen (no zobrist/eval)
///   2. evaluation       -> repeated static-eval calls, calls per second
///   3. full search      -> search to `depth`, nodes per second of the whole engine
pub fn speedbench(board: *types.Board, depth: u8, out: *std.Io.Writer) !void {
    const eval_iters: u64 = 20_000_000;

    try out.print("\n=== SPEED BENCHMARK (6 standardnih pozicij, globina {d}) ===\n", .{depth});
    try out.print("{s:<14} | {s:>12} | {s:>10} | {s:>12}\n", .{ "Pozicija", "MoveGen MN/s", "Eval M/s", "Search kN/s" });
    try out.print("---------------+--------------+------------+-------------\n", .{});

    var sum_movegen: f64 = 0;
    var sum_eval: f64 = 0;
    var total_search_nodes: u64 = 0;
    var total_search_ns: u128 = 0;

    for (types.standard_perft_positions, types.standard_perft_names) |fen, name| {
        const movegen_m = try measure_movegen(board, fen, depth);
        const eval_m = try measure_eval(board, fen, eval_iters);
        const search_m = try measure_search(board, fen, depth);

        try out.print("{s:<14} | {d:>12.2} | {d:>10.2} | {d:>12.0}\n", .{ name, movegen_m.mps(), eval_m.mps(), search_m.per_sec() / 1000.0 });

        sum_movegen += movegen_m.mps();
        sum_eval += eval_m.mps();
        total_search_nodes += search_m.nodes;
        total_search_ns += search_m.ns;
    }

    const agg_search_nps = @as(f64, @floatFromInt(total_search_nodes)) * std.time.ns_per_s / @as(f64, @floatFromInt(total_search_ns));
    try out.print("---------------+--------------+------------+-------------\n", .{});
    try out.print("{s:<14} | {d:>12.2} | {d:>10.2} | {d:>12.0}\n", .{ "Povprecje", sum_movegen / 6.0, sum_eval / 6.0, agg_search_nps / 1000.0 });
    try out.print("MN/s=mio vozlisc/s (movegen), M/s=mio klicev/s (eval), kN/s=tisoc vozlisc/s (search)\n", .{});
}
