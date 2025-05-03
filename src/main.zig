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

    var occ: types.Bitboard = 0;

    // ── test #1: completely empty board ────────────────────────────────────────
    occ = 0;
    print("\nOCC = 0x{x} (empty)\n", .{occ});
    const bishopEmpty = attacks.getBishopAttacks(types.square.toU6(types.square.d4), occ);
    //const rookEmpty = attacks.getRookAttacks(types.square.d4, occ);
    print(" bishop(d4) → 0x{x}\n", .{bishopEmpty});
    //print("  rook(d4) → 0x{x}\n", .{rookEmpty});

    // ── test #2: bishop blocked by pieces on b4 and f6 ───────────────────────
    occ = ((1 << @intFromEnum(types.square.e7)) |
        (1 << @intFromEnum(types.square.f6)));
    print("\nOCC = 0x{x} (blockers on b4,f6)\n", .{occ});
    bitboard.print_board(occ);
    const bishopBlocked = attacks.getBishopAttacks(types.square.toU6(types.square.b4), occ);
    print(" bishop(d4) → 0x{x}\n", .{bishopBlocked});
    bitboard.print_board(bishopBlocked);

    // ── test #3: rook   blocked by pieces on b4 and d6 ───────────────────────
    occ = ((1 << @intFromEnum(types.square.b4)) |
        (1 << @intFromEnum(types.square.d6)));
    print("\nOCC = 0x{x} (blockers on b4,d6)\n", .{occ});
    bitboard.print_board(occ);
    const rookBlocked = attacks.getRookAttacks(types.square.toU6(types.square.d4), occ);
    print("  rook(d4) → 0x{x}\n", .{rookBlocked});
    bitboard.print_board(rookBlocked);
}
