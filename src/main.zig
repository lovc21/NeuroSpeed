const std = @import("std");
const print = std.debug.print;
const bitboard = @import("bitboard.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const attacks = @import("attacks.zig");
const lists = @import("lists.zig");
const move_gen = @import("move_generation.zig");
const stdout = std.io.getStdOut().writer();

pub fn main() !void {
    attacks.init_attacks();

    var b = types.Board.new();
    try bitboard.fan_pars(types.tricky_position, &b);

    const bb = b.pieces_combined();
    print("Occupancy (hex): 0x{x}\n", .{bb});

    b.side = types.Color.White;
    bitboard.print_unicode_board(b);

    bitboard.print_attacked_squares(&b);
    bitboard.print_attacked_squares_new(&b);

    var movesWhite: lists.MoveList = .{};
    move_gen.generate_moves(&b, &movesWhite, types.Color.White);

    print("White moves: \n", .{});

    move_gen.Print_move_list.print_list(&movesWhite);
    move_gen.Print_move_list.print_move_list_descriptive(&b, &movesWhite, "White");
    print("Black moves: \n", .{});

    var movesBlack: lists.MoveList = .{};
    move_gen.generate_moves(&b, &movesBlack, types.Color.Black);
    move_gen.Print_move_list.print_list(&movesBlack);
    move_gen.Print_move_list.print_move_list_descriptive(&b, &movesBlack, "Black");
}
