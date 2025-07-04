const std = @import("std");
const util = @import("util.zig");
const types = @import("types.zig");
const attacks = @import("attacks.zig");
const tables = @import("tabeles.zig");
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
                    print(" {s}", .{types.unicodePice[i]});
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
    const side_str = switch (board.side) {
        .White => "White",
        .Black => "Black",
        else => "Both",
    };

    print("\n     a b c d e f g h\n\n", .{});
    print(" Side: {s}\n", .{side_str});
    // print(" En-passant: {s}\n", .{board.enpassant});
    // print(" Castling:   {s}\n", .{cast_str})
    print(" Bitboard: 0x{0x}\n", .{board.pieces_combined()});
    print(" Bitboard: 0b{b}\n\n", .{board.pieces_combined()});
}

pub fn print_attacked_squares(board: *types.Board) void {
    const occ = board.pieces_combined();
    const bbs = board.pieces;
    const side = board.side;

    print("\n", .{});

    for (0..8) |rank| {
        print("  {} ", .{8 - rank});
        for (0..8) |file| {
            const square: u6 = @intCast((7 - rank) * 8 + file);
            const attacked = switch (side) {
                .White => (attacks.pawn_attacks_from_square(square, .Black) & bbs[@intFromEnum(types.Piece.WHITE_PAWN)]) != 0 or
                    (attacks.piece_attacks(square, occ, types.PieceType.Knight) & bbs[@intFromEnum(types.Piece.WHITE_KNIGHT)]) != 0 or
                    (attacks.piece_attacks(square, occ, types.PieceType.Bishop) & bbs[@intFromEnum(types.Piece.WHITE_BISHOP)]) != 0 or
                    (attacks.piece_attacks(square, occ, types.PieceType.Rook) & bbs[@intFromEnum(types.Piece.WHITE_ROOK)]) != 0 or
                    (attacks.get_queen_attacks(square, occ) & bbs[@intFromEnum(types.Piece.WHITE_QUEEN)]) != 0 or
                    (attacks.piece_attacks(square, occ, types.PieceType.King) & bbs[@intFromEnum(types.Piece.WHITE_KING)]) != 0,

                .Black => (attacks.pawn_attacks_from_square(square, .White) & bbs[@intFromEnum(types.Piece.BLACK_PAWN)]) != 0 or
                    (attacks.piece_attacks(square, occ, types.PieceType.Knight) & bbs[@intFromEnum(types.Piece.BLACK_KNIGHT)]) != 0 or
                    (attacks.piece_attacks(square, occ, types.PieceType.Bishop) & bbs[@intFromEnum(types.Piece.BLACK_BISHOP)]) != 0 or
                    (attacks.piece_attacks(square, occ, types.PieceType.Rook) & bbs[@intFromEnum(types.Piece.BLACK_ROOK)]) != 0 or
                    (attacks.get_queen_attacks(square, occ) & bbs[@intFromEnum(types.Piece.BLACK_QUEEN)]) != 0 or
                    (attacks.piece_attacks(square, occ, types.PieceType.King) & bbs[@intFromEnum(types.Piece.BLACK_KING)]) != 0,

                else => unreachable,
            };
            const ch: u8 = if (attacked) 'X' else '.';
            print(" {c} ", .{ch});
        }
        print("\n", .{});
    }

    print("\n   a  b  c  d  e  f  g  h\n", .{});
}

pub fn is_square_attacked(
    board: *const types.Board,
    square: u6,
    by_side: types.Color,
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

pub fn print_attacked_squares_new(board: *types.Board) void {
    print("\n", .{});
    print("--- Attacked squares for side: {} ---\n", .{board.side});

    for (0..8) |rank| {
        print("  {} ", .{8 - rank});
        for (0..8) |file| {
            const square: u6 = @intCast((7 - rank) * 8 + file);

            const attacked = is_square_attacked(board, square, board.side);
            const ch: u8 = if (attacked) 'X' else '.';
            print(" {c} ", .{ch});
        }
        print("\n", .{});
    }

    print("\n   a  b  c  d  e  f  g  h\n", .{});
}

pub const FenError = error{
    InvalidFormat,
    InvalidPosition,
    InvalidCastlingRights,
    InvalidEnPassant,
};

pub fn fan_pars(fen: []const u8, board: *types.Board) !void {
    var it = std.mem.tokenizeAny(u8, fen, " ");
    const placement = it.next() orelse return FenError.InvalidFormat;
    const active = it.next() orelse return FenError.InvalidFormat;
    const castl = it.next() orelse return FenError.InvalidFormat;
    const ep = it.next() orelse return FenError.InvalidFormat;

    // print("FEN fields:\n", .{});
    // print("  placement: {s}\n", .{placement});
    // print("  active   : {s}\n", .{active});
    // print("  castling : {s}\n", .{castl});
    // print("  en-pass. : {s}\n\n", .{ep});

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
        const pe = switch (c) {
            'P' => types.Piece.WHITE_PAWN,
            'N' => types.Piece.WHITE_KNIGHT,
            'B' => types.Piece.WHITE_BISHOP,
            'R' => types.Piece.WHITE_ROOK,
            'Q' => types.Piece.WHITE_QUEEN,
            'K' => types.Piece.WHITE_KING,
            'p' => types.Piece.BLACK_PAWN,
            'n' => types.Piece.BLACK_KNIGHT,
            'b' => types.Piece.BLACK_BISHOP,
            'r' => types.Piece.BLACK_ROOK,
            'q' => types.Piece.BLACK_QUEEN,
            'k' => types.Piece.BLACK_KING,
            else => return FenError.InvalidFormat,
        };
        if (rank >= 8 or file >= 8) return FenError.InvalidPosition;
        const sq_idx = (7 - rank) * 8 + file;
        const piece_index: usize = @intCast(@intFromEnum(pe));
        board.pieces[piece_index] |= (@as(u64, 1) << @intCast(sq_idx));
        file += 1;
    }

    if (rank != 7) return FenError.InvalidPosition;

    // Active color
    board.side = if (active[0] == 'w') types.Color.White else types.Color.Black;

    // Castling rights
    var mask: u8 = 0;
    if (!std.mem.eql(u8, castl, "-")) {
        for (castl) |c| {
            switch (c) {
                'K' => mask |= @intFromEnum(types.Castle.WK),
                'Q' => mask |= @intFromEnum(types.Castle.WQ),
                'k' => mask |= @intFromEnum(types.Castle.BK),
                'q' => mask |= @intFromEnum(types.Castle.BQ),
                else => return FenError.InvalidCastlingRights,
            }
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
}
