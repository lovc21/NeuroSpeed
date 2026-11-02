const std = @import("std");
const tabeles = @import("tabeles.zig");
const attacks = @import("attacks.zig");
const types = @import("types.zig");
const router = @import("router.zig");
const util = @import("util.zig");

const Board = types.Board;
const Color = types.Color;
const Piece = types.Piece;
const PieceType = types.PieceType;

// every eval term is a [mid_game, end_game] pair
pub const Score = @Vector(2, i32);
const zero: Score = .{ 0, 0 };

// zip a mid game and an end game table into one table of [mg, eg] pairs
pub fn zip(comptime n: usize, mg: [n]i32, eg: [n]i32) [n]Score {
    var t: [n]Score = undefined;
    for (0..n) |i| t[i] = .{ mg[i], eg[i] };
    return t;
}

pub var global_evaluator: Evaluator = Evaluator.init_empty();

// HCE scaling in percent (100 = neutral), SPSA-tunable.
pub var hce_corner_pct: i32 = 100; // corner-driving bonus (B+N mate corners)
pub var hce_kingdist_pct: i32 = 100; // king-proximity term in won endgames
pub var hce_edge_pct: i32 = 100; // CENTER_CONTROL edge-driving term
pub var hce_tempo_pct: i32 = 100; // both tempo bonuses (mg/eg interpolated)
pub var hce_lazy_margin: i32 = 600; // lazy alpha/beta cutoff margin

pub const options = [_]types.Option{
    .{ .name = "hce_corner_pct", .ptr = &hce_corner_pct, .min = 0, .max = 300 },
    .{ .name = "hce_kingdist_pct", .ptr = &hce_kingdist_pct, .min = 0, .max = 300 },
    .{ .name = "hce_edge_pct", .ptr = &hce_edge_pct, .min = 0, .max = 300 },
    .{ .name = "hce_tempo_pct", .ptr = &hce_tempo_pct, .min = 0, .max = 300 },
    .{ .name = "hce_lazy_margin", .ptr = &hce_lazy_margin, .min = 150, .max = 1200 },
};
const threat_victims = [_]PieceType{ .Pawn, .Knight, .Bishop, .Rook, .Queen };

// single tuned values
const tempo_bonus: Score = .{ 15, 5 };
// material value per piece type P N B R Q K
const material: [6]Score = .{ .{ 82, 94 }, .{ 337, 281 }, .{ 365, 297 }, .{ 477, 512 }, .{ 1025, 936 }, .{ 0, 0 } };

// game phase contribution per piece type P N B R Q K
const phase_inc = [_]u8{ 0, 1, 1, 3, 6, 0 };
// doubled pawns on one file
const doubled_pawns: Score = .{ -2, -13 };

// piece placement bonuses
const knight_outpost: Score = .{ 25, 15 };
const knight_rim: Score = .{ -15, -5 };
const bishop_outpost: Score = .{ 20, 10 };
const bishop_pair: Score = .{ 30, 50 };
const bad_bishop_per_pawn: Score = .{ -3, -2 };
const bad_bishop_min_pawns = 4;
const rook_open_file: Score = .{ 30, 15 };
const rook_semi_open_file: Score = .{ 15, 8 };
const rook_seventh: Score = .{ 25, 35 };
const rook_behind_passer: Score = .{ 15, 25 };

// king safety, danger points per attacker type P N B R Q K scaled by how many attackers there are
const king_danger_weight = [_]i32{ 1, 2, 2, 3, 5, 0 };
const danger_multipliers = [_]i32{ 0, 50, 70, 80, 90, 95, 98, 100 };
const shelter_open_file: i32 = 20;
const dark_squares: u64 = 0xAA55AA55AA55AA55;

// passed_span[color][sq] = the three files ahead of a pawn where an enemy pawn would stop it
const passed_span: [2][64]u64 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [2][64]u64 = .{ .{0} ** 64, .{0} ** 64 };
    for (0..64) |sq| {
        const file = types.file_of(sq);
        const rank = types.rank_of(sq);
        var w: u64 = 0;
        for (rank + 1..8) |r| {
            w |= types.square_bb[r * 8 + file];
            if (file > 0) w |= types.square_bb[r * 8 + (file - 1)];
            if (file < 7) w |= types.square_bb[r * 8 + (file + 1)];
        }
        t[0][sq] = w;
        var b: u64 = 0;
        var r = rank;
        while (r > 0) {
            r -= 1;
            b |= types.square_bb[r * 8 + file];
            if (file > 0) b |= types.square_bb[r * 8 + (file - 1)];
            if (file < 7) b |= types.square_bb[r * 8 + (file + 1)];
        }
        t[1][sq] = b;
    }
    break :blk t;
};

