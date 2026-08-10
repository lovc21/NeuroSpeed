const std = @import("std");
const attacks = @import("attacks.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const bitboard = @import("bitboard.zig");
const move_gen = @import("move.zig");
const movegen = @import("movegen.zig");
const print = std.debug.print;
const search = @import("search.zig");
const bench = @import("bench.zig");
const datagen = @import("datagen.zig");
const rescore = @import("rescore.zig");
const lists = @import("lists.zig");
const eval = @import("evaluation.zig");
const nnue = @import("nnue.zig");
const globals = @import("globals.zig");

const UCI_COMMANDS_MAX: usize = 10000;
const VERSION: []const u8 = "0.1";
const ENGINE_NAME: []const u8 = "NeuroSpeed";
const AUTHOR: []const u8 = "Jakob Dekleva";

/// Batch-tool dispatch shared by the CLI (main.zig, `NeuroSpeed datagen ...`)
/// and the UCI loop (`datagen ...` typed into a running engine). argv[0] is
/// the tool name. Returns true if a tool ran (or its help was printed).
///
/// The tools run BEFORE the engine activates its net in CLI mode: datagen
/// labels with the HCE unless --nnue is given (datagen.run flips use_nnue on
/// itself; it never turns it off) — the loop-mode caller is responsible for
/// saving/restoring nnue.use_nnue around this call.
pub fn run_subcommand(allocator: std.mem.Allocator, argv: []const [:0]const u8) !bool {
    if (argv.len == 0) return false;

    // `datagen [options]` → self-play training-data generation.
    if (std.ascii.eqlIgnoreCase(argv[0], "datagen")) {
        const cfg = datagen.parse_args(argv[1..]) catch |err| {
            if (err == error.HelpRequested) return true;
            return err;
        };
        try datagen.run(allocator, cfg);
        return true;
    }

    // `rescore [options]` → re-label a bulletformat file with the embedded
    // NNUE via shallow search (Gen-3 data lever).
    if (std.ascii.eqlIgnoreCase(argv[0], "rescore")) {
        const cfg = try rescore.parse_args(argv[1..]);
        try rescore.run(allocator, cfg);
        return true;
    }

    // `dumpfen <in.data> <out.epd> <stride> <limit>` → sample decided records
    // into a FEN opening book (in-band SPRT source).
    if (std.ascii.eqlIgnoreCase(argv[0], "dumpfen")) {
        if (argv.len < 5) {
            print("usage: dumpfen <in.data> <out.epd> <stride> <limit>\n", .{});
            return true;
        }
        const stride = try std.fmt.parseUnsigned(u64, argv[3], 10);
        const limit = try std.fmt.parseUnsigned(u64, argv[4], 10);
        try rescore.dump_fens(argv[1], argv[2], stride, limit);
        return true;
    }

    return false;
}

pub const UCI = struct {
    board: types.Board,
    allocator: std.mem.Allocator,
    is_searching: bool,
    stop_search: bool,
    move_overhead: u64 = 10, // ms subtracted per move for GUI/process latency

    // new uci
    pub fn new(allocator: std.mem.Allocator) UCI {
        attacks.init_attacks();
        search.init_search();
        search.init_tt(std.heap.page_allocator, 64); // Default 64 MB TT
        var board = types.Board.new();
        bitboard.parse_fen(types.start_position, &board) catch {
            print("Error parsing fen in the new uci function\n", .{});
        };
        return UCI{
            .board = board,
            .allocator = allocator,
            .is_searching = false,
            .stop_search = false,
        };
    }

    // parse moves
    fn parse_move(self: *UCI, move_string: []const u8) ?move_gen.Move {
        if (move_string.len < 4) return null;

        // Parse source and target squares
        const from_file = move_string[0] - 'a';
        const from_rank = move_string[1] - '1';
        const to_file = move_string[2] - 'a';
        const to_rank = move_string[3] - '1';

        if (from_file > 7 or from_rank > 7 or to_file > 7 or to_rank > 7) return null;

        const from_square: u6 = @intCast(from_rank * 8 + from_file);
        const to_square: u6 = @intCast(to_rank * 8 + to_file);

        // Generate legal moves to find the matching move
        var move_list: lists.MoveList = .{};
        if (self.board.side == types.Color.White)
            movegen.generate_legal_moves(&self.board, &move_list, types.Color.White)
        else
            movegen.generate_legal_moves(&self.board, &move_list, types.Color.Black);

        // Find matching move
        for (0..move_list.count) |i| {
            const move = move_list.moves[i];
            if (move.from == from_square and move.to == to_square) {
                if (move_string.len >= 5) {
                    const promotion_piece = move_string[4];
                    const expected_flag = switch (promotion_piece) {
                        'q' => if (move.is_capture()) types.MoveFlags.PC_QUEEN else types.MoveFlags.PR_QUEEN,
                        'r' => if (move.is_capture()) types.MoveFlags.PC_ROOK else types.MoveFlags.PR_ROOK,
                        'b' => if (move.is_capture()) types.MoveFlags.PC_BISHOP else types.MoveFlags.PR_BISHOP,
                        'n' => if (move.is_capture()) types.MoveFlags.PC_KNIGHT else types.MoveFlags.PR_KNIGHT,
                        else => continue,
                    };
                    if (move.flags == expected_flag) return move;
                } else {
                    if (!move.is_promotion()) return move;
                }
            }
        }

        return null;
    }

    // Parse a position command
    fn parse_position(self: *UCI, command: []const u8) !void {
        var tokens = std.mem.tokenizeScalar(u8, command, ' ');
        _ = tokens.next();

        const position_type = tokens.next() orelse return;

        if (std.mem.eql(u8, position_type, "startpos")) {
            try bitboard.parse_fen(types.start_position, &self.board);
        } else if (std.mem.eql(u8, position_type, "fen")) {
            var fen_buffer: [256]u8 = undefined;
            var fen_len: usize = 0;

            var parts_count: u8 = 0;
            while (parts_count < 6) : (parts_count += 1) {
                const part = tokens.next() orelse break;
                if (std.mem.eql(u8, part, "moves")) break;

                if (fen_len > 0) {
                    fen_buffer[fen_len] = ' ';
                    fen_len += 1;
                }
                @memcpy(fen_buffer[fen_len .. fen_len + part.len], part);
                fen_len += part.len;
            }

            if (fen_len > 0) {
                try bitboard.parse_fen(fen_buffer[0..fen_len], &self.board);
            }
        }

        // Record starting position hash for repetition detection
        search.global_search.game_count = 0;
        if (search.global_search.game_count < 512) {
            search.global_search.game_hashes[search.global_search.game_count] = self.board.hash;
            search.global_search.game_count += 1;
        }

        const rest = tokens.rest();
        if (rest.len > 0) {
            var moves_tokens = std.mem.tokenizeScalar(u8, rest, ' ');
            if (moves_tokens.next()) |first_token| {
                if (std.mem.eql(u8, first_token, "moves")) {
                    // Parse and play moves, recording each resulting hash
                    while (moves_tokens.next()) |move_str| {
                        if (self.parse_move(move_str)) |move| {
                            _ = move_gen.make_move_search(&self.board, move);
                            if (search.global_search.game_count < 512) {
                                search.global_search.game_hashes[search.global_search.game_count] = self.board.hash;
                                search.global_search.game_count += 1;
                            }
                        }
                    }
                }
            }
        }
    }

    // parse go
    fn parse_go(self: *UCI, command: []const u8) void {
        var tokens = std.mem.tokenizeScalar(u8, command, ' ');
        _ = tokens.next();

        var depth: ?u8 = null;
        var movetime: ?u64 = null;
        var wtime: ?u64 = null;
        var btime: ?u64 = null;
        var winc: ?u64 = null;
        var binc: ?u64 = null;
        var movestogo: ?u64 = null;
        var infinite = false;

        while (tokens.next()) |token| {
            if (std.mem.eql(u8, token, "depth")) {
                if (tokens.next()) |depth_str| {
                    depth = std.fmt.parseUnsigned(u8, depth_str, 10) catch null;
                }
            } else if (std.mem.eql(u8, token, "movetime")) {
                if (tokens.next()) |time_str| {
                    movetime = std.fmt.parseUnsigned(u64, time_str, 10) catch null;
                }
            } else if (std.mem.eql(u8, token, "wtime")) {
                if (tokens.next()) |time_str| {
                    wtime = std.fmt.parseUnsigned(u64, time_str, 10) catch null;
                }
            } else if (std.mem.eql(u8, token, "btime")) {
                if (tokens.next()) |time_str| {
                    btime = std.fmt.parseUnsigned(u64, time_str, 10) catch null;
                }
            } else if (std.mem.eql(u8, token, "winc")) {
                if (tokens.next()) |inc_str| {
                    winc = std.fmt.parseUnsigned(u64, inc_str, 10) catch null;
                }
            } else if (std.mem.eql(u8, token, "binc")) {
                if (tokens.next()) |inc_str| {
                    binc = std.fmt.parseUnsigned(u64, inc_str, 10) catch null;
                }
            } else if (std.mem.eql(u8, token, "movestogo")) {
                if (tokens.next()) |moves_str| {
                    movestogo = std.fmt.parseUnsigned(u64, moves_str, 10) catch null;
                }
            } else if (std.mem.eql(u8, token, "infinite")) {
                infinite = true;
            }
        }

        // Calculate time for move (0 = no time limit)
        var soft_limit: u64 = 0;
        var hard_limit: u64 = 0;

        if (movetime) |mt| {
            soft_limit = mt;
            hard_limit = mt;
        } else if (infinite or depth != null) {
            soft_limit = 0;
            hard_limit = 0;
        } else {
            // Calculate time based on remaining time and increment
            var my_time: ?u64 = null;
            var my_inc: ?u64 = null;

            if (self.board.side == types.Color.White) {
                my_time = wtime;
                my_inc = winc;
            } else {
                my_time = btime;
                my_inc = binc;
            }

            if (my_time) |time| {
                const inc = my_inc orelse 0;
                const overhead: u64 = self.move_overhead;
                const mtg: u64 = if (movestogo) |m| @min(m, 50) else 50;

                // Adjust remaining time by expected increment value (Lambergar-style)
                var adj_time = time;
                if (inc > overhead) {
                    adj_time = time + mtg * (inc - overhead);
                }

                if (movestogo != null) {
                    // Movestogo mode: scale by remaining moves
                    soft_limit = @min(7 * adj_time / (10 * mtg), 4 * time / 5);
                } else {
                    // Free/sudden-death time control: spend ~1/30 of remaining
                    // time per move. Below tm_collapse_ms the move horizon
                    // collapses with the clock (Stockfish-style: 400ms → plan
                    // 20 moves, 100ms → 5) so the engine keeps THINKING near
                    // the flag instead of dribbling 1ms moves.
                    var horizon: u64 = 30;
                    if (time < @as(u64, @intCast(@max(0, search.params.tm_collapse_ms)))) {
                        const div: u64 = @intCast(@max(1, search.params.tm_collapse_div));
                        horizon = @min(30, @max(2, time / div));
                    }
                    // Bank the overhead for every expected remaining move
                    // (Stockfish: OH*(2+mtg)) so the clock never dribbles into
                    // the sub-20ms zone where poll granularity + IO latency
                    // exceed the whole budget (observed: all 15+0 forfeits).
                    const reserve: u64 = overhead * (2 + horizon);
                    const banked: u64 = if (adj_time > reserve) adj_time - reserve else 1;
                    soft_limit = @min(banked / horizon, time / 5);
                }

                // Hard limit: tunable fraction of the overhead-adjusted clock.
                // The old min(2.5*soft, 80%) ≈ 8.3% of the clock was 2.5-8x
                // tighter than every verified engine (Ethereal 20%, Viridithas
                // 46%, Stormphrax 65%, SF 81%, Berserk 92%) — critical moves
                // (root fail-lows) are allowed to burn real time ONCE; normal
                // moves are still governed by the soft limit.
                const usable: u64 = if (time > overhead) time - overhead else 1;
                // Clamp to [1, 100]: values above 100 (reachable via the unclamped
                // SPSA setoption path) would let one move burn more than the whole
                // remaining clock. Default 46 is unaffected.
                hard_limit = usable * @as(u64, @intCast(@min(100, @max(1, search.params.tm_hard_pct)))) / 100;

                // Safety buffer: always leave the overhead in reserve
                if (time > overhead) {
                    hard_limit = @min(hard_limit, time - overhead);
                    soft_limit = @min(soft_limit, time - overhead);
                } else {
                    hard_limit = 1;
                    soft_limit = 1;
                }

                // Minimum limits — never above what's actually on the clock
                // (the old flat 5ms floor could overcommit a near-empty clock).
                const floor: u64 = @min(5, @max(time / 4, 1));
                soft_limit = @max(soft_limit, floor);
                hard_limit = @max(hard_limit, floor);
            }
        }

        searchWrapper(self, depth, soft_limit, hard_limit);
    }

    fn run_bench(self: *UCI, stdout: *std.Io.Writer) !void {
        // Quick in-loop identity check: first 5 bench positions at depth 11
        // (311432 nodes for the champion config). The full 20-position CLI
        // fingerprint lives behind `NeuroSpeed bench [depth]` (bench.zig).
        var timer: globals.Timer = .start();
        const total_nodes = bench.run_nodes(&self.board, 5, 11);
        const elapsed_ns = @max(1, timer.read());
        const nps = @as(u128, total_nodes) * std.time.ns_per_s / elapsed_ns;

        try stdout.print("{d} nodes {d} nps\n", .{ total_nodes, nps });
    }

    // Component speed benchmark for the thesis methodology (tab:perft_positions).
    // Over the six standard PERFT positions, measures all three component speeds:
    //   1. move generator  -> perft to `depth`, pure movegen (no zobrist/eval)
    //   2. evaluation       -> repeated static-eval calls, calls per second
    //   3. full search      -> search to `depth`, nodes per second of the whole engine
    fn run_speedbench(self: *UCI, depth: u8, stdout: *std.Io.Writer) !void {
        const eval_iters: u64 = 20_000_000;

        try stdout.print("\n=== SPEED BENCHMARK (6 standardnih pozicij, globina {d}) ===\n", .{depth});
        try stdout.print("{s:<14} | {s:>12} | {s:>10} | {s:>12}\n", .{ "Pozicija", "MoveGen MN/s", "Eval M/s", "Search kN/s" });
        try stdout.print("---------------+--------------+------------+-------------\n", .{});

        var sum_movegen: f64 = 0;
        var sum_eval: f64 = 0;
        var total_search_nodes: u64 = 0;
        var total_search_ns: u128 = 0;

        for (types.standard_perft_positions, types.standard_perft_names) |fen, name| {
            // --- 1. Move generator (perft, fast play/undo, no eval/zobrist) ---
            try bitboard.parse_fen(fen, &self.board);
            const white = self.board.side == types.Color.White;
            var t1: globals.Timer = .start();
            const perft_nodes: u64 = if (white)
                util.perft_legal(types.Color.White, &self.board, depth)
            else
                util.perft_legal(types.Color.Black, &self.board, depth);
            const t1_ns = @max(1, t1.read());
            const movegen_mnps = @as(f64, @floatFromInt(perft_nodes)) / @as(f64, @floatFromInt(t1_ns)) * 1000.0;

            // --- 2. Evaluation function (repeated static-eval calls) ---
            var sink: i64 = 0;
            var t2: globals.Timer = .start();
            var i: u64 = 0;
            while (i < eval_iters) : (i += 1) {
                const s = if (white)
                    eval.global_evaluator.eval_full(&self.board, types.Color.White)
                else
                    eval.global_evaluator.eval_full(&self.board, types.Color.Black);
                sink +%= s;
            }
            const t2_ns = @max(1, t2.read());
            std.mem.doNotOptimizeAway(sink);
            const eval_meps = @as(f64, @floatFromInt(eval_iters)) / @as(f64, @floatFromInt(t2_ns)) * 1000.0;

            // --- 3. Full search (whole engine) ---
            try bitboard.parse_fen(fen, &self.board); // restore clean state for search
            search.init_search();
            if (search.global_tt) |*tt| tt.clear();
            var t3: globals.Timer = .start();
            if (white)
                search.search_position(&self.board, depth, 0, 0, types.Color.White)
            else
                search.search_position(&self.board, depth, 0, 0, types.Color.Black);
            const t3_ns = @max(1, t3.read());
            const search_nodes = search.global_search.nodes;
            const search_nps = @as(f64, @floatFromInt(search_nodes)) * std.time.ns_per_s / @as(f64, @floatFromInt(t3_ns));

            try stdout.print("{s:<14} | {d:>12.2} | {d:>10.2} | {d:>12.0}\n", .{ name, movegen_mnps, eval_meps, search_nps / 1000.0 });

            sum_movegen += movegen_mnps;
            sum_eval += eval_meps;
            total_search_nodes += search_nodes;
            total_search_ns += t3_ns;
        }

        const agg_search_nps = @as(f64, @floatFromInt(total_search_nodes)) * std.time.ns_per_s / @as(f64, @floatFromInt(total_search_ns));
        try stdout.print("---------------+--------------+------------+-------------\n", .{});
        try stdout.print("{s:<14} | {d:>12.2} | {d:>10.2} | {d:>12.0}\n", .{ "Povprecje", sum_movegen / 6.0, sum_eval / 6.0, agg_search_nps / 1000.0 });
        try stdout.print("MN/s=mio vozlisc/s (movegen), M/s=mio klicev/s (eval), kN/s=tisoc vozlisc/s (search)\n", .{});
    }

    fn parse_setoption(self: *UCI, command: []const u8) void {
        // Format: setoption name <name...> value <value>  (names may contain spaces)
        var tokens = std.mem.tokenizeScalar(u8, command, ' ');
        _ = tokens.next(); // "setoption"

        const name_kw = tokens.next() orelse return;
        if (!std.mem.eql(u8, name_kw, "name")) return;

        // Collect name tokens until the "value" keyword (e.g. "Move Overhead").
        var name_buf: [64]u8 = undefined;
        var name_len: usize = 0;
        var value_str: ?[]const u8 = null;
        while (tokens.next()) |tok| {
            if (std.mem.eql(u8, tok, "value")) {
                value_str = tokens.next();
                break;
            }
            if (name_len > 0 and name_len < name_buf.len) {
                name_buf[name_len] = ' ';
                name_len += 1;
            }
            const n = @min(tok.len, name_buf.len - name_len);
            @memcpy(name_buf[name_len..][0..n], tok[0..n]);
            name_len += n;
        }
        const name = name_buf[0..name_len];
        const value = value_str orelse return;

        if (std.mem.eql(u8, name, "Hash")) {
            const size_mb = std.fmt.parseUnsigned(usize, value, 10) catch return;
            const clamped = @max(1, @min(size_mb, 4096));
            search.init_tt(std.heap.page_allocator, clamped);
            print("info string Hash set to {} MB\n", .{clamped});
        }

        if (std.mem.eql(u8, name, "UseNNUE")) {
            const want = std.ascii.eqlIgnoreCase(value, "true");
            nnue.use_nnue = want and nnue.loaded();
            print("info string UseNNUE set to {}\n", .{nnue.use_nnue});
        }

        if (std.mem.eql(u8, name, "Move Overhead")) {
            const ms = std.fmt.parseUnsigned(u64, value, 10) catch return;
            self.move_overhead = @min(ms, 1000);
            print("info string Move Overhead set to {} ms\n", .{self.move_overhead});
        }

        // Eval shaping: 50-move damping divisor (0 = off). Kept in nnue, not
        // search.Params, to avoid a search<->nnue import cycle.
        if (std.mem.eql(u8, name, "r50_div")) {
            const v = std.fmt.parseInt(i32, value, 10) catch return;
            nnue.r50_div = @max(0, @min(v, 1024));
            print("info string r50_div set to {}\n", .{nnue.r50_div});
        }

        // Per-node dual-net router (SF style): |material| > small_thresh ->
        // small net (-1 = always small, 30000 = never); small_guard = re-eval
        // band with the big net when the small net's score is modest (0 = off).
        if (std.mem.eql(u8, name, "small_thresh")) {
            const v = std.fmt.parseInt(i32, value, 10) catch return;
            nnue.small_thresh = @max(-1, @min(v, 30000));
            print("info string small_thresh set to {}\n", .{nnue.small_thresh});
        }
        if (std.mem.eql(u8, name, "small_guard")) {
            const v = std.fmt.parseInt(i32, value, 10) catch return;
            nnue.small_guard = @max(0, @min(v, 2000));
            print("info string small_guard set to {}\n", .{nnue.small_guard});
        }
        if (std.mem.eql(u8, name, "phase_floor_pct")) {
            const v = std.fmt.parseInt(i32, value, 10) catch return;
            nnue.phase_floor_pct = @max(30, @min(v, 100));
            print("info string phase_floor_pct set to {}\n", .{nnue.phase_floor_pct});
        }
        if (std.mem.eql(u8, name, "hce_corner_pct")) {
            const v = std.fmt.parseInt(i32, value, 10) catch return;
            nnue.hce_corner_pct = @max(0, @min(v, 300));
            print("info string hce_corner_pct set to {}\n", .{nnue.hce_corner_pct});
        }
        if (std.mem.eql(u8, name, "hce_kingdist_pct")) {
            const v = std.fmt.parseInt(i32, value, 10) catch return;
            nnue.hce_kingdist_pct = @max(0, @min(v, 300));
            print("info string hce_kingdist_pct set to {}\n", .{nnue.hce_kingdist_pct});
        }
        if (std.mem.eql(u8, name, "hce_edge_pct")) {
            const v = std.fmt.parseInt(i32, value, 10) catch return;
            nnue.hce_edge_pct = @max(0, @min(v, 300));
            print("info string hce_edge_pct set to {}\n", .{nnue.hce_edge_pct});
        }
        if (std.mem.eql(u8, name, "hce_tempo_pct")) {
            const v = std.fmt.parseInt(i32, value, 10) catch return;
            nnue.hce_tempo_pct = @max(0, @min(v, 300));
            print("info string hce_tempo_pct set to {}\n", .{nnue.hce_tempo_pct});
        }
        if (std.mem.eql(u8, name, "hce_lazy_margin")) {
            const v = std.fmt.parseInt(i32, value, 10) catch return;
            nnue.hce_lazy_margin = @max(150, @min(v, 1200));
            print("info string hce_lazy_margin set to {}\n", .{nnue.hce_lazy_margin});
        }
        if (std.mem.eql(u8, name, "hce_thresh")) {
            const v = std.fmt.parseInt(i32, value, 10) catch return;
            nnue.hce_thresh = @max(-1, @min(v, 30000));
            print("info string hce_thresh set to {}\n", .{nnue.hce_thresh});
        }

        // Tunable search parameters (SPSA): every search.Params field is a
        // UCI spin option with the same name.
        inline for (std.meta.fields(search.Params)) |f| {
            if (std.mem.eql(u8, name, f.name)) {
                const v = std.fmt.parseInt(i32, value, 10) catch return;
                @field(search.params, f.name) = v;
                search.rebuild_tables();
                print("info string {s} set to {}\n", .{ f.name, v });
            }
        }
    }

    fn searchWrapper(self: *UCI, depth: ?u8, soft_limit: u64, hard_limit: u64) void {
        if (self.board.side == types.Color.White) {
            search.search_position(&self.board, depth, soft_limit, hard_limit, types.Color.White);
        } else {
            search.search_position(&self.board, depth, soft_limit, hard_limit, types.Color.Black);
        }
    }
    // main loop
    pub fn uci_loop(self: *UCI) !void {
        const io = globals.io;

        var stdin_buf: [UCI_COMMANDS_MAX]u8 = undefined;
        var stdin_fr = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
        const stdin = &stdin_fr.interface;

        var stdout_buf: [4096]u8 = undefined;
        var stdout_fw = std.Io.File.stdout().writerStreaming(io, &stdout_buf);
        const stdout = &stdout_fw.interface;

        try stdout.print("NeuroSpeed version {s}\n", .{VERSION});
        try stdout.flush();

        while (true) {
            {
                const maybe_line = stdin.takeDelimiter('\n') catch |err| {
                    print("Error reading input: {}\n", .{err});
                    break;
                };
                const line = maybe_line orelse break; // clean EOF
                const trimmed = std.mem.trim(u8, line, " \r\n\t");

                if (trimmed.len == 0) continue;

                var tokens = std.mem.tokenizeScalar(u8, trimmed, ' ');
                const command = tokens.next() orelse continue;

                if (std.mem.eql(u8, command, "quit")) {
                    break;
                } else if (std.mem.eql(u8, command, "uci")) {
                    try stdout.print("id name {s} {s}\n", .{ ENGINE_NAME, VERSION });
                    try stdout.print("id author {s}\n", .{AUTHOR});
                    try stdout.print("option name Hash type spin default 64 min 1 max 4096\n", .{});
                    try stdout.print("option name Threads type spin default 1 min 1 max 1\n", .{});
                    try stdout.print("option name UseNNUE type check default true\n", .{});
                    try stdout.print("option name Move Overhead type spin default 10 min 0 max 1000\n", .{});
                    try stdout.print("option name r50_div type spin default 0 min 0 max 1024\n", .{});
                    try stdout.print("option name small_thresh type spin default {} min -1 max 30000\n", .{nnue.small_thresh});
                    try stdout.print("option name small_guard type spin default {} min 0 max 2000\n", .{nnue.small_guard});
                    try stdout.print("option name hce_thresh type spin default {} min -1 max 30000\n", .{nnue.hce_thresh});
                    try stdout.print("option name phase_floor_pct type spin default {} min 30 max 100\n", .{nnue.phase_floor_pct});
                    try stdout.print("option name hce_corner_pct type spin default {} min 0 max 300\n", .{nnue.hce_corner_pct});
                    try stdout.print("option name hce_kingdist_pct type spin default {} min 0 max 300\n", .{nnue.hce_kingdist_pct});
                    try stdout.print("option name hce_edge_pct type spin default {} min 0 max 300\n", .{nnue.hce_edge_pct});
                    try stdout.print("option name hce_tempo_pct type spin default {} min 0 max 300\n", .{nnue.hce_tempo_pct});
                    try stdout.print("option name hce_lazy_margin type spin default {} min 150 max 1200\n", .{nnue.hce_lazy_margin});
                    inline for (std.meta.fields(search.Params)) |f| {
                        try stdout.print("option name {s} type spin default {} min -1000000 max 1000000\n", .{ f.name, @field(search.params, f.name) });
                    }
                    try stdout.print("uciok\n", .{});
                } else if (std.mem.eql(u8, command, "isready")) {
                    try stdout.print("readyok\n", .{});
                } else if (std.mem.eql(u8, command, "ucinewgame")) {
                    // Reset board to starting position
                    self.board = types.Board.new();
                    try bitboard.parse_fen(types.start_position, &self.board);
                    search.init_search(); // Reset search state (also resets game_count to 0)
                    if (search.global_tt) |*tt| {
                        tt.clear();
                    }
                    self.stop_search = true;
                } else if (std.mem.eql(u8, command, "setoption")) {
                    self.parse_setoption(trimmed);
                } else if (std.mem.eql(u8, command, "position")) {
                    try self.parse_position(trimmed);
                } else if (std.mem.eql(u8, command, "go")) {
                    if (!self.is_searching) {
                        self.parse_go(trimmed);
                    }
                } else if (std.mem.eql(u8, command, "stop")) {
                    self.stop_search = true;
                } else if (std.mem.eql(u8, command, "d")) {
                    // Debug command to display board
                    bitboard.print_unicode_board(self.board);
                } else if (std.mem.eql(u8, command, "fen")) {
                    var fbuf: [128]u8 = undefined;
                    const f = @import("datagen.zig").board_to_fen(&self.board, 1, &fbuf);
                    try stdout.print("{s}\n", .{f});
                } else if (std.mem.eql(u8, command, "datagen") or
                    std.mem.eql(u8, command, "rescore") or
                    std.mem.eql(u8, command, "dumpfen"))
                {
                    // Batch tools, callable from a running engine too. CLI
                    // parity: datagen labels with the HCE unless --nnue, so
                    // the engine's active net is disabled around the call and
                    // restored after; search/TT state is re-initialized since
                    // the tool ran its own searches.
                    var argbuf: [32][:0]const u8 = undefined;
                    var argc: usize = 0;
                    argbuf[argc] = try self.allocator.dupeZ(u8, command);
                    argc += 1;
                    while (tokens.next()) |t| {
                        if (argc >= argbuf.len) break;
                        argbuf[argc] = try self.allocator.dupeZ(u8, t);
                        argc += 1;
                    }
                    defer for (argbuf[0..argc]) |a| self.allocator.free(a);

                    const saved_use_nnue = nnue.use_nnue;
                    nnue.use_nnue = false;
                    _ = run_subcommand(self.allocator, argbuf[0..argc]) catch |err| {
                        print("info string tool error: {}\n", .{err});
                    };
                    nnue.use_nnue = saved_use_nnue;
                    search.init_search();
                    if (search.global_tt) |*tt| tt.clear();
                } else if (std.mem.eql(u8, command, "perft")) {
                    var depth: u8 = 1;
                    if (tokens.next()) |depth_str| {
                        depth = std.fmt.parseUnsigned(u8, depth_str, 10) catch 1;
                    }

                    var timer: globals.Timer = .start();
                    const nodes: u64 = if (self.board.side == types.Color.White)
                        util.perft_legal(types.Color.White, &self.board, depth)
                    else
                        util.perft_legal(types.Color.Black, &self.board, depth);
                    const elapsed_ns = timer.read();
                    const elapsed_ms = elapsed_ns / std.time.ns_per_ms;
                    const mnps = if (elapsed_ns > 0) @as(f64, @floatFromInt(nodes)) / @as(f64, @floatFromInt(elapsed_ns)) * 1000.0 else 0.0;
                    try stdout.print("{d} nodes, {d}ms, {d:.2} MNodes/s\n", .{ nodes, elapsed_ms, mnps });
                } else if (std.mem.eql(u8, command, "evalspeed")) {
                    // Izmeri hitrost evalvacijske funkcije: N-krat poklicemo eval na
                    // trenutni poziciji in izpisemo "evalspeed evals <N> time <ms>".
                    var iters: u64 = 1000000;
                    if (tokens.next()) |iters_str| {
                        iters = std.fmt.parseUnsigned(u64, iters_str, 10) catch 1000000;
                    }
                    const white = self.board.side == types.Color.White;
                    var sink: i64 = 0;
                    var timer: globals.Timer = .start();
                    var i: u64 = 0;
                    while (i < iters) : (i += 1) {
                        const s = if (white)
                            eval.global_evaluator.eval_full(&self.board, types.Color.White)
                        else
                            eval.global_evaluator.eval_full(&self.board, types.Color.Black);
                        sink +%= s;
                    }
                    const elapsed_ms = @as(f64, @floatFromInt(timer.read())) / 1_000_000.0;
                    try stdout.print("evalspeed evals {d} time {d:.3}\n", .{ iters, elapsed_ms });
                    if (sink == std.math.minInt(i64)) {
                        print("{d}\n", .{sink});
                    }
                } else if (std.mem.eql(u8, command, "eval")) {
                    // Print static evaluation of the current position (White's perspective).
                    // eval_full must be called with the true side to move: the NNUE branch
                    // returns STM-relative scores regardless of the color param, so calling
                    // it with White on a black-to-move position mislabels the sign. Negate
                    // the STM-relative result for Black to get the White perspective.
                    const score_white = if (self.board.side == types.Color.White)
                        eval.global_evaluator.eval_full(&self.board, types.Color.White)
                    else
                        -eval.global_evaluator.eval_full(&self.board, types.Color.Black);
                    try stdout.print("eval cp {d} (white perspective)\n", .{score_white});
                } else if (std.mem.eql(u8, command, "bench")) {
                    // Bare `bench`: quick 5-position check at depth 11
                    // (311432 for the champion config). `bench <depth>`: the
                    // full 20-position fingerprint (`bench 6` = 56024).
                    if (tokens.next()) |depth_str| {
                        const depth = std.fmt.parseUnsigned(u8, depth_str, 10) catch 5;
                        var timer: globals.Timer = .start();
                        const total_nodes = bench.run_nodes(&self.board, bench.positions.len, depth);
                        const elapsed_ns = @max(1, timer.read());
                        const nps = @as(u128, total_nodes) * std.time.ns_per_s / elapsed_ns;
                        try stdout.print("{d} nodes {d} nps\n", .{ total_nodes, nps });
                    } else {
                        try self.run_bench(stdout);
                    }
                } else if (std.mem.eql(u8, command, "verify")) {
                    // Debug: refresh-and-compare both incremental accumulator
                    // stacks on every eval. `verify` = on, `verify off` = off.
                    if (tokens.next()) |arg| {
                        nnue.verify_incremental = !std.mem.eql(u8, arg, "off");
                    } else {
                        nnue.verify_incremental = true;
                    }
                    try stdout.print("info string verify_incremental {}\n", .{nnue.verify_incremental});
                } else if (std.mem.eql(u8, command, "speedbench")) {
                    var depth: u8 = 6;
                    if (tokens.next()) |depth_str| {
                        depth = std.fmt.parseUnsigned(u8, depth_str, 10) catch 6;
                    }
                    try self.run_speedbench(depth, stdout);
                } else {
                    try stdout.print("Unknown command: {s}\n", .{command});
                }
            }

            // Deliver everything before blocking on the next read — a buffered
            // uciok/readyok while waiting on stdin deadlocks GUIs.
            stdout.flush() catch {};
        }

        search.deinit_tt();
    }
};
