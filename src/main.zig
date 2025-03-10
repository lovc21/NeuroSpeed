const std = @import("std");
const print = std.debug.print;
const bitboard = @import("bitboard.zig");
const types = @import("types.zig");
const util = @import("util.zig");

pub fn main() !void {
    print("Hello NeroSpeed.\n", .{});
    var bitboard_1: u64 = 0;
    bitboard_1 = util.set_bit(bitboard_1, types.square.e4);
    bitboard_1 = util.set_bit(bitboard_1, types.square.e6);
    bitboard_1 = util.set_bit(bitboard_1, types.square.e2);

    bitboard_1 = util.clear_bit(bitboard_1, types.square.e6);

    print("bit on bitbord {d}\n", .{bitboard_1});
    try bitboard.print_board(bitboard_1);
}