// passed_front_file[color][sq] = own file from the pawn forward, pawn square included
const passed_front_file: [2][64]u64 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [2][64]u64 = .{ .{0} ** 64, .{0} ** 64 };
    for (0..64) |sq| {
        const file = types.file_of(sq);
        const upto: u64 = if (sq == 63) ~@as(u64, 0) else (@as(u64, 1) << @intCast(sq + 1)) - 1;
        t[0][sq] = types.mask_file[file] & ~((@as(u64, 1) << @intCast(sq)) - 1);
        t[1][sq] = types.mask_file[file] & upto;
    }
    break :blk t;
};

// ranks_ahead[color][rank] = every square on the ranks in front of that rank
const ranks_ahead: [2][8]u64 = blk: {
    var t: [2][8]u64 = undefined;
    for (0..8) |r| {
        const below: u64 = (@as(u64, 1) << @intCast(r * 8)) - 1;
        const up_to: u64 = if (r == 7) ~@as(u64, 0) else (@as(u64, 1) << @intCast((r + 1) * 8)) - 1;
        t[0][r] = ~up_to;
        t[1][r] = below;
    }
    break :blk t;
};

// adjacent_files[file] = the files on both sides
const adjacent_files: [8]u64 = blk: {
    var t: [8]u64 = undefined;
    for (0..8) |f| t[f] = (if (f > 0) types.mask_file[f - 1] else 0) | (if (f < 7) types.mask_file[f + 1] else 0);
    break :blk t;
};

inline fn piece_type_index(piece: Piece) u3 {
    return piece.piece_type().toU3();
}

inline fn piece_color_index(piece: Piece) u1 {
    return @intCast(@intFromEnum(piece.color()));
}

inline fn piece_bb(board: *const Board, comptime color: Color, comptime pt: PieceType) u64 {
    return board.pieces[@as(usize, color.toU4()) * 8 + pt.toU3()];
}

// blend the mg and eg halves by game phase, 64 = full board
inline fn taper(score: Score, phase: i32) i32 {
    return @divTrunc(score[0] * phase + score[1] * (64 - phase), 64);
}

// turn a white relative score into the given side's view
inline fn from_view(score: i32, comptime color: Color) i32 {
    return if (color == .White) score else -score;
}

inline fn splat(count: i32) Score {
    return @splat(count);
}

inline fn king_distance(a: u6, b: u6) u4 {
    const file_dist = @abs(@as(i32, types.file_of(a)) - @as(i32, types.file_of(b)));
    const rank_dist = @abs(@as(i32, types.rank_of(a)) - @as(i32, types.rank_of(b)));
    return @intCast(@max(file_dist, rank_dist));
}

// white relative material value of a piece
inline fn material_value(piece: Piece) Score {
    const value = material[piece_type_index(piece)];
    return if (piece_color_index(piece) == 0) value else -value;
}

// white relative piece-square value, white mirrors because the tables are a8-first
inline fn psqt_value(piece: Piece, sq: u6) Score {
    const pt = piece_type_index(piece);
    if (piece_color_index(piece) == 0) return .{ tabeles.mg_psqt[pt][types.flip_rank(sq)], tabeles.eg_psqt[pt][types.flip_rank(sq)] };
    return -Score{ tabeles.mg_psqt[pt][sq], tabeles.eg_psqt[pt][sq] };
}

// full PSQT sum, only used to double check the incremental one in safe builds
fn psqt_score(board: *const Board) Score {
    var score = zero;
    inline for ([_]Color{ .White, .Black }) |c| {
        inline for (0..6) |pt| {
            const piece: Piece = @enumFromInt(@as(u8, c.toU4()) * 8 + pt);
            var bb = board.pieces[piece.toU4()];
            while (bb != 0) : (bb &= bb - 1) score += psqt_value(piece, @intCast(@ctz(bb)));
        }
    }
    return score;
}

