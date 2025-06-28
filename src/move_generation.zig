const std = @import("std");
const types = @import("types.zig");
const attacks = @import("attacks.zig");
const lists = @import("lists.zig");
const util = @import("util.zig");
const bitboard = @import("bitboard.zig");
const print = std.debug.print;

pub const Print_move_list = struct {
    pub inline fn is_capture(move: Move) bool {
        return switch (move.flags) {
            types.MoveFlags.CAPTURE, types.MoveFlags.EN_PASSANT, types.MoveFlags.PC_QUEEN, types.MoveFlags.PC_ROOK, types.MoveFlags.PC_BISHOP, types.MoveFlags.PC_KNIGHT => true,
            else => false,
        };
    }

    pub inline fn is_promotion(move: Move) bool {
        return switch (move.flags) {
            types.MoveFlags.PR_QUEEN, types.MoveFlags.PR_ROOK, types.MoveFlags.PR_BISHOP, types.MoveFlags.PR_KNIGHT, types.MoveFlags.PC_QUEEN, types.MoveFlags.PC_ROOK, types.MoveFlags.PC_BISHOP, types.MoveFlags.PC_KNIGHT => true,
            else => false,
        };
    }
    pub inline fn is_double_push(move: Move) bool {
        return move.flags == types.MoveFlags.DOUBLE_PUSH;
    }

    pub inline fn is_en_passant(move: Move) bool {
        return move.flags == types.MoveFlags.EN_PASSANT;
    }

    pub inline fn is_castling(move: Move) bool {
        return move.flags == types.MoveFlags.OO or move.flags == types.MoveFlags.OOO;
    }

    pub inline fn get_promotion_char(move: Move) u8 {
        return switch (move.flags) {
            types.MoveFlags.PR_QUEEN, types.MoveFlags.PC_QUEEN => 'q',
            types.MoveFlags.PR_ROOK, types.MoveFlags.PC_ROOK => 'r',
            types.MoveFlags.PR_BISHOP, types.MoveFlags.PC_BISHOP => 'b',
            types.MoveFlags.PR_KNIGHT, types.MoveFlags.PC_KNIGHT => 'n',
            else => ' ',
        };
    }

    pub fn print_list(move_list: *lists.MoveList) void {
        // Handle empty move list
        if (move_list.count == 0) {
            print("\n     No moves in the move list!\n", .{});
            return;
        }

        print("\n     move      capture   double    enpass    castling  promotion\n\n", .{});

        for (0..move_list.count) |i| {
            const move = move_list.moves[i];
            const from_sq: types.square = @enumFromInt(move.from);
            const to_sq: types.square = @enumFromInt(move.to);
            const from_str = types.SquareString.getSquareToString(from_sq);
            const to_str = types.SquareString.getSquareToString(to_sq);

            const promotion_char = if (is_promotion(move)) get_promotion_char(move) else ' ';

            print("     {s}{s}{c}      {d}         {d}         {d}         {d}         {c}\n", .{
                from_str,
                to_str,
                promotion_char,
                if (is_capture(move)) @as(u8, 1) else @as(u8, 0),
                if (is_double_push(move)) @as(u8, 1) else @as(u8, 0),
                if (is_en_passant(move)) @as(u8, 1) else @as(u8, 0),
                if (is_castling(move)) @as(u8, 1) else @as(u8, 0),
                promotion_char,
            });
        }

        print("\n\n     Total number of moves: {d}\n\n", .{move_list.count});
    }

    fn print_move_description(board: *types.Board, move: Move) void {
        const from_sq: types.square = @enumFromInt(move.from);
        const to_sq: types.square = @enumFromInt(move.to);
        const from_str = types.SquareString.getSquareToString(from_sq);
        const to_str = types.SquareString.getSquareToString(to_sq);

        // Get the piece at the from square
        const piece = board.pieces;
        var piece_name: []const u8 = "unknown";
        var piece_found = false;

        // Find which piece is at the from square
        if (util.get_bit(piece[@intFromEnum(types.Piece.WHITE_PAWN)], move.from) or
            util.get_bit(piece[@intFromEnum(types.Piece.BLACK_PAWN)], move.from))
        {
            piece_name = "pawn";
            piece_found = true;
        } else if (util.get_bit(piece[@intFromEnum(types.Piece.WHITE_KNIGHT)], move.from) or
            util.get_bit(piece[@intFromEnum(types.Piece.BLACK_KNIGHT)], move.from))
        {
            piece_name = "knight";
            piece_found = true;
        } else if (util.get_bit(piece[@intFromEnum(types.Piece.WHITE_BISHOP)], move.from) or
            util.get_bit(piece[@intFromEnum(types.Piece.BLACK_BISHOP)], move.from))
        {
            piece_name = "bishop";
            piece_found = true;
        } else if (util.get_bit(piece[@intFromEnum(types.Piece.WHITE_ROOK)], move.from) or
            util.get_bit(piece[@intFromEnum(types.Piece.BLACK_ROOK)], move.from))
        {
            piece_name = "rook";
            piece_found = true;
        } else if (util.get_bit(piece[@intFromEnum(types.Piece.WHITE_QUEEN)], move.from) or
            util.get_bit(piece[@intFromEnum(types.Piece.BLACK_QUEEN)], move.from))
        {
            piece_name = "queen";
            piece_found = true;
        } else if (util.get_bit(piece[@intFromEnum(types.Piece.WHITE_KING)], move.from) or
            util.get_bit(piece[@intFromEnum(types.Piece.BLACK_KING)], move.from))
        {
            piece_name = "king";
            piece_found = true;
        }

        if (!piece_found) {
            print("{s} at {s} -> {s} (unknown piece)\n", .{ piece_name, from_str, to_str });
            return;
        }

        // Describe the action
        const action = switch (move.flags) {
            types.MoveFlags.QUIET => "can move to",
            types.MoveFlags.DOUBLE_PUSH => "can double push to",
            types.MoveFlags.CAPTURE => "can capture at",
            types.MoveFlags.EN_PASSANT => "can capture en passant at",
            types.MoveFlags.OO => "can castle kingside",
            types.MoveFlags.OOO => "can castle queenside",
            types.MoveFlags.PR_QUEEN => "can push and promote to queen at",
            types.MoveFlags.PR_ROOK => "can push and promote to rook at",
            types.MoveFlags.PR_BISHOP => "can push and promote to bishop at",
            types.MoveFlags.PR_KNIGHT => "can push and promote to knight at",
            types.MoveFlags.PC_QUEEN => "can capture and promote to queen at",
            types.MoveFlags.PC_ROOK => "can capture and promote to rook at",
            types.MoveFlags.PC_BISHOP => "can capture and promote to bishop at",
            types.MoveFlags.PC_KNIGHT => "can capture and promote to knight at",
            else => "can make unknown move to",
        };

        if (move.flags == types.MoveFlags.OO or move.flags == types.MoveFlags.OOO) {
            print("{s} at {s} {s}\n", .{ piece_name, from_str, action });
        } else {
            print("{s} at {s} {s} {s}\n", .{ piece_name, from_str, action, to_str });
        }
    }

    pub fn print_move_list_descriptive(board: *types.Board, move_list: *lists.MoveList, color_name: []const u8) void {
        if (move_list.count == 0) {
            print("\n{s} has no legal moves!\n\n", .{color_name});
            return;
        }

        print("\n=== {s} Moves ===\n", .{color_name});
        for (0..move_list.count) |i| {
            const move = move_list.moves[i];
            print("{d:2}. ", .{i + 1});
            print_move_description(board, move);
        }
        print("\nTotal: {d} moves\n\n", .{move_list.count});
    }
};

