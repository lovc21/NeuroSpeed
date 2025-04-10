const types = @import("types.zig");

pub inline fn set_bit(bitboard: u64, s: types.square) u64 {
    return (bitboard | (@as(u64, 1) << @intCast(@intFromEnum(s))));
}

pub inline fn get_bit(bitboard: u64, square: usize) bool {
    return (bitboard & @as(u64, 1) << @intCast(square)) != 0;
}

pub inline fn clear_bit(bitboard: u64, s: types.square) u64 {
    return (bitboard & ~(@as(u64, 1) << @intCast(@intFromEnum(s))));
}

// Pseudorandom number generator
pub const PRNG = struct {};
