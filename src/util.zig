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

// bit counting routine
/// Fastest population count, using hardware acceleration if available
pub inline fn popcount(n: u64) u7 {
    return @popCount(n);
}

// get the last bit
pub inline fn lsb_index(n: u64) u7 {
    return @ctz(n);
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
