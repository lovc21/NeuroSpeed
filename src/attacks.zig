const types = @import("types.zig");
const std = @import("std");
const print = std.debug.print;
const tabele = @import("tabeles.zig");
const util = @import("util.zig");

pub inline fn rook_attack_mask_from_bitboard(bb: types.Bitboard) types.Bitboard {
    var attacks: u64 = 0;
    // convere bb int to a square index
    const square_index = @ctz(bb);

    const rank: i64 = @intCast(square_index / 8);
    const file: i64 = @intCast(square_index % 8);
    const one: types.Bitboard = 1;

    var r: i64 = rank + 1;
    while (r <= 6) {
        attacks |= one << @intCast(r * 8 + file);
        r += 1;
    }

    r = rank - 1;
    while (r >= 1) {
        attacks |= one << @intCast(r * 8 + file);
        r -= 1;
    }

    var f: i64 = file + 1;
    while (f <= 6) {
        attacks |= one << @intCast(rank * 8 + f);
        f += 1;
    }

    f = file - 1;
    while (f >= 1) {
        attacks |= one << @intCast(rank * 8 + f);
        f -= 1;
    }

    return attacks;
}

pub inline fn bishop_attack_mask_from_bitboard(bb: types.Bitboard) types.Bitboard {
    var attacks: u64 = 0;
    // convere bb int to a square index
    const square_index = @ctz(bb);

    const rank: i64 = @intCast(square_index / 8);
    const file: i64 = @intCast(square_index % 8);
    const one: types.Bitboard = 1;

    var r: i64 = rank + 1;
    var f: i64 = file + 1;
    while (r <= 6 and f <= 6) {
        attacks |= one << @intCast(r * 8 + f);
        r += 1;
        f += 1;
    }

    r = rank - 1;
    f = file + 1;
    while (r >= 1 and f <= 6) {
        attacks |= one << @intCast(r * 8 + f);
        r -= 1;
        f += 1;
    }

    r = rank + 1;
    f = file - 1;
    while (r <= 6 and f >= 1) {
        attacks |= one << @intCast(r * 8 + f);
        r += 1;
        f -= 1;
    }

    r = rank - 1;
    f = file - 1;
    while (r >= 1 and f >= 1) {
        attacks |= one << @intCast(r * 8 + f);
        r -= 1;
        f -= 1;
    }

    return attacks;
}

// generate knight attacks tabele
pub inline fn knight_attacks_from_bitboard(bb: types.Bitboard) types.Bitboard {
    return (((bb << 17) & ~@intFromEnum(types.MaskFile.AFILE)) |
        ((bb << 15) & ~@intFromEnum(types.MaskFile.HFILE)) |
        ((bb << 10) & ~(@intFromEnum(types.MaskFile.AFILE) | @intFromEnum(types.MaskFile.BFILE))) |
        ((bb << 6) & ~(@intFromEnum(types.MaskFile.HFILE) | @intFromEnum(types.MaskFile.GFILE))) |
        ((bb >> 15) & ~@intFromEnum(types.MaskFile.AFILE)) |
        ((bb >> 17) & ~@intFromEnum(types.MaskFile.HFILE)) |
        ((bb >> 6) & ~(@intFromEnum(types.MaskFile.AFILE) | @intFromEnum(types.MaskFile.BFILE))) |
        ((bb >> 10) & ~(@intFromEnum(types.MaskFile.HFILE) | @intFromEnum(types.MaskFile.GFILE))));
}

// generate king attacks tabelRook_attacks_shiftse
pub inline fn king_attacks_from_bitboard(bb: types.Bitboard) types.Bitboard {
    return (bb << 8) |
        (bb >> 8) |
        ((bb & ~@intFromEnum(types.MaskFile.HFILE)) << 1) |
        ((bb & ~@intFromEnum(types.MaskFile.AFILE)) >> 1) |
        ((bb & ~@intFromEnum(types.MaskFile.HFILE)) << 9) |
        ((bb & ~@intFromEnum(types.MaskFile.AFILE)) << 7) |
        ((bb & ~@intFromEnum(types.MaskFile.HFILE)) >> 7) |
        ((bb & ~@intFromEnum(types.MaskFile.AFILE)) >> 9);
}

// generate pawn attacks tabele
pub inline fn pawn_attacks_from_bitboard(comptime color: types.Color, bb: types.Bitboard) types.Bitboard {
    return if (color == types.Color.White)
        ((bb & ~(@intFromEnum(types.MaskFile.AFILE))) << 7) | ((bb & ~(@intFromEnum(types.MaskFile.HFILE))) << 9)
    else
        ((bb & ~(@intFromEnum(types.MaskFile.AFILE))) >> 9) | ((bb & ~(@intFromEnum(types.MaskFile.HFILE))) >> 7);
}

// generate rook magice Bitboards
var Rook_attacks: [64][4096]types.Bitboard align(64) = std.mem.zeroes([64][4096]u64);
var Rook_attacks_shifts: [64]i32 = std.mem.zeroes([64]i32);

pub inline fn init_rook_attackes() void {
    for (types.square_number) |square| {
        // const maske = tabele.Rook_attackes_tabele;
        Rook_attacks_shifts[square] = 64 - util.popcount(tabele.Rook_attackes_tabele[square]);
    }
}

//  bishop magice Bitboards
var bishop_attacks: [64][4096]types.Bitboard align(64) = std.mem.zeroes([64][4096]u64);
var bishop_attacks_shifts: [64]i32 = std.mem.zeroes([64]i32);

pub inline fn init_bishop_attackes() void {
    for (types.square_number) |square| {
        // const maske = tabele.Rook_attackes_tabele;
        Rook_attacks_shifts[square] = 64 - util.popcount(tabele.Bishops_attackes_tabele[square]);
    }
}
