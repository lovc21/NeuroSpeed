const std = @import("std");
const types = @import("types.zig");
const clock = @import("clock.zig");

const Board = types.Board;
const Color = types.Color;

/// Master switch. Flipped on once a net is loaded (UCI option / startup).
pub var use_nnue = false;

// --- Architecture (must equal the bullet HIDDEN_SIZE of the trained net) ---
pub const HIDDEN: usize = 640;
const FT: usize = 768; // features per king-input-bucket (Chess768)

// King-input buckets (bullet `ChessBucketsMirrored`): each perspective selects
// a 768-feature block by its OWN king square, plus the file mirror.
// NUM_INPUT_BUCKETS=1 = mirror-only (the SHIPPING config: 4 king-file buckets
// REGRESSED -62.8 vs mirror at 558M data — too starved per bucket; revisit
// buckets once data >= ~1.5B). The bucket machinery below stays general so a
// future retry only needs to bump NUM_INPUT_BUCKETS + the buckets_32 layout.
// MIRROR-ONLY is the shipping config. King-input bucketing REGRESSED for us at
// every variant: 4 king-FILE buckets -62.8, 10 king-REGION buckets (factorised,
// done right) -71.4 — both at 558M AND 1.22B. Not a layout/factoriser/data issue;
// fundamental (eval inflation breaks cp-pruning margins + per-bucket dilution).
// Buckets are OUT. The machinery stays general (set NUM_INPUT_BUCKETS + the
// buckets_32 layout to retry) but don't expect it to help without margin re-tune.
const NUM_INPUT_BUCKETS: usize = 1;
const INPUT: usize = FT * NUM_INPUT_BUCKETS;

const buckets_32: [32]usize = .{0} ** 32; // all-zero = mirror only
const buckets_expanded: [64]usize = blk: {
    const mir = [8]usize{ 0, 1, 2, 3, 3, 2, 1, 0 };
    var e: [64]usize = undefined;
    for (0..64) |idx| e[idx] = buckets_32[(idx / 8) * 4 + mir[idx % 8]];
    break :blk e;
};

// Output buckets, selected by material count exactly as bullet's
// `MaterialCount<8>`: bucket = (piece_count - 2) / ceil(32/8).
const OUTPUT_BUCKETS: usize = 8;

// --- Quantisation constants (must equal the bullet training config) ---
const QA: i32 = 255;
const QB: i32 = 64;
const SCALE: i32 = 400;
const QA64: i64 = QA;
const QB64: i64 = QB;
const SCALE64: i64 = SCALE;

// --- Multilayer head (per output bucket): acc(1024) -CReLU-> pairwise(1024->512)
// per perspective, concat -> 1024 -> L1(1024->16, i8) -SCReLU-> L2(16->32, f32)
// -SCReLU-> L3(32->1, f32). The accumulator (l0) is unchanged + still incremental.
const PW: usize = HIDDEN / 2; // 512
const L1_OUT: usize = 16;
const L2_OUT: usize = 32;
// L1 dequant: pairwise product (<=QA^2) is shifted >>8 to 8-bit, l1w is QB-scaled,
// so divide the integer L1 sum by (QA^2/256)*QB = QA^2*QB/256.
const L1_DEQUANT: f32 = @as(f32, @floatFromInt(QA * QA * QB)) / 256.0; // 16256.25

var feature_weights: [INPUT][HIDDEN]i16 = undefined;
var feature_bias: [HIDDEN]i16 = undefined;
// All layer-stack weights are OUT-major contiguous (bullet `.transpose()` layout):
// disk[out*in_size + in]. weights[out] = that output neuron's input vector.
var l1_weights: [OUTPUT_BUCKETS * L1_OUT][2 * PW]i8 = undefined; // i8, in = 1024
var l1_bias: [OUTPUT_BUCKETS * L1_OUT]f32 = undefined;
var l2_weights: [OUTPUT_BUCKETS * L2_OUT][L1_OUT]f32 = undefined;
var l2_bias: [OUTPUT_BUCKETS * L2_OUT]f32 = undefined;
var l3_weights: [OUTPUT_BUCKETS][L2_OUT]f32 = undefined;
var l3_bias: [OUTPUT_BUCKETS]f32 = undefined;
var net_loaded: bool = false;

/// Size in bytes of the parameter region of a `quantised.bin` for this
/// architecture (the file itself is padded up to a multiple of 64 bytes).
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