pub const Move = struct {
    from: u6,
    to: u6,
    flags: types.MoveFlags,

    pub inline fn new(from: u6, to: u6, flags: types.MoveFlags) Move {
        return Move{ .from = from, .to = to, .flags = flags };
    }
};

pub fn generate_moves(board: *types.Board, list: *lists.MoveList, comptime color: types.Color) void {
    const us = color;
    const them = if (us == types.Color.White) types.Color.Black else types.Color.White;

    const us_bb: u64 = board.set_pieces(us);
    const them_bb: u64 = board.set_pieces(them);
    const occ = us_bb | them_bb;

    // Pawn moves (existing code)
    const pawn_piece = if (us == types.Color.White) types.Piece.WHITE_PAWN else types.Piece.BLACK_PAWN;
    var b: u64 = board.pieces[@intFromEnum(pawn_piece)];

    while (b != 0) {
        const from_idx = util.lsb_index(b);
        const from: u6 = @intCast(from_idx);
        b &= b - 1;
        const from_bb = types.squar_bb[from];

        // single push
        const dir: u64 = if (us == types.Color.White) from_bb << 8 else from_bb >> 8;
        if ((dir & occ) == 0) {
            const to_idx = util.lsb_index(dir);
            const to: u6 = @intCast(to_idx);

            // promotion rank check
            if ((dir & types.mask_rank[if (us == types.Color.White) 7 else 0]) != 0) {
                list.append(Move.new(from, to, types.MoveFlags.PR_QUEEN));
                list.append(Move.new(from, to, types.MoveFlags.PR_ROOK));
                list.append(Move.new(from, to, types.MoveFlags.PR_BISHOP));
                list.append(Move.new(from, to, types.MoveFlags.PR_KNIGHT));
            } else {
                list.append(Move.new(from, to, types.MoveFlags.QUIET));

                // double push
                const start_mask = types.mask_rank[if (us == types.Color.White) 1 else 6];
                if ((from_bb & start_mask) != 0) {
                    const dir2 = if (us == types.Color.White) from_bb << 16 else from_bb >> 16;
                    if ((dir2 & occ) == 0) {
                        const to2: u6 = @intCast(util.lsb_index(dir2));
                        list.append(Move.new(from, to2, types.MoveFlags.DOUBLE_PUSH));
                    }
                }
            }
        }

        // captures & promotions
        const cap_bb = attacks.pawn_attacks_from_square(from, us) & them_bb;
        var c: u64 = cap_bb;
        while (c != 0) {
            const to_idx = util.lsb_index(c);
            const to: u6 = @intCast(to_idx);
            c &= c - 1;

            // promotion rank check for captures
            if ((types.squar_bb[to] & types.mask_rank[if (us == types.Color.White) 7 else 0]) != 0) {
                list.append(Move.new(from, to, types.MoveFlags.PC_QUEEN));
                list.append(Move.new(from, to, types.MoveFlags.PC_ROOK));
                list.append(Move.new(from, to, types.MoveFlags.PC_BISHOP));
                list.append(Move.new(from, to, types.MoveFlags.PC_KNIGHT));
            } else {
                list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
            }
        }

        // en-passant
        if (board.enpassant != types.square.NO_SQUARE) {
            const ep_sq: u6 = @intCast(@intFromEnum(board.enpassant));
            const ep_bb = types.squar_bb[ep_sq];
            if ((attacks.pawn_attacks_from_square(from, us) & ep_bb) != 0) {
                list.append(Move.new(from, ep_sq, types.MoveFlags.EN_PASSANT));
            }
        }
    }

    // Knight moves
    const knight_piece = if (us == types.Color.White) types.Piece.WHITE_KNIGHT else types.Piece.BLACK_KNIGHT;
    b = board.pieces[@intFromEnum(knight_piece)];
    while (b != 0) {
        const from_idx = util.lsb_index(b);
        const from: u6 = @intCast(from_idx);
        b &= b - 1;

        const knight_attacks = attacks.piece_attacks(from, occ, types.PieceType.Knight);

        // Quiet moves
        var quiet_targets = knight_attacks & ~occ;
        while (quiet_targets != 0) {
            const to: u6 = @intCast(util.lsb_index(quiet_targets));
            list.append(Move.new(from, to, types.MoveFlags.QUIET));
            quiet_targets &= quiet_targets - 1;
        }

        // Captures
        var capture_targets = knight_attacks & them_bb;
        while (capture_targets != 0) {
            const to: u6 = @intCast(util.lsb_index(capture_targets));
            list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
            capture_targets &= capture_targets - 1;
        }
    }

    // Bishop moves
    const bishop_piece = if (us == types.Color.White) types.Piece.WHITE_BISHOP else types.Piece.BLACK_BISHOP;
    b = board.pieces[@intFromEnum(bishop_piece)];
    while (b != 0) {
        const from_idx = util.lsb_index(b);
        const from: u6 = @intCast(from_idx);
        b &= b - 1;

        const bishop_attacks_bb = attacks.get_bishop_attacks(from, occ);

        // Quiet moves
        var quiet_targets = bishop_attacks_bb & ~occ;
        while (quiet_targets != 0) {
            const to: u6 = @intCast(util.lsb_index(quiet_targets));
            list.append(Move.new(from, to, types.MoveFlags.QUIET));
            quiet_targets &= quiet_targets - 1;
        }

        // Captures
        var capture_targets = bishop_attacks_bb & them_bb;
        while (capture_targets != 0) {
            const to: u6 = @intCast(util.lsb_index(capture_targets));
            list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
            capture_targets &= capture_targets - 1;
        }
    }

    // Rook moves
    const rook_piece = if (us == types.Color.White) types.Piece.WHITE_ROOK else types.Piece.BLACK_ROOK;
    b = board.pieces[@intFromEnum(rook_piece)];
    while (b != 0) {
        const from_idx = util.lsb_index(b);
        const from: u6 = @intCast(from_idx);
        b &= b - 1;

        const rook_attacks_bb = attacks.get_rook_attacks(from, occ);

        // Quiet moves
        var quiet_targets = rook_attacks_bb & ~occ;
        while (quiet_targets != 0) {
            const to: u6 = @intCast(util.lsb_index(quiet_targets));
            list.append(Move.new(from, to, types.MoveFlags.QUIET));
            quiet_targets &= quiet_targets - 1;
        }

        // Captures
        var capture_targets = rook_attacks_bb & them_bb;
        while (capture_targets != 0) {
            const to: u6 = @intCast(util.lsb_index(capture_targets));
            list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
            capture_targets &= capture_targets - 1;
        }
    }

    // Queen moves
    const queen_piece = if (us == types.Color.White) types.Piece.WHITE_QUEEN else types.Piece.BLACK_QUEEN;
    b = board.pieces[@intFromEnum(queen_piece)];
    while (b != 0) {
        const from_idx = util.lsb_index(b);
        const from: u6 = @intCast(from_idx);
        b &= b - 1;

        const queen_attacks_bb = attacks.get_queen_attacks(from, occ);

        // Quiet moves
        var quiet_targets = queen_attacks_bb & ~occ;
        while (quiet_targets != 0) {
            const to: u6 = @intCast(util.lsb_index(quiet_targets));
            list.append(Move.new(from, to, types.MoveFlags.QUIET));
            quiet_targets &= quiet_targets - 1;
        }

        // Captures
        var capture_targets = queen_attacks_bb & them_bb;
        while (capture_targets != 0) {
            const to: u6 = @intCast(util.lsb_index(capture_targets));
            list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
            capture_targets &= capture_targets - 1;
        }
    }

    // King moves
    const king_piece = if (us == types.Color.White) types.Piece.WHITE_KING else types.Piece.BLACK_KING;
    b = board.pieces[@intFromEnum(king_piece)];
    if (b != 0) {
        const from_idx = util.lsb_index(b);
        const from: u6 = @intCast(from_idx);

        const king_attacks_bb = attacks.piece_attacks(from, occ, types.PieceType.King);

        // Quiet moves
        var quiet_targets = king_attacks_bb & ~occ;
        while (quiet_targets != 0) {
            const to: u6 = @intCast(util.lsb_index(quiet_targets));
            list.append(Move.new(from, to, types.MoveFlags.QUIET));
            quiet_targets &= quiet_targets - 1;
        }

        // Captures
        var capture_targets = king_attacks_bb & them_bb;
        while (capture_targets != 0) {
            const to: u6 = @intCast(util.lsb_index(capture_targets));
            list.append(Move.new(from, to, types.MoveFlags.CAPTURE));
            capture_targets &= capture_targets - 1;
        }
    }

    // Castling
    if (us == types.Color.White) {
        // White kingside castling
        if ((board.castle & @intFromEnum(types.Castle.WK)) != 0) {
            if ((occ & 0x60) == 0) { // f1 and g1 empty
                if (!bitboard.is_square_attacked(board, @intFromEnum(types.square.e1), them) and
                    !bitboard.is_square_attacked(board, @intFromEnum(types.square.f1), them) and
                    !bitboard.is_square_attacked(board, @intFromEnum(types.square.g1), them))
                {
                    list.append(Move.new(@intFromEnum(types.square.e1), @intFromEnum(types.square.g1), types.MoveFlags.OO));
                }
            }
        }

        // White queenside castling
        if ((board.castle & @intFromEnum(types.Castle.WQ)) != 0) {
            if ((occ & 0xe) == 0) { // b1, c1, d1 empty
                if (!bitboard.is_square_attacked(board, @intFromEnum(types.square.e1), them) and
                    !bitboard.is_square_attacked(board, @intFromEnum(types.square.d1), them) and
                    !bitboard.is_square_attacked(board, @intFromEnum(types.square.c1), them))
                {
                    list.append(Move.new(@intFromEnum(types.square.e1), @intFromEnum(types.square.c1), types.MoveFlags.OOO));
                }
            }
        }
    } else {
        // Black kingside castling
        if ((board.castle & @intFromEnum(types.Castle.BK)) != 0) {
            if ((occ & 0x6000000000000000) == 0) { // f8 and g8 empty
                if (!bitboard.is_square_attacked(board, @intFromEnum(types.square.e8), them) and
                    !bitboard.is_square_attacked(board, @intFromEnum(types.square.f8), them) and
                    !bitboard.is_square_attacked(board, @intFromEnum(types.square.g8), them))
                {
                    list.append(Move.new(@intFromEnum(types.square.e8), @intFromEnum(types.square.g8), types.MoveFlags.OO));
                }
            }
        }

        // Black queenside castling
        if ((board.castle & @intFromEnum(types.Castle.BQ)) != 0) {
            if ((occ & 0xe00000000000000) == 0) { // b8, c8, d8 empty
                if (!bitboard.is_square_attacked(board, @intFromEnum(types.square.e8), them) and
                    !bitboard.is_square_attacked(board, @intFromEnum(types.square.d8), them) and
                    !bitboard.is_square_attacked(board, @intFromEnum(types.square.c8), them))
                {
                    list.append(Move.new(@intFromEnum(types.square.e8), @intFromEnum(types.square.c8), types.MoveFlags.OOO));
                }
            }
        }
    }
}

