const std = @import("std");
const types = @import("types.zig");
const lists = @import("lists.zig");
const move_gen = @import("move.zig");
const attacks = @import("attacks.zig");
const Bitboard = @import("bitboard.zig");
const movegen = @import("movegen.zig");
const print = std.debug.print;

/// Set a single bit in a bitboard
pub inline fn set_bit(bitboard: u64, s: types.square) u64 {
    return (bitboard | (@as(u64, 1) << @intCast(@intFromEnum(s))));
}

/// Get a single bit in a bitboard
pub inline fn get_bit(bitboard: u64, square: usize) bool {
    return (bitboard & @as(u64, 1) << @intCast(square)) != 0;
}

/// value * percent / 100 (truncating)
pub inline fn pct(value: anytype, percent: anytype) @TypeOf(value) {
    return @divTrunc(value * @as(@TypeOf(value), @intCast(percent)), 100);
}

/// Little-endian scalar read from a byte buffer (integers, or f32 by bit pattern).
pub inline fn read_le(comptime T: type, data: []const u8, off: usize) T {
    if (T == f32) return @bitCast(std.mem.readInt(u32, data[off..][0..4], .little));
    return std.mem.readInt(T, data[off..][0..@sizeOf(T)], .little);
}

/// Mix two 64-bit words into one well-distributed hash
pub inline fn mix64(a: u64, b: u64) u64 {
    var h: u64 = a *% 0x9E3779B97F4A7C15;
    h = (h ^ b) *% 0xBF58476D1CE4E5B9;
    h ^= h >> 31;
    return h;
}

// Pseudorandom number generator https://en.wikipedia.org/wiki/Xorshift#xoroshiro
pub const PRNG = struct {
    seed: u64,

    pub fn init(seed: u64) PRNG {
        return PRNG{ .seed = seed };
    }

    pub fn rand64(self: *PRNG) u64 {
        var x = self.seed;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.seed = x;
        return x *% 0x2545F4914F6CDD1D;
    }
};

// Perft: move generator, evaluation, search
pub const Perft = struct {
    nodes: u64 = 0,
    captures: u64 = 0,
    en_passant: u64 = 0,
    castles: u64 = 0,
    promotions: u64 = 0,
    checks: u64 = 0,
    double_checks: u64 = 0,
    checkmates: u64 = 0,

    fn add(self: *Perft, other: Perft) void {
        inline for (std.meta.fields(Perft)) |f| @field(self, f.name) += @field(other, f.name);
    }

    pub fn run(comptime color: types.Color, board: *types.Board, depth: u8, comptime detailed: bool) Perft {
        if (depth == 0) return .{ .nodes = 1 };
        const them = comptime color.other();

        var list: lists.MoveList = .{};
        movegen.generate_legal_moves(board, &list, color);
        if (!detailed and depth == 1) return .{ .nodes = list.count };

        var stats: Perft = .{};
        for (list.moves[0..list.count]) |move| {
            const undo = move_gen.make_move_search(board, move, color);
            if (detailed and depth == 1) {
                stats.nodes += 1;
                if (move.is_capture()) stats.captures += 1;
                if (move.flags == types.MoveFlags.EN_PASSANT) stats.en_passant += 1;
                if (move.is_castling()) stats.castles += 1;
                if (move.is_promotion()) stats.promotions += 1;

                const king = if (them == types.Color.White) types.Piece.WHITE_KING else types.Piece.BLACK_KING;
                const king_sq: u6 = @intCast(@ctz(board.pieces[@intFromEnum(king)]));
                if (Bitboard.is_square_attacked(board, king_sq, color)) {
                    stats.checks += 1;
                    const attackers = Bitboard.get_all_attackers(board, king_sq, board.pieces_combined()) & board.set_pieces(color);
                    if (@popCount(attackers) >= 2) stats.double_checks += 1;
                    var replies: lists.MoveList = .{};
                    movegen.generate_legal_moves(board, &replies, them);
                    if (replies.count == 0) stats.checkmates += 1;
                }
            } else {
                stats.add(run(them, board, depth - 1, detailed));
            }
            move_gen.unmake_move_search(board, move, undo, color);
        }
        return stats;
    }
};
