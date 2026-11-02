const std = @import("std");
const util = @import("util.zig");
const types = @import("types.zig");
const attacks = @import("attacks.zig");
const tabeles = @import("tabeles.zig");
const eval = @import("evaluation.zig");
const zobrist = @import("zobrist.zig");
const print = std.debug.print;

pub fn print_board(bitboard: types.Bitboard) void {
    print("\n", .{});
    for (0..8) |rank| {
        print("  {} ", .{8 - rank});
        for (0..8) |file| {
            const square = (7 - rank) * 8 + file;
            const bit_on_board: u64 = if (util.get_bit(bitboard, square)) 1 else 0;
            print(" {d}", .{(bit_on_board)});
        }
        print("\n", .{});
    }

    print("\n     a b c d e f g h\n\n", .{});
    print(" Bitboard: 0x{0x}\n", .{bitboard});
    print(" Bitboard: 0b{b}\n\n", .{bitboard});
}

pub fn print_unicode_board(board: types.Board) void {
    print("\n", .{});
    for (0..8) |rank| {
        print("  {} ", .{8 - rank});
        for (0..8) |file| {
            const square = (7 - rank) * 8 + file;

            var printed = false;

            for (0..types.Board.PieceCount) |i| {
                const bb = board.pieces[i];
                if (util.get_bit(bb, square)) {
                    print(" {s}", .{types.unicode_piece[i]});
                    printed = true;
                    break;
                }
            }
            if (!printed) {
                print(" .", .{});
            }
        }
        print("\n", .{});
    }
    var fbuf: [128]u8 = undefined;
    print("\n     a b c d e f g h\n\n", .{});
    print(" FEN: {s}\n", .{board_to_fen(&board, 1, &fbuf)});
    print(" Phase white: {}, phase black: {}\n", .{ eval.global_evaluator.phase[0], eval.global_evaluator.phase[1] });
    print(" Bitboard: 0x{0x}\n", .{board.pieces_combined()});
    print(" Bitboard: 0b{b}\n\n", .{board.pieces_combined()});
}

pub fn is_square_attacked(
    board: *const types.Board,
    square: u6,
    comptime by_side: types.Color,
) bool {
    const occ = board.pieces_combined();
    const bbs = board.pieces;

    return switch (by_side) {
        .White => {
            if ((attacks.pawn_attacks_from_square(square, .Black) &
                bbs[@intFromEnum(types.Piece.WHITE_PAWN)]) != 0) return true;
            if ((attacks.piece_attacks(square, occ, .Knight) &
                bbs[@intFromEnum(types.Piece.WHITE_KNIGHT)]) != 0) return true;
            if ((attacks.piece_attacks(square, occ, .King) &
                bbs[@intFromEnum(types.Piece.WHITE_KING)]) != 0) return true;
            if ((attacks.piece_attacks(square, occ, .Bishop) &
                (bbs[@intFromEnum(types.Piece.WHITE_BISHOP)] |
                    bbs[@intFromEnum(types.Piece.WHITE_QUEEN)])) != 0) return true;
            if ((attacks.piece_attacks(square, occ, .Rook) &
                (bbs[@intFromEnum(types.Piece.WHITE_ROOK)] |
                    bbs[@intFromEnum(types.Piece.WHITE_QUEEN)])) != 0) return true;

            return false;
        },
        .Black => {
            if ((attacks.pawn_attacks_from_square(square, .White) &
                bbs[@intFromEnum(types.Piece.BLACK_PAWN)]) != 0) return true;
            if ((attacks.piece_attacks(square, occ, .Knight) &
                bbs[@intFromEnum(types.Piece.BLACK_KNIGHT)]) != 0) return true;
            if ((attacks.piece_attacks(square, occ, .King) &
                bbs[@intFromEnum(types.Piece.BLACK_KING)]) != 0) return true;
            if ((attacks.piece_attacks(square, occ, .Bishop) &
                (bbs[@intFromEnum(types.Piece.BLACK_BISHOP)] |
                    bbs[@intFromEnum(types.Piece.BLACK_QUEEN)])) != 0) return true;
            if ((attacks.piece_attacks(square, occ, .Rook) &
                (bbs[@intFromEnum(types.Piece.BLACK_ROOK)] |
                    bbs[@intFromEnum(types.Piece.BLACK_QUEEN)])) != 0) return true;

            return false;
        },
        .both => unreachable,
    };
}

