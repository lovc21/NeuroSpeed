const types = @import("types.zig");
const eval = @import("evaluation.zig");
const zobrist = @import("zobrist.zig");
const nnue = @import("nnue.zig");
const attacks = @import("attacks.zig");

// A move packed into 16 bits: from (6), to (6), flags (4)
pub const Move = packed struct {
    from: u6,
    to: u6,
    flags: types.MoveFlags,

    pub inline fn new(from: u6, to: u6, flags: types.MoveFlags) Move {
        return Move{ .from = from, .to = to, .flags = flags };
    }

    pub inline fn is_empty(self: Move) bool {
        return self.from == 0 and self.to == 0 and self.flags == types.MoveFlags.QUIET;
    }

    pub inline fn empty() Move {
        return Move{ .from = 0, .to = 0, .flags = types.MoveFlags.QUIET };
    }

    pub inline fn is_capture(self: Move) bool {
        return switch (self.flags) {
            types.MoveFlags.CAPTURE, types.MoveFlags.EN_PASSANT, types.MoveFlags.PC_QUEEN, types.MoveFlags.PC_ROOK, types.MoveFlags.PC_BISHOP, types.MoveFlags.PC_KNIGHT => true,
            else => false,
        };
    }

    pub inline fn is_promotion(self: Move) bool {
        return switch (self.flags) {
            types.MoveFlags.PR_QUEEN, types.MoveFlags.PR_ROOK, types.MoveFlags.PR_BISHOP, types.MoveFlags.PR_KNIGHT, types.MoveFlags.PC_QUEEN, types.MoveFlags.PC_ROOK, types.MoveFlags.PC_BISHOP, types.MoveFlags.PC_KNIGHT => true,
            else => false,
        };
    }

    // Same from, to and flags
    pub inline fn eql(a: Move, b: Move) bool {
        return a.from == b.from and a.to == b.to and a.flags == b.flags;
    }

    // Same from and to squares, flags ignored
    pub inline fn same_squares(a: Move, b: Move) bool {
        return a.from == b.from and a.to == b.to;
    }

    // UCI text ("e2e4", "e7e8q") written into buf
    pub fn to_uci(self: Move, buf: *[5]u8) []const u8 {
        const from = types.SquareString.getSquareToString(@enumFromInt(self.from));
        const to = types.SquareString.getSquareToString(@enumFromInt(self.to));
        buf[0..2].* = from[0..2].*;
        buf[2..4].* = to[0..2].*;
        if (!self.is_promotion()) return buf[0..4];
        buf[4] = self.promotion_char();
        return buf[0..5];
    }

    pub inline fn is_castling(self: Move) bool {
        return self.flags == types.MoveFlags.OO or self.flags == types.MoveFlags.OOO;
    }

    pub inline fn promotion_char(self: Move) u8 {
        return switch (self.flags) {
            types.MoveFlags.PR_QUEEN, types.MoveFlags.PC_QUEEN => 'q',
            types.MoveFlags.PR_ROOK, types.MoveFlags.PC_ROOK => 'r',
            types.MoveFlags.PR_BISHOP, types.MoveFlags.PC_BISHOP => 'b',
            types.MoveFlags.PR_KNIGHT, types.MoveFlags.PC_KNIGHT => 'n',
            else => ' ',
        };
    }
};

// Piece a promotion move creates for `color`
inline fn promoted_piece(flags: types.MoveFlags, comptime color: types.Color) types.Piece {
    const white = color == types.Color.White;
    return switch (flags) {
        types.MoveFlags.PR_QUEEN, types.MoveFlags.PC_QUEEN => if (white) types.Piece.WHITE_QUEEN else types.Piece.BLACK_QUEEN,
        types.MoveFlags.PR_ROOK, types.MoveFlags.PC_ROOK => if (white) types.Piece.WHITE_ROOK else types.Piece.BLACK_ROOK,
        types.MoveFlags.PR_BISHOP, types.MoveFlags.PC_BISHOP => if (white) types.Piece.WHITE_BISHOP else types.Piece.BLACK_BISHOP,
        types.MoveFlags.PR_KNIGHT, types.MoveFlags.PC_KNIGHT => if (white) types.Piece.WHITE_KNIGHT else types.Piece.BLACK_KNIGHT,
        else => types.Piece.NO_PIECE,
    };
}

// Rook from/to squares of a castling move: O-O h->f, O-O-O a->d
inline fn castle_rook_squares(move: Move) [2]u6 {
    return if (move.flags == types.MoveFlags.OO) .{ move.to + 1, move.to - 1 } else .{ move.to - 2, move.to + 1 };
}

// Square of the pawn taken en passant (behind the target square)
inline fn ep_capture_square(to: u6, comptime color: types.Color) u6 {
    return if (color == types.Color.White) to -% 8 else to +% 8;
}

// Everything make_move_search changes that unmake can't recompute
pub const SearchUndo = struct {
    captured: types.Piece, // NO_PIECE if nothing was captured
    castle: u8,
    enpassant: types.square,
    hash: u64,
    halfmove: u16,
    evaluator: eval.Evaluator,
};

