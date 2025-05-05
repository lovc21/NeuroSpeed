const types = @import("types.zig");
const std = @import("std");
const print = std.debug.print;
const tabele = @import("tabeles.zig");
const util = @import("util.zig");
const bitboard = @import("bitboard.zig");
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

pub var pawn_attacks: [2][64]u64 = undefined;
pub var pseudo_legal_attacks: [6][64]u64 = undefined;

pub fn initialise_pseudo_legal() void {
    // copy pawn-attack tables directly
    pawn_attacks[0] = tabele.White_pawn_attacks_tabele;
    pawn_attacks[1] = tabele.Black_pawn_attacks_tabele;

    // copy fixed knight & king tables
    const knight_i = @intFromEnum(types.PieceType.Knight);
    const king_i = @intFromEnum(types.PieceType.King);
    pseudo_legal_attacks[knight_i] = tabele.Knight_attackes_tabele;
    pseudo_legal_attacks[king_i] = tabele.King_attackes_tabele;

    // build rook, bishop, queen on empty board
    const rook_i = @intFromEnum(types.PieceType.Rook);
    const bishop_i = @intFromEnum(types.PieceType.Bishop);
    const queen_i = @intFromEnum(types.PieceType.Queen);

    // single pass over all 64 squares
    for (types.square_number) |s| {
        const sq: u8 = @intCast(s);
        const occ = 0; // empty occupancy

        // sliding attacks
        const r_att = get_rook_attacks_for_init(sq, occ);
        const b_att = get_bishop_attacks_for_init(sq, occ);

        pseudo_legal_attacks[rook_i][s] = r_att;
        pseudo_legal_attacks[bishop_i][s] = b_att;
        pseudo_legal_attacks[queen_i][s] = r_att | b_att;
    }
}

/// Returns the pawn-attack mask for square `s` (0..63) and color `c`
pub inline fn pawn_attacks_from_square(s: usize, c: types.Color) u64 {
    return pawn_attacks[@intFromEnum(c)][s];
}