pub const Evaluator = struct {
    psqt: Score = zero,
    material: Score = zero,
    phase: [2]u8 = .{ 0, 0 },

    pub fn init_empty() Evaluator {
        return .{};
    }

    pub inline fn add_piece_material(self: *Evaluator, piece: Piece) void {
        self.material += material_value(piece);
    }

    pub inline fn remove_piece_material(self: *Evaluator, piece: Piece) void {
        self.material -= material_value(piece);
    }

    pub inline fn add_piece_psqt(self: *Evaluator, piece: Piece, sq: u6) void {
        self.psqt += psqt_value(piece, sq);
    }

    pub inline fn remove_piece_psqt(self: *Evaluator, piece: Piece, sq: u6) void {
        self.psqt -= psqt_value(piece, sq);
    }

    pub inline fn put_piece_phase(self: *Evaluator, piece: Piece) void {
        self.phase[piece_color_index(piece)] += phase_inc[piece_type_index(piece)];
    }

    pub inline fn remove_piece_phase(self: *Evaluator, piece: Piece) void {
        const inc = phase_inc[piece_type_index(piece)];
        const c = piece_color_index(piece);
        // never go below zero
        if (self.phase[c] >= inc) self.phase[c] -= inc;
    }

    // hand crafted eval from the side to move's view
    pub fn hce_eval(self: Evaluator, board: *const Board, comptime color: Color, alpha: i32, beta: i32) i32 {
        if (is_draw(board)) return 0;

        const phase: i32 = @min(@as(i32, self.phase[0]) + @as(i32, self.phase[1]), 64);
        const tempo = util.pct(taper(tempo_bonus, phase), hce_tempo_pct);

        // the incremental PSQT must match a fresh recompute in safe builds
        if (std.debug.runtime_safety) std.debug.assert(@reduce(.And, psqt_score(board) == self.psqt));

        // cheap material + PSQT base, enough for a lazy cutoff far outside the window
        const base = self.material + self.psqt;
        const lazy = from_view(taper(base, phase) + tempo, color);
        if (lazy - hce_lazy_margin >= beta or lazy + hce_lazy_margin <= alpha) return lazy;

        const score = taper(base + evaluate_pieces(board), phase) + self.special_endgames(board);
        return from_view(score + tempo, color);
    }

    // the tier choice between HCE and the two nets lives in router.zig
    pub fn eval(self: Evaluator, board: *const Board, comptime color: Color, alpha: i32, beta: i32) i32 {
        return router.eval(self, board, color, alpha, beta);
    }

    // full eval with no lazy cutoff, for UCI display, benchmarks and tests
    pub fn eval_full(self: Evaluator, board: *const Board, comptime color: Color) i32 {
        return self.eval(board, color, -1_000_000, 1_000_000);
    }

    // extra push toward mate when the defender has nothing but a king
    inline fn special_endgames(self: Evaluator, board: *const Board) i32 {
        inline for ([_]Color{ .White, .Black }) |us| {
            const them = comptime us.other();
            const bare_king = self.phase[them.toU4()] == 0 and piece_bb(board, them, .Pawn) == 0;
            // phase 2 lets bishop+knight and two bishops in, two knights are already a draw
            if (self.phase[us.toU4()] >= 2 and bare_king) return from_view(self.mate_drive_bonus(board, us), us);
        }
        return 0;
    }

    // bonus for the winning side, from its own view
    inline fn mate_drive_bonus(self: Evaluator, board: *const Board, comptime us: Color) i32 {
        const them = comptime us.other();
        const our_king: u6 = @intCast(@ctz(piece_bb(board, us, .King)));
        const their_king: u6 = @intCast(@ctz(piece_bb(board, them, .King)));
        const bishops = piece_bb(board, us, .Bishop);
        var bonus: i32 = 0;

        const bishop_and_knight = @popCount(bishops) == 1 and @popCount(piece_bb(board, us, .Knight)) == 1;
        if (self.phase[us.toU4()] == 2 and bishop_and_knight) {
            // bishop and knight can only mate in a corner of the bishop's color
            const light_bishop = (bishops & ~dark_squares) != 0;
            bonus += util.pct(corner_distance_bonus(their_king, light_bishop), hce_corner_pct);
        } else {
            // otherwise push the lone king to the edge
            bonus -= util.pct(tabeles.center_control[their_king], hce_edge_pct);
        }
        // and bring our king closer
        bonus -= util.pct(@as(i32, king_distance(our_king, their_king)) * 5, hce_kingdist_pct);
        return bonus;
    }
};

// bonus for the lone king being near a corner of the given color
inline fn corner_distance_bonus(king_sq: u6, light_corner: bool) i32 {
    const corners: [2]u6 = if (light_corner) .{ 56, 7 } else .{ 0, 63 };
    const dist = @min(king_distance(king_sq, corners[0]), king_distance(king_sq, corners[1]));
    return (14 - @as(i32, dist)) * 10;
}

