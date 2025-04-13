const std = @import("std");
const print = std.debug.print;
const bitboard = @import("bitboard.zig");
const types = @import("types.zig");
const util = @import("util.zig");
const attacks = @import("attacks.zig");
const stdout = std.io.getStdOut().writer();

pub fn main() !void {
    for (0..types.number_of_squares) |i| {
        const sq: types.square = @enumFromInt(i);
        var bb: types.Bitboard = 0;
        bb = util.set_bit(bb, sq);
        print("hello", .{});
        const maskbishop = attacks.rook_attack_mask_from_bitboard(bb);
        bitboard.print_board(maskbishop);
        try stdout.print("Square {d}: 0x{x}\n", .{ i, maskbishop });
    }

    const bb: types.Bitboard = 21; // Example bitboard
    const result = types.popcount(bb);
    bitboard.print_board(bb);
    print("Population count: {d}\n", .{result});

    var prng = util.PRNG.init(0x123456789ABCDEF);
    const randomBitboard: u64 = prng.rand64();
    std.debug.print("Random bitboard: {d}\n", .{randomBitboard});
}
