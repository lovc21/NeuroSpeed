const std = @import("std");
const types = @import("types.zig");
const move_gen = @import("move.zig");
const Move = move_gen.Move;

// Transposition Table entry flags
pub const TTFlag = enum(u2) {
    NONE = 0,
    EXACT = 1, // PV node — score is exact
    LOWER = 2, // Fail-high — score is a lower bound (beta cutoff)
    UPPER = 3, // Fail-low — score is an upper bound
};

/// Sentinel for "no static eval stored" (in-check nodes).
pub const NO_EVAL: i16 = std.math.minInt(i16);

// TT Entry: 16 bytes (4 entries per cache line)
pub const TTEntry = struct {
    key: u32 = 0,
    best_move: Move = Move.empty(),
    score: i16 = 0,
    static_eval: i16 = NO_EVAL,
    depth: u8 = 0,
    flag: TTFlag = .NONE,
    age: u8 = 0,

    pub inline fn is_empty(self: *const TTEntry) bool {
        return self.flag == .NONE;
    }
};

pub const TT = struct {
    entries: []TTEntry,
    mask: usize,
    age: u8 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, size_mb: usize) !TT {
        const entry_size = @sizeOf(TTEntry);
        const num_entries_raw = (size_mb * 1024 * 1024) / entry_size;

        var num_entries: usize = 1;
        while (num_entries * 2 <= num_entries_raw) {
            num_entries *= 2;
        }

        const entries = try allocator.alloc(TTEntry, num_entries);
        @memset(entries, TTEntry{});

        return TT{
            .entries = entries,
            .mask = num_entries - 1,
            .age = 0,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TT) void {
        self.allocator.free(self.entries);
    }

    pub fn clear(self: *TT) void {
        @memset(self.entries, TTEntry{});
        self.age = 0;
    }

    pub fn new_search(self: *TT) void {
        self.age +%= 1;
    }

    inline fn index(self: *const TT, hash: u64) usize {
        return @as(usize, @truncate(hash)) & self.mask;
    }

    inline fn verification_key(hash: u64) u32 {
        return @truncate(hash >> 32);
    }

    pub fn probe(self: *const TT, hash: u64) ?*const TTEntry {
        const idx = self.index(hash);
        const entry = &self.entries[idx];
        if (entry.flag != .NONE and entry.key == verification_key(hash)) {
            return entry;
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
    ) void {
        const idx = self.index(hash);
        const entry = &self.entries[idx];
        const vkey = verification_key(hash);

        // Replacement policy (depth-preferred with aging). The old rule
        // "age != current -> always replace" let depth-0 qsearch stores wipe
        // the previous move's deep entries — in real games the TT carries
        // over between moves and that carried depth is most of its value.
        const same_key = entry.key == vkey and entry.flag != .NONE;
        const age_dist: i32 = @intCast(self.age -% entry.age);
        const replace = if (entry.flag == .NONE)
            true
        else if (same_key)
            // Same position: refresh freely (newest bounds win) EXCEPT when a
            // shallow store would wipe much deeper data — the qsearch depth-0
            // spam case that motivated this policy.
            @as(i32, depth) + 8 >= @as(i32, entry.depth)
        else
            // Collision: older entries get progressively easier to evict;
            // same-age requires comparable depth.
            @as(i32, depth) + 4 * @min(age_dist, 4) >= @as(i32, entry.depth);

        if (!replace) {
            // Still-useful same-position entry: mark it current so collisions
            // don't age it out while it keeps serving this search.
            if (same_key) entry.age = self.age;
            return;
        }
        {
            // Clamp score to i16 range
            const clamped_score: i16 = if (score > std.math.maxInt(i16))
                std.math.maxInt(i16)
            else if (score < std.math.minInt(i16))
                std.math.minInt(i16)
            else
                @intCast(score);

            entry.* = TTEntry{
                .key = vkey,
                .depth = depth,
                .score = clamped_score,
                .static_eval = static_eval,
                .flag = flag,
                .best_move = best_move,
                .age = self.age,
            };
        }
    }

    // Get the approximate usage of the TT (per mille, 0-1000)
    pub fn hashfull(self: *const TT) u32 {
        var used: u32 = 0;
        const sample = @min(self.entries.len, 1000);
        for (0..sample) |i| {
            if (self.entries[i].flag != .NONE and self.entries[i].age == self.age) {
                used += 1;
            }
        }
        return used * 1000 / @as(u32, @intCast(sample));
    }
};
