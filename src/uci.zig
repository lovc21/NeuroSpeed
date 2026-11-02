const std = @import("std");
const attacks = @import("attacks.zig");
const types = @import("types.zig");
const bitboard = @import("bitboard.zig");
const move_gen = @import("move.zig");
const movegen = @import("movegen.zig");
const print = std.debug.print;
const search = @import("search.zig");
const tt_mod = @import("tt.zig");
const bench = @import("bench.zig");
const datagen = @import("datagen.zig");
const lists = @import("lists.zig");
const eval = @import("evaluation.zig");
const nnue = @import("nnue.zig");
const clock = @import("clock.zig");
const tm = @import("time_management.zig");
const router = @import("router.zig");

const UCI_COMMANDS_MAX: usize = 10000;
const VERSION: []const u8 = @import("build_options").version;
const ENGINE_NAME: []const u8 = "NeuroSpeed";
const AUTHOR: []const u8 = "Jakob Dekleva";

/// Every module-owned spin option (name, bounds, storage), for `uci` and `setoption`.
const options = router.options ++ eval.options ++ nnue.options;

pub const UCI = struct {
    board: types.Board,
    allocator: std.mem.Allocator,
    move_overhead: u64 = 10,

    // new uci
    pub fn new(allocator: std.mem.Allocator) UCI {
        attacks.init_attacks();
        search.init_search();
        tt_mod.init_global(std.heap.page_allocator, 64) catch print("info string Failed to allocate TT (64 MB)\n", .{}); // default 64 MB
        var board = types.Board.new();
        bitboard.parse_fen(types.start_position, &board) catch {
            print("Error parsing fen in the new uci function\n", .{});
        };
        return UCI{
            .board = board,
            .allocator = allocator,
        };
    }

    /// position (startpos | fen <fields>) [moves <uci> ...]
    fn parse_position(self: *UCI, command: []const u8) !void {
        var it = std.mem.tokenizeScalar(u8, command, ' ');
        _ = it.next(); // "position"
        const kind = it.next() orelse return;
        const rest = it.rest();
        const moves_at = std.mem.indexOf(u8, rest, "moves");

        const fen = if (std.mem.eql(u8, kind, "startpos"))
            types.start_position
        else if (std.mem.eql(u8, kind, "fen"))
            std.mem.trim(u8, rest[0..(moves_at orelse rest.len)], " ")
        else
            return;
        if (fen.len == 0) return;

        // Parse into a scratch board so a bad FEN leaves the current position intact.
        var parsed = types.Board.new();
        try bitboard.parse_fen(fen, &parsed);
        self.board = parsed;

        search.global_search.game_count = 0;
        search.global_search.push_game_hash(self.board.hash);
        if (moves_at) |at| {
            var moves = std.mem.tokenizeScalar(u8, rest[at + "moves".len ..], ' ');
            next_move: while (moves.next()) |text| {
                // A UCI move string has no flags; play the legal move whose text matches.
                var list: lists.MoveList = .{};
                movegen.generate_legal_moves_rt(&self.board, &list);
                for (list.moves[0..list.count]) |move| {
                    var buf: [5]u8 = undefined;
                    if (!std.mem.eql(u8, move.to_uci(&buf), text)) continue;
                    _ = move_gen.make_move_search_rt(&self.board, move);
                    search.global_search.push_game_hash(self.board.hash);
                    continue :next_move;
                }
                break; // illegal or malformed move
            }
        }
    }

    /// go [depth N] [movetime N] [wtime N] [btime N] [winc N] [binc N] [movestogo N] [infinite]
    fn parse_go(self: *UCI, command: []const u8) void {
        var go: tm.Go = .{};
        var it = std.mem.tokenizeScalar(u8, command, ' ');
        _ = it.next(); // "go"
        while (it.next()) |tok| {
            if (std.mem.eql(u8, tok, "infinite")) {
                go.infinite = true;
                continue;
            }
            if (std.mem.eql(u8, tok, "ponder")) continue; // flag without a value; not supported
            const val = it.next() orelse break;
            inline for (std.meta.fields(tm.Go)) |f| {
                if (f.type != bool and std.mem.eql(u8, tok, f.name)) {
                    @field(go, f.name) = std.fmt.parseUnsigned(@typeInfo(f.type).optional.child, val, 10) catch null;
                }
            }
        }
        const b = tm.budget(go, self.board.side, self.move_overhead);
        search.search_position_rt(&self.board, go.depth, b.soft, b.hard);
    }

    /// setoption name <name...> value <value>  (names may contain spaces)
    fn parse_setoption(self: *UCI, command: []const u8) void {
        const name_at = std.mem.indexOf(u8, command, "name ") orelse return;
        const after = command[name_at + "name ".len ..];
        const value_at = std.mem.indexOf(u8, after, " value ") orelse return;
        const name = std.mem.trim(u8, after[0..value_at], " ");
        const value = std.mem.trim(u8, after[value_at + " value ".len ..], " ");

        if (std.mem.eql(u8, name, "Hash")) {
            const mb = std.fmt.parseUnsigned(usize, value, 10) catch return;
            const clamped = std.math.clamp(mb, 1, 4096);
            tt_mod.init_global(std.heap.page_allocator, clamped) catch print("info string Failed to allocate TT ({} MB)\n", .{clamped});
            print("info string Hash set to {} MB\n", .{clamped});
        } else if (std.mem.eql(u8, name, "UseNNUE")) {
            nnue.use_nnue = std.ascii.eqlIgnoreCase(value, "true") and nnue.loaded();
            print("info string UseNNUE set to {}\n", .{nnue.use_nnue});
        } else if (std.mem.eql(u8, name, "Move Overhead")) {
            const ms = std.fmt.parseUnsigned(u64, value, 10) catch return;
            self.move_overhead = @min(ms, 1000);
            print("info string Move Overhead set to {} ms\n", .{self.move_overhead});
        } else {
            for (options) |o| {
                if (!std.mem.eql(u8, name, o.name)) continue;
                const v = std.fmt.parseInt(i32, value, 10) catch return;
                o.ptr.* = std.math.clamp(v, o.min, o.max);
                print("info string {s} set to {}\n", .{ o.name, o.ptr.* });
                return;
            }
            // Tunable search parameters (SPSA)
            inline for (std.meta.fields(search.Params)) |f| {
                if (std.mem.eql(u8, name, f.name)) {
                    const v = std.fmt.parseInt(i32, value, 10) catch return;
                    @field(search.params, f.name) = v;
                    search.rebuild_tables();
                    print("info string {s} set to {}\n", .{ f.name, v });
                }
            }
        }
    }

    // main loop
    pub fn uci_loop(self: *UCI) !void {
        const io = clock.io;

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
                const line = maybe_line orelse break; // EOF
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
                    for (options) |o| {
                        try stdout.print("option name {s} type spin default {} min {} max {}\n", .{ o.name, o.ptr.*, o.min, o.max });
                    }
                    inline for (std.meta.fields(search.Params)) |f| {
                        try stdout.print("option name {s} type spin default {} min -1000000 max 1000000\n", .{ f.name, @field(search.params, f.name) });
                    }
                    try stdout.print("uciok\n", .{});
                } else if (std.mem.eql(u8, command, "isready")) {
                    try stdout.print("readyok\n", .{});
                } else if (std.mem.eql(u8, command, "ucinewgame")) {
                    // Start position, fresh search state (incl. game history), empty TT.
                    self.board = types.Board.new();
                    try bitboard.parse_fen(types.start_position, &self.board);
                    search.init_search();
                    if (tt_mod.global) |*tt| {
                        tt.clear();
                    }
                } else if (std.mem.eql(u8, command, "setoption")) {
                    self.parse_setoption(trimmed);
                } else if (std.mem.eql(u8, command, "position")) {
                    self.parse_position(trimmed) catch |err| print("info string position error: {}\n", .{err});
                } else if (std.mem.eql(u8, command, "go")) {
                    self.parse_go(trimmed);
                } else if (std.mem.eql(u8, command, "stop")) {
                    // No-op: `go` searches synchronously, so nothing can be running here.
                } else if (std.mem.eql(u8, command, "d")) {
                    // Debug: print the board.
                    bitboard.print_unicode_board(self.board);
                } else if (std.mem.eql(u8, command, "fen")) {
                    var fbuf: [128]u8 = undefined;
                    const f = bitboard.board_to_fen(&self.board, 1, &fbuf);
                    try stdout.print("{s}\n", .{f});
                } else if (std.mem.eql(u8, command, "datagen")) {
                    // Self-play data generation (`datagen --help`); labels with HCE unless --nnue.
                    var argbuf: [32][:0]const u8 = undefined;
                    var argc: usize = 0;
                    while (tokens.next()) |t| {
                        if (argc >= argbuf.len) break;
                        argbuf[argc] = try self.allocator.dupeZ(u8, t);
                        argc += 1;
                    }
                    defer for (argbuf[0..argc]) |a| self.allocator.free(a);

                    const saved_use_nnue = nnue.use_nnue; // net off during the tool, restored after
                    nnue.use_nnue = false;
                    if (datagen.parse_args(argbuf[0..argc])) |cfg| {
                        datagen.run(self.allocator, cfg) catch |err| print("info string datagen error: {}\n", .{err});
                    } else |err| {
                        if (err != error.HelpRequested) print("info string datagen error: {}\n", .{err});
                    }
                    nnue.use_nnue = saved_use_nnue;
                    search.init_search(); // the tool ran its own searches
                    if (tt_mod.global) |*tt| tt.clear();
                } else if (std.mem.eql(u8, command, "perft")) {
                    var depth: u8 = 1;
                    if (tokens.next()) |depth_str| {
                        depth = std.fmt.parseUnsigned(u8, depth_str, 10) catch 1;
                    }

                    const m = bench.measure_movegen_pos(&self.board, depth);
                    try stdout.print("{d} nodes, {d}ms, {d:.2} MNodes/s\n", .{ m.nodes, m.ns / std.time.ns_per_ms, m.mps() });
                } else if (std.mem.eql(u8, command, "evalspeed")) {
                    // Eval speed: N full static evals of the current position.
                    var iters: u64 = 1000000;
                    if (tokens.next()) |iters_str| {
                        iters = std.fmt.parseUnsigned(u64, iters_str, 10) catch 1000000;
                    }
                    const m = bench.measure_eval_pos(&self.board, iters);
                    const elapsed_ms = @as(f64, @floatFromInt(m.ns)) / 1_000_000.0;
                    try stdout.print("evalspeed evals {d} time {d:.3}\n", .{ iters, elapsed_ms });
                } else if (std.mem.eql(u8, command, "eval")) {
                    // Static eval from White's view; the net scores side-to-move, so negate for Black.
                    const score_white = if (self.board.side == types.Color.White)
                        eval.global_evaluator.eval_full(&self.board, types.Color.White)
                    else
                        -eval.global_evaluator.eval_full(&self.board, types.Color.Black);
                    try stdout.print("eval cp {d} (white perspective)\n", .{score_white});
                } else if (std.mem.eql(u8, command, "bench")) {
                    // `bench` = 5 positions at depth 11, `bench <d>` = all 20 positions.
                    if (tokens.next()) |depth_str| {
                        const depth = std.fmt.parseUnsigned(u8, depth_str, 10) catch 5;
                        try bench.run(&self.board, bench.positions.len, depth, stdout);
                    } else {
                        try bench.run(&self.board, 5, 11, stdout);
                    }
                } else if (std.mem.eql(u8, command, "verify")) {
                    // Debug: check the incremental NNUE accumulators on every eval (`verify off` disables).
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
                    try bench.speedbench(&self.board, depth, stdout);
                } else {
                    try stdout.print("Unknown command: {s}\n", .{command});
                }
            }

            stdout.flush() catch {}; // GUIs wait for uciok/readyok: never block on stdin with buffered output
        }

        tt_mod.deinit_global();
    }
};
