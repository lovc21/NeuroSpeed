const std = @import("std");
const types = @import("types.zig");
const util = @import("util.zig");

const Board = types.Board;
const Color = types.Color;

/// Use NNUE instead of HCE; set once a net is loaded.
pub var use_nnue = false;

// Architecture, must match the trained net.
pub const HIDDEN: usize = 640;
const FT: usize = 768; // features per input bucket (Chess768)

// King input buckets with horizontal mirroring; 1 = mirror only (more buckets tested worse).
const NUM_INPUT_BUCKETS: usize = 1;
const INPUT: usize = FT * NUM_INPUT_BUCKETS;

const buckets_32: [32]usize = .{0} ** 32; // all-zero = mirror only
const buckets_expanded: [64]usize = blk: {
    const mir = [8]usize{ 0, 1, 2, 3, 3, 2, 1, 0 };
    var e: [64]usize = undefined;
    for (0..64) |idx| e[idx] = buckets_32[types.rank_of(idx) * 4 + mir[types.file_of(idx)]];
    break :blk e;
};

// Output bucket by piece count, same as bullet MaterialCount<8>.
pub const OUTPUT_BUCKETS: usize = 8;

// Quantisation, must match the training config.
const QA: i32 = 255;
const QB: i32 = 64;
const SCALE: i32 = 400;
const QA64: i64 = QA;
const QB64: i64 = QB;
const SCALE64: i64 = SCALE;

// Head per output bucket: pairwise CReLU -> L1 (i8) -> SCReLU -> L2 (f32) -> SCReLU -> L3 (f32).
const PW: usize = HIDDEN / 2;
const L1_OUT: usize = 16;
const L2_OUT: usize = 32;
// L1 inputs are (QA*QA)>>8 and weights are QB-scaled.
const L1_DEQUANT: f32 = @as(f32, @floatFromInt(QA * QA * QB)) / 256.0; // 16256.25

var feature_weights: [INPUT][HIDDEN]i16 = undefined;
var feature_bias: [HIDDEN]i16 = undefined;
// Layer weights are out-major: weights[out] is that neuron's input vector.
var l1_weights: [OUTPUT_BUCKETS * L1_OUT][2 * PW]i8 = undefined;
var l1_bias: [OUTPUT_BUCKETS * L1_OUT]f32 align(64) = undefined;
var l2_weights: [OUTPUT_BUCKETS * L2_OUT][L1_OUT]f32 = undefined;
var l2_bias: [OUTPUT_BUCKETS * L2_OUT]f32 align(64) = undefined;
var l3_weights: [OUTPUT_BUCKETS][L2_OUT]f32 align(64) = undefined;
var l3_bias: [OUTPUT_BUCKETS]f32 = undefined;
var net_loaded: bool = false;

/// Parameter bytes in a quantised.bin (the file is padded to a multiple of 64).
pub const NET_BYTES: usize =
    INPUT * HIDDEN * @sizeOf(i16) // l0w
    + HIDDEN * @sizeOf(i16) // l0b
    + (2 * PW) * (OUTPUT_BUCKETS * L1_OUT) * @sizeOf(i8) // l1w (i8)
    + (OUTPUT_BUCKETS * L1_OUT) * @sizeOf(f32) // l1b (f32)
    + L1_OUT * (OUTPUT_BUCKETS * L2_OUT) * @sizeOf(f32) // l2w (f32)
    + (OUTPUT_BUCKETS * L2_OUT) * @sizeOf(f32) // l2b (f32)
    + L2_OUT * OUTPUT_BUCKETS * @sizeOf(f32) // l3w (f32)
    + OUTPUT_BUCKETS * @sizeOf(f32); // l3b (f32)

pub fn loaded() bool {
    return net_loaded;
}

// Chess768 index: enemy*384 + piece_type*64 + square, square rank-flipped for black and file-flipped if mirrored.
pub inline fn feature_index(persp_white: bool, piece_idx: usize, sq: u6, mirror: bool, bucket: usize) usize {
    const piece_type: usize = piece_idx & 7;
    const piece_white: bool = piece_idx < 8;
    const friendly: usize = if (piece_white == persp_white) 0 else 384;
    var rel_sq: usize = if (persp_white) @as(usize, sq) else types.flip_rank(@as(usize, sq));
    if (mirror) rel_sq ^= 7;
    return FT * bucket + friendly + piece_type * 64 + rel_sq;
}

/// True if this perspective's king is on files e-h.
inline fn king_mirror(board: *const Board, persp_white: bool) bool {
    const kbb = if (persp_white) board.pieces[5] else board.pieces[13];
    return (@as(usize, @ctz(kbb)) & 7) > 3;
}

/// Input bucket from this perspective's king square (rank-flipped for black).
inline fn king_bucket(board: *const Board, persp_white: bool) usize {
    if (comptime NUM_INPUT_BUCKETS == 1) return 0;
    const kbb = if (persp_white) board.pieces[5] else board.pieces[13];
    const ksq: usize = @ctz(kbb);
    const rel: usize = if (persp_white) ksq else types.flip_rank(ksq);
    return buckets_expanded[rel];
}

/// Accumulators for both perspectives (white = 0, black = 1).
pub const Accumulator = struct {
    vals: [2][HIDDEN]i16 = undefined,
    mirror: [2]bool = .{ false, false },
    bucket: [2]usize = .{ 0, 0 },
    // If !computed[ci], vals[ci] is stale and gets rebuilt from the parent using delta.
    computed: [2]bool = .{ false, false },
    delta: FeatDelta = .{},

    /// Rebuild both perspectives from scratch.
    pub fn refresh(self: *Accumulator, board: *const Board) void {
        inline for ([_]bool{ true, false }) |persp_white| {
            refresh_one(self, board, persp_white, king_mirror(board, persp_white), king_bucket(board, persp_white));
        }
    }
};

