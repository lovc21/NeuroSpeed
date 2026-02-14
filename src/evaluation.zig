const std = @import("std");
const tabeles = @import("tabeles.zig");
const attacks = @import("attacks.zig");
const types = @import("types.zig");
const nnue = @import("nnue.zig");
const print = std.debug.print;
const util = @import("util.zig");

// Position Evaluation
pub var global_evaluator: Evaluat = Evaluat.init_empty();

// tempo bonus
const mid_game_tempo_bonus = 15;
const end_game_tempo_bonus = 5;

const mid_game_material_score: [6]i32 = .{ 82, 337, 365, 477, 1025, 0 };
const end_game_material_score: [6]i32 = .{ 94, 281, 297, 512, 936, 0 };

const mid_game_pawn_table: [64]i16 = .{
    0,   0,   0,   0,   0,   0,   0,  0,
    98,  134, 61,  95,  68,  126, 34, -11,
    -6,  7,   26,  31,  65,  56,  25, -20,
    -14, 13,  6,   21,  23,  12,  17, -23,
    -27, -2,  -5,  12,  17,  6,   10, -25,
    -26, -4,  -4,  -10, 3,   3,   33, -12,
    -35, -1,  -20, -23, -15, 24,  38, -22,
    0,   0,   0,   0,   0,   0,   0,  0,
};

const end_game_pawn_table: [64]i16 = .{
    0,   0,   0,   0,   0,   0,   0,   0,
    178, 173, 158, 134, 147, 132, 165, 187,
    94,  100, 85,  67,  56,  53,  82,  84,
    32,  24,  13,  5,   -2,  4,   17,  17,
    13,  9,   -3,  -7,  -7,  -8,  3,   -1,
    4,   7,   -6,  1,   0,   -5,  -1,  -8,
    13,  8,   8,   10,  13,  0,   2,   -7,
    0,   0,   0,   0,   0,   0,   0,   0,
};

const mid_game_knight_table: [64]i16 = .{
    -167, -89, -34, -49, 61,  -97, -15, -107,
    -73,  -41, 72,  36,  23,  62,  7,   -17,
    -47,  60,  37,  65,  84,  129, 73,  44,
    -9,   17,  19,  53,  37,  69,  18,  22,
    -13,  4,   16,  13,  28,  19,  21,  -8,
    -23,  -9,  12,  10,  19,  17,  25,  -16,
    -29,  -53, -12, -3,  -1,  18,  -14, -19,
    -105, -21, -58, -33, -17, -28, -19, -23,
};

const end_game_knight_table: [64]i16 = .{
    -58, -38, -13, -28, -31, -27, -63, -99,
    -25, -8,  -25, -2,  -9,  -25, -24, -52,
    -24, -20, 10,  9,   -1,  -9,  -19, -41,
    -17, 3,   22,  22,  22,  11,  8,   -18,
    -18, -6,  16,  25,  16,  17,  4,   -18,
    -23, -3,  -1,  15,  10,  -3,  -20, -22,
    -42, -20, -10, -5,  -2,  -20, -23, -44,
    -29, -51, -23, -15, -22, -18, -50, -64,
};

const mid_game_bishop_table: [64]i16 = .{
    -29, 4,  -82, -37, -25, -42, 7,   -8,
    -26, 16, -18, -13, 30,  59,  18,  -47,
    -16, 37, 43,  40,  35,  50,  37,  -2,
    -4,  5,  19,  50,  37,  37,  7,   -2,
    -6,  13, 13,  26,  34,  12,  10,  4,
    0,   15, 15,  15,  14,  27,  18,  10,
    4,   15, 16,  0,   7,   21,  33,  1,
    -33, -3, -14, -21, -13, -12, -39, -21,
};

const end_game_bishop_table: [64]i16 = .{
    -14, -21, -11, -8,  -7, -9,  -17, -24,
    -8,  -4,  7,   -12, -3, -13, -4,  -14,
    2,   -8,  0,   -1,  -2, 6,   0,   4,
    -3,  9,   12,  9,   14, 10,  3,   2,
    -6,  3,   13,  19,  7,  10,  -3,  -9,
    -12, -3,  8,   10,  13, 3,   -7,  -15,
    -14, -18, -7,  -1,  4,  -9,  -15, -27,
    -23, -9,  -23, -5,  -9, -16, -5,  -17,
};

const mid_game_rook_table: [64]i16 = .{
    32,  42,  32,  51,  63, 9,  31,  43,
    27,  32,  58,  62,  80, 67, 26,  44,
    -5,  19,  26,  36,  17, 45, 61,  16,
    -24, -11, 7,   26,  24, 35, -8,  -20,
    -36, -26, -12, -1,  9,  -7, 6,   -23,
    -45, -25, -16, -17, 3,  0,  -5,  -33,
    -44, -16, -20, -9,  -1, 11, -6,  -71,
    -19, -13, 1,   17,  16, 7,  -37, -26,
};

const end_game_rook_table: [64]i16 = .{
    13, 10, 18, 15, 12, 12,  8,   5,
    11, 13, 13, 11, -3, 3,   8,   3,
    7,  7,  7,  5,  4,  -3,  -5,  -3,
    4,  3,  13, 1,  2,  1,   -1,  2,
    3,  5,  8,  4,  -5, -6,  -8,  -11,
    -4, 0,  -5, -1, -7, -12, -8,  -16,
    -6, -6, 0,  2,  -9, -9,  -11, -3,
    -9, 2,  3,  -1, -5, -13, 4,   -20,
};

const mid_game_queen_table: [64]i16 = .{
    -28, 0,   29,  12,  59,  44,  43,  45,
    -24, -39, -5,  1,   -16, 57,  28,  54,
    -13, -17, 7,   8,   29,  56,  47,  57,
    -27, -27, -16, -16, -1,  17,  -2,  1,
    -9,  -26, -9,  -10, -2,  -4,  3,   -3,
    -14, 2,   -11, -2,  -5,  2,   14,  5,
    -35, -8,  11,  2,   8,   15,  -3,  1,
    -1,  -18, -9,  10,  -15, -25, -31, -50,
};

const end_game_queen_table: [64]i16 = .{
    -9,  22,  22,  27,  27,  19,  10,  20,
    -17, 20,  32,  41,  58,  25,  30,  0,
    -20, 6,   9,   49,  47,  35,  19,  9,
    3,   22,  24,  45,  57,  40,  57,  36,
    -18, 28,  19,  47,  31,  34,  39,  23,
    -16, -27, 15,  6,   9,   17,  10,  5,
    -22, -23, -30, -16, -16, -23, -36, -32,
    -33, -28, -22, -43, -5,  -32, -20, -41,
};

const mid_game_king_table: [64]i16 = .{
    -65, 23,  16,  -15, -56, -34, 2,   13,
    29,  -1,  -20, -7,  -8,  -4,  -38, -29,
    -9,  24,  2,   -16, -20, 6,   22,  -22,
    -17, -20, -12, -27, -30, -25, -14, -36,
    -49, -1,  -27, -39, -46, -44, -33, -51,
    -14, -14, -22, -46, -44, -30, -15, -27,
    1,   7,   -8,  -64, -43, -16, 9,   8,
    -15, 36,  12,  -54, 8,   -28, 24,  14,
};

const end_game_king_table: [64]i16 = .{
    -74, -35, -18, -18, -11, 15,  4,   -17,
    -12, 17,  14,  17,  17,  38,  23,  11,
    10,  17,  23,  15,  20,  45,  44,  13,
    -8,  22,  24,  27,  26,  33,  26,  3,
    -18, -4,  21,  24,  27,  23,  9,   -11,
    -19, -3,  11,  21,  23,  16,  7,   -9,
    -27, -11, 4,   13,  14,  4,   -5,  -17,
    -53, -34, -21, -11, -28, -14, -24, -43,
};

inline fn get_piece_type_index(piece: types.Piece) u3 {
    return @intCast(@intFromEnum(piece) % 8);
}

inline fn get_piece_color_index(piece: types.Piece) u1 {
    return if (@intFromEnum(piece) < 8) 0 else 1;
}

// Game phase calculation
const game_phase_inc = [_]u8{ 0, 1, 1, 3, 6, 0 };
//                                   P  N  B  R  Q  K

const mid_game_tables: [6][64]i16 = .{
    mid_game_pawn_table,
    mid_game_knight_table,
    mid_game_bishop_table,
    mid_game_rook_table,
    mid_game_queen_table,
    mid_game_king_table,
};

const end_game_tables: [6][64]i16 = .{
    end_game_pawn_table,
    end_game_knight_table,
    end_game_bishop_table,
    end_game_rook_table,
    end_game_queen_table,
    end_game_king_table,
};

