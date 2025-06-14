const std = @import("std");
const print = std.debug.print;
const bitboard = @import("bitboard.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const attacks = @import("attacks.zig");
const stdout = std.io.getStdOut().writer();

pub fn main() !void {
    attacks.init_attacks();

    var b = types.Board.new();
    //try bitboard.fan_pars(types.start_position, &b);

    //const bb = b.pieces_combined();
    //print("Occupancy (hex): 0x{x}\n", .{bb});

    const mybb = b.set_pieces(types.Color.White);
    bitboard.print_board(mybb);
    bitboard.print_unicode_board(b);
    b.side = types.Color.White;

    bitboard.print_attacked_squares(&b);
}
