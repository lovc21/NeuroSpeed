const std = @import("std");
const types = @import("types.zig");

const Board = types.Board;
const Color = types.Color;

/// Master switch. Flipped on once a net is loaded (UCI option / startup).
pub var use_nnue = false;

// --- Architecture (must equal the bullet HIDDEN_SIZE of the trained net) ---
pub const HIDDEN: usize = 1024;
const INPUT: usize = 768;

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

// --- Network parameters, parsed from a bullet `quantised.bin` ---
// `feature_weights` is column-major exactly as bullet writes it: column `f`
// (length HIDDEN) is the vector added to the accumulator when feature `f` is
// active. So the on-disk order == `feature_weights[feature][hidden]`.
var feature_weights: [INPUT][HIDDEN]i16 = undefined;
var feature_bias: [HIDDEN]i16 = undefined;
// One output row per bucket. Within a bucket: [0..HIDDEN]=stm, [HIDDEN..]=ntm.
// bullet saves these `.transpose()`d, i.e. bucket-major / each bucket contiguous.
var output_weights: [OUTPUT_BUCKETS][2 * HIDDEN]i16 = undefined;
var output_bias: [OUTPUT_BUCKETS]i16 = undefined;
var net_loaded: bool = false;

/// Size in bytes of the parameter region of a `quantised.bin` for this
/// architecture (the file itself is padded up to a multiple of 64 bytes).
pub const NET_BYTES: usize =
    INPUT * HIDDEN * @sizeOf(i16) // feature_weights (l0w)
+ HIDDEN * @sizeOf(i16) // feature_bias   (l0b)
+ OUTPUT_BUCKETS * 2 * HIDDEN * @sizeOf(i16) // output_weights (l1w, bucket-major)
+ OUTPUT_BUCKETS * @sizeOf(i16); // output_bias    (l1b, one per bucket)

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
pub inline fn feature_index(persp_white: bool, piece_idx: usize, sq: u6) usize {
    const piece_type: usize = piece_idx & 7;
    const piece_white: bool = piece_idx < 8;
    const friendly: usize = if (piece_white == persp_white) 0 else 384;
    const rel_sq: usize = if (persp_white) @as(usize, sq) else @as(usize, sq) ^ 56;
    return friendly + piece_type * 64 + rel_sq;
}

/// Two perspective accumulators, indexed by colour (White = 0, Black = 1).
pub const Accumulator = struct {
    vals: [2][HIDDEN]i16 = undefined,

    /// Rebuild both accumulators from scratch off the board bitboards.
    pub fn refresh(self: *Accumulator, board: *const Board) void {
        inline for ([_]Color{ .White, .Black }) |persp| {
            const ci: usize = @intFromEnum(persp);
            const persp_white = (persp == .White);
            self.vals[ci] = feature_bias;

            // White pieces are indices 0..5, black 8..13 (6,7 are gaps).
            inline for ([_]usize{ 0, 1, 2, 3, 4, 5, 8, 9, 10, 11, 12, 13 }) |pc| {
                var bbv = board.pieces[pc];
                while (bbv != 0) {
                    const sq: u6 = @intCast(@ctz(bbv));
                    bbv &= bbv - 1;
                    const col = &feature_weights[feature_index(persp_white, pc, sq)];
                    for (0..HIDDEN) |i| self.vals[ci][i] +%= col[i];
                }
            }
        }
    }
};

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

/// Forward pass from a built accumulator, using output bucket `bucket`. Returns
/// a side-to-move-relative score in centipawns (positive = good for `stm`).
/// Bit-identical to bullet's reference inference; the i64 accumulation only
/// guards against overflow.
pub fn evaluate_acc(acc: *const Accumulator, stm: Color, bucket: usize) i32 {
    const us: usize = @intFromEnum(stm);
    const them: usize = us ^ 1;
    const w = &output_weights[bucket];

    var sum: i64 = 0;
    for (0..HIDDEN) |i| sum += @as(i64, screlu(acc.vals[us][i])) * @as(i64, w[i]);
    for (0..HIDDEN) |i| sum += @as(i64, screlu(acc.vals[them][i])) * @as(i64, w[HIDDEN + i]);

    sum = @divTrunc(sum, QA64); // QA*QA*QB -> QA*QB
    sum += @as(i64, output_bias[bucket]);
    sum *= SCALE64;
    sum = @divTrunc(sum, QA64 * QB64); // -> centipawns
    return @intCast(sum);
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

/// Parse network parameters from raw `quantised.bin` bytes. Trailing padding
/// (the ASCII "bullet" filler bytes) is ignored.
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
    // l1w is bucket-major (transposed): each bucket's 2*HIDDEN weights contiguous.
    for (0..OUTPUT_BUCKETS) |b| {
        for (0..2 * HIDDEN) |i| {
            output_weights[b][i] = read_i16(data, off);
            off += 2;
        }
    }
    for (0..OUTPUT_BUCKETS) |b| {
        output_bias[b] = read_i16(data, off);
        off += 2;
    }

    net_loaded = true;
}

/// Load a net from a file on disk (used until the net is `@embedFile`d).
pub fn load_file(allocator: std.mem.Allocator, path: []const u8) !void {
    const data = try std.fs.cwd().readFileAlloc(allocator, path, 64 << 20);
    defer allocator.free(data);
    try load_bytes(data);
}

// The trained Gen-0 net, embedded for a dependency-free release build.
const embedded_net = @embedFile("nnue_net.bin");

/// Load the embedded net into the module-level parameters and mark it ready.
pub fn load_embedded() !void {
    try load_bytes(embedded_net);
}