pub const Evaluat = struct {
    mid_game_eval: i32,
    end_game_eval: i32,
    phase: [2]u8 = [1]u8{0} ** 2,
    material_mg: i32,
    material_eg: i32,

    pub fn init_empty() Evaluat {
        return Evaluat{
            .mid_game_eval = 0,
            .end_game_eval = 0,
            .phase = [1]u8{0} ** 2,
            .material_mg = 0,
            .material_eg = 0,
        };
    }

    pub inline fn add_piece_material(self: *Evaluat, piece: types.Piece) void {
        const piece_type_idx = get_piece_type_index(piece);
        const color_multiplier: i32 = if (get_piece_color_index(piece) == 0) 1 else -1;

        self.material_mg += mid_game_material_score[piece_type_idx] * color_multiplier;
        self.material_eg += end_game_material_score[piece_type_idx] * color_multiplier;
    }

    pub inline fn remove_piece_material(self: *Evaluat, piece: types.Piece) void {
        const piece_type_idx = get_piece_type_index(piece);
        const color_multiplier: i32 = if (get_piece_color_index(piece) == 0) 1 else -1;

        self.material_mg -= mid_game_material_score[piece_type_idx] * color_multiplier;
        self.material_eg -= end_game_material_score[piece_type_idx] * color_multiplier;
    }

    // Initialize material from board position
    pub fn calculate_initial_material(self: *Evaluat, board: *const types.Board) void {
        self.material_mg = 0;
        self.material_eg = 0;

        // Count all pieces and add their material values
        for (0..types.Board.PieceCount) |i| {
            if (i == @intFromEnum(types.Piece.NO_PIECE)) continue;

            const piece: types.Piece = @enumFromInt(i);
            const count = util.popcount(board.pieces[i]);

            for (0..count) |_| {
                self.add_piece_material(piece);
            }
        }
    }

    // Initialize both phase and material from board
    pub fn calculate_initial_phase_and_material(self: *Evaluat, board: *const types.Board) void {
        self.phase = [1]u8{0} ** 2;
        self.material_mg = 0;
        self.material_eg = 0;

        // Count white pieces
        for (0..6) |piece_type| {
            const white_piece: types.Piece = @enumFromInt(piece_type);
            const piece_count: u8 = @intCast(util.popcount(board.pieces[@intFromEnum(white_piece)]));
            self.phase[0] += game_phase_inc[piece_type] * piece_count;

            // Add material
            for (0..piece_count) |_| {
                self.add_piece_material(white_piece);
            }
        }

        // Count black pieces
        for (0..6) |piece_type| {
            const black_piece: types.Piece = @enumFromInt(piece_type + 8);
            const piece_count: u8 = @intCast(util.popcount(board.pieces[@intFromEnum(black_piece)]));
            self.phase[1] += game_phase_inc[piece_type] * piece_count;

            // Add material
            for (0..piece_count) |_| {
                self.add_piece_material(black_piece);
            }
        }
    }

    pub inline fn put_piece_phase(self: *Evaluat, piece: types.Piece) void {
        const piece_type_idx = get_piece_type_index(piece);
        const color_idx = get_piece_color_index(piece);

        self.phase[color_idx] += game_phase_inc[piece_type_idx];
    }

    pub inline fn remove_piece_phase(self: *Evaluat, piece: types.Piece) void {
        const piece_type_idx = get_piece_type_index(piece);
        const color_idx = get_piece_color_index(piece);

        if (self.phase[color_idx] >= game_phase_inc[piece_type_idx]) {
            self.phase[color_idx] -= game_phase_inc[piece_type_idx];
        }
    }

    pub inline fn move_piece_phase(self: *Evaluat, captured_piece: types.Piece) void {
        // Only update for captured piece (moving piece doesn't change phase)
        if (captured_piece != types.Piece.NO_PIECE) {
            self.remove_piece_phase(captured_piece);
        }
    }

    // Calculate initial phase from board
    pub fn calculate_initial_phase(self: *Evaluat, board: *const types.Board) void {
        self.phase = [1]u8{0} ** 2;

        // Count white pieces
        for (0..6) |piece_type| {
            const white_piece: types.Piece = @enumFromInt(piece_type);
            const piece_count: u8 = @intCast(util.popcount(board.pieces[@intFromEnum(white_piece)]));
            self.phase[0] += game_phase_inc[piece_type] * piece_count;
        }

        // Count black pieces
        for (0..6) |piece_type| {
            const black_piece: types.Piece = @enumFromInt(piece_type + 8);
            const piece_count: u8 = @intCast(util.popcount(board.pieces[@intFromEnum(black_piece)]));
            self.phase[1] += game_phase_inc[piece_type] * piece_count;
        }
    }

    pub fn hce_eval(self: Evaluat, board: types.Board, comptime color: types.Color) i32 {
        if (Evaluat.is_draw(board)) {
            return 0;
        }

        const phase: i32 = @intCast(@min(self.phase[types.Color.White.toU4()] + self.phase[types.Color.Black.toU4()], 64));

        var mid_game_eval = self.mid_game_eval + self.material_mg;
        var end_game_eval = self.end_game_eval + self.material_eg;

        const pieces_score: [2]i32 = evaluate_peace(&board);

        mid_game_eval += pieces_score[0];
        end_game_eval += pieces_score[1];

        var score: i32 = @divTrunc((mid_game_eval * phase + end_game_eval * (64 - phase)), 64);
        const tempo_bonus: i32 = @divTrunc(mid_game_tempo_bonus * phase + end_game_tempo_bonus * (64 - phase), 64);

        score += evaluate_special_endgames(self, &board);

        return if (color == types.Color.White) score + tempo_bonus else -(score + tempo_bonus);
    }

    pub fn eval(self: Evaluat, board: types.Board, comptime color: types.Color) i32 {
        if (nnue.use_nnue) {
            // use NNUE to evaluate the board here
            const score = 0;
            return score;
        } else {
            return self.hce_eval(board, color);
        }
    }

    inline fn evaluate_special_endgames(self: Evaluat, board: *const types.Board) i32 {
        var endgame_bonus: i32 = 0;

        const white_phase = self.phase[types.Color.White.toU4()];
        const black_phase = self.phase[types.Color.Black.toU4()];

        // White winning
        if (white_phase >= 3 and black_phase == 0 and util.popcount(board.pieces[@intFromEnum(types.Piece.BLACK_PAWN)]) == 0) {
            const white_king_sq = util.lsb_index(board.pieces[@intFromEnum(types.Piece.WHITE_KING)]);
            const black_king_sq = util.lsb_index(board.pieces[@intFromEnum(types.Piece.BLACK_KING)]);

            // Bishop + Knight vs King (phase = 2)
            if (white_phase == 2 and
                util.popcount(board.pieces[@intFromEnum(types.Piece.WHITE_BISHOP)]) == 1 and
                util.popcount(board.pieces[@intFromEnum(types.Piece.WHITE_KNIGHT)]) == 1)
            {

                // Bishop + Knight mate: drive king to correct corner
                const bishop_on_light_squares = (board.pieces[@intFromEnum(types.Piece.WHITE_BISHOP)] & 0x55AA55AA55AA55AA) != 0;

                // Bishop + Knight mate: drive king to correct corner
                if (bishop_on_light_squares) {
                    const corner_bonus = get_corner_distance_bonus(@intCast(black_king_sq), true);
                    endgame_bonus += corner_bonus;
                } else {
                    const corner_bonus = get_corner_distance_bonus(@intCast(black_king_sq), false);
                    endgame_bonus += corner_bonus;
                }
            } else {
                // Negative because we want enemy king on edge
                endgame_bonus -= CENTER_CONTROL[black_king_sq];
            }

            // Bring kings closer in winning endgames
            const distance = king_distance(@intCast(white_king_sq), @intCast(black_king_sq));
            // Closer is better
            endgame_bonus -= @as(i32, @intCast(distance)) * 5;
        }

        // Black winning endgame
        else if (black_phase >= 3 and white_phase == 0 and util.popcount(board.pieces[@intFromEnum(types.Piece.WHITE_PAWN)]) == 0) {
            const white_king_sq = util.lsb_index(board.pieces[@intFromEnum(types.Piece.WHITE_KING)]);
            const black_king_sq = util.lsb_index(board.pieces[@intFromEnum(types.Piece.BLACK_KING)]);

            // Bishop + Knight vs King
            if (black_phase == 2 and
                util.popcount(board.pieces[@intFromEnum(types.Piece.BLACK_BISHOP)]) == 1 and
                util.popcount(board.pieces[@intFromEnum(types.Piece.BLACK_KNIGHT)]) == 1)
            {
                const bishop_on_light_squares = (board.pieces[@intFromEnum(types.Piece.BLACK_BISHOP)] & 0x55AA55AA55AA55AA) != 0;

                // Bishop + Knight mate: drive king to correct corner Negative because it's good for Black
                if (bishop_on_light_squares) {
                    const corner_bonus = get_corner_distance_bonus(@intCast(white_king_sq), true);
                    endgame_bonus -= corner_bonus;
                } else {
                    const corner_bonus = get_corner_distance_bonus(@intCast(white_king_sq), false);
                    endgame_bonus -= corner_bonus;
                }
            } else {
                // General winning endgame: bring kings closer
                endgame_bonus += CENTER_CONTROL[white_king_sq];
            }

            // Bring kings closer
            const distance = king_distance(@intCast(white_king_sq), @intCast(black_king_sq));
            endgame_bonus += @as(i32, @intCast(distance)) * 5;
        }

        return endgame_bonus;
    }

    inline fn get_corner_distance_bonus(king_sq: u6, light_square_mate: bool) i32 {
        var distance_to_corner: u4 = 14; // Max distance

        // Distance to a8 (rank 7, file 0) or h1 (rank 0, file 7)
        if (light_square_mate) {
            const dist_a8: u4 = king_distance(king_sq, 56);
            const dist_h1: u4 = king_distance(king_sq, 7);
            distance_to_corner = @min(dist_a8, dist_h1);
        } else {
            const dist_a1: u4 = king_distance(king_sq, 0);
            const dist_h8: u4 = king_distance(king_sq, 63);
            distance_to_corner = @min(dist_a1, dist_h8);
        }

        // Bonus for being closer to the correct corner
        return (14 - @as(i32, @intCast(distance_to_corner))) * 10;
    }
    // inspired by https://github.com/jabolcni/Lambergar/blob/822957acfbb2d386c29889cce17b8d88c999e2a1/src/evaluation.zig#L541C1-L1479C2 and added some additional features
    pub fn evaluate_peace(board: *const types.Board) [2]i32 {
        var score = [_]i32{ 0, 0 };

        const white_pawns = board.pieces[types.Piece.WHITE_PAWN.toU4()];
        const white_knight = board.pieces[types.Piece.WHITE_KNIGHT.toU4()];
        const white_bishop = board.pieces[types.Piece.WHITE_BISHOP.toU4()];
        const white_rook = board.pieces[types.Piece.WHITE_ROOK.toU4()];
        const white_queen = board.pieces[types.Piece.WHITE_QUEEN.toU4()];
        const white_king = board.pieces[types.Piece.WHITE_KING.toU4()];
        const white_king_square = if (white_king != 0) util.lsb_index(white_king) else 0;
        const white_king_zone = if (white_king_square < 64) tabeles.King_areas[white_king_square] else 0;
        var white_danger_score: i32 = 0;
        var white_danger_pieces: u5 = 0;
        var white_att: u64 = 0;

        const white_pawn_attacks = attacks.pawn_attacks_from_bitboard(types.Color.White, white_pawns);

        const black_pawns = board.pieces[types.Piece.BLACK_PAWN.toU4()];
        const black_knight = board.pieces[types.Piece.BLACK_KNIGHT.toU4()];
        const black_bishop = board.pieces[types.Piece.BLACK_BISHOP.toU4()];
        const black_rook = board.pieces[types.Piece.BLACK_ROOK.toU4()];
        const black_queen = board.pieces[types.Piece.BLACK_QUEEN.toU4()];
        const black_king = board.pieces[types.Piece.BLACK_KING.toU4()];
        const black_king_square = if (black_king != 0) util.lsb_index(black_king) else 0;
        const black_king_zone = if (black_king_square < 64) tabeles.King_areas[black_king_square] else 0;
        var black_danger_score: i32 = 0;
        var black_danger_pieces: u5 = 0;
        var black_att: u64 = 0;

        const black_pawn_attacks = attacks.pawn_attacks_from_bitboard(types.Color.Black, black_pawns);

        const occ = board.pieces_combined();

        const white_pieces = board.pieces[types.Piece.WHITE_PAWN.toU4()] |
            board.pieces[types.Piece.WHITE_KNIGHT.toU4()] |
            board.pieces[types.Piece.WHITE_BISHOP.toU4()] |
            board.pieces[types.Piece.WHITE_ROOK.toU4()] |
            board.pieces[types.Piece.WHITE_QUEEN.toU4()] |
            board.pieces[types.Piece.WHITE_KING.toU4()];
        const black_pieces = board.pieces[types.Piece.BLACK_PAWN.toU4()] |
            board.pieces[types.Piece.BLACK_KNIGHT.toU4()] |
            board.pieces[types.Piece.BLACK_BISHOP.toU4()] |
            board.pieces[types.Piece.BLACK_ROOK.toU4()] |
            board.pieces[types.Piece.BLACK_QUEEN.toU4()] |
            board.pieces[types.Piece.BLACK_KING.toU4()];
        var pawn_structure_score = [_]i32{ 0, 0 };
        var threat_score = [_]i32{ 0, 0 };
        var king_score = [_]i32{ 0, 0 };
        var additional_material_score = [_]i32{ 0, 0 };
        var mobility_score = [_]i32{ 0, 0 };

        // check if pawn is passed
        const isPassedPawn = struct {
            fn call(pawn_sq: u6, color: types.Color, enemy_pawns: u64, own_pawns: u64) bool {
                const file: u6 = @intCast(pawn_sq % 8);
                const rank: u6 = @intCast(pawn_sq / 8);

                // Create masks for files and ranks in front of pawn
                var front_mask: u64 = 0;
                var file_mask: u64 = 0;

                if (color == types.Color.White) {
                    // White pawns move up (increasing rank)
                    for (rank + 1..8) |r| {
                        file_mask |= types.squar_bb[r * 8 + file];
                        if (file > 0) file_mask |= types.squar_bb[r * 8 + (file - 1)];
                        if (file < 7) file_mask |= types.squar_bb[r * 8 + (file + 1)];
                    }
                    // Check no enemy pawns block or attack the path
                    front_mask = file_mask & enemy_pawns;
                    // Also check no friendly pawns in front
                    const front_file = types.mask_file[file] & ~((@as(u64, 1) << @intCast(pawn_sq)) - 1);
                    return front_mask == 0 and (own_pawns & front_file) == types.squar_bb[pawn_sq];
                } else {
                    // Black pawns move down (decreasing rank)
                    var r: i8 = @intCast(rank);
                    r -= 1;
                    while (r >= 0) : (r -= 1) {
                        const ur: u6 = @intCast(r);
                        file_mask |= types.squar_bb[ur * 8 + file];
                        if (file > 0) file_mask |= types.squar_bb[ur * 8 + (file - 1)];
                        if (file < 7) file_mask |= types.squar_bb[ur * 8 + (file + 1)];
                    }
                    front_mask = file_mask & enemy_pawns;
                    const front_file = types.mask_file[file] & ((@as(u64, 1) << @intCast(pawn_sq + 1)) - 1);
                    return front_mask == 0 and (own_pawns & front_file) == types.squar_bb[pawn_sq];
                }
            }
        }.call;

        // check if pawn is isolated
        const isIsolatedPawn = struct {
            fn call(pawn_sq: u6, own_pawns: u64) bool {
                const file: u6 = @intCast(pawn_sq % 8);
                var adjacent_files: u64 = 0;
                if (file > 0) adjacent_files |= types.mask_file[file - 1];
                if (file < 7) adjacent_files |= types.mask_file[file + 1];
                return (own_pawns & adjacent_files) == 0;
            }
        }.call;

        //check if square is outpost
        const isOutpost = struct {
            fn call(sq: u6, color: types.Color, enemy_pawns: u64, own_pawn_attacks: u64) bool {
                const file: u6 = @intCast(sq % 8);
                const rank: u6 = @intCast(sq / 8);

                // Must be in enemy territory and defended by own pawn
                if (color == types.Color.White and rank < 4) return false;
                if (color == types.Color.Black and rank > 3) return false;
                if ((own_pawn_attacks & types.squar_bb[sq]) == 0) return false;

                // No enemy pawns can attack this square
                var attack_mask: u64 = 0;
                if (color == types.Color.White) {
                    // Check if black pawns can attack this square
                    if (file > 0 and rank > 0) attack_mask |= types.squar_bb[(rank - 1) * 8 + (file - 1)];
                    if (file < 7 and rank > 0) attack_mask |= types.squar_bb[(rank - 1) * 8 + (file + 1)];
                } else {
                    if (file > 0 and rank < 7) attack_mask |= types.squar_bb[(rank + 1) * 8 + (file - 1)];
                    if (file < 7 and rank < 7) attack_mask |= types.squar_bb[(rank + 1) * 8 + (file + 1)];
                }
                return (enemy_pawns & attack_mask) == 0;
            }
        }.call;

        // White pawns
        var pc_bb = white_pawns;
        while (pc_bb != 0) {
            const sq: u6 = @intCast(util.lsb_index(pc_bb));
            pc_bb &= pc_bb - 1;

            const file: u6 = @intCast(sq % 8);
            const rank: u6 = @intCast(sq / 8);

            // Get attacks & update king danger scores
            const att = attacks.pawn_attacks_from_square(sq, types.Color.White) & ~white_pieces;
            white_att |= att;
            if ((black_king_zone & att) != 0) {
                black_danger_score += 1;
                black_danger_pieces += 1;
            }

            // Isolated pawn evaluation
            if (isIsolatedPawn(sq, white_pawns)) {
                const tmp_sc = get_isolated_pawn_score(file);
                pawn_structure_score[0] += tmp_sc[0];
                pawn_structure_score[1] += tmp_sc[1];
            }

            // Passed pawn evaluation
            if (isPassedPawn(sq, types.Color.White, black_pawns, white_pawns)) {
                var tmp_sc = get_passed_pawn_score(sq);
                pawn_structure_score[0] += tmp_sc[0];
                pawn_structure_score[1] += tmp_sc[1];

                // Check if passed pawn is blocked
                if (rank < 7 and (types.squar_bb[sq + 8] & black_pieces) != 0) {
                    tmp_sc = get_blocked_passer_score(rank);
                    pawn_structure_score[0] += tmp_sc[0];
                    pawn_structure_score[1] += tmp_sc[1];
                }
            }

            // Pawn is supported?
            if ((white_pawn_attacks & types.squar_bb[sq]) != 0) {
                const tmp_sc = get_supported_pawn_bonus(rank);
                pawn_structure_score[0] += tmp_sc[0];
                pawn_structure_score[1] += tmp_sc[1];
            }

            // Pawn phalanx (adjacent pawns on same rank)
            if (file < 7 and (white_pawns & types.squar_bb[sq + 1]) != 0) {
                const tmp_sc = get_phalanx_score(rank);
                pawn_structure_score[0] += tmp_sc[0];
                pawn_structure_score[1] += tmp_sc[1];
            }

            // Threats
            var b1 = att & black_knight;
            if (b1 != 0) {
                const tmp_sc = get_pawn_threat(types.PieceType.Knight);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] += tmp_sc[0] * tmp_count;
                threat_score[1] += tmp_sc[1] * tmp_count;
            }
            b1 = att & black_bishop;
            if (b1 != 0) {
                const tmp_sc = get_pawn_threat(types.PieceType.Bishop);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] += tmp_sc[0] * tmp_count;
                threat_score[1] += tmp_sc[1] * tmp_count;
            }
            b1 = att & black_rook;
            if (b1 != 0) {
                const tmp_sc = get_pawn_threat(types.PieceType.Rook);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] += tmp_sc[0] * tmp_count;
                threat_score[1] += tmp_sc[1] * tmp_count;
            }
            b1 = att & black_queen;
            if (b1 != 0) {
                const tmp_sc = get_pawn_threat(types.PieceType.Queen);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] += tmp_sc[0] * tmp_count;
                threat_score[1] += tmp_sc[1] * tmp_count;
            }
        }

        // Black pawns
        pc_bb = black_pawns;
        while (pc_bb != 0) {
            const sq: u6 = @intCast(util.lsb_index(pc_bb));
            pc_bb &= pc_bb - 1;

            const file: u6 = @intCast(sq % 8);
            const rank: u6 = @intCast(sq / 8);

            // Get attacks & update king danger scores
            const att = attacks.pawn_attacks_from_square(sq, types.Color.Black) & ~black_pieces;
            black_att |= att;
            if ((white_king_zone & att) != 0) {
                white_danger_score += 1;
                white_danger_pieces += 1;
            }

            // Isolated pawn evaluation
            if (isIsolatedPawn(sq, black_pawns)) {
                const tmp_sc = get_isolated_pawn_score(file);
                pawn_structure_score[0] -= tmp_sc[0];
                pawn_structure_score[1] -= tmp_sc[1];
            }

            // Passed pawn evaluation
            if (isPassedPawn(sq, types.Color.Black, white_pawns, black_pawns)) {
                var tmp_sc = get_passed_pawn_score(sq ^ 56); // Flip for black
                pawn_structure_score[0] -= tmp_sc[0];
                pawn_structure_score[1] -= tmp_sc[1];

                // Check if passed pawn is blocked
                if (rank > 0 and (types.squar_bb[sq - 8] & white_pieces) != 0) {
                    tmp_sc = get_blocked_passer_score(7 - rank);
                    pawn_structure_score[0] -= tmp_sc[0];
                    pawn_structure_score[1] -= tmp_sc[1];
                }
            }

            // Pawn is supported?
            if ((black_pawn_attacks & types.squar_bb[sq]) != 0) {
                const tmp_sc = get_supported_pawn_bonus(7 - rank);
                pawn_structure_score[0] -= tmp_sc[0];
                pawn_structure_score[1] -= tmp_sc[1];
            }

            // Pawn phalanx
            if (file < 7 and (black_pawns & types.squar_bb[sq + 1]) != 0) {
                const tmp_sc = get_phalanx_score(7 - rank);
                pawn_structure_score[0] -= tmp_sc[0];
                pawn_structure_score[1] -= tmp_sc[1];
            }

            // Threats
            var b1 = att & white_knight;
            if (b1 != 0) {
                const tmp_sc = get_pawn_threat(types.PieceType.Knight);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] -= tmp_sc[0] * tmp_count;
                threat_score[1] -= tmp_sc[1] * tmp_count;
            }
            b1 = att & white_bishop;
            if (b1 != 0) {
                const tmp_sc = get_pawn_threat(types.PieceType.Bishop);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] -= tmp_sc[0] * tmp_count;
                threat_score[1] -= tmp_sc[1] * tmp_count;
            }
            b1 = att & white_rook;
            if (b1 != 0) {
                const tmp_sc = get_pawn_threat(types.PieceType.Rook);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] -= tmp_sc[0] * tmp_count;
                threat_score[1] -= tmp_sc[1] * tmp_count;
            }
            b1 = att & white_queen;
            if (b1 != 0) {
                const tmp_sc = get_pawn_threat(types.PieceType.Queen);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] -= tmp_sc[0] * tmp_count;
                threat_score[1] -= tmp_sc[1] * tmp_count;
            }
        }

        // White knights
        pc_bb = white_knight;
        while (pc_bb != 0) {
            const sq: u6 = @intCast(util.lsb_index(pc_bb));
            pc_bb &= pc_bb - 1;

            const att = attacks.piece_attacks(sq, occ, types.PieceType.Knight);
            const mobility = att & ~white_pieces;
            white_att |= mobility;
            const index: u7 = @intCast(util.popcount(mobility & ~black_pawn_attacks));
            var tmp_sc = get_knight_mobility_score(index);
            mobility_score[0] += tmp_sc[0];
            mobility_score[1] += tmp_sc[1];

            if ((black_king_zone & mobility) != 0) {
                black_danger_score += 2;
                black_danger_pieces += 1;
            }

            // Knight on outpost
            if (isOutpost(sq, types.Color.White, black_pawns, white_pawn_attacks)) {
                const outpost_bonus = [_]i32{ 25, 15 }; // mg, eg
                additional_material_score[0] += outpost_bonus[0];
                additional_material_score[1] += outpost_bonus[1];
            }

            // Knight on rim penalty
            const file: u6 = @intCast(sq % 8);
            const rank: u6 = @intCast(sq / 8);
            if (file == 0 or file == 7 or rank == 0 or rank == 7) {
                const rim_penalty = [_]i32{ -15, -5 }; // mg, eg
                additional_material_score[0] += rim_penalty[0];
                additional_material_score[1] += rim_penalty[1];
            }

            // Threats
            var b1 = mobility & black_pawns;
            if (b1 != 0) {
                tmp_sc = get_knight_threat(types.PieceType.Pawn);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] += tmp_sc[0] * tmp_count;
                threat_score[1] += tmp_sc[1] * tmp_count;
            }
            b1 = mobility & black_bishop;
            if (b1 != 0) {
                tmp_sc = get_knight_threat(types.PieceType.Bishop);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] += tmp_sc[0] * tmp_count;
                threat_score[1] += tmp_sc[1] * tmp_count;
            }
            b1 = mobility & black_rook;
            if (b1 != 0) {
                tmp_sc = get_knight_threat(types.PieceType.Rook);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] += tmp_sc[0] * tmp_count;
                threat_score[1] += tmp_sc[1] * tmp_count;
            }
            b1 = mobility & black_queen;
            if (b1 != 0) {
                tmp_sc = get_knight_threat(types.PieceType.Queen);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] += tmp_sc[0] * tmp_count;
                threat_score[1] += tmp_sc[1] * tmp_count;
            }
        }

        // Black knights
        pc_bb = black_knight;
        while (pc_bb != 0) {
            const sq: u6 = @intCast(util.lsb_index(pc_bb));
            pc_bb &= pc_bb - 1;

            const att = attacks.piece_attacks(sq, occ, types.PieceType.Knight);
            const mobility = att & ~black_pieces;
            black_att |= mobility;
            const index: u7 = @intCast(util.popcount(mobility & ~white_pawn_attacks));
            var tmp_sc = get_knight_mobility_score(index);
            mobility_score[0] -= tmp_sc[0];
            mobility_score[1] -= tmp_sc[1];

            if ((white_king_zone & mobility) != 0) {
                white_danger_score += 2;
                white_danger_pieces += 1;
            }

            // Knight on outpost
            if (isOutpost(sq, types.Color.Black, white_pawns, black_pawn_attacks)) {
                const outpost_bonus = [_]i32{ 25, 15 }; // mg, eg
                additional_material_score[0] -= outpost_bonus[0];
                additional_material_score[1] -= outpost_bonus[1];
            }

            // Knight on rim penalty
            const file: u6 = @intCast(sq % 8);
            const rank: u6 = @intCast(sq / 8);
            if (file == 0 or file == 7 or rank == 0 or rank == 7) {
                const rim_penalty = [_]i32{ -15, -5 }; // mg, eg
                additional_material_score[0] -= rim_penalty[0];
                additional_material_score[1] -= rim_penalty[1];
            }

            // Threats
            var b1 = mobility & white_pawns;
            if (b1 != 0) {
                tmp_sc = get_knight_threat(types.PieceType.Pawn);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] -= tmp_sc[0] * tmp_count;
                threat_score[1] -= tmp_sc[1] * tmp_count;
            }
            b1 = mobility & white_bishop;
            if (b1 != 0) {
                tmp_sc = get_knight_threat(types.PieceType.Bishop);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] -= tmp_sc[0] * tmp_count;
                threat_score[1] -= tmp_sc[1] * tmp_count;
            }
            b1 = mobility & white_rook;
            if (b1 != 0) {
                tmp_sc = get_knight_threat(types.PieceType.Rook);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] -= tmp_sc[0] * tmp_count;
                threat_score[1] -= tmp_sc[1] * tmp_count;
            }
            b1 = mobility & white_queen;
            if (b1 != 0) {
                tmp_sc = get_knight_threat(types.PieceType.Queen);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] -= tmp_sc[0] * tmp_count;
                threat_score[1] -= tmp_sc[1] * tmp_count;
            }
        }

        // White bishops
        pc_bb = white_bishop;
        while (pc_bb != 0) {
            const sq: u6 = @intCast(util.lsb_index(pc_bb));
            pc_bb &= pc_bb - 1;

            const att = attacks.get_bishop_attacks(sq, occ);
            const mobility = att & ~white_pieces;
            white_att |= mobility;
            const index: u7 = @intCast(util.popcount(mobility & ~black_pawn_attacks));
            var tmp_sc = get_bishop_mobility_score(index);
            mobility_score[0] += tmp_sc[0];
            mobility_score[1] += tmp_sc[1];

            if ((black_king_zone & mobility) != 0) {
                black_danger_score += 2;
                black_danger_pieces += 1;
            }

            // Bishop on outpost
            if (isOutpost(sq, types.Color.White, black_pawns, white_pawn_attacks)) {
                const outpost_bonus = [_]i32{ 20, 10 }; // mg, eg
                additional_material_score[0] += outpost_bonus[0];
                additional_material_score[1] += outpost_bonus[1];
            }

            // Bad bishop (blocked by own pawns)
            const bishop_color = (@as(u8, sq) + (@as(u8, sq) / 8)) & 1;
            var blocked_pawns: u64 = 0;
            if (bishop_color == 0) {
                // Dark squared bishop - count own pawns on dark squares
                blocked_pawns = white_pawns & 0xAA55AA55AA55AA55;
            } else {
                // Light squared bishop - count own pawns on light squares
                blocked_pawns = white_pawns & 0x55AA55AA55AA55AA;
            }
            const blocked_count: i32 = @intCast(util.popcount(blocked_pawns));
            if (blocked_count > 4) {
                const bad_bishop_penalty = [_]i32{ -3 * blocked_count, -2 * blocked_count };
                additional_material_score[0] += bad_bishop_penalty[0];
                additional_material_score[1] += bad_bishop_penalty[1];
            }

            // Threats
            var b1 = mobility & black_pawns;
            if (b1 != 0) {
                tmp_sc = get_bishop_threat(types.PieceType.Pawn);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] += tmp_sc[0] * tmp_count;
                threat_score[1] += tmp_sc[1] * tmp_count;
            }
            b1 = mobility & black_knight;
            if (b1 != 0) {
                tmp_sc = get_bishop_threat(types.PieceType.Knight);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] += tmp_sc[0] * tmp_count;
                threat_score[1] += tmp_sc[1] * tmp_count;
            }
            b1 = mobility & black_rook;
            if (b1 != 0) {
                tmp_sc = get_bishop_threat(types.PieceType.Rook);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] += tmp_sc[0] * tmp_count;
                threat_score[1] += tmp_sc[1] * tmp_count;
            }
            b1 = mobility & black_queen;
            if (b1 != 0) {
                tmp_sc = get_bishop_threat(types.PieceType.Queen);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] += tmp_sc[0] * tmp_count;
                threat_score[1] += tmp_sc[1] * tmp_count;
            }
        }

        // Black bishops
        pc_bb = black_bishop;
        while (pc_bb != 0) {
            const sq: u6 = @intCast(util.lsb_index(pc_bb));
            pc_bb &= pc_bb - 1;

            const att = attacks.get_bishop_attacks(sq, occ);
            const mobility = att & ~black_pieces;
            black_att |= mobility;
            const index: u7 = @intCast(util.popcount(mobility & ~white_pawn_attacks));
            var tmp_sc = get_bishop_mobility_score(index);
            mobility_score[0] -= tmp_sc[0];
            mobility_score[1] -= tmp_sc[1];

            if ((white_king_zone & mobility) != 0) {
                white_danger_score += 2;
                white_danger_pieces += 1;
            }

            // Bishop on outpost
            if (isOutpost(sq, types.Color.Black, white_pawns, black_pawn_attacks)) {
                const outpost_bonus = [_]i32{ 20, 10 }; // mg, eg
                additional_material_score[0] -= outpost_bonus[0];
                additional_material_score[1] -= outpost_bonus[1];
            }

            // Bad bishop
            const bishop_color = (@as(u8, sq) + (@as(u8, sq) / 8)) & 1;
            var blocked_pawns: u64 = 0;
            if (bishop_color == 0) {
                blocked_pawns = black_pawns & 0xAA55AA55AA55AA55;
            } else {
                blocked_pawns = black_pawns & 0x55AA55AA55AA55AA;
            }
            const blocked_count: i32 = @intCast(util.popcount(blocked_pawns));
            if (blocked_count > 4) {
                const bad_bishop_penalty = [_]i32{ -3 * blocked_count, -2 * blocked_count };
                additional_material_score[0] -= bad_bishop_penalty[0];
                additional_material_score[1] -= bad_bishop_penalty[1];
            }

            // Threats
            var b1 = mobility & white_pawns;
            if (b1 != 0) {
                tmp_sc = get_bishop_threat(types.PieceType.Pawn);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] -= tmp_sc[0] * tmp_count;
                threat_score[1] -= tmp_sc[1] * tmp_count;
            }
            b1 = mobility & white_knight;
            if (b1 != 0) {
                tmp_sc = get_bishop_threat(types.PieceType.Knight);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] -= tmp_sc[0] * tmp_count;
                threat_score[1] -= tmp_sc[1] * tmp_count;
            }
            b1 = mobility & white_rook;
            if (b1 != 0) {
                tmp_sc = get_bishop_threat(types.PieceType.Rook);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] -= tmp_sc[0] * tmp_count;
                threat_score[1] -= tmp_sc[1] * tmp_count;
            }
            b1 = mobility & white_queen;
            if (b1 != 0) {
                tmp_sc = get_bishop_threat(types.PieceType.Queen);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] -= tmp_sc[0] * tmp_count;
                threat_score[1] -= tmp_sc[1] * tmp_count;
            }
        }

        // White rooks
        pc_bb = white_rook;
        while (pc_bb != 0) {
            const sq: u6 = @intCast(util.lsb_index(pc_bb));
            pc_bb &= pc_bb - 1;

            const file: u6 = @intCast(sq % 8);
            const rank: u6 = @intCast(sq / 8);

            const att = attacks.get_rook_attacks(sq, occ);
            const mobility = att & ~white_pieces;
            white_att |= mobility;
            const index: u7 = @intCast(util.popcount(mobility & ~black_pawn_attacks));
            var tmp_sc = get_rook_mobility_score(index);
            mobility_score[0] += tmp_sc[0];
            mobility_score[1] += tmp_sc[1];

            if ((black_king_zone & mobility) != 0) {
                black_danger_score += 3;
                black_danger_pieces += 1;
            }

            // Rook on open/semi-open file
            const file_mask = types.mask_file[file];
            const white_pawns_on_file = util.popcount(white_pawns & file_mask);
            const black_pawns_on_file = util.popcount(black_pawns & file_mask);

            if (white_pawns_on_file == 0) {
                if (black_pawns_on_file == 0) {
                    // Open file
                    const open_file_bonus = [_]i32{ 30, 15 }; // mg, eg
                    additional_material_score[0] += open_file_bonus[0];
                    additional_material_score[1] += open_file_bonus[1];
                } else {
                    // Semi-open file
                    const semi_open_bonus = [_]i32{ 15, 8 }; // mg, eg
                    additional_material_score[0] += semi_open_bonus[0];
                    additional_material_score[1] += semi_open_bonus[1];
                }
            }

            // Rook on 7th rank
            if (rank == 6 and util.popcount(black_pawns & types.mask_rank[6]) > 0) {
                const seventh_rank_bonus = [_]i32{ 25, 35 }; // mg, eg
                additional_material_score[0] += seventh_rank_bonus[0];
                additional_material_score[1] += seventh_rank_bonus[1];
            }

            // Threats
            var b1 = mobility & black_pawns;
            if (b1 != 0) {
                tmp_sc = get_rook_threat(types.PieceType.Pawn);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] += tmp_sc[0] * tmp_count;
                threat_score[1] += tmp_sc[1] * tmp_count;
            }
            b1 = mobility & black_knight;
            if (b1 != 0) {
                tmp_sc = get_rook_threat(types.PieceType.Knight);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] += tmp_sc[0] * tmp_count;
                threat_score[1] += tmp_sc[1] * tmp_count;
            }
            b1 = mobility & black_bishop;
            if (b1 != 0) {
                tmp_sc = get_rook_threat(types.PieceType.Bishop);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] += tmp_sc[0] * tmp_count;
                threat_score[1] += tmp_sc[1] * tmp_count;
            }
            b1 = mobility & black_queen;
            if (b1 != 0) {
                tmp_sc = get_rook_threat(types.PieceType.Queen);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] += tmp_sc[0] * tmp_count;
                threat_score[1] += tmp_sc[1] * tmp_count;
            }
        }

        // Black rooks
        pc_bb = black_rook;
        while (pc_bb != 0) {
            const sq: u6 = @intCast(util.lsb_index(pc_bb));
            pc_bb &= pc_bb - 1;

            const file: u6 = @intCast(sq % 8);
            const rank: u6 = @intCast(sq / 8);

            const att = attacks.get_rook_attacks(sq, occ);
            const mobility = att & ~black_pieces;
            black_att |= mobility;
            const index: u7 = @intCast(util.popcount(mobility & ~white_pawn_attacks));
            var tmp_sc = get_rook_mobility_score(index);
            mobility_score[0] -= tmp_sc[0];
            mobility_score[1] -= tmp_sc[1];

            if ((white_king_zone & mobility) != 0) {
                white_danger_score += 3;
                white_danger_pieces += 1;
            }

            // Rook on open/semi-open file
            const file_mask = types.mask_file[file];
            const white_pawns_on_file = util.popcount(white_pawns & file_mask);
            const black_pawns_on_file = util.popcount(black_pawns & file_mask);

            if (black_pawns_on_file == 0) {
                if (white_pawns_on_file == 0) {
                    // Open file
                    const open_file_bonus = [_]i32{ 30, 15 }; // mg, eg
                    additional_material_score[0] -= open_file_bonus[0];
                    additional_material_score[1] -= open_file_bonus[1];
                } else {
                    // Semi-open file
                    const semi_open_bonus = [_]i32{ 15, 8 }; // mg, eg
                    additional_material_score[0] -= semi_open_bonus[0];
                    additional_material_score[1] -= semi_open_bonus[1];
                }
            }

            // Rook on 2nd rank
            if (rank == 1 and util.popcount(white_pawns & types.mask_rank[1]) > 0) {
                const second_rank_bonus = [_]i32{ 25, 35 }; // mg, eg
                additional_material_score[0] -= second_rank_bonus[0];
                additional_material_score[1] -= second_rank_bonus[1];
            }

            // Threats
            var b1 = mobility & white_pawns;
            if (b1 != 0) {
                tmp_sc = get_rook_threat(types.PieceType.Pawn);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] -= tmp_sc[0] * tmp_count;
                threat_score[1] -= tmp_sc[1] * tmp_count;
            }
            b1 = mobility & white_knight;
            if (b1 != 0) {
                tmp_sc = get_rook_threat(types.PieceType.Knight);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] -= tmp_sc[0] * tmp_count;
                threat_score[1] -= tmp_sc[1] * tmp_count;
            }
            b1 = mobility & white_bishop;
            if (b1 != 0) {
                tmp_sc = get_rook_threat(types.PieceType.Bishop);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] -= tmp_sc[0] * tmp_count;
                threat_score[1] -= tmp_sc[1] * tmp_count;
            }
            b1 = mobility & white_queen;
            if (b1 != 0) {
                tmp_sc = get_rook_threat(types.PieceType.Queen);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] -= tmp_sc[0] * tmp_count;
                threat_score[1] -= tmp_sc[1] * tmp_count;
            }
        }

        // White queens
        pc_bb = white_queen;
        while (pc_bb != 0) {
            const sq: u6 = @intCast(util.lsb_index(pc_bb));
            pc_bb &= pc_bb - 1;

            const att = attacks.get_queen_attacks(sq, occ);
            const mobility = att & ~white_pieces;
            white_att |= mobility;
            const index: u7 = @intCast(util.popcount(mobility & ~black_pawn_attacks));
            var tmp_sc = get_queen_mobility_score(index);
            mobility_score[0] += tmp_sc[0];
            mobility_score[1] += tmp_sc[1];

            if ((black_king_zone & mobility) != 0) {
                black_danger_score += 5;
                black_danger_pieces += 1;
            }

            // Threats
            var b1 = mobility & black_pawns;
            if (b1 != 0) {
                tmp_sc = get_queen_threat(types.PieceType.Pawn);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] += tmp_sc[0] * tmp_count;
                threat_score[1] += tmp_sc[1] * tmp_count;
            }
            b1 = mobility & black_knight;
            if (b1 != 0) {
                tmp_sc = get_queen_threat(types.PieceType.Knight);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] += tmp_sc[0] * tmp_count;
                threat_score[1] += tmp_sc[1] * tmp_count;
            }
            b1 = mobility & black_bishop;
            if (b1 != 0) {
                tmp_sc = get_queen_threat(types.PieceType.Bishop);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] += tmp_sc[0] * tmp_count;
                threat_score[1] += tmp_sc[1] * tmp_count;
            }
            b1 = mobility & black_rook;
            if (b1 != 0) {
                tmp_sc = get_queen_threat(types.PieceType.Rook);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] += tmp_sc[0] * tmp_count;
                threat_score[1] += tmp_sc[1] * tmp_count;
            }
        }

        // Black queens
        pc_bb = black_queen;
        while (pc_bb != 0) {
            const sq: u6 = @intCast(util.lsb_index(pc_bb));
            pc_bb &= pc_bb - 1;

            const att = attacks.get_queen_attacks(sq, occ);
            const mobility = att & ~black_pieces;
            black_att |= mobility;
            const index: u7 = @intCast(util.popcount(mobility & ~white_pawn_attacks));
            var tmp_sc = get_queen_mobility_score(index);
            mobility_score[0] -= tmp_sc[0];
            mobility_score[1] -= tmp_sc[1];

            if ((white_king_zone & mobility) != 0) {
                white_danger_score += 5;
                white_danger_pieces += 1;
            }

            // Threats
            var b1 = mobility & white_pawns;
            if (b1 != 0) {
                tmp_sc = get_queen_threat(types.PieceType.Pawn);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] -= tmp_sc[0] * tmp_count;
                threat_score[1] -= tmp_sc[1] * tmp_count;
            }
            b1 = mobility & white_knight;
            if (b1 != 0) {
                tmp_sc = get_queen_threat(types.PieceType.Knight);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] -= tmp_sc[0] * tmp_count;
                threat_score[1] -= tmp_sc[1] * tmp_count;
            }
            b1 = mobility & white_bishop;
            if (b1 != 0) {
                tmp_sc = get_queen_threat(types.PieceType.Bishop);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] -= tmp_sc[0] * tmp_count;
                threat_score[1] -= tmp_sc[1] * tmp_count;
            }
            b1 = mobility & white_rook;
            if (b1 != 0) {
                tmp_sc = get_queen_threat(types.PieceType.Rook);
                const tmp_count: i32 = @intCast(util.popcount(b1));
                threat_score[0] -= tmp_sc[0] * tmp_count;
                threat_score[1] -= tmp_sc[1] * tmp_count;
            }
        }

        // King safety with pawn shelter
        const danger_multipliers = [_]i32{ 0, 50, 70, 80, 90, 95, 98, 100 };

        // Evaluate pawn shelter for white king
        const white_king_file: u6 = @intCast(white_king_square % 8);
        var white_shelter_penalty: i32 = 0;
        for (0..3) |i| {
            const check_file: i6 = @as(i6, @intCast(white_king_file)) + @as(i6, @intCast(i)) - 1;
            if (check_file >= 0 and check_file < 8) {
                const file_mask = types.mask_file[@intCast(check_file)];
                const pawns_in_front = white_pawns & file_mask & ~((@as(u64, 1) << @intCast(white_king_square + 8)) - 1);
                if (pawns_in_front == 0) {
                    white_shelter_penalty += 20;
                }
            }
        }

        // Evaluate pawn shelter for black king
        const black_king_file: u6 = @intCast(black_king_square % 8);
        var black_shelter_penalty: i32 = 0;
        for (0..3) |i| {
            const check_file: i6 = @as(i6, @intCast(black_king_file)) + @as(i6, @intCast(i)) - 1;
            if (check_file >= 0 and check_file < 8) {
                const file_mask = types.mask_file[@intCast(check_file)];
                const pawns_in_front = black_pawns & file_mask & ((@as(u64, 1) << @intCast(black_king_square)) - 1);
                if (pawns_in_front == 0) {
                    black_shelter_penalty += 20;
                }
            }
        }

        const white_king_safety_final = @divTrunc((white_danger_score + white_shelter_penalty) * danger_multipliers[@min(white_danger_pieces, 7)], 100);
        const black_king_safety_final = @divTrunc((black_danger_score + black_shelter_penalty) * danger_multipliers[@min(black_danger_pieces, 7)], 100);

        if (white_king_safety_final > 0) {
            king_score[0] -= white_king_safety_final;
            king_score[1] -= white_king_safety_final;
        }
        if (black_king_safety_final > 0) {
            king_score[0] += black_king_safety_final;
            king_score[1] += black_king_safety_final;
        }

        // Bishop pair bonus
        const white_bishop_count = util.popcount(white_bishop);
        const black_bishop_count = util.popcount(black_bishop);

        if (white_bishop_count >= 2) {
            const tmp_sc = [_]i32{ 12, 46 };
            additional_material_score[0] += tmp_sc[0];
            additional_material_score[1] += tmp_sc[1];
        }
        if (black_bishop_count >= 2) {
            const tmp_sc = [_]i32{ 12, 46 };
            additional_material_score[0] -= tmp_sc[0];
            additional_material_score[1] -= tmp_sc[1];
        }

        // Doubled pawns
        for (0..8) |i| {
            const file_mask = types.mask_file[i];
            const white_pawns_on_file = util.popcount(white_pawns & file_mask);
            const black_pawns_on_file = util.popcount(black_pawns & file_mask);

            if (white_pawns_on_file >= 2) {
                const tmp_sc = [_]i32{ -2, -13 };
                pawn_structure_score[0] += tmp_sc[0];
                pawn_structure_score[1] += tmp_sc[1];
            }
            if (black_pawns_on_file >= 2) {
                const tmp_sc = [_]i32{ -2, -13 };
                pawn_structure_score[0] -= tmp_sc[0];
                pawn_structure_score[1] -= tmp_sc[1];
            }
        }

        // Sum all scores
        score[0] = pawn_structure_score[0] + threat_score[0] + king_score[0] + additional_material_score[0] + mobility_score[0];
        score[1] = pawn_structure_score[1] + threat_score[1] + king_score[1] + additional_material_score[1] + mobility_score[1];

        return score;
    }

    pub inline fn is_draw(board: types.Board) bool {
        const all = board.pieces_combined();
        const king = board.pieces[@intFromEnum(types.Piece.WHITE_KING)] | board.pieces[@intFromEnum(types.Piece.BLACK_KING)];

        // if all pieces are on the king, the board is a draw
        if (all == king) {
            return true;
        }

        // get the pieces
        const white_bishops = board.pieces[@intFromEnum(types.Piece.WHITE_BISHOP)];
        const black_bishops = board.pieces[@intFromEnum(types.Piece.BLACK_BISHOP)];
        const white_knights = board.pieces[@intFromEnum(types.Piece.WHITE_KNIGHT)];
        const black_knights = board.pieces[@intFromEnum(types.Piece.BLACK_KNIGHT)];
        const white_rooks = board.pieces[@intFromEnum(types.Piece.WHITE_ROOK)];
        const black_rooks = board.pieces[@intFromEnum(types.Piece.BLACK_ROOK)];
        const white_queens = board.pieces[@intFromEnum(types.Piece.WHITE_QUEEN)];
        const black_queens = board.pieces[@intFromEnum(types.Piece.BLACK_QUEEN)];
        const white_pawns = board.pieces[@intFromEnum(types.Piece.WHITE_PAWN)];
        const black_pawns = board.pieces[@intFromEnum(types.Piece.BLACK_PAWN)];

        if (white_pawns == 0 and black_pawns == 0 and white_rooks == 0 and black_rooks == 0 and white_queens == 0 and black_queens == 0) {
            const white_bishop_count = @popCount(white_bishops);
            const black_bishop_count = @popCount(black_bishops);
            const white_knight_count = @popCount(white_knights);
            const black_knight_count = @popCount(black_knights);

            const total_minors = white_bishop_count + black_bishop_count + white_knight_count + black_knight_count;

            // King vs King + Bishop
            if (total_minors == 1 and (white_bishop_count == 1 or black_bishop_count == 1)) {
                return true;
            }

            // King vs King + Knight
            if (total_minors == 1 and (white_knight_count == 1 or black_knight_count == 1)) {
                return true;
            }

            // King + Bishop vs King + Bishop (same color squares)
            if (total_minors == 2 and white_bishop_count == 1 and black_bishop_count == 1) {
                // Check if bishops are on same color squares
                const white_bishop_square = @ctz(white_bishops);
                const black_bishop_square = @ctz(black_bishops);

                const white_bishop_color = (white_bishop_square + (white_bishop_square >> 3)) & 1;
                const black_bishop_color = (black_bishop_square + (black_bishop_square >> 3)) & 1;

                if (white_bishop_color == black_bishop_color) {
                    return true;
                }
            }

            // King + Knight vs King + Knight
            if (total_minors == 2 and white_knight_count == 1 and black_knight_count == 1) {
                return true;
            }

            // King + Bishop vs King + Knight
            if (total_minors == 2 and
                ((white_bishop_count == 1 and black_knight_count == 1) or
                    (white_knight_count == 1 and black_bishop_count == 1)))
            {
                return true;
            }

            // King + two Knights vs King
            if (total_minors == 2 and
                ((white_knight_count == 2 and black_bishop_count == 0 and black_knight_count == 0) or
                    (black_knight_count == 2 and white_bishop_count == 0 and white_knight_count == 0)))
            {
                return true;
            }
        }

        return false;
    }
};