// Make a move: bitboards, mailbox, hash, eval and NNUE accumulator (`color` = mover)
pub inline fn make_move_search(board: *types.Board, move: Move, comptime color: types.Color) SearchUndo {
    const from = move.from;
    const to = move.to;
    const flags = move.flags;
    const piece = board.board[from];
    const piece_idx = @intFromEnum(piece);
    const moving_white = comptime color == types.Color.White;
    const rook: types.Piece = if (moving_white) types.Piece.WHITE_ROOK else types.Piece.BLACK_ROOK;

    var undo = SearchUndo{
        .captured = board.board[to], // NO_PIECE for quiet, EP and castling moves
        .castle = board.castle,
        .enpassant = board.enpassant,
        .hash = board.hash,
        .halfmove = board.halfmove,
        .evaluator = eval.global_evaluator,
    };

    board.hash ^= zobrist.piece_keys[piece_idx][from];
    board.hash ^= zobrist.piece_keys[piece_idx][to];

    // Remove a piece captured on the target square
    if (undo.captured != types.Piece.NO_PIECE) {
        board.pieces[@intFromEnum(undo.captured)] ^= types.square_bb[to];
        board.hash ^= zobrist.piece_keys[@intFromEnum(undo.captured)][to];
        eval.global_evaluator.remove_piece_phase(undo.captured);
        eval.global_evaluator.remove_piece_material(undo.captured);
        eval.global_evaluator.remove_piece_psqt(undo.captured, to);
    }

    // Move the piece (one XOR clears from and sets to)
    board.pieces[piece_idx] ^= types.square_bb[from] | types.square_bb[to];
    eval.global_evaluator.remove_piece_psqt(piece, from);
    eval.global_evaluator.add_piece_psqt(piece, to);
    board.board[to] = piece;
    board.board[from] = types.Piece.NO_PIECE;

    // En passant: remove the pawn behind the target square
    if (flags == types.MoveFlags.EN_PASSANT) {
        const captured_sq = ep_capture_square(to, color);
        const captured_pawn: types.Piece = if (moving_white) types.Piece.BLACK_PAWN else types.Piece.WHITE_PAWN;
        undo.captured = captured_pawn;
        board.pieces[@intFromEnum(captured_pawn)] ^= types.square_bb[captured_sq];
        board.board[captured_sq] = types.Piece.NO_PIECE;
        board.hash ^= zobrist.piece_keys[@intFromEnum(captured_pawn)][captured_sq];
        eval.global_evaluator.remove_piece_phase(captured_pawn);
        eval.global_evaluator.remove_piece_material(captured_pawn);
        eval.global_evaluator.remove_piece_psqt(captured_pawn, captured_sq);
    }

    // Promotion: swap the pawn on the target square for the new piece
    if (move.is_promotion()) {
        const promoted = promoted_piece(flags, color);
        board.pieces[piece_idx] ^= types.square_bb[to];
        board.pieces[@intFromEnum(promoted)] ^= types.square_bb[to];
        board.board[to] = promoted;
        board.hash ^= zobrist.piece_keys[piece_idx][to];
        board.hash ^= zobrist.piece_keys[@intFromEnum(promoted)][to];
        eval.global_evaluator.remove_piece_phase(piece);
        eval.global_evaluator.remove_piece_material(piece);
        eval.global_evaluator.put_piece_phase(promoted);
        eval.global_evaluator.add_piece_material(promoted);
        eval.global_evaluator.remove_piece_psqt(piece, to);
        eval.global_evaluator.add_piece_psqt(promoted, to);
    }

    // Set an EP square only if an enemy pawn can take there (a phantom one would split the hash)
    board.enpassant = types.square.NO_SQUARE;
    if (flags == types.MoveFlags.DOUBLE_PUSH) {
        const ep: u6 = if (moving_white) to - 8 else to + 8;
        const enemy_pawns = board.pieces[@intFromEnum(if (moving_white) types.Piece.BLACK_PAWN else types.Piece.WHITE_PAWN)];
        if (attacks.pawn_attacks_from_square(ep, color) & enemy_pawns != 0) board.enpassant = @enumFromInt(ep);
    }

    // Castling: move the rook too
    if (move.is_castling()) {
        const rf, const rt = castle_rook_squares(move);
        board.pieces[@intFromEnum(rook)] ^= types.square_bb[rf] | types.square_bb[rt];
        board.board[rt] = rook;
        board.board[rf] = types.Piece.NO_PIECE;
        board.hash ^= zobrist.piece_keys[@intFromEnum(rook)][rf];
        board.hash ^= zobrist.piece_keys[@intFromEnum(rook)][rt];
        eval.global_evaluator.remove_piece_psqt(rook, rf);
        eval.global_evaluator.add_piece_psqt(rook, rt);
    }

    // Castling rights, EP square and side to move in the hash
    board.castle &= types.castle_mask[from] & types.castle_mask[to];
    if (undo.castle != board.castle) {
        board.hash ^= zobrist.castle_hash[undo.castle] ^ zobrist.castle_hash[board.castle];
    }
    if (undo.enpassant != types.square.NO_SQUARE) {
        board.hash ^= zobrist.ep_keys[types.file_of(@intFromEnum(undo.enpassant))];
    }
    if (board.enpassant != types.square.NO_SQUARE) {
        board.hash ^= zobrist.ep_keys[types.file_of(@intFromEnum(board.enpassant))];
    }

    // 50-move clock resets on pawn moves and captures (EP included)
    const is_pawn_move = piece == types.Piece.WHITE_PAWN or piece == types.Piece.BLACK_PAWN;
    board.halfmove = if (is_pawn_move or undo.captured != types.Piece.NO_PIECE) 0 else board.halfmove + 1;

    board.hash ^= zobrist.side_key;
    board.side = comptime if (moving_white) types.Color.Black else types.Color.White;

    // Push the NNUE accumulator (board is already the post-move position)
    if (nnue.acc_active) {
        var d = nnue.FeatDelta{};
        if (move.is_castling()) {
            const rf, const rt = castle_rook_squares(move);
            d.add(piece_idx, to);
            d.add(@intFromEnum(rook), rt);
            d.sub(piece_idx, from);
            d.sub(@intFromEnum(rook), rf);
        } else if (move.is_promotion()) {
            d.add(@intFromEnum(promoted_piece(flags, color)), to);
            d.sub(piece_idx, from);
            if (undo.captured != types.Piece.NO_PIECE) d.sub(@intFromEnum(undo.captured), to);
        } else if (flags == types.MoveFlags.EN_PASSANT) {
            d.add(piece_idx, to);
            d.sub(piece_idx, from);
            d.sub(@intFromEnum(undo.captured), ep_capture_square(to, color));
        } else if (undo.captured != types.Piece.NO_PIECE) {
            d.add(piece_idx, to);
            d.sub(piece_idx, from);
            d.sub(@intFromEnum(undo.captured), to);
        } else {
            d.add(piece_idx, to);
            d.sub(piece_idx, from);
        }
        nnue.apply(board, d);
    }

    return undo;
}

