const std = @import("std");
const util = @import("util.zig");
const print = std.debug.print;

pub fn print_board(bitboard: u64) void {
    print("\n", .{});
    for (0..8) |rank| {
        print("  {} ", .{8 - rank});
        for (0..8) |file| {
            const square = rank * 8 + file;
            const bit_on_board: u64 = if (util.get_bit(bitboard, square)) 1 else 0;
            print(" {d}", .{(bit_on_board)});
        }
        print("\n", .{});
    }

    print("\n     a b c d e f g h\n\n", .{});
    print(" Bitboard: 0x{0x}\n", .{bitboard});
    print(" Bitboard: 0b{b}\n\n", .{bitboard});
}