const CENTER_CONTROL = [64]i32{
    -30, -20, -10, 0,  0,  -10, -20, -30,
    -20, -10, 0,   10, 10, 0,   -10, -20,
    -10, 0,   10,  20, 20, 10,  0,   -10,
    0,   10,  20,  30, 30, 20,  10,  0,
    0,   10,  20,  30, 30, 20,  10,  0,
    -10, 0,   10,  20, 20, 10,  0,   -10,
    -20, -10, 0,   10, 10, 0,   -10, -20,
    -30, -20, -10, 0,  0,  -10, -20, -30,
};

inline fn king_distance(sq1: u6, sq2: u6) u4 {
    const file1 = sq1 % 8;
    const rank1 = sq1 / 8;
    const file2 = sq2 % 8;
    const rank2 = sq2 / 8;

    const file_dist = if (file1 > file2) file1 - file2 else file2 - file1;
    const rank_dist = if (rank1 > rank2) rank1 - rank2 else rank2 - rank1;

    return @intCast(@max(file_dist, rank_dist));
}

const mg_passed_score: [64]i32 = .{
    0,  0,  0,   0,   0,   0,   0,   0,
    0,  -6, -11, -13, 3,   -10, 4,   12,
    5,  -9, -14, -23, -3,  -22, -17, 21,
    10, 0,  -13, -3,  -15, -34, -49, 0,
    30, 26, 17,  10,  5,   -3,  -16, -4,
    77, 62, 49,  31,  0,   2,   -25, -9,
    67, 71, 64,  73,  57,  38,  -23, 4,
    0,  0,  0,   0,   0,   0,   0,   0,
};