// Hot loops use explicit @Vector code since Zig 0.16 disables LLVM's loop auto-vectorizer.
const VL16: usize = std.simd.suggestVectorLength(i16) orelse 8;
const VL32: usize = std.simd.suggestVectorLength(i32) orelse 4;
comptime {
    std.debug.assert(HIDDEN % VL16 == 0);
    std.debug.assert(PW % VL16 == 0);
    std.debug.assert((2 * PW) % (2 * VL32) == 0);
}

const builtin = @import("builtin");
const HAS_VNNI512 = builtin.cpu.arch == .x86_64 and
    builtin.cpu.has(.x86, .avx512vnni) and VL32 >= 16;

const N_CHUNKS: usize = 2 * PW / 4; // 4-byte activation chunks

/// L1 weights grouped by input chunk: sparse[b][c*64 + j*4 + k] = w[out j][c*4 + k].
var l1_weights_sparse: [OUTPUT_BUCKETS][N_CHUNKS * 64]i8 align(64) = undefined;

fn build_sparse_l1() void {
    for (0..OUTPUT_BUCKETS) |b| {
        for (0..N_CHUNKS) |c| {
            for (0..L1_OUT) |j| {
                for (0..4) |k| {
                    l1_weights_sparse[b][c * 64 + j * 4 + k] = l1_weights[b * L1_OUT + j][c * 4 + k];
                }
            }
        }
    }
}

// l2_weights transposed to in-major so the L2 outputs map to vector lanes.
var l2_wT: [OUTPUT_BUCKETS][L1_OUT][L2_OUT]f32 align(64) = undefined;

fn build_l2_transposed() void {
    for (0..OUTPUT_BUCKETS) |b| {
        for (0..L1_OUT) |k| {
            for (0..L2_OUT) |m| {
                l2_wT[b][k][m] = l2_weights[b * L2_OUT + m][k];
            }
        }
    }
}

/// AVX512-VNNI vpdpbusd: sum[j] += dot(u[4j..4j+4], w[4j..4j+4]), no saturation.
fn dpbusd512(sum: @Vector(16, i32), u: @Vector(64, u8), w: @Vector(64, i8)) @Vector(16, i32) {
    return @extern(*const fn (@Vector(16, i32), @Vector(16, i32), @Vector(16, i32)) callconv(.c) @Vector(16, i32), .{
        .name = "llvm.x86.avx512.vpdpbusd.512",
    }).*(sum, @bitCast(u), @bitCast(w));
}

// Bitmask byte -> positions of its set bits.
const NONZERO_INDICES: [256]@Vector(8, u16) = blk: {
    var res: [256]@Vector(8, u16) = @splat(@splat(0));
    @setEvalBranchQuota(256 * 8 * 2);
    for (0..256) |i| {
        var count: usize = 0;
        for (0..8) |j| {
            if (i & (1 << j) != 0) {
                res[i][count] = j;
                count += 1;
            }
        }
    }
    break :blk res;
};

/// Collect indices of nonzero 4-byte chunks of the activation vector.
fn find_nonzero_chunks(x8: *align(64) const [2 * PW]u8, indices: *[N_CHUNKS]u16) usize {
    var count: usize = 0;
    var base: @Vector(8, u16) = @splat(0);
    var i: usize = 0;
    while (i < 2 * PW) : (i += 64) {
        const v: @Vector(16, i32) = @bitCast(@as(@Vector(64, u8), x8[i..][0..64].*));
        const mask: u16 = @bitCast(v != @as(@Vector(16, i32), @splat(0)));
        inline for (0..2) |j| {
            const byte: usize = (mask >> (8 * j)) & 0xff;
            const idxs: [8]u16 = NONZERO_INDICES[byte] + base;
            @memcpy(indices[count..][0..8], &idxs);
            count += @popCount(byte);
            base += @splat(8);
        }
    }
    return count;
}

inline fn add_col(v: *[HIDDEN]i16, col: *const [HIDDEN]i16) void {
    var i: usize = 0;
    while (i < HIDDEN) : (i += VL16) {
        const a: @Vector(VL16, i16) = v[i..][0..VL16].*;
        const b: @Vector(VL16, i16) = col[i..][0..VL16].*;
        v[i..][0..VL16].* = a +% b;
    }
}

/// dst = src - subs + adds in one pass; tuples keep the column pointers in registers.
fn apply_fused(
    dst: *[HIDDEN]i16,
    src: *const [HIDDEN]i16,
    subs: anytype,
    adds: anytype,
) void {
    var i: usize = 0;
    while (i < HIDDEN) : (i += VL16) {
        var a: @Vector(VL16, i16) = src[i..][0..VL16].*;
        inline for (subs) |c| a -%= @as(@Vector(VL16, i16), c[i..][0..VL16].*);
        inline for (adds) |c| a +%= @as(@Vector(VL16, i16), c[i..][0..VL16].*);
        dst[i..][0..VL16].* = a;
    }
}

/// Rebuild one perspective from scratch.
fn refresh_one(acc: *Accumulator, board: *const Board, comptime persp_white: bool, m: bool, b: usize) void {
    const ci: usize = if (persp_white) 0 else 1;
    acc.mirror[ci] = m;
    acc.bucket[ci] = b;
    acc.vals[ci] = feature_bias;
    // Unused piece ordinals are always empty.
    inline for (0..types.Board.PieceCount) |pc| {
        var bbv = board.pieces[pc];
        while (bbv != 0) {
            const sq: u6 = @intCast(@ctz(bbv));
            bbv &= bbv - 1;
            const col = &feature_weights[feature_index(persp_white, pc, sq, m, b)];
            add_col(&acc.vals[ci], col);
        }
    }
}