// generate attacks for slidng pieces (bishop,rook)
pub fn rook_attack_mask_from_bitboard(bb: types.Bitboard) types.Bitboard {
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

pub fn bishop_attack_mask_from_bitboard(bb: types.Bitboard) types.Bitboard {
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
// Mostly copied and improved from https://github.com/SnowballSH/Avalanche/blob/c44569afbee44716e18a9698430c1016438d3874/src/chess/tables.zig#L80C1-L231C77
inline fn reverse64(b: u64) u64 {
    var x: u64 = b;
    x = ((x & 0x5555555555555555) << 1) | ((x >> 1) & 0x5555555555555555);
    x = ((x & 0x3333333333333333) << 2) | ((x >> 2) & 0x3333333333333333);
    x = ((x & 0x0f0f0f0f0f0f0f0f) << 4) | ((x >> 4) & 0x0f0f0f0f0f0f0f0f);
    x = ((x & 0x00ff00ff00ff00ff) << 8) | ((x >> 8) & 0x00ff00ff00ff00ff);
    return (x << 48) | ((x & 0xffff0000) << 16) | (((x >> 16) & 0xffff0000)) | (x >> 48);
}

// Hyperbola Quintessence Algorithm
pub inline fn sliding_attacks(sq_idx: u8, occ: u64, mask: u64) u64 {
    const occ_masked = occ & mask;
    const bb = types.squar_bb[sq_idx];
    const rev_bb = reverse64(bb);

    const forward = occ_masked -% (bb << 1);
    const rev_occ = reverse64(occ_masked);
    const backward = rev_occ -% (rev_bb << 1);

    return ((forward ^ reverse64(backward)) & mask);
}

pub inline fn get_rook_attacks_for_init(square: u8, occ: u64) u64 {
    const rankMask: u64 = types.mask_rank[square / 8];
    const fileMask: u64 = types.mask_file[square % 8];
    const horizontalAttacks = sliding_attacks(square, occ, rankMask);
    const verticalAttacks = sliding_attacks(square, occ, fileMask);
    return horizontalAttacks | verticalAttacks;
}

// generate rook magice Bitboards
pub var Rook_attacks: [64][4096]types.Bitboard align(64) = std.mem.zeroes([64][4096]u64);

pub inline fn init_rook_attackes() void {
    for (types.square_number) |square| {
        const mask = tabele.Rook_attackes_tabele[square];
        const relevantBits = tabele.Rook_index_bit[square];
        const magic = tabele.rook_magics[square];

        const shift: u6 = @truncate(64 - relevantBits);
        const sq6 = @as(u8, @intCast(square));
        var subset: types.Bitboard = mask;

        while (true) {
            var idx64: u64 = @as(u64, subset) *% magic;
            idx64 = idx64 >> shift;
            const idx: usize = @intCast(idx64);
            Rook_attacks[square][idx] = get_rook_attacks_for_init(sq6, subset);
            if (subset == 0) break;
            subset = (subset - 1) & mask;
        }
    }
}

pub inline fn get_rook_attacks(square: u6, occ: u64) u64 {
    const mask: u64 = tabele.Rook_attackes_tabele[square];
    const magic: u64 = tabele.rook_magics[square];
    const shift: u6 = @intCast(64 - tabele.Rook_index_bit[square]);
    const relevant: u64 = occ & mask;
    const idx: usize = @intCast((relevant *% magic) >> shift);
    return Rook_attacks[square][idx];
}

pub inline fn get_bishop_attacks_for_init(square: u8, occ: u64) u64 {
    const rank_i8: i8 = @intCast(square / 8);
    const file_i8: i8 = @intCast(square % 8);
    const diag_i: i8 = rank_i8 - file_i8 + 7;
    const anti_i: i8 = rank_i8 + file_i8;
    const diag_idx: usize = @intCast(diag_i);
    const anti_idx: usize = @intCast(anti_i);
    const mask1: u64 = types.mask_diagonal_nw_se[diag_idx];
    const mask2: u64 = types.mask_anti_diagonal_ne_sw[anti_idx];
    const att1 = sliding_attacks(square, occ, mask1);
    const att2 = sliding_attacks(square, occ, mask2);
    return att1 | att2;
}

//  bishop magice Bitboards
pub var Bishop_attacks: [64][512]types.Bitboard align(64) = std.mem.zeroes([64][512]u64);

pub inline fn init_bishop_attackes() void {
    for (types.square_number) |square| {
        const mask = tabele.Bishops_attackes_tabele[square];
        const relevantBits = tabele.Bishop_index_bit[square];
        const magic = tabele.bishop_magics[square];

        const shift: u6 = @truncate(64 - relevantBits);
        const sq6 = @as(u8, @intCast(square));
        var subset: types.Bitboard = mask;

        while (true) {
            var idx64: u64 = @as(u64, subset) *% magic;
            idx64 = idx64 >> shift;
            const idx: usize = @intCast(idx64);
            Bishop_attacks[square][idx] = get_bishop_attacks_for_init(sq6, subset);
            if (subset == 0) break;
            subset = (subset - 1) & mask;
        }
    }
}

pub inline fn get_bishop_attacks(square: u6, occ: u64) u64 {
    const mask: u64 = tabele.Bishops_attackes_tabele[square];
    const magic: u64 = tabele.bishop_magics[square];
    const shift: u6 = @intCast(64 - tabele.Bishop_index_bit[square]);
    const relevant: u64 = occ & mask;
    const raw_idx: u64 = (relevant *% magic) >> shift;
    const idx: usize = @intCast(raw_idx);
    const idx: usize = @intCast((relevant *% magic) >> shift);
    return Bishop_attacks[square][idx];
}

pub inline fn get_queen_attacks(square: u6, occ: u64) u64 {
    const queen_attacks: u64 = get_bishop_attacks(square, occ) | get_rook_attacks(square, occ);
    return queen_attacks;
}

pub fn piece_attacks(square: u6, occ: u64, comptime Piece: types.PieceType) void {
    if (Piece != types.PieceType.Pawn) {
        return switch (Piece) {
            types.PieceType.Bishop => get_bishop_attacks(square, occ),
            types.PieceType.Rook => get_rook_attacks(square, occ),
            types.PieceType.Queen => get_queen_attacks(square, occ),
            else => print("pseudo legal attacks", .{}),
        };
    } else {
        @panic("don't pass pawns");
    }
}

pub fn init_attacks() void {
    init_bishop_attackes();
    init_rook_attackes();
    initialise_pseudo_legal();
}