const eg_passed_score: [64]i32 = .{
    0,   0,   0,   0,  0,  0,   0,   0,
    12,  22,  14,  18, 12, 13,  25,  11,
    16,  28,  17,  18, 17, 24,  40,  11,
    43,  50,  39,  30, 36, 48,  71,  43,
    73,  73,  59,  56, 54, 66,  77,  63,
    126, 121, 105, 95, 87, 104, 106, 120,
    96,  87,  82,  66, 65, 75,  97,  95,
    0,   0,   0,   0,  0,  0,   0,   0,
};

const mg_isolated_pawn_score: [8]i32 = .{ -6, -1, -7, -10, -9, -7, -1, -6 };
const eg_isolated_pawn_score: [8]i32 = .{ -5, -9, -9, -9, -9, -9, -9, -5 };

const mg_blocked_passer_score: [8]i32 = .{ 0, -7, 0, 4, 5, 11, -3, 0 };
const eg_blocked_passer_score: [8]i32 = .{ 0, -6, -13, -29, -50, -90, -84, 0 };

const mg_supported_pawn: [8]i32 = .{ 0, 0, 13, 8, 12, 36, 222, 0 };
const eg_supported_pawn: [8]i32 = .{ 0, 0, 10, 6, 10, 23, -22, 0 };

