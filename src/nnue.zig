const std = @import("std");
const types = @import("types.zig");
const globals = @import("globals.zig");

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
fn refresh_one(acc: *Accumulator, board: *const Board, persp_white: bool, m: bool, b: usize) void {
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
    acc_stack[0].refresh(board);
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

/// Push the next accumulator from `delta`. `board` is the POST-move position.
/// Per perspective: if its own king crossed the d/e boundary (mirror flipped),
/// fully refresh that perspective; otherwise copy the parent and apply the
/// add/sub columns under the perspective's current mirror. At most one
/// perspective can refresh per move (only one piece moves).
pub fn apply(board: *const Board, delta: FeatDelta) void {
    const src = &acc_stack[acc_sp];
    acc_sp += 1;
    const dst = &acc_stack[acc_sp];
    inline for ([_]bool{ true, false }) |pw| {
        const ci: usize = if (pw) 0 else 1;
        const m = king_mirror(board, pw);
        const b = king_bucket(board, pw);
        if (m != src.mirror[ci] or b != src.bucket[ci]) {
            // This perspective's own king changed mirror or bucket → remap all.
            refresh_one(dst, board, pw, m, b);
        } else {
            dst.mirror[ci] = m;
            dst.bucket[ci] = b;
            var subs: [2]*const [HIDDEN]i16 = undefined;
            var adds: [2]*const [HIDDEN]i16 = undefined;
            var k: usize = 0;
            while (k < delta.n_sub) : (k += 1) {
                subs[k] = &feature_weights[feature_index(pw, delta.sub_pc[k], delta.sub_sq[k], m, b)];
            }
            k = 0;
            while (k < delta.n_add) : (k += 1) {
                adds[k] = &feature_weights[feature_index(pw, delta.add_pc[k], delta.add_sq[k], m, b)];
            }
            const dv = &dst.vals[ci];
            const sv = &src.vals[ci];
            if (delta.n_add == 1) {
                if (delta.n_sub == 1) {
                    apply_fused(dv, sv, .{subs[0]}, .{adds[0]}); // quiet
                } else {
                    apply_fused(dv, sv, .{ subs[0], subs[1] }, .{adds[0]}); // capture / ep
                }
            } else {
                if (delta.n_sub == 1) {
                    apply_fused(dv, sv, .{subs[0]}, .{ adds[0], adds[1] });
                } else {
                    apply_fused(dv, sv, .{ subs[0], subs[1] }, .{ adds[0], adds[1] }); // castling
                }
            }
        }
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
        if (verify_incremental) verify_stack_top(board);
        s = evaluate_acc(&acc_stack[acc_sp], board.side, output_bucket(board));
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
    var x8: [2 * PW]u8 = undefined;
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
    for (0..L1_OUT) |k| {
        const s = dot_u8i8(&x8, &l1_weights[l1b + k]);
        h2[k] = screlu_f(@as(f32, @floatFromInt(s)) / L1_DEQUANT + l1_bias[l1b + k]);
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
    const data = try std.Io.Dir.cwd().readFileAlloc(globals.io, path, allocator, .limited(64 << 20));
    defer allocator.free(data);
    try load_bytes(data);
}

// The trained Gen-0 net, embedded for a dependency-free release build.
const embedded_net = @embedFile("nnue_net.bin");

/// Load the embedded net into the module-level parameters and mark it ready.
pub fn load_embedded() !void {
    try load_bytes(embedded_net);
}