// ===========================================================================
// Feature encoding — bullet `Chess768`, dual perspective.
//
//   friendly = (piece_colour == perspective) ? 0 : 1
//   rel_sq   = (perspective == White) ? sq : sq ^ 56      // flip rank only
//   index    = friendly*384 + piece_type*64 + rel_sq
//
// piece_idx is NeuroSpeed's `Piece` ordinal: WHITE_* = 0..5, BLACK_* = 8..13,
// so `piece_idx & 7` is the piece type (P,N,B,R,Q,K = 0..5) and `piece_idx < 8`
// is the colour — identical to bullet's `piece & 7` / `piece & 8`.
// ===========================================================================
// Horizontal mirroring (bullet `ChessBucketsMirrored::default()`): each
// perspective flips the file of every feature square iff that perspective's
// OWN king stands on files e-h. `mirror` XORs the relative square's low 3 bits
// (its file), matching bullet's `feat ^ 7`. num_inputs stays 768 (no buckets).
pub inline fn feature_index(persp_white: bool, piece_idx: usize, sq: u6, mirror: bool, bucket: usize) usize {
    const piece_type: usize = piece_idx & 7;
    const piece_white: bool = piece_idx < 8;
    const friendly: usize = if (piece_white == persp_white) 0 else 384;
    var rel_sq: usize = if (persp_white) @as(usize, sq) else @as(usize, sq) ^ 56;
    if (mirror) rel_sq ^= 7;
    return FT * bucket + friendly + piece_type * 64 + rel_sq;
}

/// Whether perspective `persp_white`'s own king is on files e-h (→ mirror).
/// File is invariant under the vertical (rank) perspective flip, so absolute
/// king file is correct for both perspectives.
inline fn king_mirror(board: *const Board, persp_white: bool) bool {
    const kbb = if (persp_white) board.pieces[5] else board.pieces[13];
    return (@as(usize, @ctz(kbb)) & 7) > 3;
}

/// Input bucket selected by perspective `persp_white`'s own king square, seen
/// FROM that perspective (vertical rank flip for Black) — the bucket layout is
/// rank-dependent, so Black must use ksq^56 (file-only buckets masked this bug).
inline fn king_bucket(board: *const Board, persp_white: bool) usize {
    // Mirror-only shipping config: the bucket is provably always 0, so skip
    // the ctz/xor/table load in every apply/refresh. Flipping
    // NUM_INPUT_BUCKETS back on restores the full computation.
    if (comptime NUM_INPUT_BUCKETS == 1) return 0;
    const kbb = if (persp_white) board.pieces[5] else board.pieces[13];
    const ksq: usize = @ctz(kbb);
    const rel: usize = if (persp_white) ksq else ksq ^ 56;
    return buckets_expanded[rel];
}

/// Two perspective accumulators (White = 0, Black = 1), each tagged with the
/// mirror state it was built under so incremental updates can detect a king
/// crossing the d/e boundary (which remaps every feature → full refresh).
pub const Accumulator = struct {
    vals: [2][HIDDEN]i16 = undefined,
    mirror: [2]bool = .{ false, false },
    bucket: [2]usize = .{ 0, 0 },
    // Lazy-update state: computed[ci] = vals[ci] is valid; else it must be
    // resolved on demand from `delta` + the nearest computed ancestor. `delta`
    // holds the world-feature change from the PARENT stack level to this one.
    computed: [2]bool = .{ false, false },
    delta: FeatDelta = .{},

    /// Rebuild both accumulators from scratch off the board bitboards.
    pub fn refresh(self: *Accumulator, board: *const Board) void {
        inline for ([_]bool{ true, false }) |persp_white| {
            refresh_one(self, board, persp_white, king_mirror(board, persp_white), king_bucket(board, persp_white));
        }
    }
};

// ===========================================================================
// Explicit SIMD kernels. Zig 0.16's LLVM disables the loop auto-vectorizer
// (miscompilation workaround), so every hot loop must carry its own @Vector
// code. Zen 5 native: 512-bit → VL16=32, VL32=16; baseline x86_64 (SSE2):
// VL16=8, VL32=4. HIDDEN=640 and 2*PW=1024 are divisible by all of these.
// All integer kernels are bit-identical to the scalar loops they replace
// (elementwise wrapping ops; i32 sums cannot overflow, so order is free).
// ===========================================================================
const VL16: usize = std.simd.suggestVectorLength(i16) orelse 8;
const VL32: usize = std.simd.suggestVectorLength(i32) orelse 4;
comptime {
    std.debug.assert(HIDDEN % VL16 == 0);
    std.debug.assert((2 * PW) % (2 * VL32) == 0);
}

const builtin = @import("builtin");
const HAS_VNNI512 = builtin.cpu.arch == .x86_64 and
    builtin.cpu.has(.x86, .avx512vnni) and VL32 >= 16;