// insufficient material check
fn is_draw(board: *const Board) bool {
    const wb = piece_bb(board, .White, .Bishop);
    const bb = piece_bb(board, .Black, .Bishop);
    const wn = piece_bb(board, .White, .Knight);
    const bn = piece_bb(board, .Black, .Knight);
    const kings = piece_bb(board, .White, .King) | piece_bb(board, .Black, .King);
    if (board.pieces_combined() == kings) return true;

    // anything with a pawn, rook or queen can still be won
    const heavy = piece_bb(board, .White, .Pawn) | piece_bb(board, .Black, .Pawn) |
        piece_bb(board, .White, .Rook) | piece_bb(board, .Black, .Rook) |
        piece_bb(board, .White, .Queen) | piece_bb(board, .Black, .Queen);
    if (heavy != 0) return false;

    const wb_count = @popCount(wb);
    const bb_count = @popCount(bb);
    const wn_count = @popCount(wn);
    const bn_count = @popCount(bn);
    const minors = wb_count + bb_count + wn_count + bn_count;

    // a single minor cannot mate
    if (minors <= 1) return true;
    if (minors != 2) return false;
    // two knights cannot force mate either
    if (wn_count == 2 or bn_count == 2) return true;
    // bishops on the same color are a dead draw
    if (wb_count == 1 and bb_count == 1) return ((wb & dark_squares) != 0) == ((bb & dark_squares) != 0);
    // one minor each is a draw, two minors on one side is not
    return wb_count + wn_count == 1;
}

// Piece evaluation, written once and run for both colors

// shared state for one evaluate_pieces call, indexed [white, black]
const EvalCtx = struct {
    board: *const Board,
    occ: u64,
    pieces: [2]u64,
    pawns: [2]u64,
    pawn_attacks: [2]u64,
    king_sq: [2]u6,
    king_zone: [2]u64,
    passed: [2]u64 = .{ 0, 0 },
    danger: [2]i32 = .{ 0, 0 },
    danger_pieces: [2]u8 = .{ 0, 0 },

    fn init(board: *const Board) EvalCtx {
        const wk = piece_bb(board, .White, .King);
        const bk = piece_bb(board, .Black, .King);
        const wk_sq: u6 = if (wk != 0) @intCast(@ctz(wk)) else 0;
        const bk_sq: u6 = if (bk != 0) @intCast(@ctz(bk)) else 0;
        const wp = piece_bb(board, .White, .Pawn);
        const bp = piece_bb(board, .Black, .Pawn);
        return .{
            .board = board,
            .occ = board.pieces_combined(),
            .pieces = .{ board.set_pieces(.White), board.set_pieces(.Black) },
            .pawns = .{ wp, bp },
            .pawn_attacks = .{ attacks.pawn_attacks_from_bitboard(.White, wp), attacks.pawn_attacks_from_bitboard(.Black, bp) },
            .king_sq = .{ wk_sq, bk_sq },
            .king_zone = .{ tabeles.King_areas[wk_sq], tabeles.King_areas[bk_sq] },
        };
    }

    // count an attacker that reaches the enemy king zone
    inline fn add_king_danger(self: *EvalCtx, them: usize, att: u64, weight: i32) void {
        if ((self.king_zone[them] & att) == 0) return;
        self.danger[them] += weight;
        self.danger_pieces[them] += 1;
    }
};

// white relative sum of all piece terms
fn evaluate_pieces(board: *const Board) Score {
    var ctx = EvalCtx.init(board);
    var score = zero;
    // pawns go first because they fill the passed pawn bitboards the rooks read
    score += eval_pawns(&ctx, .White) - eval_pawns(&ctx, .Black);
    inline for ([_]PieceType{ .Knight, .Bishop, .Rook, .Queen }) |pt| {
        score += eval_pieces(&ctx, .White, pt) - eval_pieces(&ctx, .Black, pt);
    }
    // king safety needs every attacker counted first
    score += king_safety(&ctx, .White) - king_safety(&ctx, .Black);
    score += side_bonuses(&ctx, .White) - side_bonuses(&ctx, .Black);
    return score;
}

// no enemy pawn ahead on the three files and no own pawn ahead on the file
inline fn is_passed_pawn(sq: u6, comptime color: Color, enemy_pawns: u64, own_pawns: u64) bool {
    const c = comptime color.toU4();
    if ((passed_span[c][sq] & enemy_pawns) != 0) return false;
    return (own_pawns & passed_front_file[c][sq]) == types.square_bb[sq];
}

