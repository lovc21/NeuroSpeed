const std = @import("std");
const attacks = @import("attacks.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const bitboard = @import("bitboard.zig");
const move_gen = @import("move_generation.zig");
const print = std.debug.print;
const search = @import("search.zig");
const lists = @import("lists.zig");
const eval = @import("evaluation.zig");

const UCI_COMMANDS_MAX: usize = 10000;
const VERSION: []const u8 = "0.1";
const ENGINE_NAME: []const u8 = "NeuroSpeed";
const AUTHOR: []const u8 = "Jakob Dekleva";

pub const UCI = struct {
    board: types.Board,
    allocator: std.mem.Allocator,
    is_searching: bool,
    stop_search: bool,
    search_thread: ?std.Thread,

    // new uci
    pub fn new(allocator: std.mem.Allocator) UCI {
        attacks.init_attacks();
        search.init_search();
        var board = types.Board.new();
        bitboard.fan_pars(types.start_position, &board) catch {
            print("Error parsing fen in the new uci function\n", .{});
        };
        return UCI{
            .board = board,
            .allocator = allocator,
            .is_searching = false,
            .stop_search = false,
            .search_thread = null,
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
            move_gen.generate_moves(&self.board, &move_list, types.Color.White)
        else
            move_gen.generate_moves(&self.board, &move_list, types.Color.Black);

        // Find matching move
        for (0..move_list.count) |i| {
            const move = move_list.moves[i];
            if (move.from == from_square and move.to == to_square) {
                if (move_string.len >= 5) {
                    const promotion_piece = move_string[4];
                    const expected_flag = switch (promotion_piece) {
                        'q' => if (move_gen.Print_move_list.is_capture(move)) types.MoveFlags.PC_QUEEN else types.MoveFlags.PR_QUEEN,
                        'r' => if (move_gen.Print_move_list.is_capture(move)) types.MoveFlags.PC_ROOK else types.MoveFlags.PR_ROOK,
                        'b' => if (move_gen.Print_move_list.is_capture(move)) types.MoveFlags.PC_BISHOP else types.MoveFlags.PR_BISHOP,
                        'n' => if (move_gen.Print_move_list.is_capture(move)) types.MoveFlags.PC_KNIGHT else types.MoveFlags.PR_KNIGHT,
                        else => continue,
                    };
                    if (move.flags == expected_flag) return move;
                } else {
                    if (!move_gen.Print_move_list.is_promotion(move)) return move;
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
            try bitboard.fan_pars(types.start_position, &self.board);
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
                try bitboard.fan_pars(fen_buffer[0..fen_len], &self.board);
            }
        }

        const rest = tokens.rest();
        if (rest.len > 0) {
            var moves_tokens = std.mem.tokenizeScalar(u8, rest, ' ');
            if (moves_tokens.next()) |first_token| {
                if (std.mem.eql(u8, first_token, "moves")) {
                    // Parse and play moves
                    while (moves_tokens.next()) |move_str| {
                        if (self.parse_move(move_str)) |move| {
                            _ = move_gen.make_move(&self.board, move);
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

        // Calculate time for move
        var calculated_time: u64 = 1000;

        if (movetime) |mt| {
            calculated_time = mt;
        } else if (infinite) {
            calculated_time = 1000000; // Very long time for infinite
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
                if (movestogo) |moves| {
                    // Fixed number of moves
                    calculated_time = (time / moves) + inc;
                } else {
                    // Sudden death or increment
                    calculated_time = (time / 30) + inc; // Assume 30 moves left
                }
                calculated_time = @min(calculated_time, time - 100); // Leave 100ms buffer
                calculated_time = @max(calculated_time, 100); // Minimum 100ms
            }
        }

        // // Start search in a separate thread
        // self.search_thread = std.Thread.spawn(.{}, searchWrapper, .{ self, depth, calculated_time }) catch |err| {
        //     print("Error starting search thread: {}\n", .{err});
        //     return;
        // };
        //
        //
        searchWrapper(self, depth, calculated_time);
    }

    fn run_bench(self: *UCI, stdout: anytype) !void {
        // Benchmark positions (use diverse positions)
        const bench_positions = [_][]const u8{
            "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
            "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
            "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
            "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
            "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
        };

        var total_nodes: u64 = 0;
        const start_time = std.time.milliTimestamp();

        // Run perft depth 5 on each position
        for (bench_positions) |fen| {
            // Parse position
            try bitboard.fan_pars(fen, &self.board);

            // Run perft (you'll need to modify perft to return nodes)
            const nodes = self.count_nodes(4);
            total_nodes += nodes;
        }

        const end_time = std.time.milliTimestamp();
        const elapsed_ms = @as(u64, @intCast(end_time - start_time));
        const elapsed_s = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
        const nps: u64 = if (elapsed_s > 0) @intFromFloat(@as(f64, @floatFromInt(total_nodes)) / elapsed_s) else total_nodes;

        // CRITICAL: Output in EXACTLY this format for OpenBench
        try stdout.print("Nodes: {d}\n", .{total_nodes});
        try stdout.print("NPS: {d}\n", .{nps});
    }

    // Helper function to count nodes (wrapper around perft)
    fn count_nodes(self: *UCI, depth: u8) u64 {
        if (depth == 0) return 1;

        var move_list: lists.MoveList = .{};
        var nodes: u64 = 0;

        if (self.board.side == types.Color.White) {
            move_gen.generate_moves(&self.board, &move_list, types.Color.White);
        } else {
            move_gen.generate_moves(&self.board, &move_list, types.Color.Black);
        }

        for (0..move_list.count) |i| {
            // Save evaluator state before making move
            const saved_evaluator = eval.global_evaluator;

            var board_copy = self.board;
            _ = move_gen.make_move(&board_copy, move_list.moves[i]);

            var temp_uci = UCI{
                .board = board_copy,
                .allocator = self.allocator,
                .is_searching = false,
                .stop_search = false,
                .search_thread = null,
            };

            nodes += temp_uci.count_nodes(depth - 1);

            // Restore evaluator state after recursive call
            eval.global_evaluator = saved_evaluator;
        }

        return nodes;
    }

    fn searchWrapper(self: *UCI, depth: ?u8, time_ms: u64) void {
        if (self.board.side == types.Color.White) {
            search.search_position(&self.board, depth, time_ms, types.Color.White);
        } else {
            search.search_position(&self.board, depth, time_ms, types.Color.Black);
        }
    }
    // main loop
    pub fn uci_loop(self: *UCI) !void {
        var stdin = std.io.getStdIn().reader();
        var stdout = std.io.getStdOut().writer();

        try stdout.print("NeuroSpeed version {s}\n", .{VERSION});

        const buffer = try self.allocator.alloc(u8, UCI_COMMANDS_MAX);
        defer self.allocator.free(buffer);

        while (true) {
            if (stdin.readUntilDelimiterOrEof(buffer, '\n')) |maybe_line| {
                const line = maybe_line orelse break;
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
                    try stdout.print("uciok\n", .{});
                } else if (std.mem.eql(u8, command, "isready")) {
                    try stdout.print("readyok\n", .{});
                } else if (std.mem.eql(u8, command, "ucinewgame")) {
                    // Reset board to starting position
                    self.board = types.Board.new();
                    try bitboard.fan_pars(types.start_position, &self.board);
                    self.stop_search = true;
                    if (self.search_thread) |thread| {
                        thread.join();
                        self.search_thread = null;
                    }
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
                } else if (std.mem.eql(u8, command, "perft")) {
                    var depth: u8 = 1;
                    if (tokens.next()) |depth_str| {
                        depth = std.fmt.parseUnsigned(u8, depth_str, 10) catch 1;
                    }

                    util.perft_test_detailed(&self.board, depth);
                } else if (std.mem.eql(u8, command, "bench")) {
                    try self.run_bench(stdout);
                } else {
                    try stdout.print("Unknown command: {s}\n", .{command});
                    break;
                }
            } else |err| {
                print("Error reading input: {}\n", .{err});
                continue;
            }
        }

        // Clean up
        if (self.search_thread) |thread| {
            self.stop_search = true;
            thread.join();
        }
    }
};
