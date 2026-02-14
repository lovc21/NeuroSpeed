const std = @import("std");
const Move = @import("move_generation.zig").Move;

pub const MoveList = struct {
    moves: [255]Move = undefined,
    count: usize = 0,

    pub fn append(self: *MoveList, m: Move) void {
        self.moves[self.count] = m;
        self.count += 1;
    }
};

pub const ScoreList = struct {
    scores: [255]i32 = undefined,
    count: usize = 0,

    pub fn append(self: *ScoreList, s: i32) void {
        self.scores[self.count] = s;
        self.count += 1;
    }
};

pub const ScoredMoveList = struct {
    moves: [255]Move = undefined,
    scores: [255]i32 = undefined,
    count: usize = 0,

    pub fn append(self: *ScoredMoveList, m: Move, s: i32) void {
        self.moves[self.count] = m;
        self.scores[self.count] = s;
        self.count += 1;
    }
};
