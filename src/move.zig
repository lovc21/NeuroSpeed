const types = @import("types.zig");
const eval = @import("evaluation.zig");
const zobrist = @import("zobrist.zig");

// Define a move (packed 16-bit: 6+6+4 bits for cache-friendly MoveList)
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

    pub inline fn is_double_push(self: Move) bool {
        return self.flags == types.MoveFlags.DOUBLE_PUSH;
    }

    pub inline fn is_en_passant(self: Move) bool {
        return self.flags == types.MoveFlags.EN_PASSANT;
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

// Update castling rights using bitboard masks
inline fn update_castling_rights(board: *types.Board, source_square: u6, target_square: u6) void {
    board.castle &= types.castle_mask[source_square] & types.castle_mask[target_square];
}

inline fn is_promotion_move(flags: types.MoveFlags) bool {
    return switch (flags) {
        types.MoveFlags.PR_QUEEN, types.MoveFlags.PR_ROOK, types.MoveFlags.PR_BISHOP, types.MoveFlags.PR_KNIGHT, types.MoveFlags.PC_QUEEN, types.MoveFlags.PC_ROOK, types.MoveFlags.PC_BISHOP, types.MoveFlags.PC_KNIGHT => true,
        else => false,
    };
}

inline fn get_promoted_piece(flags: types.MoveFlags, side: types.Color) types.Piece {
    return switch (flags) {
        types.MoveFlags.PR_QUEEN, types.MoveFlags.PC_QUEEN => if (side == types.Color.White) types.Piece.WHITE_QUEEN else types.Piece.BLACK_QUEEN,
        types.MoveFlags.PR_ROOK, types.MoveFlags.PC_ROOK => if (side == types.Color.White) types.Piece.WHITE_ROOK else types.Piece.BLACK_ROOK,
        types.MoveFlags.PR_BISHOP, types.MoveFlags.PC_BISHOP => if (side == types.Color.White) types.Piece.WHITE_BISHOP else types.Piece.BLACK_BISHOP,
        types.MoveFlags.PR_KNIGHT, types.MoveFlags.PC_KNIGHT => if (side == types.Color.White) types.Piece.WHITE_KNIGHT else types.Piece.BLACK_KNIGHT,
        else => types.Piece.NO_PIECE,
    };
}

// Minimal undo info for perft (no zobrist, no eval, no full board copy)
pub const PerftUndo = struct {
    captured: types.Piece, // captured piece (NO_PIECE if quiet)
    castle: u8, // old castling rights
    enpassant: types.square, // old ep square
};

/// Fast make_move for perft only. No zobrist, no eval, maintains mailbox.
pub inline fn make_move_perft(board: *types.Board, move: Move) PerftUndo {
    const from = move.from;
    const to = move.to;
    const flags = move.flags;

    // O(1) piece lookup from mailbox
    const piece = board.board[from];
    const piece_idx = @intFromEnum(piece);
    const moving_white = piece_idx < 6;

    // Save captured piece BEFORE overwriting mailbox
    var undo = PerftUndo{
        .captured = board.board[to], // NO_PIECE for quiet/ep/castle moves
        .castle = board.castle,
        .enpassant = board.enpassant,
    };

    // Remove captured piece from its bitboard (regular captures)
    if (undo.captured != types.Piece.NO_PIECE) {
        board.pieces[@intFromEnum(undo.captured)] ^= types.square_bb[to];
    }

    // Move piece in bitboards (XOR trick: clear source + set target in one op)
    board.pieces[piece_idx] ^= types.square_bb[from] | types.square_bb[to];

    // Update mailbox
    board.board[to] = piece;
    board.board[from] = types.Piece.NO_PIECE;

    // Handle en passant
    if (flags == types.MoveFlags.EN_PASSANT) {
        const captured_sq: u6 = if (moving_white) to -% 8 else to +% 8;
        const captured_pawn: types.Piece = if (moving_white) types.Piece.BLACK_PAWN else types.Piece.WHITE_PAWN;
        undo.captured = captured_pawn;
        board.pieces[@intFromEnum(captured_pawn)] ^= types.square_bb[captured_sq];
        board.board[captured_sq] = types.Piece.NO_PIECE;
    }

    // Handle promotions
    if (is_promotion_move(flags)) {
        // Remove the pawn from target, add promoted piece
        board.pieces[piece_idx] ^= types.square_bb[to]; // remove pawn
        const side: types.Color = if (moving_white) types.Color.White else types.Color.Black;
        const promoted = get_promoted_piece(flags, side);
        board.pieces[@intFromEnum(promoted)] ^= types.square_bb[to]; // add promoted piece
        board.board[to] = promoted;
    }

    // Reset en passant
    board.enpassant = types.square.NO_SQUARE;

    // Double pawn push - set ep square
    if (flags == types.MoveFlags.DOUBLE_PUSH) {
        board.enpassant = if (moving_white) @enumFromInt(to - 8) else @enumFromInt(to + 8);
    }

    // Castling - move the rook
    if (flags == types.MoveFlags.OO or flags == types.MoveFlags.OOO) {
        const rook_piece: types.Piece = if (moving_white) types.Piece.WHITE_ROOK else types.Piece.BLACK_ROOK;
        const rook_idx = @intFromEnum(rook_piece);
        switch (to) {
            @intFromEnum(types.square.g1) => {
                board.pieces[rook_idx] ^= types.square_bb[@intFromEnum(types.square.h1)] | types.square_bb[@intFromEnum(types.square.f1)];
                board.board[@intFromEnum(types.square.f1)] = rook_piece;
                board.board[@intFromEnum(types.square.h1)] = types.Piece.NO_PIECE;
            },
            @intFromEnum(types.square.c1) => {
                board.pieces[rook_idx] ^= types.square_bb[@intFromEnum(types.square.a1)] | types.square_bb[@intFromEnum(types.square.d1)];
                board.board[@intFromEnum(types.square.d1)] = rook_piece;
                board.board[@intFromEnum(types.square.a1)] = types.Piece.NO_PIECE;
            },
            @intFromEnum(types.square.g8) => {
                board.pieces[rook_idx] ^= types.square_bb[@intFromEnum(types.square.h8)] | types.square_bb[@intFromEnum(types.square.f8)];
                board.board[@intFromEnum(types.square.f8)] = rook_piece;
                board.board[@intFromEnum(types.square.h8)] = types.Piece.NO_PIECE;
            },
            @intFromEnum(types.square.c8) => {
                board.pieces[rook_idx] ^= types.square_bb[@intFromEnum(types.square.a8)] | types.square_bb[@intFromEnum(types.square.d8)];
                board.board[@intFromEnum(types.square.d8)] = rook_piece;
                board.board[@intFromEnum(types.square.a8)] = types.Piece.NO_PIECE;
            },
            else => {},
        }
    }

    // Update castling rights
    update_castling_rights(board, from, to);

    // Flip side
    board.side = if (board.side == types.Color.White) types.Color.Black else types.Color.White;

    return undo;
}

/// Fast unmake_move for perft only. Reverses make_move_perft.
pub inline fn unmake_move_perft(board: *types.Board, move: Move, undo: PerftUndo) void {
    const from = move.from;
    const to = move.to;
    const flags = move.flags;

    // Flip side back
    board.side = if (board.side == types.Color.White) types.Color.Black else types.Color.White;

    // Get the piece on target (may be promoted piece)
    var piece = board.board[to];
    var piece_idx = @intFromEnum(piece);
    const moving_white = @intFromEnum(board.side) == 0;

    // Undo castling rook movement
    if (flags == types.MoveFlags.OO or flags == types.MoveFlags.OOO) {
        const rook_piece: types.Piece = if (moving_white) types.Piece.WHITE_ROOK else types.Piece.BLACK_ROOK;
        const rook_idx = @intFromEnum(rook_piece);
        switch (to) {
            @intFromEnum(types.square.g1) => {
                board.pieces[rook_idx] ^= types.square_bb[@intFromEnum(types.square.f1)] | types.square_bb[@intFromEnum(types.square.h1)];
                board.board[@intFromEnum(types.square.h1)] = rook_piece;
                board.board[@intFromEnum(types.square.f1)] = types.Piece.NO_PIECE;
            },
            @intFromEnum(types.square.c1) => {
                board.pieces[rook_idx] ^= types.square_bb[@intFromEnum(types.square.d1)] | types.square_bb[@intFromEnum(types.square.a1)];
                board.board[@intFromEnum(types.square.a1)] = rook_piece;
                board.board[@intFromEnum(types.square.d1)] = types.Piece.NO_PIECE;
            },
            @intFromEnum(types.square.g8) => {
                board.pieces[rook_idx] ^= types.square_bb[@intFromEnum(types.square.f8)] | types.square_bb[@intFromEnum(types.square.h8)];
                board.board[@intFromEnum(types.square.h8)] = rook_piece;
                board.board[@intFromEnum(types.square.f8)] = types.Piece.NO_PIECE;
            },
            @intFromEnum(types.square.c8) => {
                board.pieces[rook_idx] ^= types.square_bb[@intFromEnum(types.square.d8)] | types.square_bb[@intFromEnum(types.square.a8)];
                board.board[@intFromEnum(types.square.a8)] = rook_piece;
                board.board[@intFromEnum(types.square.d8)] = types.Piece.NO_PIECE;
            },
            else => {},
        }
    }

    // Undo promotion: remove promoted piece, restore pawn at source only
    if (is_promotion_move(flags)) {
        board.pieces[piece_idx] ^= types.square_bb[to]; // remove promoted piece
        const pawn: types.Piece = if (moving_white) types.Piece.WHITE_PAWN else types.Piece.BLACK_PAWN;
        piece = pawn;
        piece_idx = @intFromEnum(pawn);
        // Pawn was cleared from both `from` and `to` during make (XOR from|to, then XOR to),
        // so only restore at `from` — toggling `to` would leave a phantom pawn.
        board.pieces[piece_idx] ^= types.square_bb[from];
    } else {
        // Move piece back in bitboards
        board.pieces[piece_idx] ^= types.square_bb[from] | types.square_bb[to];
    }

    // Update mailbox
    board.board[from] = piece;

    // Undo en passant capture
    if (flags == types.MoveFlags.EN_PASSANT) {
        board.board[to] = types.Piece.NO_PIECE;
        const captured_sq: u6 = if (moving_white) to -% 8 else to +% 8;
        board.pieces[@intFromEnum(undo.captured)] ^= types.square_bb[captured_sq];
        board.board[captured_sq] = undo.captured;
    } else {
        // Restore captured piece (or NO_PIECE for quiet moves)
        board.board[to] = undo.captured;
        if (undo.captured != types.Piece.NO_PIECE) {
            board.pieces[@intFromEnum(undo.captured)] ^= types.square_bb[to];
        }
    }

    // Restore castling rights and ep
    board.castle = undo.castle;
    board.enpassant = undo.enpassant;
}

// Undo info for search path (compact alternative to full BoardState save/restore)
pub const SearchUndo = struct {
    captured: types.Piece, // captured piece (NO_PIECE if quiet)
    castle: u8, // old castling rights
    enpassant: types.square, // old ep square
    hash: u64, // old Zobrist hash
    halfmove: u16, // old half-move clock
    evaluator: eval.Evaluator, // old eval state
};

/// Make move for search path. Like make_move_perft but also updates Zobrist hash and eval.
/// Uses O(1) mailbox lookup instead of scanning bitboards. Returns SearchUndo for unmake.
pub inline fn make_move_search(board: *types.Board, move: Move) SearchUndo {
    const from = move.from;
    const to = move.to;
    const flags = move.flags;

    // O(1) piece lookup from mailbox
    const piece = board.board[from];
    const piece_idx = @intFromEnum(piece);
    const moving_white = piece_idx < 6;
    const pi = zobrist.piece_index(piece);

    // Save undo info
    var undo = SearchUndo{
        .captured = board.board[to], // NO_PIECE for quiet/ep/castle moves
        .castle = board.castle,
        .enpassant = board.enpassant,
        .hash = board.hash,
        .halfmove = board.halfmove,
        .evaluator = eval.global_evaluator,
    };

    // Zobrist: remove piece from source, add to target
    board.hash ^= zobrist.piece_keys[pi][from];
    board.hash ^= zobrist.piece_keys[pi][to];

    // Remove captured piece from its bitboard (regular captures only)
    if (undo.captured != types.Piece.NO_PIECE) {
        board.pieces[@intFromEnum(undo.captured)] ^= types.square_bb[to];
        board.hash ^= zobrist.piece_keys[zobrist.piece_index(undo.captured)][to];
        eval.global_evaluator.remove_piece_phase(undo.captured);
        eval.global_evaluator.remove_piece_material(undo.captured);
    }

    // Move piece in bitboards (XOR trick: clear source + set target in one op)
    board.pieces[piece_idx] ^= types.square_bb[from] | types.square_bb[to];

    // Update mailbox
    board.board[to] = piece;
    board.board[from] = types.Piece.NO_PIECE;

    // Handle en passant capture
    if (flags == types.MoveFlags.EN_PASSANT) {
        const captured_sq: u6 = if (moving_white) to -% 8 else to +% 8;
        const captured_pawn: types.Piece = if (moving_white) types.Piece.BLACK_PAWN else types.Piece.WHITE_PAWN;
        undo.captured = captured_pawn;
        board.pieces[@intFromEnum(captured_pawn)] ^= types.square_bb[captured_sq];
        board.board[captured_sq] = types.Piece.NO_PIECE;
        board.hash ^= zobrist.piece_keys[zobrist.piece_index(captured_pawn)][captured_sq];
        eval.global_evaluator.remove_piece_phase(captured_pawn);
        eval.global_evaluator.remove_piece_material(captured_pawn);
    }

    // Handle promotions
    if (is_promotion_move(flags)) {
        // Remove the pawn from target, add promoted piece
        board.pieces[piece_idx] ^= types.square_bb[to]; // remove pawn
        const side: types.Color = if (moving_white) types.Color.White else types.Color.Black;
        const promoted = get_promoted_piece(flags, side);
        board.pieces[@intFromEnum(promoted)] ^= types.square_bb[to]; // add promoted piece
        board.board[to] = promoted;
        // Zobrist: remove pawn at target (was moved there above), add promoted piece
        board.hash ^= zobrist.piece_keys[pi][to];
        board.hash ^= zobrist.piece_keys[zobrist.piece_index(promoted)][to];
        // Eval: remove pawn, add promoted piece
        eval.global_evaluator.remove_piece_phase(piece);
        eval.global_evaluator.remove_piece_material(piece);
        eval.global_evaluator.put_piece_phase(promoted);
        eval.global_evaluator.add_piece_material(promoted);
    }

    // Reset en passant
    board.enpassant = types.square.NO_SQUARE;

    // Double pawn push - set ep square
    if (flags == types.MoveFlags.DOUBLE_PUSH) {
        board.enpassant = if (moving_white) @enumFromInt(to - 8) else @enumFromInt(to + 8);
    }

    // Castling - move the rook
    if (flags == types.MoveFlags.OO or flags == types.MoveFlags.OOO) {
        const rook_piece: types.Piece = if (moving_white) types.Piece.WHITE_ROOK else types.Piece.BLACK_ROOK;
        const rook_idx = @intFromEnum(rook_piece);
        const rook_pi = zobrist.piece_index(rook_piece);
        switch (to) {
            @intFromEnum(types.square.g1) => {
                board.pieces[rook_idx] ^= types.square_bb[@intFromEnum(types.square.h1)] | types.square_bb[@intFromEnum(types.square.f1)];
                board.board[@intFromEnum(types.square.f1)] = rook_piece;
                board.board[@intFromEnum(types.square.h1)] = types.Piece.NO_PIECE;
                board.hash ^= zobrist.piece_keys[rook_pi][@intFromEnum(types.square.h1)];
                board.hash ^= zobrist.piece_keys[rook_pi][@intFromEnum(types.square.f1)];
            },
            @intFromEnum(types.square.c1) => {
                board.pieces[rook_idx] ^= types.square_bb[@intFromEnum(types.square.a1)] | types.square_bb[@intFromEnum(types.square.d1)];
                board.board[@intFromEnum(types.square.d1)] = rook_piece;
                board.board[@intFromEnum(types.square.a1)] = types.Piece.NO_PIECE;
                board.hash ^= zobrist.piece_keys[rook_pi][@intFromEnum(types.square.a1)];
                board.hash ^= zobrist.piece_keys[rook_pi][@intFromEnum(types.square.d1)];
            },
            @intFromEnum(types.square.g8) => {
                board.pieces[rook_idx] ^= types.square_bb[@intFromEnum(types.square.h8)] | types.square_bb[@intFromEnum(types.square.f8)];
                board.board[@intFromEnum(types.square.f8)] = rook_piece;
                board.board[@intFromEnum(types.square.h8)] = types.Piece.NO_PIECE;
                board.hash ^= zobrist.piece_keys[rook_pi][@intFromEnum(types.square.h8)];
                board.hash ^= zobrist.piece_keys[rook_pi][@intFromEnum(types.square.f8)];
            },
            @intFromEnum(types.square.c8) => {
                board.pieces[rook_idx] ^= types.square_bb[@intFromEnum(types.square.a8)] | types.square_bb[@intFromEnum(types.square.d8)];
                board.board[@intFromEnum(types.square.d8)] = rook_piece;
                board.board[@intFromEnum(types.square.a8)] = types.Piece.NO_PIECE;
                board.hash ^= zobrist.piece_keys[rook_pi][@intFromEnum(types.square.a8)];
                board.hash ^= zobrist.piece_keys[rook_pi][@intFromEnum(types.square.d8)];
            },
            else => {},
        }
    }

    // Update castling rights
    update_castling_rights(board, from, to);

    // Zobrist: update castling rights (XOR out old, XOR in new)
    if (undo.castle != board.castle) {
        if (undo.castle & @intFromEnum(types.Castle.WK) != 0) board.hash ^= zobrist.castle_keys[0];
        if (undo.castle & @intFromEnum(types.Castle.WQ) != 0) board.hash ^= zobrist.castle_keys[1];
        if (undo.castle & @intFromEnum(types.Castle.BK) != 0) board.hash ^= zobrist.castle_keys[2];
        if (undo.castle & @intFromEnum(types.Castle.BQ) != 0) board.hash ^= zobrist.castle_keys[3];
        if (board.castle & @intFromEnum(types.Castle.WK) != 0) board.hash ^= zobrist.castle_keys[0];
        if (board.castle & @intFromEnum(types.Castle.WQ) != 0) board.hash ^= zobrist.castle_keys[1];
        if (board.castle & @intFromEnum(types.Castle.BK) != 0) board.hash ^= zobrist.castle_keys[2];
        if (board.castle & @intFromEnum(types.Castle.BQ) != 0) board.hash ^= zobrist.castle_keys[3];
    }

    // Zobrist: update en passant
    if (undo.enpassant != types.square.NO_SQUARE) {
        board.hash ^= zobrist.ep_keys[@intFromEnum(undo.enpassant) % 8];
    }
    if (board.enpassant != types.square.NO_SQUARE) {
        board.hash ^= zobrist.ep_keys[@intFromEnum(board.enpassant) % 8];
    }

    // Update half-move clock: reset on pawn moves or captures, else increment
    const is_pawn_move = piece == types.Piece.WHITE_PAWN or piece == types.Piece.BLACK_PAWN;
    // undo.captured is set for regular captures and for en passant (updated above)
    const is_capture_move = undo.captured != types.Piece.NO_PIECE;
    board.halfmove = if (is_pawn_move or is_capture_move) 0 else board.halfmove + 1;

    // Zobrist: flip side to move
    board.hash ^= zobrist.side_key;

    // Flip side
    board.side = if (board.side == types.Color.White) types.Color.Black else types.Color.White;

    return undo;
}

/// Unmake move for search path. Reverses make_move_search using saved undo info.
/// Restores hash and eval from undo struct instead of re-XORing.
pub inline fn unmake_move_search(board: *types.Board, move: Move, undo: SearchUndo) void {
    const from = move.from;
    const to = move.to;
    const flags = move.flags;

    // Flip side back
    board.side = if (board.side == types.Color.White) types.Color.Black else types.Color.White;

    // Get the piece on target (may be promoted piece)
    var piece = board.board[to];
    var piece_idx = @intFromEnum(piece);
    const moving_white = @intFromEnum(board.side) == 0;

    // Undo castling rook movement
    if (flags == types.MoveFlags.OO or flags == types.MoveFlags.OOO) {
        const rook_piece: types.Piece = if (moving_white) types.Piece.WHITE_ROOK else types.Piece.BLACK_ROOK;
        const rook_idx = @intFromEnum(rook_piece);
        switch (to) {
            @intFromEnum(types.square.g1) => {
                board.pieces[rook_idx] ^= types.square_bb[@intFromEnum(types.square.f1)] | types.square_bb[@intFromEnum(types.square.h1)];
                board.board[@intFromEnum(types.square.h1)] = rook_piece;
                board.board[@intFromEnum(types.square.f1)] = types.Piece.NO_PIECE;
            },
            @intFromEnum(types.square.c1) => {
                board.pieces[rook_idx] ^= types.square_bb[@intFromEnum(types.square.d1)] | types.square_bb[@intFromEnum(types.square.a1)];
                board.board[@intFromEnum(types.square.a1)] = rook_piece;
                board.board[@intFromEnum(types.square.d1)] = types.Piece.NO_PIECE;
            },
            @intFromEnum(types.square.g8) => {
                board.pieces[rook_idx] ^= types.square_bb[@intFromEnum(types.square.f8)] | types.square_bb[@intFromEnum(types.square.h8)];
                board.board[@intFromEnum(types.square.h8)] = rook_piece;
                board.board[@intFromEnum(types.square.f8)] = types.Piece.NO_PIECE;
            },
            @intFromEnum(types.square.c8) => {
                board.pieces[rook_idx] ^= types.square_bb[@intFromEnum(types.square.d8)] | types.square_bb[@intFromEnum(types.square.a8)];
                board.board[@intFromEnum(types.square.a8)] = rook_piece;
                board.board[@intFromEnum(types.square.d8)] = types.Piece.NO_PIECE;
            },
            else => {},
        }
    }

    // Undo promotion: remove promoted piece, restore pawn at source only
    if (is_promotion_move(flags)) {
        board.pieces[piece_idx] ^= types.square_bb[to]; // remove promoted piece
        const pawn: types.Piece = if (moving_white) types.Piece.WHITE_PAWN else types.Piece.BLACK_PAWN;
        piece = pawn;
        piece_idx = @intFromEnum(pawn);
        board.pieces[piece_idx] ^= types.square_bb[from];
    } else {
        // Move piece back in bitboards
        board.pieces[piece_idx] ^= types.square_bb[from] | types.square_bb[to];
    }

    // Update mailbox
    board.board[from] = piece;

    // Undo en passant capture
    if (flags == types.MoveFlags.EN_PASSANT) {
        board.board[to] = types.Piece.NO_PIECE;
        const captured_sq: u6 = if (moving_white) to -% 8 else to +% 8;
        board.pieces[@intFromEnum(undo.captured)] ^= types.square_bb[captured_sq];
        board.board[captured_sq] = undo.captured;
    } else {
        // Restore captured piece (or NO_PIECE for quiet moves)
        board.board[to] = undo.captured;
        if (undo.captured != types.Piece.NO_PIECE) {
            board.pieces[@intFromEnum(undo.captured)] ^= types.square_bb[to];
        }
    }

    // Restore castling rights, ep, halfmove, hash, and eval from undo struct
    board.castle = undo.castle;
    board.enpassant = undo.enpassant;
    board.halfmove = undo.halfmove;
    board.hash = undo.hash;
    eval.global_evaluator = undo.evaluator;
}

