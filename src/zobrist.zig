const types = @import("types.zig");
const util = @import("util.zig");

pub const side_key: u64 = all_keys[768];
const castle_keys: [4]u64 = all_keys[769..773].*;
pub const ep_keys: [8]u64 = all_keys[773..781].*;

pub const piece_keys: [types.Board.PieceCount][64]u64 = blk: {
    var t: [types.Board.PieceCount][64]u64 = @splat(@splat(0));
    for (0..12) |k| {
        const slot = if (k < 6) k else k + 2;
        t[slot] = all_keys[k * 64 ..][0..64].*;
    }
    break :blk t;
};

pub const castle_hash: [16]u64 = blk: {
    var t: [16]u64 = undefined;
    for (0..16) |mask| {
        var h: u64 = 0;
        for (0..4) |i| {
            if (mask >> i & 1 != 0) h ^= castle_keys[i];
        }
        t[mask] = h;
    }
    break :blk t;
};

const all_keys: [12 * 64 + 1 + 4 + 8]u64 = blk: {
    @setEvalBranchQuota(20_000);
    var prng = util.PRNG.init(0x53087C3ED1E4665A);
    var all: [12 * 64 + 1 + 4 + 8]u64 = undefined;
    for (&all) |*k| k.* = prng.rand64();
    break :blk all;
};

pub fn compute_hash(board: *const types.Board) u64 {
    var hash: u64 = 0;

    inline for (0..12) |k| {
        const slot = if (k < 6) k else k + 2; // real piece ordinals only
        var bb = board.pieces[slot];
        while (bb != 0) : (bb &= bb - 1) {
            hash ^= piece_keys[slot][@intCast(@ctz(bb))];
        }
    }

    if (board.side == types.Color.Black) {
        hash ^= side_key;
    }

    hash ^= castle_hash[board.castle];

    if (board.enpassant != types.square.NO_SQUARE) {
        const file = types.file_of(@intFromEnum(board.enpassant));
        hash ^= ep_keys[file];
    }

    return hash;
}