const N_CHUNKS: usize = 2 * PW / 4; // 256 4-byte activation chunks

/// Sparse L1 weight layout: for chunk c, 64 contiguous bytes hold
/// out j (0..15) x in k (0..3): sparse[b][c*64 + j*4 + k] = w[out j][c*4 + k].
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

/// AVX512-VNNI u8 x i8 dot-accumulate: sum[j] += sum_k(u[4j+k] * w[4j+k]),
/// products summed in full i32 precision (exact, unlike vpdpbusds/pmaddubsw).
fn dpbusd512(sum: @Vector(16, i32), u: @Vector(64, u8), w: @Vector(64, i8)) @Vector(16, i32) {
    return @extern(*const fn (@Vector(16, i32), @Vector(16, i32), @Vector(16, i32)) callconv(.c) @Vector(16, i32), .{
        .name = "llvm.x86.avx512.vpdpbusd.512",
    }).*(sum, @bitCast(u), @bitCast(w));
}

// Lookup: bitmask byte -> up to 8 set-bit positions
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

inline fn sub_col(v: *[HIDDEN]i16, col: *const [HIDDEN]i16) void {
    var i: usize = 0;
    while (i < HIDDEN) : (i += VL16) {
        const a: @Vector(VL16, i16) = v[i..][0..VL16].*;
        const b: @Vector(VL16, i16) = col[i..][0..VL16].*;
        v[i..][0..VL16].* = a -% b;
    }
}

/// Fused incremental update: dst = src - subs[..] + adds[..] in ONE pass over
/// the accumulator (no intermediate copy — the copy+in-place-update pattern
/// costs ~2x the memory traffic). `subs`/`adds` are comptime-length TUPLES of
/// column pointers so they live in SSA registers — an in-memory pointer array
/// can alias `dst` as far as LLVM knows, forcing per-chunk pointer reloads.
/// Bit-identical to sequential sub/add: same elementwise wrapping ops.
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

/// Rebuild a single perspective's accumulator from scratch under (mirror, bucket).
fn refresh_one(acc: *Accumulator, board: *const Board, comptime persp_white: bool, m: bool, b: usize) void {
    const ci: usize = if (persp_white) 0 else 1;
    acc.mirror[ci] = m;
    acc.bucket[ci] = b;
    acc.vals[ci] = feature_bias;
    // White pieces are indices 0..5, black 8..13 (6,7 are gaps).
    inline for ([_]usize{ 0, 1, 2, 3, 4, 5, 8, 9, 10, 11, 12, 13 }) |pc| {
        var bbv = board.pieces[pc];
        while (bbv != 0) {
            const sq: u6 = @intCast(@ctz(bbv));
            bbv &= bbv - 1;
            const col = &feature_weights[feature_index(persp_white, pc, sq, m, b)];
            add_col(&acc.vals[ci], col);
        }
    }
}

// ===========================================================================
// Incremental accumulator stack (search path).
//
// `acc_stack[acc_sp]` always holds the accumulator pair for the CURRENT board
// inside a search: make_move_search pushes (fused copy + add/sub of the moved
// feature columns), unmake_move_search pops. Null moves don't move pieces, so
// they leave the stack untouched and the top entry stays valid. Chess768 has
// no king buckets, so add/sub columns always suffice — a full refresh is only
// ever needed at the search root.
// ===========================================================================
const STACK_SIZE: usize = 160; // > MAX_PLY (128) + qsearch margin

pub var acc_stack: [STACK_SIZE]Accumulator = undefined;
pub var acc_sp: usize = 0;
/// True only between stack_init (search root) and stack_stop. Gates the
/// make/unmake hooks so datagen / UCI position setup never touch the stack.
pub var acc_active: bool = false;
/// Debug: refresh-and-compare on every stack eval (CLI arg `verify`).
pub var verify_incremental: bool = false;

