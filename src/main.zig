const std = @import("std");
const print = std.debug.print;
const bitboard = @import("bitboard.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const attacks = @import("attacks.zig");
const lists = @import("lists.zig");
const move_gen = @import("move_generation.zig");
const uci = @import("uci.zig");
const eval = @import("evaluation.zig");
const search = @import("search.zig");
const debug = false;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    if (debug == true) {
        attacks.init_attacks();

        var board = types.Board.new();
        bitboard.fan_pars(types.start_position, &board) catch {
            print("Error parsing fen in the new uci function\n", .{});
        };

        search.search_position(&board, null, types.Color.White);
    } else {
        var game = uci.UCI.new(allocator);
        try game.uci_loop();
    }
}
