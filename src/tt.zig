const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");
const move_gen = @import("move.zig");
const Move = move_gen.Move;

// Mate scores are stored relative to the position, not the root
pub inline fn score_to_tt(score: i32, ply: u16) i32 {
    if (score > types.MATE_BOUND) return score + @as(i32, ply);
    if (score < -types.MATE_BOUND) return score - @as(i32, ply);
    return score;
}

pub inline fn score_from_tt(score: i16, ply: u16) i32 {
    const s: i32 = score;
    if (s > types.MATE_BOUND) return s - @as(i32, ply);
    if (s < -types.MATE_BOUND) return s + @as(i32, ply);
    return s;
}

// True if a stored bound already decides the (alpha, beta) window
pub inline fn cutoff(flag: TTFlag, score: i32, alpha: i32, beta: i32) bool {
    return switch (flag) {
        .EXACT => true,
        .LOWER => score >= beta,
        .UPPER => score <= alpha,
        .NONE => false,
    };
}

// The engine's transposition table (null if allocation failed)
pub var global: ?TT = null;

// (Re)allocate the global table
pub fn init_global(allocator: std.mem.Allocator, size_mb: usize) !void {
    deinit_global();
    global = try TT.init(allocator, size_mb);
}

pub fn deinit_global() void {
    if (global) |*t| {
        t.deinit();
        global = null;
    }
}

// Transposition Table entry flags
pub const TTFlag = enum(u2) {
    NONE = 0,
    EXACT = 1, // PV node
    LOWER = 2, // Fail-high
    UPPER = 3, // Fail-low
};

/// Sentinel for "no static eval stored"
pub const NO_EVAL: i16 = std.math.minInt(i16);

// TT Entry: 16 bytes, 4 per 64-byte cluster
pub const TTEntry = struct {
    key: u32 = 0,
    best_move: Move = Move.empty(),
    score: i16 = 0,
    static_eval: i16 = NO_EVAL,
    depth: u8 = 0,
    flag: TTFlag = .NONE,
    age: u8 = 0,
    // ttPv: position was searched with an open window at some point
    pv: bool = false,

    pub inline fn is_empty(self: *const TTEntry) bool {
        return self.flag == .NONE;
    }
};

pub const CLUSTER_SIZE = 4;
pub const Cluster = [CLUSTER_SIZE]TTEntry;
const CLUSTER_BYTES = @sizeOf(Cluster);
const EMPTY_CLUSTER: Cluster = .{TTEntry{}} ** CLUSTER_SIZE;

// 2 MB alignment so the kernel can back the table with transparent huge pages
const HUGE_PAGE: usize = 2 * 1024 * 1024;
const HUGE_ALIGN = std.mem.Alignment.fromByteUnits(HUGE_PAGE);