// Update castling rights using bitboard masks
inline fn update_castling_rights(board: *types.Board, source_square: u6, target_square: u6) void {
    const source_bb = types.squar_bb[source_square];
    const target_bb = types.squar_bb[target_square];

    // Check if any critical castling squares were touched
    if ((source_bb | target_bb) & types.casteling_rights != 0) {
        // White king moved from e1
        if (source_square == @intFromEnum(types.square.e1)) {
            board.castle &= ~(@intFromEnum(types.Castle.WK) | @intFromEnum(types.Castle.WQ));
        }
        // Black king moved from e8
        else if (source_square == @intFromEnum(types.square.e8)) {
            board.castle &= ~(@intFromEnum(types.Castle.BK) | @intFromEnum(types.Castle.BQ));
        }

        // White rook moves or captures
        if (source_square == @intFromEnum(types.square.a1) or target_square == @intFromEnum(types.square.a1)) {
            board.castle &= ~@intFromEnum(types.Castle.WQ);
        }
        if (source_square == @intFromEnum(types.square.h1) or target_square == @intFromEnum(types.square.h1)) {
            board.castle &= ~@intFromEnum(types.Castle.WK);
        }

        // Black rook moves or captures
        if (source_square == @intFromEnum(types.square.a8) or target_square == @intFromEnum(types.square.a8)) {
            board.castle &= ~@intFromEnum(types.Castle.BQ);
        }
        if (source_square == @intFromEnum(types.square.h8) or target_square == @intFromEnum(types.square.h8)) {
            board.castle &= ~@intFromEnum(types.Castle.BK);
        }
    }
}

