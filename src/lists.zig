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