// Search accumulator stack: apply() pushes a level per move, pop_acc() pops it; null moves don't touch it.
const STACK_SIZE: usize = 160; // MAX_PLY plus qsearch headroom

pub var acc_stack: [STACK_SIZE]Accumulator = undefined;
pub var acc_sp: usize = 0;
/// True between stack_init and stack_stop, so moves outside search skip the stack.
pub var acc_active: bool = false;
/// Check every incremental eval against a full refresh (CLI arg `verify`).
pub var verify_incremental: bool = false;

/// Begin incremental tracking for a search rooted at `board`.
pub fn stack_init(board: *const Board) void {
    // Refresh both nets, the router can pick either one at any node.
    acc_stack[0].refresh(board);
    acc_stack[0].computed = .{ true, true };
    acc_stack_s[0].refresh(board);
    acc_stack_s[0].computed = .{ true, true };
    acc_sp = 0;
    acc_active = true;
}

pub fn stack_stop() void {
    acc_active = false;
}

pub inline fn pop_acc() void {
    acc_sp -= 1;
}

/// Piece/square changes of a move, at most 2 adds and 2 subs (castling).
pub const FeatDelta = struct {
    add_pc: [2]usize = undefined,
    add_sq: [2]u6 = undefined,
    n_add: usize = 0,
    sub_pc: [2]usize = undefined,
    sub_sq: [2]u6 = undefined,
    n_sub: usize = 0,

    pub inline fn add(self: *FeatDelta, pc: usize, sq: u6) void {
        self.add_pc[self.n_add] = pc;
        self.add_sq[self.n_add] = sq;
        self.n_add += 1;
    }
    pub inline fn sub(self: *FeatDelta, pc: usize, sq: u6) void {
        self.sub_pc[self.n_sub] = pc;
        self.sub_sq[self.n_sub] = sq;
        self.n_sub += 1;
    }
};

/// Push a level for the post-move `board`; the update is deferred to eval time unless a king crosses the mirror line.
pub fn apply(board: *const Board, delta: FeatDelta) void {
    const srcb = &acc_stack[acc_sp];
    acc_sp += 1;
    const dstb = &acc_stack[acc_sp];
    const dsts = &acc_stack_s[acc_sp];
    dstb.delta = delta;
    dsts.delta = delta;

    inline for ([_]bool{ true, false }) |pw| {
        const ci: usize = if (pw) 0 else 1;
        const m = king_mirror(board, pw);
        const b = king_bucket(board, pw);
        const bucket_changed = NUM_INPUT_BUCKETS > 1 and b != srcb.bucket[ci];
        if (m != srcb.mirror[ci] or bucket_changed) {
            // Mirror changed: refresh now while we have the board.
            refresh_one(dstb, board, pw, m, b);
            dstb.computed[ci] = true;
            refresh_one_s(dsts, board, pw, m, b);
            dsts.computed[ci] = true;
        } else {
            // Deferred until ensure_computed.
            dstb.mirror[ci] = m;
            dstb.bucket[ci] = b;
            dstb.computed[ci] = false;
            dsts.mirror[ci] = m;
            dsts.bucket[ci] = b;
            dsts.computed[ci] = false;
        }
    }
}

/// dst = src - subs + adds for one perspective.
fn apply_delta_one(
    dst: *[HIDDEN]i16,
    src: *const [HIDDEN]i16,
    delta: FeatDelta,
    comptime persp_white: bool,
    m: bool,
    b: usize,
) void {
    var subs: [2]*const [HIDDEN]i16 = undefined;
    var adds: [2]*const [HIDDEN]i16 = undefined;
    var k: usize = 0;
    while (k < delta.n_sub) : (k += 1) {
        subs[k] = &feature_weights[feature_index(persp_white, delta.sub_pc[k], delta.sub_sq[k], m, b)];
        @prefetch(subs[k], .{ .rw = .read });
    }
    k = 0;
    while (k < delta.n_add) : (k += 1) {
        adds[k] = &feature_weights[feature_index(persp_white, delta.add_pc[k], delta.add_sq[k], m, b)];
        @prefetch(adds[k], .{ .rw = .read });
    }
    if (delta.n_add == 1) {
        if (delta.n_sub == 1) {
            apply_fused(dst, src, .{subs[0]}, .{adds[0]}); // quiet
        } else {
            apply_fused(dst, src, .{ subs[0], subs[1] }, .{adds[0]}); // capture / ep
        }
    } else {
        if (delta.n_sub == 1) {
            apply_fused(dst, src, .{subs[0]}, .{ adds[0], adds[1] });
        } else {
            apply_fused(dst, src, .{ subs[0], subs[1] }, .{ adds[0], adds[1] }); // castling
        }
    }
}

/// Bring level `sp` up to date by replaying deltas from the nearest computed level.
fn ensure_computed(sp: usize, comptime ci: usize) void {
    if (acc_stack[sp].computed[ci]) return;
    var anchor = sp;
    while (!acc_stack[anchor].computed[ci]) anchor -= 1;
    const pw = comptime (ci == 0);
    var l = anchor + 1;
    while (l <= sp) : (l += 1) {
        const lvl = &acc_stack[l];
        apply_delta_one(&lvl.vals[ci], &acc_stack[l - 1].vals[ci], lvl.delta, pw, lvl.mirror[ci], lvl.bucket[ci]);
        lvl.computed[ci] = true;
    }
}

/// Scale eval toward 0 as the halfmove clock grows (0 = off).
pub var r50_div: i32 = 0;