const mg_pawn_phalanx: [8]i32 = .{ 0, 3, 12, 15, 40, 216, -289, 0 };
const eg_pawn_phalanx: [8]i32 = .{ 0, 2, 6, 22, 63, 39, 328, 0 };

const mg_knight_mobility: [9]i32 = .{ -44, -28, -22, -18, -15, -13, -11, -8, -4 };
const eg_knight_mobility: [9]i32 = .{ -50, -23, -5, 2, 10, 18, 19, 16, 9 };

const mg_bishop_mobility: [14]i32 = .{ -35, -29, -23, -19, -15, -13, -11, -10, -7, -6, 0, 7, 2, 48 };
const eg_bishop_mobility: [14]i32 = .{ -46, -25, -14, -4, 5, 14, 20, 23, 27, 26, 25, 21, 34, 8 };

const mg_rook_mobility: [15]i32 = .{ -33, -27, -22, -18, -18, -13, -11, -8, -5, -3, -1, 0, 5, 10, 21 };
const eg_rook_mobility: [15]i32 = .{ -25, -20, -20, -16, -8, -4, 1, 5, 11, 17, 22, 27, 26, 25, 16 };

const mg_queen_mobility: [28]i32 = .{
    -16, -14, -11, -10,  -7, -5, -4, -3,
    0,   0,   1,   2,    3,  4,  6,  7,
    11,  15,  20,  30,   44, 89, 77, 170,
    132, 304, 594, 1448,
};
const eg_queen_mobility: [28]i32 = .{
    -106, -46,  -36,  -26,  -24, -17, -10, -2,
    1,    7,    12,   17,   20,  23,  27,  32,
    29,   27,   27,   20,   9,   -18, -14, -59,
    -46,  -133, -273, -683,
};