inline fn is_isolated_pawn(sq: u6, own_pawns: u64) bool {
    return (own_pawns & adjacent_files[types.file_of(sq)]) == 0;
}

// in the enemy half, guarded by a pawn and out of reach of enemy pawns
inline fn is_outpost(sq: u6, comptime color: Color, enemy_pawns: u64, own_pawn_attacks: u64) bool {
    const rank = types.rank_of(sq);
    if (color == .White and rank < 4) return false;
    if (color == .Black and rank > 3) return false;
    if ((own_pawn_attacks & types.square_bb[sq]) == 0) return false;
    // squares an enemy pawn attacks from are the squares a pawn of our color attacks to
    const attackers = if (color == .White) tabeles.Black_pawn_attacks_tabele[sq] else tabeles.White_pawn_attacks_tabele[sq];
    return (enemy_pawns & attackers) == 0;
}

inline fn on_rim(sq: u6) bool {
    const file = types.file_of(sq);
    const rank = types.rank_of(sq);
    return file == 0 or file == 7 or rank == 0 or rank == 7;
}

// bonus for every enemy piece the attacker hits, own piece type is skipped
inline fn threats(comptime attacker: PieceType, comptime color: Color, att: u64, board: *const Board) Score {
    const them = comptime color.other();
    var score = zero;
    inline for (threat_victims) |victim| {
        if (victim == attacker) continue;
        const hit = att & piece_bb(board, them, victim);
        if (hit != 0) score += tabeles.threat[attacker.toU3()][victim.toU3()] * splat(@intCast(@popCount(hit)));
    }
    return score;
}

inline fn eval_pawns(ctx: *EvalCtx, comptime color: Color) Score {
    const us = comptime color.toU4();
    const them = us ^ 1;
    var score = zero;
    var bb = ctx.pawns[us];
    while (bb != 0) : (bb &= bb - 1) {
        const sq: u6 = @intCast(@ctz(bb));
        // rel is the square seen from white's side so one table serves both colors
        const rel: u6 = if (color == .White) sq else types.flip_rank(sq);
        const rank: u6 = types.rank_of(rel);
        const file: u6 = types.file_of(sq);

        const att = attacks.pawn_attacks_from_square(sq, color) & ~ctx.pieces[us];
        ctx.add_king_danger(them, att, king_danger_weight[PieceType.Pawn.toU3()]);

        if (is_isolated_pawn(sq, ctx.pawns[us])) score += tabeles.isolated_pawn[file];

        const passed = is_passed_pawn(sq, color, ctx.pawns[them], ctx.pawns[us]);
        if (passed) {
            ctx.passed[us] |= types.square_bb[sq];
            score += tabeles.passed_pawn[rel];
            // blocked when an enemy piece stands on the square in front, the shift is 0 past the last rank
            const front = if (color == .White) types.square_bb[sq] << 8 else types.square_bb[sq] >> 8;
            if ((front & ctx.pieces[them]) != 0) score += tabeles.blocked_passer[rank];
        }

        const supported = (ctx.pawn_attacks[us] & types.square_bb[sq]) != 0;
        if (supported) score += tabeles.supported_pawn[rank];

        // phalanx is a friendly pawn on the next file of the same rank
        const phalanx = file < 7 and (ctx.pawns[us] & types.square_bb[sq + 1]) != 0;
        if (phalanx) score += tabeles.pawn_phalanx[rank];

        if (passed and (supported or phalanx)) score += tabeles.connected_passer[rank];

        score += threats(.Pawn, color, att, ctx.board);
    }
    return score;
}

// mobility, king danger and threats for one piece type, plus the type specific extras
inline fn eval_pieces(ctx: *EvalCtx, comptime color: Color, comptime pt: PieceType) Score {
    const us = comptime color.toU4();
    const them = us ^ 1;
    var score = zero;
    var bb = piece_bb(ctx.board, color, pt);
    while (bb != 0) : (bb &= bb - 1) {
        const sq: u6 = @intCast(@ctz(bb));
        const mobility = attacks.piece_attacks(sq, ctx.occ, pt) & ~ctx.pieces[us];

        // squares not covered by enemy pawns count as safe
        const safe_squares = @popCount(mobility & ~ctx.pawn_attacks[them]);
        score += mobility_score(pt, safe_squares);
        ctx.add_king_danger(them, mobility, king_danger_weight[pt.toU3()]);

        score += switch (pt) {
            .Knight => knight_extras(ctx, color, sq),
            .Bishop => bishop_extras(ctx, color, sq),
            .Rook => rook_extras(ctx, color, sq),
            else => zero,
        };
        score += threats(pt, color, mobility, ctx.board);
    }
    return score;
}