/// Eval for search: uses the accumulator stack when active, otherwise a full refresh.
pub fn evaluate_search(board: *const Board) i32 {
    var s: i32 = undefined;
    if (acc_active) {
        if (want_small) {
            ensure_computed_s(acc_sp, 0);
            ensure_computed_s(acc_sp, 1);
            if (verify_incremental) verify_stack_top_s(board);
            s = evaluate_acc_s(&acc_stack_s[acc_sp], board.side, output_bucket(board));
            // Small net misjudges sacrifices, so re-check modest scores with the big net.
            if (small_guard > 0 and s < small_guard and s > -small_guard) {
                ensure_computed(acc_sp, 0);
                ensure_computed(acc_sp, 1);
                if (verify_incremental) verify_stack_top(board);
                s = evaluate_acc(&acc_stack[acc_sp], board.side, output_bucket(board));
            }
        } else {
            ensure_computed(acc_sp, 0);
            ensure_computed(acc_sp, 1);
            if (verify_incremental) verify_stack_top(board);
            s = evaluate_acc(&acc_stack[acc_sp], board.side, output_bucket(board));
        }
    } else {
        s = evaluate(board);
    }
    if (r50_div > 0) {
        const hm: i32 = @min(@as(i32, board.halfmove), 100);
        s = @divTrunc(s * (r50_div - hm), r50_div);
    }
    return s;
}

/// Panic if the stack top differs from a fresh refresh.
fn verify_stack_top(board: *const Board) void {
    var fresh: Accumulator = undefined;
    fresh.refresh(board);
    for (0..2) |ci| {
        for (0..HIDDEN) |i| {
            if (fresh.vals[ci][i] != acc_stack[acc_sp].vals[ci][i]) {
                std.debug.print(
                    "NNUE incremental mismatch: persp {} idx {} fresh {} inc {} (sp {})\n",
                    .{ ci, i, fresh.vals[ci][i], acc_stack[acc_sp].vals[ci][i], acc_sp },
                );
                @panic("NNUE incremental accumulator mismatch");
            }
        }
    }
}

/// verify_stack_top for the small net.
fn verify_stack_top_s(board: *const Board) void {
    var fresh: AccumulatorS = undefined;
    fresh.refresh(board);
    for (0..2) |ci| {
        for (0..HIDDEN_S) |i| {
            if (fresh.vals[ci][i] != acc_stack_s[acc_sp].vals[ci][i]) {
                std.debug.print(
                    "NNUE small incremental mismatch: persp {} idx {} fresh {} inc {} (sp {})\n",
                    .{ ci, i, fresh.vals[ci][i], acc_stack_s[acc_sp].vals[ci][i], acc_sp },
                );
                @panic("NNUE small incremental accumulator mismatch");
            }
        }
    }
}

/// Square Clipped ReLU: clamp to [0, QA] then square. Widens i16 -> i32.
inline fn screlu(x: i16) i32 {
    const y: i32 = std.math.clamp(@as(i32, x), 0, QA);
    return y * y;
}

/// Output bucket from piece count (bullet MaterialCount).
inline fn output_bucket(board: *const Board) usize {
    const divisor: usize = (32 + OUTPUT_BUCKETS - 1) / OUTPUT_BUCKETS;
    const count: usize = @popCount(board.pieces_combined());
    return (count - 2) / divisor;
}

inline fn screlu_f(x: f32) f32 {
    const c = std.math.clamp(x, 0.0, 1.0);
    return c * c;
}

// screlu_f for vectors.
inline fn screlu_v(x: anytype) @TypeOf(x) {
    const V = @TypeOf(x);
    const c = std.math.clamp(x, @as(V, @splat(0.0)), @as(V, @splat(1.0)));
    return c * c;
}

/// u8 x i8 dot product for L1; sums fit i32, so the result is exact.
fn dot_u8i8(x: *const [2 * PW]u8, w: *const [2 * PW]i8) i32 {
    const N = 2 * VL32; // elements per vector step
    const U = 4; // independent accumulators to hide latency
    comptime std.debug.assert((2 * PW) % (U * N) == 0);
    var accs: [U]@Vector(VL32, i32) = undefined;
    inline for (0..U) |u| accs[u] = @splat(0);
    var j: usize = 0;
    while (j < 2 * PW) : (j += U * N) {
        inline for (0..U) |u| {
            const xv: @Vector(N, u8) = x[j + u * N ..][0..N].*;
            const wv: @Vector(N, i8) = w[j + u * N ..][0..N].*;
            // Widen, multiply, add pairs: LLVM turns this into vpmaddwd.
            const xi: @Vector(N, i32) = @intCast(xv);
            const wi: @Vector(N, i32) = @intCast(wv);
            const prod = xi * wi;
            const halves = std.simd.deinterlace(2, prod);
            accs[u] += halves[0] + halves[1];
        }
    }
    var acc = accs[0];
    inline for (1..U) |u| acc += accs[u];
    return @reduce(.Add, acc);
}

