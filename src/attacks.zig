const print = std.debug.print;
const types = @import("types.zig");
const std = @import("std");
const tables = @import("tables.zig");
const util = @import("util.zig");
const bitboard = @import("bitboard.zig");

// Knight attack generation from bitboard
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

// King attack generation from bitboard
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

// Pawn attack generation from bitboard
pub inline fn pawn_attacks_from_bitboard(comptime color: types.Color, bb: types.Bitboard) types.Bitboard {
    return if (color == types.Color.White)
        ((bb & ~(@intFromEnum(types.MaskFile.AFILE))) << 7) | ((bb & ~(@intFromEnum(types.MaskFile.HFILE))) << 9)
    else
        ((bb & ~(@intFromEnum(types.MaskFile.AFILE))) >> 9) | ((bb & ~(@intFromEnum(types.MaskFile.HFILE))) >> 7);
}

pub var pawn_attacks: [2][64]u64 = undefined;
pub var pseudo_legal_attacks: [6][64]u64 = undefined;

pub fn init_pseudo_legal() void {
    pawn_attacks[0] = tables.white_pawn_attacks;
    pawn_attacks[1] = tables.black_pawn_attacks;

    const knight_i = @intFromEnum(types.PieceType.Knight);
    const king_i = @intFromEnum(types.PieceType.King);
    pseudo_legal_attacks[knight_i] = tables.knight_attacks;
    pseudo_legal_attacks[king_i] = tables.king_attacks;

    const rook_i = @intFromEnum(types.PieceType.Rook);
    const bishop_i = @intFromEnum(types.PieceType.Bishop);
    const queen_i = @intFromEnum(types.PieceType.Queen);

    for (0..64) |s| {
        const sq: u8 = @intCast(s);
        const occ = 0;

        // sliding attacks
        const r_att = get_rook_attacks_for_init(sq, occ);
        const b_att = get_bishop_attacks_for_init(sq, occ);

        pseudo_legal_attacks[rook_i][s] = r_att;
        pseudo_legal_attacks[bishop_i][s] = b_att;
        pseudo_legal_attacks[queen_i][s] = r_att | b_att;
    }
}

// use this for pawn attacks
pub inline fn pawn_attacks_from_square(s: usize, c: types.Color) u64 {
    return pawn_attacks[@intFromEnum(c)][s];
}

