const std = @import("std");
const types = @import("types.zig");
const print = std.debug.print;

const material_scores = [_]i32{ 100, 300, 350, 500, 1000, 10000 };

pub inline fn evaluat_material(board: types.Board) i32 {
    var score: i32 = 0;

    inline for (0..6) |i| {
        const white_piece = @as(types.Piece, @enumFromInt(i));
        const black_piece = @as(types.Piece, @enumFromInt(i + 8));

        const white_count = @popCount(board.pieces[@intFromEnum(white_piece)]);
        const black_count = @popCount(board.pieces[@intFromEnum(black_piece)]);

        score += material_scores[i] * @as(i32, white_count);
        score -= material_scores[i] * @as(i32, black_count);
    }
    return if (board.side == types.Color.White) score else -score;
}
