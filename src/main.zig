const std = @import("std");
const print = std.debug.print;
const bitboard = @import("bitboard.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const attacks = @import("attacks.zig");
const lists = @import("lists.zig");
const move_gen = @import("move.zig");
const movegen = @import("movegen.zig");
const move_scores = @import("score_moves.zig");
const uci = @import("uci.zig");
const eval = @import("evaluation.zig");
const search = @import("search.zig");
const debug = false;

fn print_moves_and_scores(move_list: *const lists.MoveList, score_list: *const lists.ScoreList) void {
    print("\n=== Generated Moves and Scores ===\n", .{});
    print("Total moves: {}\n\n", .{move_list.count});

    if (move_list.count != score_list.count) {
        print("WARNING: Move count ({}) doesn't match score count ({})\n", .{ move_list.count, score_list.count });
        return;
    }

    print("Total moves: {}\n\n", .{move_list.count});
    print("Total scores: {}\n\n", .{score_list.count});

    // Group moves by score for better readability

    var scores: [255]i32 = undefined;
    var indices: [255]usize = undefined;

    // Copy scores and create index array
    for (0..move_list.count) |i| {
        scores[i] = score_list.scores[i];
        indices[i] = i;
    }

    print("Rank | Score     | Move      | Type\n", .{});
    print("-----|-----------|-----------|------------------\n", .{});

    for (0..@min(move_list.count, 50)) |rank| {
        const idx = indices[rank];
        const move = move_list.moves[idx];
        const score = score_list.scores[idx];

        const from_sq = types.SquareString.getSquareToString(@enumFromInt(move.from));
        const to_sq = types.SquareString.getSquareToString(@enumFromInt(move.to));

        var move_type: []const u8 = "Quiet";
        if (move.is_promotion() and move.is_capture()) {
            move_type = "Promo+Capture";
        } else if (move.is_capture()) {
            move_type = "Capture";
        } else if (move.is_promotion()) {
            move_type = "Promotion";
        } else if (move.is_castling()) {
            move_type = "Castling";
        } else if (move.is_en_passant()) {
            move_type = "En Passant";
        } else if (move.is_double_push()) {
            move_type = "Double Push";
        }

        var promotion_char: u8 = ' ';
        if (move.is_promotion()) {
            promotion_char = move.promotion_char();
        }

        if (promotion_char != ' ') {
            print("{:>4} | {:>9} | {s}{s}{c} | {s}\n", .{ rank + 1, score, from_sq, to_sq, promotion_char, move_type });
        } else {
            print("{:>4} | {:>9} | {s}{s}  | {s}\n", .{ rank + 1, score, from_sq, to_sq, move_type });
        }
    }

    print("\n", .{});
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var do_bench = false;
    var bench_depth: u8 = 5;
    var args = std.process.args();
    _ = args.next();
    while (args.next()) |arg| {
        if (std.ascii.eqlIgnoreCase(arg, "bench")) {
            do_bench = true;
        }
        if (std.fmt.parseUnsigned(u8, arg, 10)) |depth| {
            bench_depth = depth;
        } else |_| {}
    }

    if (do_bench) {
        run_bench(bench_depth);
        return;
    }

    if (debug == true) {
        attacks.init_attacks();

        var board = types.Board.new();
        bitboard.parse_fen(types.tricky_position, &board) catch {
            print("Error parsing fen in the new uci function\n", .{});
        };

        var move_list: lists.MoveList = .{};
        var score_list: lists.ScoreList = .{};
        movegen.generate_legal_moves(&board, &move_list, types.Color.White);
        move_scores.score_move(&board, &move_list, &score_list, move_gen.Move.empty(), move_gen.Move.empty());

        bitboard.print_unicode_board(board);
        print_moves_and_scores(&move_list, &score_list);
    } else {
        var game = uci.UCI.new(allocator);
        try game.uci_loop();
    }
}

fn run_bench(depth: u8) void {
    const stdout = std.io.getStdOut().writer();

    attacks.init_attacks();
    search.init_search();

    const bench_positions = [_][]const u8{
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

    var total_nodes: u64 = 0;
    var timer = std.time.Timer.start() catch {
        print("Fatal: timer failed to start\n", .{});
        return;
    };

    for (bench_positions) |fen| {
        var board = types.Board.new();
        bitboard.parse_fen(fen, &board) catch continue;

        search.init_search();

        if (board.side == types.Color.White) {
            search.search_position(&board, depth, 0, 0, types.Color.White);
        } else {
            search.search_position(&board, depth, 0, 0, types.Color.Black);
        }

        total_nodes += search.global_search.nodes;
    }

    const elapsed_ns = @max(1, timer.read());
    const nps = @as(u128, total_nodes) * std.time.ns_per_s / elapsed_ns;

    stdout.print("{d} nodes {d} nps\n", .{ total_nodes, nps }) catch {};
}
