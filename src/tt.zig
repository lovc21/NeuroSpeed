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

// TT Entry: 16 bytes (2 entries per cache line)
pub const TTEntry = struct {
    key: u32 = 0,
    best_move: Move = Move.empty(),
    score: i16 = 0,
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
    ) void {
        const idx = self.index(hash);
        const entry = &self.entries[idx];
        const vkey = verification_key(hash);

        // Replacement policy: replace if
        // 1. Empty slot
        // 2. Same position (update with potentially deeper/better info)
        // 3. Old age (from previous search)
        // 4. Shallower depth
        if (entry.flag == .NONE or
            entry.key == vkey or
            entry.age != self.age or
            entry.depth <= depth)
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