/// Big-net forward pass, centipawns from the side to move.
pub fn evaluate_acc(acc: *const Accumulator, stm: Color, bucket: usize) i32 {
    const us: usize = @intFromEnum(stm);
    const them: usize = us ^ 1;

    // Pairwise CReLU: x8[j] = (clamp(acc[j]) * clamp(acc[j + PW])) >> 8.
    var x8: [2 * PW]u8 align(64) = undefined;
    // 255*255 fits u16.
    const PVL = VL16;
    const z: @Vector(PVL, i16) = @splat(0);
    const q: @Vector(PVL, i16) = @splat(@as(i16, QA));
    inline for ([_]usize{ 0, 1 }) |side| {
        const av = if (side == 0) &acc.vals[us] else &acc.vals[them];
        const base = side * PW;
        var j: usize = 0;
        while (j < PW) : (j += PVL) {
            const lo: @Vector(PVL, i16) = av[j..][0..PVL].*;
            const hi: @Vector(PVL, i16) = av[j + PW ..][0..PVL].*;
            const lc: @Vector(PVL, u16) = @min(@max(lo, z), q);
            const hc: @Vector(PVL, u16) = @min(@max(hi, z), q);
            const p: @Vector(PVL, u16) = (lc *% hc) >> @splat(8);
            x8[base + j ..][0..PVL].* = @as(@Vector(PVL, u8), @truncate(p));
        }
    }

    // L1 (i8) -> dequant + bias -> SCReLU (16).
    var sums: [L1_OUT]i32 = undefined;
    const l1b = bucket * L1_OUT;
    if (comptime HAS_VNNI512) {
        // Sparse L1: one vpdpbusd per nonzero chunk, two accumulators to hide latency.
        var idxs: [N_CHUNKS]u16 = undefined;
        const nnz = find_nonzero_chunks(&x8, &idxs);
        const x32: [*]const i32 = @ptrCast(@alignCast(&x8));
        const wsp: [*]const i8 = &l1_weights_sparse[bucket];
        var acc0: @Vector(16, i32) = @splat(0);
        var acc1: @Vector(16, i32) = @splat(0);
        var t: usize = 0;
        while (t + 2 <= nnz) : (t += 2) {
            const c0: usize = idxs[t];
            const c1: usize = idxs[t + 1];
            acc0 = dpbusd512(acc0, @bitCast(@as(@Vector(16, i32), @splat(x32[c0]))), wsp[c0 * 64 ..][0..64].*);
            acc1 = dpbusd512(acc1, @bitCast(@as(@Vector(16, i32), @splat(x32[c1]))), wsp[c1 * 64 ..][0..64].*);
        }
        if (t < nnz) {
            const c0: usize = idxs[t];
            acc0 = dpbusd512(acc0, @bitCast(@as(@Vector(16, i32), @splat(x32[c0]))), wsp[c0 * 64 ..][0..64].*);
        }
        sums = acc0 + acc1;
    } else {
        for (0..L1_OUT) |k| sums[k] = dot_u8i8(&x8, &l1_weights[l1b + k]);
    }
    // Dequant, add bias, SCReLU.
    const V1 = @Vector(L1_OUT, f32);
    const l1_out = @as(V1, @floatFromInt(@as(@Vector(L1_OUT, i32), sums))) / @as(V1, @splat(L1_DEQUANT)) + @as(V1, l1_bias[l1b..][0..L1_OUT].*);
    const h2: [L1_OUT]f32 = screlu_v(l1_out);
    // L2 (f32), one lane per output.
    const V2 = @Vector(L2_OUT, f32);
    const wT = &l2_wT[bucket];
    var l2_sum: V2 = l2_bias[bucket * L2_OUT ..][0..L2_OUT].*;
    inline for (0..L1_OUT) |k| l2_sum += @as(V2, wT[k]) * @as(V2, @splat(h2[k]));
    // L3 (f32) -> cp.
    const l3_prod: [L2_OUT]f32 = @as(V2, l3_weights[bucket]) * screlu_v(l2_sum);
    var o: f32 = l3_bias[bucket];
    inline for (l3_prod) |x| o += x;
    return @intFromFloat(@round(o * @as(f32, @floatFromInt(SCALE))));
}

/// Full evaluation of `board` from the side-to-move's perspective.
pub fn evaluate(board: *const Board) i32 {
    // Same net choice and small_guard fallback as evaluate_search.
    if (want_small) {
        var acc_s: AccumulatorS = undefined;
        acc_s.refresh(board);
        const s = evaluate_acc_s(&acc_s, board.side, output_bucket(board));
        if (!(small_guard > 0 and s < small_guard and s > -small_guard)) return s;
    }
    var acc: Accumulator = undefined;
    acc.refresh(board);
    return evaluate_acc(&acc, board.side, output_bucket(board));
}

/// Load a big-net quantised.bin: l0w l0b l1w l1b l2w l2b l3w l3b, little-endian, no header.
pub fn load_bytes(data: []const u8) !void {
    if (data.len < NET_BYTES) return error.NnueNetTooSmall;

    var off: usize = 0;
    for (0..INPUT) |f| {
        for (0..HIDDEN) |h| {
            feature_weights[f][h] = util.read_le(i16, data, off);
            off += 2;
        }
    }
    for (0..HIDDEN) |h| {
        feature_bias[h] = util.read_le(i16, data, off);
        off += 2;
    }
    for (0..OUTPUT_BUCKETS * L1_OUT) |o| {
        for (0..2 * PW) |j| {
            l1_weights[o][j] = @bitCast(data[off]);
            off += 1;
        }
    }
    build_sparse_l1();
    for (0..OUTPUT_BUCKETS * L1_OUT) |o| {
        l1_bias[o] = util.read_le(f32, data, off);
        off += 4;
    }
    for (0..OUTPUT_BUCKETS * L2_OUT) |o| {
        for (0..L1_OUT) |k| {
            l2_weights[o][k] = util.read_le(f32, data, off);
            off += 4;
        }
    }
    build_l2_transposed();
    for (0..OUTPUT_BUCKETS * L2_OUT) |o| {
        l2_bias[o] = util.read_le(f32, data, off);
        off += 4;
    }
    for (0..OUTPUT_BUCKETS) |b| {
        for (0..L2_OUT) |m| {
            l3_weights[b][m] = util.read_le(f32, data, off);
            off += 4;
        }
    }
    for (0..OUTPUT_BUCKETS) |b| {
        l3_bias[b] = util.read_le(f32, data, off);
        off += 4;
    }

    net_loaded = true;
}

