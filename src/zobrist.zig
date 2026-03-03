const std = @import("std");
const types = @import("types.zig");

fn generate_keys() struct {
    piece_keys: [12][64]u64,
    side_key: u64,
    castle_keys: [4]u64,
    ep_keys: [8]u64,
} {
    @setEvalBranchQuota(1 << 30);
    // Fixed seed for deterministic comptime generation
    var prng = std.Random.DefaultCsprng.init(.{
        0x53, 0x08, 0x7C, 0x3E, 0xD1, 0xE4, 0x66, 0x5A,
        0x8B, 0x5E, 0xF7, 0xEA, 0x17, 0xED, 0xE3, 0x53,
        0xB9, 0xBB, 0xF9, 0xAA, 0xBB, 0xA8, 0x83, 0x74,
        0x28, 0xA0, 0x79, 0xEF, 0x58, 0x36, 0xB9, 0x53,
    });
    const rng = prng.random();

    var pk: [12][64]u64 = undefined;
    for (0..12) |piece| {
        for (0..64) |sq| {
            pk[piece][sq] = rng.int(u64);
        }
    }

    const sk = rng.int(u64);

    var ck: [4]u64 = undefined;
    for (0..4) |i| {
        ck[i] = rng.int(u64);
    }

    var ek: [8]u64 = undefined;
    for (0..8) |i| {
        ek[i] = rng.int(u64);
    }

    return .{
        .piece_keys = pk,
        .side_key = sk,
        .castle_keys = ck,
        .ep_keys = ek,
    };
}

const keys = generate_keys();

pub const piece_keys: [12][64]u64 = keys.piece_keys;
pub const side_key: u64 = keys.side_key;
pub const castle_keys: [4]u64 = keys.castle_keys;
pub const ep_keys: [8]u64 = keys.ep_keys;

pub inline fn piece_index(piece: types.Piece) usize {
    const raw = @intFromEnum(piece);
    return if (raw < 6) raw else raw - 2;
}

pub fn compute_hash(board: *const types.Board) u64 {
    var hash: u64 = 0;

    const piece_list = [_]types.Piece{
        .WHITE_PAWN, .WHITE_KNIGHT, .WHITE_BISHOP, .WHITE_ROOK, .WHITE_QUEEN, .WHITE_KING,
        .BLACK_PAWN, .BLACK_KNIGHT, .BLACK_BISHOP, .BLACK_ROOK, .BLACK_QUEEN, .BLACK_KING,
    };

    for (piece_list) |piece| {
        var bb = board.pieces[@intFromEnum(piece)];
        while (bb != 0) {
            const sq: u6 = @intCast(@ctz(bb));
            hash ^= piece_keys[piece_index(piece)][sq];
            bb &= bb - 1;
        }
    }

    if (board.side == types.Color.Black) {
        hash ^= side_key;
    }

    if (board.castle & @intFromEnum(types.Castle.WK) != 0) hash ^= castle_keys[0];
    if (board.castle & @intFromEnum(types.Castle.WQ) != 0) hash ^= castle_keys[1];
    if (board.castle & @intFromEnum(types.Castle.BK) != 0) hash ^= castle_keys[2];
    if (board.castle & @intFromEnum(types.Castle.BQ) != 0) hash ^= castle_keys[3];

    if (board.enpassant != types.square.NO_SQUARE) {
        const file = @intFromEnum(board.enpassant) % 8;
        hash ^= ep_keys[file];
    }

    return hash;
}