const mg_pawn_attacking: [6]i32 = .{ 0, 36, 41, 25, 23, 0 };
const eg_pawn_attacking: [6]i32 = .{ 0, 18, 43, 10, 34, 0 };

const mg_knight_attacking: [6]i32 = .{ -7, 0, 23, 32, 14, 0 };
const eg_knight_attacking: [6]i32 = .{ 7, 0, 25, -13, -5, 0 };

const mg_bishop_attacking: [6]i32 = .{ -1, 12, 0, 22, 26, 0 };
const eg_bishop_attacking: [6]i32 = .{ 8, 27, 0, -4, 51, 0 };

const mg_rook_attacking: [6]i32 = .{ -3, 4, 11, 0, 34, 0 };
const eg_rook_attacking: [6]i32 = .{ 8, 18, 14, 0, 24, 0 };

const mg_queen_attacking: [6]i32 = .{ 0, 1, 0, -4, 0, 0 };
const eg_queen_attacking: [6]i32 = .{ 0, -3, 8, 3, 0, 0 };

const mg_doubled_pawns: [1]i32 = .{-2};
const eg_doubled_pawns: [1]i32 = .{-13};

const mg_bishop_pair: [1]i32 = .{12};
const eg_bishop_pair: [1]i32 = .{46};

pub inline fn get_passed_pawn_score(sq: u6) [2]i32 {
    return .{ mg_passed_score[sq], eg_passed_score[sq] };
}

