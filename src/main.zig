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
    try bitboard.fan_pars(types.tricky_position, &b);

    const bb = b.pieces_combined();
    print("Occupancy (hex): 0x{x}\n", .{bb});

    b.side = types.Color.Black;

    bitboard.print_unicode_board(b);
    //bitboard.print_attacked_squares(&b);
    b.side = types.Color.White;

    bitboard.print_attacked_squares(&b);
}
