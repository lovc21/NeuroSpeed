const std = @import("std");
const util = @import("util.zig");
const types = @import("types.zig");
const print = std.debug.print;

pub fn print_board(bitboard: types.Bitboard) void {
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

pub fn print_unicode_board(board: types.Board) void {
    print("\n", .{});
    for (0..8) |rank| {
        print("  {} ", .{8 - rank});
        for (0..8) |file| {
            const square = rank * 8 + file;
            var printed = false;

            for (0..types.Board.PieceCount) |i| {
                const bb = board.pieces[i];
                if (util.get_bit(bb, square)) {
                    print(" {s}", .{types.unicodePice[i]});
                    printed = true;
                    break;
                }
            }
            if (!printed) {
                print(" .", .{});
            }
        }
        print("\n", .{});
    }

    print("\n     a b c d e f g h\n\n", .{});
    print(" Bitboard: 0x{0x}\n", .{board.pieces_combined()});
    print(" Bitboard: 0b{b}\n\n", .{board.pieces_combined()});
}
