const std = @import("std");
const types = @import("types.zig");
const attacks = @import("attacks.zig");
const lists = @import("lists.zig");
const util = @import("util.zig");

pub const Move = struct {
    from: u6,
    to: u6,
    flags: types.MoveFlags,

    pub inline fn new(from: u6, to: u6, flags: types.MoveFlags) Move {
        return Move{ .from = from, .to = to, .flags = flags };
    }
};

pub fn generate_moves(list: *lists.MoveList) void {
    const us = types.Board.side; // side to move
    const them = if (types.Board.side == .white) .black else .white;
    _ = us;
    _ = them;
    _ = list;
}
