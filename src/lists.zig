const std = @import("std");
const Move = @import("move.zig").Move;

// MoveList that holds 255 moves
pub const MoveList = struct {
    moves: [255]Move = undefined,
    count: usize = 0,

    pub inline fn append(self: *MoveList, m: Move) void {
        self.moves[self.count] = m;
        self.count += 1;
    }
};

// Lanes per i32 vector; the picker in score_moves.zig scans scores VL at a time.
pub const VL: usize = std.simd.suggestVectorLength(i32) orelse 4;

// ScoreList that holds 255 scores plus one vector of -inf padding for the SIMD picker.
pub const ScoreList = struct {
    scores: [255 + VL]i32 = undefined,
    count: usize = 0,

    pub inline fn append(self: *ScoreList, s: i32) void {
        self.scores[self.count] = s;
        self.count += 1;
    }
};