inline fn mobility_score(comptime pt: PieceType, safe_squares: u7) Score {
    return switch (pt) {
        .Knight => tabeles.knight_mobility[safe_squares],
        .Bishop => tabeles.bishop_mobility[safe_squares],
        .Rook => tabeles.rook_mobility[safe_squares],
        .Queen => tabeles.queen_mobility[safe_squares],
        else => unreachable,
    };
}

inline fn knight_extras(ctx: *const EvalCtx, comptime color: Color, sq: u6) Score {
    const us = comptime color.toU4();
    var score = zero;
    if (is_outpost(sq, color, ctx.pawns[us ^ 1], ctx.pawn_attacks[us])) score += knight_outpost;
    if (on_rim(sq)) score += knight_rim;
    return score;
}

inline fn bishop_extras(ctx: *const EvalCtx, comptime color: Color, sq: u6) Score {
    const us = comptime color.toU4();
    var score = zero;
    if (is_outpost(sq, color, ctx.pawns[us ^ 1], ctx.pawn_attacks[us])) score += bishop_outpost;
    // a bishop hemmed in by many own pawns on its square color is bad
    const own_color = if ((types.square_bb[sq] & dark_squares) != 0) dark_squares else ~dark_squares;
    const blocked: i32 = @intCast(@popCount(ctx.pawns[us] & own_color));
    if (blocked > bad_bishop_min_pawns) score += bad_bishop_per_pawn * splat(blocked);
    return score;
}

inline fn rook_extras(ctx: *const EvalCtx, comptime color: Color, sq: u6) Score {
    const us = comptime color.toU4();
    const them = us ^ 1;
    var score = zero;
    const file_mask = types.mask_file[types.file_of(sq)];

    if ((ctx.pawns[us] & file_mask) == 0) {
        score += if ((ctx.pawns[them] & file_mask) == 0) rook_open_file else rook_semi_open_file;
    }

    // rook on the seventh while enemy pawns still sit there
    const seventh: u6 = if (color == .White) 6 else 1;
    if (types.rank_of(sq) == seventh and (ctx.pawns[them] & types.mask_rank[seventh]) != 0) score += rook_seventh;

    // rook behind a passed pawn of either side
    const up = comptime color == .White;
    if (rook_behind(sq, ctx.passed[us] & file_mask, up)) score += rook_behind_passer;
    if (rook_behind(sq, ctx.passed[them] & file_mask, !up)) score += rook_behind_passer;
    return score;
}

// true when the rook sits behind every passer on its file, behind means against the pawn's direction
inline fn rook_behind(sq: u6, passers: u64, comptime pawns_move_up: bool) bool {
    if (passers == 0) return false;
    return if (pawns_move_up) sq < @ctz(passers) else sq > 63 - @clz(passers);
}

// king danger points and open shelter files, both scaled by the attacker count
inline fn king_safety(ctx: *const EvalCtx, comptime color: Color) Score {
    const us = comptime color.toU4();
    const shelter = shelter_penalty(ctx.king_sq[us], ctx.pawns[us], color);
    const danger = util.pct(ctx.danger[us] + shelter, danger_multipliers[@min(ctx.danger_pieces[us], 7)]);
    if (danger <= 0) return zero;
    return .{ -danger, -danger };
}

// flat penalty for every file around the king with no own pawn ahead
inline fn shelter_penalty(king_sq: u6, own_pawns: u64, comptime color: Color) i32 {
    const ahead = ranks_ahead[color.toU4()][types.rank_of(king_sq)];
    var penalty: i32 = 0;
    for (0..3) |i| {
        const file = @as(i32, types.file_of(king_sq)) + @as(i32, @intCast(i)) - 1;
        if (file < 0 or file > 7) continue;
        if ((own_pawns & types.mask_file[@intCast(file)] & ahead) == 0) penalty += shelter_open_file;
    }
    return penalty;
}

// bishop pair and doubled pawns
inline fn side_bonuses(ctx: *const EvalCtx, comptime color: Color) Score {
    const us = comptime color.toU4();
    var score = zero;
    if (@popCount(piece_bb(ctx.board, color, .Bishop)) >= 2) score += bishop_pair;
    for (types.mask_file) |file_mask| {
        if (@popCount(ctx.pawns[us] & file_mask) >= 2) score += doubled_pawns;
    }
    return score;
}