// Rook attack mask generation (excludes edges)
pub fn rook_attack_mask_from_bitboard(bb: types.Bitboard) types.Bitboard {
    var attacks: u64 = 0;
    // convert bitboard to square index
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
    // convert bitboard to square index
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
    const bb = types.square_bb[sq_idx];
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

// Rook magic bitboard attack table
pub var rook_attacks_table: [64][4096]types.Bitboard align(64) = std.mem.zeroes([64][4096]u64);

pub inline fn init_rook_attacks() void {
    for (0..64) |square| {
        const mask = tables.rook_attack_masks[square];
        const relevantBits = tables.rook_index_bits[square];
        const magic = tables.rook_magics[square];

        const shift: u6 = @truncate(64 - relevantBits);
        const sq6 = @as(u8, @intCast(square));
        var subset: types.Bitboard = mask;

        while (true) {
            var idx64: u64 = @as(u64, subset) *% magic;
            idx64 = idx64 >> shift;
            const idx: usize = @intCast(idx64);
            rook_attacks_table[square][idx] = get_rook_attacks_for_init(
                sq6,
                subset,
            );
            if (subset == 0) break;
            subset = (subset - 1) & mask;
        }
    }
}

pub inline fn get_rook_attacks(square: u6, occ: u64) u64 {
    const mask: u64 = tables.rook_attack_masks[square];
    const magic: u64 = tables.rook_magics[square];
    const shift: u6 = @intCast(64 - tables.rook_index_bits[square]);
    const relevant: u64 = occ & mask;
    const idx: usize = @intCast((relevant *% magic) >> shift);

    return rook_attacks_table[square][idx];
}

// Correct on-the-fly attack generation for bishops using simple ray-casting.
// This is a one-time cost at initialization.
pub fn get_bishop_attacks_for_init(square: u8, blockers: u64) u64 {
    var attacks: u64 = 0;
    const r: i8 = @intCast(square / 8);
    const f: i8 = @intCast(square % 8);
    const one: u64 = 1;

    // North-East
    var cr = r + 1;
    var cf = f + 1;
    while (cr <= 7 and cf <= 7) : ({
        cr += 1;
        cf += 1;
    }) {
        const s = cr * 8 + cf;
        attacks |= (one << @intCast(s));
        if ((blockers & (one << @intCast(s))) != 0) break;
    }
    // South-West
    cr = r - 1;
    cf = f - 1;
    while (cr >= 0 and cf >= 0) : ({
        cr -= 1;
        cf -= 1;
    }) {
        const s = cr * 8 + cf;
        attacks |= (one << @intCast(s));
        if ((blockers & (one << @intCast(s))) != 0) break;
    }
    // North-West
    cr = r + 1;
    cf = f - 1;
    while (cr <= 7 and cf >= 0) : ({
        cr += 1;
        cf -= 1;
    }) {
        const s = cr * 8 + cf;
        attacks |= (one << @intCast(s));
        if ((blockers & (one << @intCast(s))) != 0) break;
    }
    // South-East
    cr = r - 1;
    cf = f + 1;
    while (cr >= 0 and cf <= 7) : ({
        cr -= 1;
        cf += 1;
    }) {
        const s = cr * 8 + cf;
        attacks |= (one << @intCast(s));
        if ((blockers & (one << @intCast(s))) != 0) break;
    }

    return attacks;
}

// Bishop magic bitboard attack table
pub var bishop_attacks_table: [64][512]types.Bitboard align(64) = std.mem.zeroes([64][512]u64);

pub inline fn init_bishop_attacks() void {
    for (0..64) |square| {
        const mask = tables.bishop_attack_masks[square];
        const relevantBits = tables.bishop_index_bits[square];
        const magic = tables.bishop_magics[square];
        const shift: u6 = @truncate(64 - relevantBits);
        const sq6 = @as(u8, @intCast(square));

        // Clear the table for this square first
        const table_size = @as(usize, 1) << @intCast(relevantBits);
        @memset(bishop_attacks_table[square][0..table_size], 0);

        var subset: types.Bitboard = mask;
        while (true) {
            var idx64: u64 = @as(u64, subset) *% magic;
            idx64 = idx64 >> shift;
            const idx: usize = @intCast(idx64);

            const correct_attacks = get_bishop_attacks_for_init(
                sq6,
                subset,
            );

            // Check for collision
            if (bishop_attacks_table[square][idx] != 0 and
                bishop_attacks_table[square][idx] != correct_attacks)
            {
                std.debug.panic(
                    "Magic collision detected for bishop square {} at index {}: existing=0x{x}, new=0x{x}\n",
                    .{
                        square,
                        idx,
                        bishop_attacks_table[square][idx],
                        correct_attacks,
                    },
                );
            }

            bishop_attacks_table[square][idx] = correct_attacks;

            if (subset == 0) break;
            subset = (subset - 1) & mask;
        }
    }
}

pub inline fn get_bishop_attacks(square: u6, occ: u64) u64 {
    const mask: u64 = tables.bishop_attack_masks[square];
    const magic: u64 = tables.bishop_magics[square];
    const shift: u6 = @intCast(64 - tables.bishop_index_bits[square]);
    const relevant: u64 = occ & mask;
    const idx: usize = @intCast((relevant *% magic) >> shift);
    return bishop_attacks_table[square][idx];
}

pub inline fn get_queen_attacks(square: u6, occ: u64) u64 {
    const queen_attacks: u64 = get_bishop_attacks(square, occ) |
        get_rook_attacks(square, occ);
    return queen_attacks;
}

// use this for all attacks except pawns
pub fn piece_attacks(
    square: u6,
    occ: u64,
    comptime Piece: types.PieceType,
) types.Bitboard {
    if (Piece != types.PieceType.Pawn) {
        return switch (Piece) {
            types.PieceType.Bishop => get_bishop_attacks(square, occ),
            types.PieceType.Rook => get_rook_attacks(square, occ),
            types.PieceType.Queen => get_queen_attacks(square, occ),
            else => (&pseudo_legal_attacks)[Piece.toU3()][square],
        };
    } else {
        @panic("don't pass pawns");
    }
}

const movegen = @import("movegen.zig");

pub fn init_attacks() void {
    init_bishop_attacks();
    init_rook_attacks();
    init_pseudo_legal();
    movegen.init();
}