// Helper function to handle castling rook movement
inline fn handle_castling(board: *types.Board, target_square: u6, side: types.Color) void {
    const rook_piece = if (side == types.Color.White) types.Piece.WHITE_ROOK else types.Piece.BLACK_ROOK;

    switch (target_square) {
        // White kingside castling
        @intFromEnum(types.square.g1) => {
            board.pieces[@intFromEnum(rook_piece)] = util.clear_bit(board.pieces[@intFromEnum(rook_piece)], types.square.h1);
            board.pieces[@intFromEnum(rook_piece)] = util.set_bit(board.pieces[@intFromEnum(rook_piece)], types.square.f1);
        },
        // White queenside castling
        @intFromEnum(types.square.c1) => {
            board.pieces[@intFromEnum(rook_piece)] = util.clear_bit(board.pieces[@intFromEnum(rook_piece)], types.square.a1);
            board.pieces[@intFromEnum(rook_piece)] = util.set_bit(board.pieces[@intFromEnum(rook_piece)], types.square.d1);
        },
        // Black kingside castling
        @intFromEnum(types.square.g8) => {
            board.pieces[@intFromEnum(rook_piece)] = util.clear_bit(board.pieces[@intFromEnum(rook_piece)], types.square.h8);
            board.pieces[@intFromEnum(rook_piece)] = util.set_bit(board.pieces[@intFromEnum(rook_piece)], types.square.f8);
        },
        // Black queenside castling
        @intFromEnum(types.square.c8) => {
            board.pieces[@intFromEnum(rook_piece)] = util.clear_bit(board.pieces[@intFromEnum(rook_piece)], types.square.a8);
            board.pieces[@intFromEnum(rook_piece)] = util.set_bit(board.pieces[@intFromEnum(rook_piece)], types.square.d8);
        },
        else => {},
    }
}