pub inline fn get_isolated_pawn_score(file: u6) [2]i32 {
    return .{ mg_isolated_pawn_score[file], eg_isolated_pawn_score[file] };
}

pub inline fn get_blocked_passer_score(rank: u6) [2]i32 {
    return .{ mg_blocked_passer_score[rank], eg_blocked_passer_score[rank] };
}

pub inline fn get_pawn_threat(pt: types.PieceType) [2]i32 {
    const idx = pt.toU3();
    return .{ mg_pawn_attacking[idx], eg_pawn_attacking[idx] };
}

pub inline fn get_knight_threat(pt: types.PieceType) [2]i32 {
    const idx = pt.toU3();
    return .{ mg_knight_attacking[idx], eg_knight_attacking[idx] };
}

pub inline fn get_bishop_threat(pt: types.PieceType) [2]i32 {
    const idx = pt.toU3();
    return .{ mg_bishop_attacking[idx], eg_bishop_attacking[idx] };
}

pub inline fn get_rook_threat(pt: types.PieceType) [2]i32 {
    const idx = pt.toU3();
    return .{ mg_rook_attacking[idx], eg_rook_attacking[idx] };
}

pub inline fn get_queen_threat(pt: types.PieceType) [2]i32 {
    const idx = pt.toU3();
    return .{ mg_queen_attacking[idx], eg_queen_attacking[idx] };
}

pub inline fn get_supported_pawn_bonus(rank: u6) [2]i32 {
    return .{ mg_supported_pawn[rank], eg_supported_pawn[rank] };
}

pub inline fn get_phalanx_score(rank: u6) [2]i32 {
    return .{ mg_pawn_phalanx[rank], eg_pawn_phalanx[rank] };
}

pub inline fn get_knight_mobility_score(idx: u7) [2]i32 {
    return .{ mg_knight_mobility[idx], eg_knight_mobility[idx] };
}

pub inline fn get_bishop_mobility_score(idx: u7) [2]i32 {
    return .{ mg_bishop_mobility[idx], eg_bishop_mobility[idx] };
}

pub inline fn get_rook_mobility_score(idx: u7) [2]i32 {
    return .{ mg_rook_mobility[idx], eg_rook_mobility[idx] };
}

pub inline fn get_queen_mobility_score(idx: u7) [2]i32 {
    return .{ mg_queen_mobility[idx], eg_queen_mobility[idx] };
}

// Simple Material Evaluation
// return the material score of the board
const material_scores = [_]i32{ 100, 300, 350, 500, 1000, 10000 };

pub inline fn simple_evaluat_material(board: *const types.Board) i32 {
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
