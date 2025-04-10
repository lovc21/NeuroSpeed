const types = @import("types.zig");
const std = @import("std");
const print = std.debug.print;

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

    // upper right diagonal: increasing rank and file until just before the board edge
    var r: i64 = rank + 1;
    var f: i64 = file + 1;
    while (r <= 6 and f <= 6) {
        attacks |= one << @intCast(r * 8 + f);
        r += 1;
        f += 1;
    }

    // lower right diagonal: decreasing rank, increasing file
    r = rank - 1;
    f = file + 1;
    while (r >= 1 and f <= 6) {
        attacks |= one << @intCast(r * 8 + f);
        r -= 1;
        f += 1;
    }

    // upper left diagonal: increasing rank, decreasing file
    r = rank + 1;
    f = file - 1;
    while (r <= 6 and f >= 1) {
        attacks |= one << @intCast(r * 8 + f);
        r += 1;
        f -= 1;
    }

    // lower left diagonal: decreasing rank and file
    r = rank - 1;
    f = file - 1;
    while (r >= 1 and f >= 1) {
        attacks |= one << @intCast(r * 8 + f);
        r -= 1;
        f -= 1;
    }

    return attacks;
}

// generate king attacks tabele
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

// generate king attacks tabele
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