pub const TT = struct {
    clusters: []align(HUGE_PAGE) Cluster,
    age: u8 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size_mb: usize) !TT {
        const num_clusters = @max(1, (size_mb * 1024 * 1024) / CLUSTER_BYTES);

        const clusters = try allocator.alignedAlloc(Cluster, HUGE_ALIGN, num_clusters);
        advise_huge_pages(clusters);
        @memset(clusters, EMPTY_CLUSTER);

        return TT{
            .clusters = clusters,
            .age = 0,
            .allocator = allocator,
        };
    }

    fn advise_huge_pages(clusters: []align(HUGE_PAGE) Cluster) void {
        if (builtin.os.tag != .linux) return;
        const bytes = std.mem.sliceAsBytes(clusters);
        std.posix.madvise(@alignCast(bytes.ptr), bytes.len, std.os.linux.MADV.HUGEPAGE) catch {};
    }

    pub fn deinit(self: *TT) void {
        self.allocator.free(self.clusters);
    }

    pub fn clear(self: *TT) void {
        @memset(self.clusters, EMPTY_CLUSTER);
        self.age = 0;
    }

    pub fn new_search(self: *TT) void {
        self.age +%= 1;
    }

    // Cluster index = floor(hash * n / 2^64): uniform over any n, one MUL; uses the HIGH hash bits
    inline fn index(self: *const TT, hash: u64) usize {
        const wide = @as(u128, hash) * @as(u128, self.clusters.len);
        return @intCast(wide >> 64);
    }

    // LOW hash bits: independent of the index bits above
    inline fn verification_key(hash: u64) u32 {
        return @truncate(hash);
    }

    // Prefetch the cluster for `hash` right after make_move; semantically a no-op
    pub inline fn prefetch(self: *const TT, hash: u64) void {
        @prefetch(&self.clusters[self.index(hash)], .{});
    }

    pub fn probe(self: *const TT, hash: u64) ?*const TTEntry {
        const cluster = &self.clusters[self.index(hash)];
        const vkey = verification_key(hash);
        for (cluster) |*entry| {
            if (entry.flag != .NONE and entry.key == vkey) return entry;
        }
        return null;
    }

    pub fn store(
        self: *TT,
        hash: u64,
        depth: u8,
        score: i32,
        flag: TTFlag,
        best_move: Move,
        static_eval: i16,
        pv: bool,
    ) void {
        const cluster = &self.clusters[self.index(hash)];
        const vkey = verification_key(hash);

        // Slot selection: same position > empty slot > weakest occupant (shallowest after an age penalty)
        var slot: *TTEntry = &cluster[0];
        var same_key = false;
        var found = false;
        for (cluster) |*entry| {
            if (entry.flag != .NONE and entry.key == vkey) {
                slot = entry;
                same_key = true;
                found = true;
                break;
            }
        }
        if (!found) {
            for (cluster) |*entry| {
                if (entry.flag == .NONE) {
                    slot = entry;
                    found = true;
                    break;
                }
            }
        }
        if (!found) {
            var best_value: i32 = std.math.maxInt(i32);
            for (cluster) |*entry| {
                // Victim score: depth minus an age penalty, so stale entries are cheapest to evict.
                const age_dist: i32 = @intCast(self.age -% entry.age);
                const v = @as(i32, entry.depth) - 8 * @min(age_dist, 4);
                if (v < best_value) {
                    best_value = v;
                    slot = entry;
                }
            }
        }

        // Same position: refresh freely, except a shallow non-EXACT store must not wipe much deeper data (qsearch spam)
        if (same_key and flag != .EXACT and @as(i32, depth) + 8 < @as(i32, slot.depth)) {
            // Still-useful entry: keep it current and remember it was on the PV
            slot.age = self.age;
            slot.pv = slot.pv or pv;
            return;
        }

        // Clamp score to i16 range
        const clamped_score: i16 = if (score > std.math.maxInt(i16))
            std.math.maxInt(i16)
        else if (score < std.math.minInt(i16))
            std.math.minInt(i16)
        else
            @intCast(score);

        // A store without a best move (fail-low, qsearch) must not erase the move already known here
        const move_to_keep = if (same_key and best_move.is_empty()) slot.best_move else best_move;

        slot.* = TTEntry{
            .key = vkey,
            .depth = depth,
            .score = clamped_score,
            .static_eval = static_eval,
            .flag = flag,
            .best_move = move_to_keep,
            .age = self.age,
            .pv = pv,
        };
    }

    // Get the approximate usage of the TT (per mille, 0-1000)
    pub fn hashfull(self: *const TT) u32 {
        var used: u32 = 0;
        // Explicit usize: @min with a literal narrows to u10, and sample * 4 would overflow it.
        const sample: usize = @min(self.clusters.len, 1000);
        for (self.clusters[0..sample]) |*cluster| {
            for (cluster) |*entry| {
                if (entry.flag != .NONE and entry.age == self.age) used += 1;
            }
        }
        return used * 1000 / @as(u32, @intCast(sample * CLUSTER_SIZE));
    }
};