/// Begin incremental tracking for a search rooted at `board`.
pub fn stack_init(board: *const Board) void {
    // Anchor BOTH nets at the root (the small 128-wide refresh is trivial);
    // per-node routing may evaluate either net anywhere in the tree.
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

/// A move's feature changes as "world features" (piece, square) pairs — at most
/// 2 added and 2 subtracted (castling). Each perspective maps them with its own
/// mirror. move.zig builds this; nnue.apply consumes it.
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

/// Lazy push: record the next stack level's `delta` and resolve its mirror/
/// bucket, but DEFER the actual accumulator arithmetic — `board` is the
/// POST-move position. A perspective is computed on demand in ensure_computed()
/// (many nodes are cut before eval and never need it). EXCEPTION: if a
/// perspective's king crossed the d/e boundary (mirror/bucket changed) it needs
/// a full refresh, which requires THIS node's board, so it is done eagerly now
/// and becomes a computed anchor for descendants. At most one perspective can
/// refresh per move (only one piece moves).
pub fn apply(board: *const Board, delta: FeatDelta) void {
    // PER-NODE dual-net (SF style): record the delta into BOTH nets' lazy
    // stacks — this is only stores; the accumulator arithmetic stays deferred,
    // so only the net actually evaluated at a node resolves its column adds
    // (ensure_computed / ensure_computed_s). Refreshes (king crossing the
    // mirror boundary) stay eager and anchor both nets; they are rare.
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
        // Bucket comparison comptime-folds away in the 1-bucket config.
        const bucket_changed = NUM_INPUT_BUCKETS > 1 and b != srcb.bucket[ci];
        if (m != srcb.mirror[ci] or bucket_changed) {
            // Refresh boundary — must compute now (needs this board). Anchor.
            refresh_one(dstb, board, pw, m, b);
            dstb.computed[ci] = true;
            refresh_one_s(dsts, board, pw, m, b);
            dsts.computed[ci] = true;
        } else {
            // Incremental — defer. mirror/bucket carry over from the parent.
            dstb.mirror[ci] = m;
            dstb.bucket[ci] = b;
            dstb.computed[ci] = false;
            dsts.mirror[ci] = m;
            dsts.bucket[ci] = b;
            dsts.computed[ci] = false;
        }
    }
}

/// Apply one perspective's deferred delta: dst = src − subs[] + adds[], with the
/// columns resolved under (m, b). Bit-identical to the old eager path.
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

/// Resolve perspective `ci` of stack level `sp` on demand: walk up to the
/// nearest computed ancestor, then replay each deferred delta forward,
/// memoizing every intermediate level so later evals are O(1). The root and
/// every refresh are computed anchors, so the search always terminates.
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

/// 50-move-rule eval damping divisor (0 = off). Scales the eval toward 0 as the
/// halfmove clock approaches the draw, info the net itself can't see. Tunable
/// via the `r50_div` UCI option (SPSA). Default off so bench/datagen are
/// unchanged unless explicitly enabled.
pub var r50_div: i32 = 0;