// True if the king of `color` is attacked
pub inline fn king_attacked(board: *const types.Board, comptime color: types.Color) bool {
    const king = board.pieces[if (color == .White) types.Piece.WHITE_KING.toU4() else types.Piece.BLACK_KING.toU4()];
    if (king == 0) return false;
    return is_square_attacked(board, @intCast(@ctz(king)), comptime color.other());
}

pub const FenError = error{
    InvalidFormat,
    InvalidPosition,
    InvalidCastlingRights,
    InvalidEnPassant,
};

pub fn parse_fen(fen: []const u8, board: *types.Board) !void {
    var it = std.mem.tokenizeAny(u8, fen, " ");
    const placement = it.next() orelse return FenError.InvalidFormat;
    const active = it.next() orelse return FenError.InvalidFormat;
    const castl = it.next() orelse return FenError.InvalidFormat;
    const ep = it.next() orelse return FenError.InvalidFormat;

    // Reset the board
    @memset(board.pieces[0..], 0);
    @memset(board.board[0..], types.Piece.NO_PIECE);
    board.halfmove = 0;
    // Reset the global evaluator
    eval.global_evaluator = eval.Evaluator.init_empty();

    //  parse placement
    var rank: usize = 0;
    var file: usize = 0;
    for (placement) |c| {
        if (c == '/') {
            rank += 1;
            file = 0;
            continue;
        }
        if (c >= '1' and c <= '8') {
            file += @intCast(c - '0');
            continue;
        }
        // Reject the two gap glyphs and NO_PIECE.
        const ord = std.mem.indexOfScalar(u8, types.PieceString, c) orelse return FenError.InvalidFormat;
        if (ord == 6 or ord == 7 or ord >= @intFromEnum(types.Piece.NO_PIECE)) return FenError.InvalidFormat;
        const pe: types.Piece = @enumFromInt(ord);
        if (rank >= 8 or file >= 8) return FenError.InvalidPosition;
        const sq_idx = (7 - rank) * 8 + file;
        const piece_index: usize = @intCast(@intFromEnum(pe));
        board.pieces[piece_index] |= (@as(u64, 1) << @intCast(sq_idx));

        // Update mailbox
        board.board[sq_idx] = pe;

        // Update phase for this piece
        eval.global_evaluator.put_piece_phase(pe);
        // Add material for this piece
        eval.global_evaluator.add_piece_material(pe);
        // Add piece-square table value for this piece (incremental PSQT)
        eval.global_evaluator.add_piece_psqt(pe, @intCast(sq_idx));

        file += 1;
    }

    if (rank != 7) return FenError.InvalidPosition;

    // Active color
    board.side = if (active[0] == 'w') types.Color.White else types.Color.Black;

    // Castling rights
    var mask: u8 = 0;
    if (!std.mem.eql(u8, castl, "-")) {
        for (castl) |c| {
            const i = std.mem.indexOfScalar(u8, types.CastleString, c) orelse return FenError.InvalidCastlingRights;
            mask |= types.castle_bits[i];
        }
    }
    board.castle = mask;

    // set enpassant
    if (std.mem.eql(u8, ep, "-")) {
        board.enpassant = types.square.NO_SQUARE;
    } else if (ep.len == 2) {
        const f: usize = @intCast(ep[0] - 'a');
        const r: usize = @intCast(ep[1] - '1');
        if (f > 7 or r > 7) return FenError.InvalidEnPassant;
        const idx = r * 8 + f;
        board.enpassant = @enumFromInt(idx);
    } else {
        return FenError.InvalidEnPassant;
    }

    // Half-move clock (field 5, optional)
    if (it.next()) |hm| {
        board.halfmove = std.fmt.parseUnsigned(u16, hm, 10) catch 0;
    }

    // Compute Zobrist hash from scratch
    board.hash = zobrist.compute_hash(board);
}