// Small net: 128 wide, trained only on decided positions (|score| >= 300).
const HIDDEN_S: usize = 128;
const PW_S: usize = HIDDEN_S / 2;
/// Small-net head: .multilayer (like the big net) or .single (one linear layer); must match the embedded file.
const SMALL_ARCH: enum { multilayer, single } = .single;
comptime {
    std.debug.assert(HIDDEN_S % VL16 == 0);
    std.debug.assert((2 * PW_S) % (2 * VL32) == 0);
    std.debug.assert(PW_S % 16 == 0);
}

var fw_s: [INPUT][HIDDEN_S]i16 = undefined; // l0w
var fb_s: [HIDDEN_S]i16 = undefined; // l0b
var l1w_s: [OUTPUT_BUCKETS * L1_OUT][2 * PW_S]i8 = undefined;
var l1b_s: [OUTPUT_BUCKETS * L1_OUT]f32 = undefined;
var l2w_s: [OUTPUT_BUCKETS * L2_OUT][L1_OUT]f32 = undefined;
var l2b_s: [OUTPUT_BUCKETS * L2_OUT]f32 = undefined;
var l3w_s: [OUTPUT_BUCKETS][L2_OUT]f32 = undefined;
var l3b_s: [OUTPUT_BUCKETS]f32 = undefined;

const NET_BYTES_S: usize =
    INPUT * HIDDEN_S * @sizeOf(i16) + HIDDEN_S * @sizeOf(i16) +
    (2 * PW_S) * (OUTPUT_BUCKETS * L1_OUT) * @sizeOf(i8) + (OUTPUT_BUCKETS * L1_OUT) * @sizeOf(f32) +
    L1_OUT * (OUTPUT_BUCKETS * L2_OUT) * @sizeOf(f32) + (OUTPUT_BUCKETS * L2_OUT) * @sizeOf(f32) +
    L2_OUT * OUTPUT_BUCKETS * @sizeOf(f32) + OUTPUT_BUCKETS * @sizeOf(f32);

// Single-layer head (all i16): l1w is out-major and QB-scaled, l1b is QA*QB-scaled.
var l1w_sl: [OUTPUT_BUCKETS][2 * HIDDEN_S]i16 align(64) = undefined;
var l1b_sl: [OUTPUT_BUCKETS]i16 = undefined;
// True if every l1w_sl weight is in [-128, 128], required by head_sum_simd_s.
pub var small_head_simd: bool = false;

const NET_BYTES_SL: usize =
    INPUT * HIDDEN_S * @sizeOf(i16) + HIDDEN_S * @sizeOf(i16) +
    OUTPUT_BUCKETS * (2 * HIDDEN_S) * @sizeOf(i16) + OUTPUT_BUCKETS * @sizeOf(i16); // 200976

fn load_bytes_small_single(data: []const u8) !void {
    // Exact size check (plus up to 63 bytes padding) so a multilayer file is rejected.
    if (data.len < NET_BYTES_SL or data.len > NET_BYTES_SL + 63) return error.NnueNetSizeMismatch;
    var off: usize = 0;
    for (0..INPUT) |f| {
        for (0..HIDDEN_S) |h| {
            fw_s[f][h] = util.read_le(i16, data, off);
            off += 2;
        }
    }
    for (0..HIDDEN_S) |h| {
        fb_s[h] = util.read_le(i16, data, off);
        off += 2;
    }
    for (0..OUTPUT_BUCKETS) |o| {
        for (0..2 * HIDDEN_S) |j| {
            l1w_sl[o][j] = util.read_le(i16, data, off);
            off += 2;
        }
    }
    // clamp(v)*w must fit i16: 255*128 does, 255*129 doesn't.
    small_head_simd = for (&l1w_sl) |*row| {
        if (std.mem.min(i16, row) < -128 or std.mem.max(i16, row) > 128) break false;
    } else true;
    for (0..OUTPUT_BUCKETS) |o| {
        l1b_sl[o] = util.read_le(i16, data, off);
        off += 2;
    }
}

fn load_bytes_small(data: []const u8) !void {
    // Exact size check, see load_bytes_small_single.
    if (data.len < NET_BYTES_S or data.len > NET_BYTES_S + 63) return error.NnueNetSizeMismatch;
    var off: usize = 0;
    for (0..INPUT) |f| {
        for (0..HIDDEN_S) |h| {
            fw_s[f][h] = util.read_le(i16, data, off);
            off += 2;
        }
    }
    for (0..HIDDEN_S) |h| {
        fb_s[h] = util.read_le(i16, data, off);
        off += 2;
    }
    for (0..OUTPUT_BUCKETS * L1_OUT) |o| {
        for (0..2 * PW_S) |j| {
            l1w_s[o][j] = @bitCast(data[off]);
            off += 1;
        }
    }
    for (0..OUTPUT_BUCKETS * L1_OUT) |o| {
        l1b_s[o] = util.read_le(f32, data, off);
        off += 4;
    }
    for (0..OUTPUT_BUCKETS * L2_OUT) |o| {
        for (0..L1_OUT) |k| {
            l2w_s[o][k] = util.read_le(f32, data, off);
            off += 4;
        }
    }
    for (0..OUTPUT_BUCKETS * L2_OUT) |o| {
        l2b_s[o] = util.read_le(f32, data, off);
        off += 4;
    }
    for (0..OUTPUT_BUCKETS) |b| {
        for (0..L2_OUT) |m| {
            l3w_s[b][m] = util.read_le(f32, data, off);
            off += 4;
        }
    }
    for (0..OUTPUT_BUCKETS) |b| {
        l3b_s[b] = util.read_le(f32, data, off);
        off += 4;
    }
}