// Undo make_move_search; hash, eval and clocks come back from `undo` (`color` = mover)
pub inline fn unmake_move_search(board: *types.Board, move: Move, undo: SearchUndo, comptime color: types.Color) void {
    const from = move.from;
    const to = move.to;
    const moving_white = comptime color == types.Color.White;

    if (nnue.acc_active) nnue.pop_acc();
    board.side = color;

    // Castling: put the rook back
    if (move.is_castling()) {
        const rook: types.Piece = if (moving_white) types.Piece.WHITE_ROOK else types.Piece.BLACK_ROOK;
        const rf, const rt = castle_rook_squares(move);
        board.pieces[@intFromEnum(rook)] ^= types.square_bb[rt] | types.square_bb[rf];
        board.board[rf] = rook;
        board.board[rt] = types.Piece.NO_PIECE;
    }

    // Move the piece back; a promoted piece turns back into the pawn on `from`
    var piece = board.board[to];
    if (move.is_promotion()) {
        board.pieces[@intFromEnum(piece)] ^= types.square_bb[to];
        piece = if (moving_white) types.Piece.WHITE_PAWN else types.Piece.BLACK_PAWN;
        board.pieces[@intFromEnum(piece)] ^= types.square_bb[from];
    } else {
        board.pieces[@intFromEnum(piece)] ^= types.square_bb[from] | types.square_bb[to];
    }
    board.board[from] = piece;

    // Restore the captured piece (EP: behind the target square)
    if (move.flags == types.MoveFlags.EN_PASSANT) {
        const captured_sq = ep_capture_square(to, color);
        board.board[to] = types.Piece.NO_PIECE;
        board.pieces[@intFromEnum(undo.captured)] ^= types.square_bb[captured_sq];
        board.board[captured_sq] = undo.captured;
    } else {
        board.board[to] = undo.captured;
        if (undo.captured != types.Piece.NO_PIECE) {
            board.pieces[@intFromEnum(undo.captured)] ^= types.square_bb[to];
        }
    }

    board.castle = undo.castle;
    board.enpassant = undo.enpassant;
    board.halfmove = undo.halfmove;
    board.hash = undo.hash;
    eval.global_evaluator = undo.evaluator;
}

// Runtime-color versions for UCI, datagen and tests
pub fn make_move_search_rt(board: *types.Board, move: Move) SearchUndo {
    return switch (board.side) {
        .White => make_move_search(board, move, .White),
        .Black => make_move_search(board, move, .Black),
        .both => unreachable,
    };
}

// At unmake board.side is the mover's opponent
pub fn unmake_move_search_rt(board: *types.Board, move: Move, undo: SearchUndo) void {
    switch (board.side) {
        .White => unmake_move_search(board, move, undo, .Black),
        .Black => unmake_move_search(board, move, undo, .White),
        .both => unreachable,
    }
}
