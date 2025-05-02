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
    try bitboard.fan_pars("r3k2r/8/8/8/3pPp2/8/8/R3K1RR b KQkq e3 0 1 ", &b);

    const bb = b.pieces_combined();
    print("Occupancy (hex): 0x{x}\n", .{bb});

    bitboard.print_unicode_board(b);
}