inline fn add_col_s(v: *[HIDDEN_S]i16, col: *const [HIDDEN_S]i16) void {
    var i: usize = 0;
    while (i < HIDDEN_S) : (i += VL16) {
        const a: @Vector(VL16, i16) = v[i..][0..VL16].*;
        const b: @Vector(VL16, i16) = col[i..][0..VL16].*;
        v[i..][0..VL16].* = a +% b;
    }
}
fn apply_fused_s(dst: *[HIDDEN_S]i16, src: *const [HIDDEN_S]i16, subs: anytype, adds: anytype) void {
    var i: usize = 0;
    while (i < HIDDEN_S) : (i += VL16) {
        var a: @Vector(VL16, i16) = src[i..][0..VL16].*;
        inline for (subs) |c| a -%= @as(@Vector(VL16, i16), c[i..][0..VL16].*);
        inline for (adds) |c| a +%= @as(@Vector(VL16, i16), c[i..][0..VL16].*);
        dst[i..][0..VL16].* = a;
    }
}

pub const AccumulatorS = struct {
    vals: [2][HIDDEN_S]i16 = undefined,
    mirror: [2]bool = .{ false, false },
    bucket: [2]usize = .{ 0, 0 },
    computed: [2]bool = .{ false, false },
    delta: FeatDelta = .{},
    pub fn refresh(self: *AccumulatorS, board: *const Board) void {
        inline for ([_]bool{ true, false }) |pw| {
            refresh_one_s(self, board, pw, king_mirror(board, pw), king_bucket(board, pw));
        }
    }
};

fn refresh_one_s(acc: *AccumulatorS, board: *const Board, comptime persp_white: bool, m: bool, b: usize) void {
    const ci: usize = if (persp_white) 0 else 1;
    acc.mirror[ci] = m;
    acc.bucket[ci] = b;
    acc.vals[ci] = fb_s;
    // Unused piece ordinals are always empty.
    inline for (0..types.Board.PieceCount) |pc| {
        var bbv = board.pieces[pc];
        while (bbv != 0) {
            const sq: u6 = @intCast(@ctz(bbv));
            bbv &= bbv - 1;
            add_col_s(&acc.vals[ci], &fw_s[feature_index(persp_white, pc, sq, m, b)]);
        }
    }
}

fn apply_delta_one_s(dst: *[HIDDEN_S]i16, src: *const [HIDDEN_S]i16, delta: FeatDelta, comptime persp_white: bool, m: bool, b: usize) void {
    var subs: [2]*const [HIDDEN_S]i16 = undefined;
    var adds: [2]*const [HIDDEN_S]i16 = undefined;
    var k: usize = 0;
    while (k < delta.n_sub) : (k += 1) subs[k] = &fw_s[feature_index(persp_white, delta.sub_pc[k], delta.sub_sq[k], m, b)];
    k = 0;
    while (k < delta.n_add) : (k += 1) adds[k] = &fw_s[feature_index(persp_white, delta.add_pc[k], delta.add_sq[k], m, b)];
    if (delta.n_add == 1) {
        if (delta.n_sub == 1) apply_fused_s(dst, src, .{subs[0]}, .{adds[0]}) else apply_fused_s(dst, src, .{ subs[0], subs[1] }, .{adds[0]});
    } else {
        if (delta.n_sub == 1) apply_fused_s(dst, src, .{subs[0]}, .{ adds[0], adds[1] }) else apply_fused_s(dst, src, .{ subs[0], subs[1] }, .{ adds[0], adds[1] });
    }
}

pub var acc_stack_s: [STACK_SIZE]AccumulatorS = undefined;

fn ensure_computed_s(sp: usize, comptime ci: usize) void {
    if (acc_stack_s[sp].computed[ci]) return;
    var anchor = sp;
    while (!acc_stack_s[anchor].computed[ci]) anchor -= 1;
    const pw = comptime (ci == 0);
    var l = anchor + 1;
    while (l <= sp) : (l += 1) {
        const lvl = &acc_stack_s[l];
        apply_delta_one_s(&lvl.vals[ci], &acc_stack_s[l - 1].vals[ci], lvl.delta, pw, lvl.mirror[ci], lvl.bucket[ci]);
        lvl.computed[ci] = true;
    }
}

/// Dense u8 x i8 dot product for the small net's L1.
fn dot_u8i8_s(x: *const [2 * PW_S]u8, w: *const [2 * PW_S]i8) i32 {
    const N = 2 * VL32;
    var acc: @Vector(VL32, i32) = @splat(0);
    var j: usize = 0;
    while (j < 2 * PW_S) : (j += N) {
        const xv: @Vector(N, u8) = x[j..][0..N].*;
        const wv: @Vector(N, i8) = w[j..][0..N].*;
        const xi: @Vector(N, i32) = @intCast(xv);
        const wi: @Vector(N, i32) = @intCast(wv);
        const prod = xi * wi;
        const halves = std.simd.deinterlace(2, prod);
        acc += halves[0] + halves[1];
    }
    return @reduce(.Add, acc);
}

/// Small-net forward pass, centipawns from the side to move.
pub fn evaluate_acc_s(acc: *const AccumulatorS, stm: Color, bucket: usize) i32 {
    return if (comptime SMALL_ARCH == .multilayer)
        evaluate_acc_s_ml(acc, stm, bucket)
    else
        evaluate_acc_s_single(acc, stm, bucket);
}

/// cp = (sum(SCReLU(acc) * w) / QA + bias) * SCALE / (QA*QB), truncating like bullet.
fn evaluate_acc_s_single(acc: *const AccumulatorS, stm: Color, bucket: usize) i32 {
    const us: usize = @intFromEnum(stm);
    const w = &l1w_sl[bucket];
    const sum = if (small_head_simd) head_sum_simd_s(acc, us, w) else head_sum_scalar_s(acc, us, w);
    var out: i64 = @divTrunc(sum, QA64) + l1b_sl[bucket];
    out = @divTrunc(out * SCALE64, QA64 * QB64);
    return @intCast(out);
}