inline fn is_capture_move(flags: types.MoveFlags) bool {
    return switch (flags) {
        types.MoveFlags.CAPTURE, types.MoveFlags.EN_PASSANT, types.MoveFlags.PC_QUEEN, types.MoveFlags.PC_ROOK, types.MoveFlags.PC_BISHOP, types.MoveFlags.PC_KNIGHT => true,
        else => false,
    };
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

pub fn make_move(board: *types.Board, move: Move) bool {
    const saved_state = board.save_state();

    const source_square = move.from;
    const target_square = move.to;
    const move_flags = move.flags;

    // Find the piece to move by checking what's actually at the source square
    var piece_type: types.Piece = types.Piece.NO_PIECE;
    var moving_side: types.Color = undefined;

    // Check all pieces to find what's at the source square
    for (0..types.Board.PieceCount) |i| {
        if (i == @intFromEnum(types.Piece.NO_PIECE)) continue;
        if (util.get_bit(board.pieces[i], source_square)) {
            piece_type = @enumFromInt(i);
            break;
        }
    }

    if (piece_type == types.Piece.NO_PIECE) return false;

    // Determine the moving side based on the piece found
    moving_side = if (@intFromEnum(piece_type) < 6) types.Color.White else types.Color.Black;

    // Move the piece
    board.pieces[@intFromEnum(piece_type)] = util.clear_bit(board.pieces[@intFromEnum(piece_type)], @enumFromInt(source_square));
    board.pieces[@intFromEnum(piece_type)] = util.set_bit(board.pieces[@intFromEnum(piece_type)], @enumFromInt(target_square));

    // Handle captures
    if (is_capture_move(move_flags)) {
        if (move_flags != types.MoveFlags.EN_PASSANT) {
            // Regular capture - find and remove the captured piece
            const enemy_pieces = if (moving_side == types.Color.White)
                [_]usize{ 8, 9, 10, 11, 12, 13 } // Black pieces
            else
                [_]usize{ 0, 1, 2, 3, 4, 5 }; // White pieces

            for (enemy_pieces) |captured_piece_idx| {
                if (util.get_bit(board.pieces[captured_piece_idx], target_square)) {
                    board.pieces[captured_piece_idx] = util.clear_bit(board.pieces[captured_piece_idx], @enumFromInt(target_square));
                    break;
                }
            }
        }
    }

    // Handle promotions
    if (is_promotion_move(move_flags)) {
        const pawn_piece = if (moving_side == types.Color.White) types.Piece.WHITE_PAWN else types.Piece.BLACK_PAWN;
        board.pieces[@intFromEnum(pawn_piece)] = util.clear_bit(board.pieces[@intFromEnum(pawn_piece)], @enumFromInt(target_square));

        const promoted_piece = get_promoted_piece(move_flags, moving_side);
        board.pieces[@intFromEnum(promoted_piece)] = util.set_bit(board.pieces[@intFromEnum(promoted_piece)], @enumFromInt(target_square));
    }

    // Handle en passant capture
    if (move_flags == types.MoveFlags.EN_PASSANT) {
        const captured_pawn_square: u6 = if (moving_side == types.Color.White)
            target_square - 8
        else
            target_square + 8;

        const captured_pawn = if (moving_side == types.Color.White) types.Piece.BLACK_PAWN else types.Piece.WHITE_PAWN;
        board.pieces[@intFromEnum(captured_pawn)] = util.clear_bit(board.pieces[@intFromEnum(captured_pawn)], @enumFromInt(captured_pawn_square));
    }

    // Reset en passant square
    board.enpassant = types.square.NO_SQUARE;

    // Handle double pawn push
    if (move_flags == types.MoveFlags.DOUBLE_PUSH) {
        board.enpassant = if (moving_side == types.Color.White)
            @enumFromInt(target_square - 8)
        else
            @enumFromInt(target_square + 8);
    }

    // Handle castling moves
    if (move_flags == types.MoveFlags.OO or move_flags == types.MoveFlags.OOO) {
        handle_castling(board, target_square, moving_side);
    }

    // Update castling rights using bitboard masks
    update_castling_rights(board, source_square, target_square);

    // Check if move leaves our king in check (illegal move)
    const our_king_piece = if (moving_side == types.Color.White) types.Piece.WHITE_KING else types.Piece.BLACK_KING;
    const our_king_square: u6 = @intCast(util.lsb_index(board.pieces[@intFromEnum(our_king_piece)]));
    const opponent_side = if (moving_side == types.Color.White) types.Color.Black else types.Color.White;

    if (bitboard.is_square_attacked(board, our_king_square, opponent_side)) {
        // Restore board state - illegal move
        board.restore_state(saved_state);
        return false;
    }

    // Change side to move only after confirming the move is legal
    board.side = if (board.side == types.Color.White) types.Color.Black else types.Color.White;

    return true;
}

pub fn make_capture_only(board: *types.Board, move: Move) bool {
    if (is_capture_move(move.flags)) {
        return make_move(board, move);
    }
    return false;
}

pub fn try_make_move(board: *types.Board, move: Move) bool {
    return make_move(board, move);
}