/// Evaluation entry for the search path: uses the incremental stack top when
/// active, else falls back to a full refresh (UCI `eval`, evalspeed, datagen).
pub fn evaluate_search(board: *const Board) i32 {
    var s: i32 = undefined;
    if (acc_active) {
        if (want_small) {
            ensure_computed_s(acc_sp, 0);
            ensure_computed_s(acc_sp, 1);
            if (verify_incremental) verify_stack_top_s(board);
            s = evaluate_acc_s(&acc_stack_s[acc_sp], board.side, output_bucket(board));
            // SF-style guard: material is lopsided but the eval is modest =
            // compensation (sacrifice) — the decided-specialized small net is
            // blind there, so re-evaluate with the big net. Rare, cheap insurance.
            if (small_guard > 0 and s < small_guard and s > -small_guard) {
                ensure_computed(acc_sp, 0);
                ensure_computed(acc_sp, 1);
                if (verify_incremental) verify_stack_top(board);
                s = evaluate_acc(&acc_stack[acc_sp], board.side, output_bucket(board));
            }
        } else {
            // Resolve any deferred accumulator work for the current top before use.
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

/// Debug-only: rebuild from scratch and compare to the incremental stack top.
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

/// Small-net counterpart of verify_stack_top: `verify` mode must exercise the
/// small lazy chain (ensure_computed_s / apply_delta_one_s / refresh_one_s)
/// too, or a small-path bug ships undetected behind a clean verify run.
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

/// bullet `MaterialCount<OUTPUT_BUCKETS>`: divisor = ceil(32 / OUTPUT_BUCKETS),
/// bucket = (piece_count - 2) / divisor. Two kings are always present so the
/// count is >= 2 and the bucket index stays in [0, OUTPUT_BUCKETS).
inline fn output_bucket(board: *const Board) usize {
    const divisor: usize = (32 + OUTPUT_BUCKETS - 1) / OUTPUT_BUCKETS;
    const count: usize = @popCount(board.pieces_combined());
    return (count - 2) / divisor;
}

inline fn screlu_f(x: f32) f32 {
    const c = std.math.clamp(x, 0.0, 1.0);
    return c * c;
}

/// L1 dot: u8 (pairwise activations, 0..254) x i8 (weights), explicit vectors
/// (0.16 has no loop auto-vec). Products fit i16 exactly (max 254*127 = 32258),
/// adjacent pairs widen to i32 (the vpmaddwd/vpdpwssd idiom); per-lane sums stay
/// far below 2^31, so lane reassociation is bit-identical to the scalar sum.
fn dot_u8i8(x: *const [2 * PW]u8, w: *const [2 * PW]i8) i32 {
    const N = 2 * VL32; // elements per vector step
    const U = 4; // independent accumulator chains (hide vpdpwssd latency)
    comptime std.debug.assert((2 * PW) % (U * N) == 0);
    var accs: [U]@Vector(VL32, i32) = undefined;
    inline for (0..U) |u| accs[u] = @splat(0);
    var j: usize = 0;
    while (j < 2 * PW) : (j += U * N) {
        inline for (0..U) |u| {
            const xv: @Vector(N, u8) = x[j + u * N ..][0..N].*;
            const wv: @Vector(N, i8) = w[j + u * N ..][0..N].*;
            // Widen -> i32 multiply -> add even/odd lanes: LLVM's canonical
            // PMADDWD shape (combineToPMADDWD), fusing mul+pairwise-add into
            // one vpmaddwd/vpdpwssd instead of vpmullw + shuffles.
            const xi: @Vector(N, i32) = @intCast(xv); // zext, <= 16 bits used
            const wi: @Vector(N, i32) = @intCast(wv); // sext, <= 16 bits used
            const prod = xi * wi;
            const halves = std.simd.deinterlace(2, prod);
            accs[u] += halves[0] + halves[1];
        }
    }
    var acc = accs[0];
    inline for (1..U) |u| acc += accs[u];
    return @reduce(.Add, acc);
}

/// Multilayer forward pass. stm-relative centipawns.
pub fn evaluate_acc(acc: *const Accumulator, stm: Color, bucket: usize) i32 {
    const us: usize = @intFromEnum(stm);
    const them: usize = us ^ 1;

    // CReLU + pairwise-mul to 8-bit: x8[j] = (clamp(acc[j])*clamp(acc[j+PW]))>>8.
    var x8: [2 * PW]u8 align(64) = undefined;
    const PVL = 16;
    const z: @Vector(PVL, i16) = @splat(0);
    const q: @Vector(PVL, i16) = @splat(@as(i16, QA));
    inline for ([_]usize{ 0, 1 }) |side| {
        const av = if (side == 0) &acc.vals[us] else &acc.vals[them];
        const base = side * PW;
        var j: usize = 0;
        while (j < PW) : (j += PVL) {
            const lo: @Vector(PVL, i16) = av[j..][0..PVL].*;
            const hi: @Vector(PVL, i16) = av[j + PW ..][0..PVL].*;
            const lc: @Vector(PVL, i32) = @min(@max(lo, z), q);
            const hc: @Vector(PVL, i32) = @min(@max(hi, z), q);
            const p: @Vector(PVL, i32) = (lc * hc) >> @splat(8);
            x8[base + j ..][0..PVL].* = @as(@Vector(PVL, u8), @intCast(p));
        }
    }

    // L1 (i8) -> dequant + bias -> SCReLU (16).
    var h2: [L1_OUT]f32 = undefined;
    const l1b = bucket * L1_OUT;
    if (comptime HAS_VNNI512) {
        // Sparse path: one vpdpbusd per nonzero activation chunk computes all
        // 16 outputs; two accumulator chains hide the dpbusd latency.
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
        const sums: [L1_OUT]i32 = acc0 + acc1;
        for (0..L1_OUT) |k| {
            h2[k] = screlu_f(@as(f32, @floatFromInt(sums[k])) / L1_DEQUANT + l1_bias[l1b + k]);
        }
    } else {
        for (0..L1_OUT) |k| {
            const s = dot_u8i8(&x8, &l1_weights[l1b + k]);
            h2[k] = screlu_f(@as(f32, @floatFromInt(s)) / L1_DEQUANT + l1_bias[l1b + k]);
        }
    }
    // L2 (f32) -> SCReLU (32).
    var h3: [L2_OUT]f32 = undefined;
    const l2b = bucket * L2_OUT;
    for (0..L2_OUT) |m| {
        const wrow = &l2_weights[l2b + m];
        var t: f32 = l2_bias[l2b + m];
        for (0..L1_OUT) |k| t += wrow[k] * h2[k];
        h3[m] = screlu_f(t);
    }
    // L3 (f32) -> scalar -> cp.
    var o: f32 = l3_bias[bucket];
    for (0..L2_OUT) |m| o += l3_weights[bucket][m] * h3[m];
    return @intFromFloat(@round(o * @as(f32, @floatFromInt(SCALE))));
}

/// Full evaluation of `board` from the side-to-move's perspective.
pub fn evaluate(board: *const Board) i32 {
    // Honor the per-node router outside the search stack too (UCI `eval`,
    // evalspeed): want_small is set by Evaluator.eval from the material signal.
    if (want_small) {
        var acc_s: AccumulatorS = undefined;
        acc_s.refresh(board);
        const s = evaluate_acc_s(&acc_s, board.side, output_bucket(board));
        // Mirror evaluate_search's small_guard: without it the display path
        // (UCI `eval`, evalspeed) reports a different number than the search
        // uses in guard-band positions (modest small-net score on lopsided
        // material -> big-net re-eval).
        if (!(small_guard > 0 and s < small_guard and s > -small_guard)) return s;
    }
    var acc: Accumulator = undefined;
    acc.refresh(board);
    return evaluate_acc(&acc, board.side, output_bucket(board));
}

// ===========================================================================
// Loading a `quantised.bin` (little-endian i16, column-major, no header).
// ===========================================================================
inline fn read_i16(data: []const u8, off: usize) i16 {
    return std.mem.readInt(i16, data[off..][0..2], .little);
}
inline fn read_f32(data: []const u8, off: usize) f32 {
    return @bitCast(std.mem.readInt(u32, data[off..][0..4], .little));
}

/// Parse multilayer params in bullet save order: l0w(i16) l0b(i16) l1w(i8)
/// l1b(f32) l2w(f32) l2b(f32) l3w(f32) l3b(f32). All layer weights OUT-major.
pub fn load_bytes(data: []const u8) !void {
    if (data.len < NET_BYTES) return error.NnueNetTooSmall;

    var off: usize = 0;
    for (0..INPUT) |f| {
        for (0..HIDDEN) |h| {
            feature_weights[f][h] = read_i16(data, off);
            off += 2;
        }
    }
    for (0..HIDDEN) |h| {
        feature_bias[h] = read_i16(data, off);
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
        l1_bias[o] = read_f32(data, off);
        off += 4;
    }
    for (0..OUTPUT_BUCKETS * L2_OUT) |o| {
        for (0..L1_OUT) |k| {
            l2_weights[o][k] = read_f32(data, off);
            off += 4;
        }
    }
    for (0..OUTPUT_BUCKETS * L2_OUT) |o| {
        l2_bias[o] = read_f32(data, off);
        off += 4;
    }
    for (0..OUTPUT_BUCKETS) |b| {
        for (0..L2_OUT) |m| {
            l3_weights[b][m] = read_f32(data, off);
            off += 4;
        }
    }
    for (0..OUTPUT_BUCKETS) |b| {
        l3_bias[b] = read_f32(data, off);
        off += 4;
    }

    net_loaded = true;
}

/// Load a net from a file on disk (used until the net is `@embedFile`d).
pub fn load_file(allocator: std.mem.Allocator, path: []const u8) !void {
    const data = try std.Io.Dir.cwd().readFileAlloc(clock.io, path, allocator, .limited(64 << 20));
    defer allocator.free(data);
    try load_bytes(data);
}

// ===========================================================================
// SMALL NET (dual-net "decided" tier): an isolated 128-wide multilayer NNUE,
// decided-specialized (trained on |score|>=300 only). Structurally identical to
// the big net (768->128 acc -> CReLU+pairwise(128->64/persp) -> concat(128) ->
// per-bucket L1(128->16 i8) -SCReLU-> L2(16->32) -SCReLU-> L3(32->1)), just
// narrower and with a plain DENSE L1 (no sparse-VNNI needed at 128-wide). Shares
// the net-independent feature/mirror/bucket/delta logic. PER-NODE routing (SF
// style): apply() records deltas into BOTH lazy stacks (stores only); at each
// eval, `want_small` (set from the free incremental material signal) picks the
// net and only that net's accumulator is resolved. The big-640 path above is
// byte-for-byte untouched.
// ===========================================================================
const HIDDEN_S: usize = 128;
const PW_S: usize = HIDDEN_S / 2; // 64
/// Which architecture the embedded small net uses. `.multilayer` = ml128d
/// (multilayer head, same shape as the big net). `.single` = sl128d (bullet
/// single-layer: SCReLU(acc) -> concat -> per-bucket linear, no L2/L3 = the
/// fastest head). Both share the SAME 128-wide accumulator machinery below;
/// only the loader and the forward pass differ. Swap src/small_nnuev3.bin to the
/// matching checkpoint when flipping this.
const SMALL_ARCH: enum { multilayer, single } = .single;
comptime {
    std.debug.assert(HIDDEN_S % VL16 == 0);
    std.debug.assert((2 * PW_S) % (2 * VL32) == 0);
    std.debug.assert(PW_S % 16 == 0);
}

var fw_s: [INPUT][HIDDEN_S]i16 = undefined; // l0w
var fb_s: [HIDDEN_S]i16 = undefined; // l0b
var l1w_s: [OUTPUT_BUCKETS * L1_OUT][2 * PW_S]i8 = undefined; // in = 128
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

// --- Single-layer small-net head (SMALL_ARCH == .single): per-bucket linear
// over SCReLU(acc) concat, bullet 4-tensor save format (all i16):
//   l0w (QA) -> fw_s, l0b (QA) -> fb_s,
//   l1w (QB, .transpose() = OUT-major disk[out*256 + in]) -> l1w_sl,
//   l1b (QA*QB) -> l1b_sl.
var l1w_sl: [OUTPUT_BUCKETS][2 * HIDDEN_S]i16 = undefined;
var l1b_sl: [OUTPUT_BUCKETS]i16 = undefined;

const NET_BYTES_SL: usize =
    INPUT * HIDDEN_S * @sizeOf(i16) + HIDDEN_S * @sizeOf(i16) +
    OUTPUT_BUCKETS * (2 * HIDDEN_S) * @sizeOf(i16) + OUTPUT_BUCKETS * @sizeOf(i16); // 200976

fn load_bytes_small_single(data: []const u8) !void {
    // Exact size (allowing bullet's up-to-63-byte alignment pad): a multilayer
    // checkpoint (NET_BYTES_S = 232224) would pass a bare lower-bound check and
    // load silently as garbage after a SMALL_ARCH flip without a file swap.
    if (data.len < NET_BYTES_SL or data.len > NET_BYTES_SL + 63) return error.NnueNetSizeMismatch;
    var off: usize = 0;
    for (0..INPUT) |f| {
        for (0..HIDDEN_S) |h| {
            fw_s[f][h] = read_i16(data, off);
            off += 2;
        }
    }
    for (0..HIDDEN_S) |h| {
        fb_s[h] = read_i16(data, off);
        off += 2;
    }
    for (0..OUTPUT_BUCKETS) |o| {
        for (0..2 * HIDDEN_S) |j| {
            l1w_sl[o][j] = read_i16(data, off);
            off += 2;
        }
    }
    for (0..OUTPUT_BUCKETS) |o| {
        l1b_sl[o] = read_i16(data, off);
        off += 2;
    }
}

fn load_bytes_small(data: []const u8) !void {
    // Exact size (allowing bullet's up-to-63-byte pad) — see the single-layer
    // loader: rejects an arch-mismatched small net file instead of misparsing it.
    if (data.len < NET_BYTES_S or data.len > NET_BYTES_S + 63) return error.NnueNetSizeMismatch;
    var off: usize = 0;
    for (0..INPUT) |f| {
        for (0..HIDDEN_S) |h| {
            fw_s[f][h] = read_i16(data, off);
            off += 2;
        }
    }
    for (0..HIDDEN_S) |h| {
        fb_s[h] = read_i16(data, off);
        off += 2;
    }
    for (0..OUTPUT_BUCKETS * L1_OUT) |o| {
        for (0..2 * PW_S) |j| {
            l1w_s[o][j] = @bitCast(data[off]);
            off += 1;
        }
    }
    for (0..OUTPUT_BUCKETS * L1_OUT) |o| {
        l1b_s[o] = read_f32(data, off);
        off += 4;
    }
    for (0..OUTPUT_BUCKETS * L2_OUT) |o| {
        for (0..L1_OUT) |k| {
            l2w_s[o][k] = read_f32(data, off);
            off += 4;
        }
    }
    for (0..OUTPUT_BUCKETS * L2_OUT) |o| {
        l2b_s[o] = read_f32(data, off);
        off += 4;
    }
    for (0..OUTPUT_BUCKETS) |b| {
        for (0..L2_OUT) |m| {
            l3w_s[b][m] = read_f32(data, off);
            off += 4;
        }
    }
    for (0..OUTPUT_BUCKETS) |b| {
        l3b_s[b] = read_f32(data, off);
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
    inline for ([_]usize{ 0, 1, 2, 3, 4, 5, 8, 9, 10, 11, 12, 13 }) |pc| {
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

/// Dense u8 x i8 dot over the 128-lane small-net activation (exact i32 sum, same
/// PMADDWD widen idiom as the big net's dot_u8i8 → identical integer result).
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

/// Small-net multilayer forward pass. stm-relative centipawns. Mirrors
/// evaluate_acc exactly at HIDDEN_S=128 (dense L1); same quant/dequant/order so
/// forcing the router to always-small reproduces the standalone 128 net bit-for-bit.
/// Small-net forward pass, dispatched on SMALL_ARCH at comptime.
pub fn evaluate_acc_s(acc: *const AccumulatorS, stm: Color, bucket: usize) i32 {
    return if (comptime SMALL_ARCH == .multilayer)
        evaluate_acc_s_ml(acc, stm, bucket)
    else
        evaluate_acc_s_single(acc, stm, bucket);
}

/// Single-layer forward pass (bullet standard): raw = SCReLU(acc_us)·w_us +
/// SCReLU(acc_them)·w_them, cp = (raw/QA + l1b)*SCALE/(QA*QB). i64 accumulation:
/// screlu <= QA^2 = 65025 times an i16 weight exceeds i32 per term. Integer
/// divisions are @divTrunc to match bullet's Rust `/` on integers exactly.
fn evaluate_acc_s_single(acc: *const AccumulatorS, stm: Color, bucket: usize) i32 {
    const us: usize = @intFromEnum(stm);
    const them: usize = us ^ 1;
    const w = &l1w_sl[bucket];
    var sum: i64 = 0;
    // 4-way unroll; scalar i64 madds (the head is 256 madds total — the
    // accumulator update dominates; vectorize only if evalspeed disappoints).
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
    var out: i64 = @divTrunc(sum, QA64) + l1b_sl[bucket];
    out = @divTrunc(out * SCALE64, QA64 * QB64);
    return @intCast(out);
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

// --- Per-NODE net router (SF style). The selection signal is the FREE
// incrementally-maintained material balance (evaluation.zig material_mg, kept
// current at every make/unmake): Evaluator.eval sets `want_small` before each
// evaluate_search call. Lopsided material (|mat| > small_thresh) -> small net;
// else big net. small_guard: if the small net returns a modest score despite
// lopsided material (= compensation/sacrifice, which the decided-specialized
// net never learned), re-evaluate with the big net.
// Force modes for validation: small_thresh=30000 -> pure big (bench identity
// 65464); small_thresh=-1 + small_guard=0 -> pure small (bench identity 54171).
pub var small_thresh: i32 = 475; // cp of material_mg scale (~minor piece)
pub var small_guard: i32 = 248; // re-eval band; 0 = off
pub var want_small: bool = false;
/// Third tier ("sudden death"): |material| above this -> HCE, the fastest eval
/// (~10x, lazy alpha/beta cutoffs). In dead-won positions eval precision is
/// irrelevant — only NPS converts, exactly the bullet time-scramble case.
/// Tier ladder (Evaluator.eval): |mat| > hce_thresh -> HCE, > small_thresh ->
/// small NNUE, else big NNUE. 30000 disables the tier (SF12-15 shipped this
/// exact hybrid: classical eval when material very lopsided, NNUE otherwise).
pub var hce_thresh: i32 = 895;
// Stage 3 (Hybrid-v2): scale the router thresholds by game phase. 100 = off
// (bit-identical). Below 100: full board keeps thresholds, and as material
// comes off they shrink linearly toward phase_floor_pct% — the fast tiers are
// safest in simplified, conversion-dominated endgames. Clamped [30, 100].
pub var phase_floor_pct: i32 = 100;
// Stage 4 (Hybrid-v2): HCE conversion scalars, percent (100 = neutral,
// bit-identical). Scale the "win a won position" machinery inside hce_eval /
// evaluate_special_endgames; SPSA-tunable at bullet TC.
pub var hce_corner_pct: i32 = 100; // corner-driving bonus (B+N mate corners)
pub var hce_kingdist_pct: i32 = 100; // king-proximity term in won endgames
pub var hce_edge_pct: i32 = 100; // CENTER_CONTROL edge-driving term
pub var hce_tempo_pct: i32 = 100; // both tempo bonuses (mg/eg interpolated)
pub var hce_lazy_margin: i32 = 600; // replaces the LAZY_MARGIN const

// The trained Gen-0 net, embedded for a dependency-free release build.
// Resolved via the anonymous imports registered in build.zig — the actual
// files are nets/big_nnuev3.bin and nets/small_nnuev3.bin at the repo root.
const embedded_net = @embedFile("big_nnuev3");
const embedded_net_small = @embedFile("small_nnuev3");

/// Load the embedded nets into the module-level parameters and mark ready.
pub fn load_embedded() !void {
    try load_bytes(embedded_net);
    if (comptime SMALL_ARCH == .multilayer) {
        try load_bytes_small(embedded_net_small);
    } else {
        try load_bytes_small_single(embedded_net_small);
    }
}