/// Serialize `board` to a standard 6-field FEN into `buf`; returns the written slice.
pub fn board_to_fen(board: *const types.Board, fullmove: u32, buf: []u8) []u8 {
    var w: std.Io.Writer = .fixed(buf);

    // Piece placement: rank 8 (index 7) down to rank 1 (index 0), files a..h.
    var rank: usize = 8;
    while (rank > 0) {
        rank -= 1;
        var empties: u8 = 0;
        var file: usize = 0;
        while (file < 8) : (file += 1) {
            const pc = board.board[rank * 8 + file];
            if (pc == types.Piece.NO_PIECE) {
                empties += 1;
            } else {
                if (empties > 0) {
                    w.print("{d}", .{empties}) catch {};
                    empties = 0;
                }
                w.writeByte(types.PieceString[@intFromEnum(pc)]) catch {};
            }
        }
        if (empties > 0) w.print("{d}", .{empties}) catch {};
        if (rank > 0) w.writeByte('/') catch {};
    }

    // Side to move
    w.writeByte(' ') catch {};
    w.writeByte(if (board.side == types.Color.White) 'w' else 'b') catch {};

    // Castling rights (K Q k q order)
    w.writeByte(' ') catch {};
    if (board.castle == 0) w.writeByte('-') catch {};
    for (types.CastleString, types.castle_bits) |c, bit| {
        if (board.castle & bit != 0) w.writeByte(c) catch {};
    }

    // En passant target
    w.writeByte(' ') catch {};
    if (board.enpassant == types.square.NO_SQUARE) {
        w.writeByte('-') catch {};
    } else {
        w.writeAll(types.SquareString.getSquareToString(board.enpassant)) catch {};
    }

    // Halfmove clock + fullmove number
    w.print(" {d} {d}", .{ board.halfmove, fullmove }) catch {};

    return w.buffered();
}

pub inline fn get_all_attackers(board: *const types.Board, square: u6, occupied: u64) u64 {
    var attackers: u64 = 0;

    const white_pawn_attacks = attacks.pawn_attacks_from_square(square, types.Color.Black);
    attackers |= white_pawn_attacks & board.pieces[@intFromEnum(types.Piece.WHITE_PAWN)];

    const black_pawn_attacks = attacks.pawn_attacks_from_square(square, types.Color.White);
    attackers |= black_pawn_attacks & board.pieces[@intFromEnum(types.Piece.BLACK_PAWN)];

    const knight_attacks = attacks.piece_attacks(square, occupied, types.PieceType.Knight);
    attackers |= knight_attacks & (board.pieces[@intFromEnum(types.Piece.WHITE_KNIGHT)] |
        board.pieces[@intFromEnum(types.Piece.BLACK_KNIGHT)]);

    const bishop_attacks = attacks.get_bishop_attacks(square, occupied);
    attackers |= bishop_attacks & (board.pieces[@intFromEnum(types.Piece.WHITE_BISHOP)] |
        board.pieces[@intFromEnum(types.Piece.BLACK_BISHOP)] |
        board.pieces[@intFromEnum(types.Piece.WHITE_QUEEN)] |
        board.pieces[@intFromEnum(types.Piece.BLACK_QUEEN)]);

    const rook_attacks = attacks.get_rook_attacks(square, occupied);
    attackers |= rook_attacks & (board.pieces[@intFromEnum(types.Piece.WHITE_ROOK)] |
        board.pieces[@intFromEnum(types.Piece.BLACK_ROOK)] |
        board.pieces[@intFromEnum(types.Piece.WHITE_QUEEN)] |
        board.pieces[@intFromEnum(types.Piece.BLACK_QUEEN)]);

    const king_attacks = attacks.piece_attacks(square, occupied, types.PieceType.King);
    attackers |= king_attacks & (board.pieces[@intFromEnum(types.Piece.WHITE_KING)] |
        board.pieces[@intFromEnum(types.Piece.BLACK_KING)]);

    return attackers;
}