// Scalar head sum in i64, exact for any i16 weight.
fn head_sum_scalar_s(acc: *const AccumulatorS, us: usize, w: *const [2 * HIDDEN_S]i16) i64 {
    const them: usize = us ^ 1;
    var sum: i64 = 0;
    inline for ([_]usize{ 0, 1 }) |side| {
        const av = if (side == 0) &acc.vals[us] else &acc.vals[them];
        const base = side * HIDDEN_S;
        var i: usize = 0;
        while (i < HIDDEN_S) : (i += 4) {
            sum += @as(i64, screlu(av[i + 0])) * w[base + i + 0];
            sum += @as(i64, screlu(av[i + 1])) * w[base + i + 1];
            sum += @as(i64, screlu(av[i + 2])) * w[base + i + 2];
            sum += @as(i64, screlu(av[i + 3])) * w[base + i + 3];
        }
    }
    return sum;
}

// SIMD head sum, only valid when small_head_simd: (clamp(v)*w) in i16, then *v in i32.
inline fn head_sum_simd_s(acc: *const AccumulatorS, us: usize, w: *const [2 * HIDDEN_S]i16) i64 {
    const them: usize = us ^ 1;
    const z: @Vector(VL16, i16) = @splat(0);
    const q: @Vector(VL16, i16) = @splat(@as(i16, QA));
    var s: @Vector(VL16 / 2, i32) = @splat(0);
    inline for ([_]usize{ 0, 1 }) |side| {
        const av = if (side == 0) &acc.vals[us] else &acc.vals[them];
        const base = side * HIDDEN_S;
        var i: usize = 0;
        while (i < HIDDEN_S) : (i += VL16) {
            const v: @Vector(VL16, i16) = @min(@max(@as(@Vector(VL16, i16), av[i..][0..VL16].*), z), q);
            const wv: @Vector(VL16, i16) = w[base + i ..][0..VL16].*;
            const prod = @as(@Vector(VL16, i32), v *% wv) * @as(@Vector(VL16, i32), v);
            const halves = std.simd.deinterlace(2, prod);
            s += halves[0] + halves[1];
        }
    }
    // |sum| <= 256*255*255*128 < 2^31, so i32 can't overflow.
    return @reduce(.Add, s);
}

fn evaluate_acc_s_ml(acc: *const AccumulatorS, stm: Color, bucket: usize) i32 {
    const us: usize = @intFromEnum(stm);
    const them: usize = us ^ 1;
    var x8: [2 * PW_S]u8 align(64) = undefined;
    const PVL = 16;
    const z: @Vector(PVL, i16) = @splat(0);
    const q: @Vector(PVL, i16) = @splat(@as(i16, QA));
    inline for ([_]usize{ 0, 1 }) |side| {
        const av = if (side == 0) &acc.vals[us] else &acc.vals[them];
        const base = side * PW_S;
        var j: usize = 0;
        while (j < PW_S) : (j += PVL) {
            const lo: @Vector(PVL, i16) = av[j..][0..PVL].*;
            const hi: @Vector(PVL, i16) = av[j + PW_S ..][0..PVL].*;
            const lc: @Vector(PVL, i32) = @min(@max(lo, z), q);
            const hc: @Vector(PVL, i32) = @min(@max(hi, z), q);
            const p: @Vector(PVL, i32) = (lc * hc) >> @splat(8);
            x8[base + j ..][0..PVL].* = @as(@Vector(PVL, u8), @intCast(p));
        }
    }
    var h2: [L1_OUT]f32 = undefined;
    const l1o = bucket * L1_OUT;
    for (0..L1_OUT) |k| {
        const s = dot_u8i8_s(&x8, &l1w_s[l1o + k]);
        h2[k] = screlu_f(@as(f32, @floatFromInt(s)) / L1_DEQUANT + l1b_s[l1o + k]);
    }
    var h3: [L2_OUT]f32 = undefined;
    const l2o = bucket * L2_OUT;
    for (0..L2_OUT) |mm| {
        const wrow = &l2w_s[l2o + mm];
        var t: f32 = l2b_s[l2o + mm];
        for (0..L1_OUT) |k| t += wrow[k] * h2[k];
        h3[mm] = screlu_f(t);
    }
    var o: f32 = l3b_s[bucket];
    for (0..L2_OUT) |mm| o += l3w_s[bucket][mm] * h3[mm];
    return @intFromFloat(@round(o * @as(f32, @floatFromInt(SCALE))));
}

// Small-net scores inside (-small_guard, small_guard) get re-evaluated by the big net (0 = off).
pub var small_guard: i32 = 248;
// Set by router.zig before each eval to pick the small net.
pub var want_small: bool = false;

pub const options = [_]types.Option{
    .{ .name = "r50_div", .ptr = &r50_div, .min = 0, .max = 1024 },
    .{ .name = "small_guard", .ptr = &small_guard, .min = 0, .max = 2000 },
};

// Embedded nets, see the imports in build.zig (nets/big_nnuev3.bin, nets/small_nnuev3.bin).
const embedded_net = @embedFile("big_nnuev3");
const embedded_net_small = @embedFile("small_nnuev3");

/// Load the embedded nets.
pub fn load_embedded() !void {
    try load_bytes(embedded_net);
    if (comptime SMALL_ARCH == .multilayer) {
        try load_bytes_small(embedded_net_small);
    } else {
        try load_bytes_small_single(embedded_net_small);
    }
}
