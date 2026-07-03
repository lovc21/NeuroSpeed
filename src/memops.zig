//! Fast memset override. Zig 0.16's LLVM disables the loop auto-vectorizer
//! (miscompilation workaround), so compiler_rt's generic memset compiles down
//! to a scalar 8-byte loop — measured at ~6% of search runtime (per-node
//! move-list inits, TT clears). This strong export shadows compiler_rt's weak
//! `memset` with an explicit-@Vector implementation.
const std = @import("std");

const V = 64; // bytes per vector store; lowers to 2x32B on AVX2, 4x16B on SSE2

export fn memset(dest_opt: ?[*]u8, c: c_int, len: usize) callconv(.c) ?[*]u8 {
    const dest = dest_opt orelse return dest_opt;
    const b: u8 = @truncate(@as(u32, @bitCast(c)));
    if (len >= V) {
        const vb: @Vector(V, u8) = @splat(b);
        var i: usize = 0;
        while (i + V <= len) : (i += V) dest[i..][0..V].* = vb;
        if (i < len) dest[len - V ..][0..V].* = vb; // overlapping tail store
        return dest_opt;
    }
    if (len >= 8) {
        const w: u64 = @as(u64, 0x0101010101010101) *% @as(u64, b);
        var i: usize = 0;
        while (i + 8 <= len) : (i += 8) std.mem.writeInt(u64, dest[i..][0..8], w, .little);
        if (i < len) std.mem.writeInt(u64, dest[len - 8 ..][0..8], w, .little);
        return dest_opt;
    }
    var i: usize = 0;
    while (i < len) : (i += 1) dest[i] = b;
    return dest_opt;
}
