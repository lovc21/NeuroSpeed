const std = @import("std");
const print = std.debug.print;
const bitboard = @import("bitboard.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const attacks = @import("attacks.zig");
const lists = @import("lists.zig");
const move_gen = @import("move_generation.zig");
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
        if (move_gen.Print_move_list.is_promotion(move) and move_gen.Print_move_list.is_capture(move)) {
            move_type = "Promo+Capture";
        } else if (move_gen.Print_move_list.is_capture(move)) {
            move_type = "Capture";
        } else if (move_gen.Print_move_list.is_promotion(move)) {
            move_type = "Promotion";
        } else if (move_gen.Print_move_list.is_castling(move)) {
            move_type = "Castling";
        } else if (move_gen.Print_move_list.is_en_passant(move)) {
            move_type = "En Passant";
        } else if (move_gen.Print_move_list.is_double_push(move)) {
            move_type = "Double Push";
        }

        var promotion_char: u8 = ' ';
        if (move_gen.Print_move_list.is_promotion(move)) {
            promotion_char = move_gen.Print_move_list.get_promotion_char(move);
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

    if (debug == true) {
        attacks.init_attacks();

        var board = types.Board.new();
        bitboard.fan_pars(types.tricky_position, &board) catch {
            print("Error parsing fen in the new uci function\n", .{});
        };

        var move_list: lists.MoveList = .{};
        var score_list: lists.ScoreList = .{};
        move_gen.generate_moves(&board, &move_list, types.Color.White);
        move_scores.score_move(&board, &move_list, &score_list);

        bitboard.print_unicode_board(board);
        print_moves_and_scores(&move_list, &score_list);
    } else {
        var game = uci.UCI.new(allocator);
        try game.uci_loop();
    }
}
