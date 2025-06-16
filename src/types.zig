const std = @import("std");

// Bitboard type
pub const Bitboard = u64;

// empty Bitboard
pub const empty_Bitboard: Bitboard = 0;

// the number of squares on a chess board
pub const number_of_squares = 64;

// Little endian rank-file (LERF) mapping
pub const square = enum {
    // zig fmt: off
    a1, b1, c1, d1, e1, f1, g1, h1,
    a2, b2, c2, d2, e2, f2, g2, h2,
    a3, b3, c3, d3, e3, f3, g3, h3,
    a4, b4, c4, d4, e4, f4, g4, h4,
    a5, b5, c5, d5, e5, f5, g5, h5,
    a6, b6, c6, d6, e6, f6, g6, h6,
    a7, b7, c7, d7, e7, f7, g7, h7,
    a8, b8, c8, d8, e8, f8, g8, h8,
    NO_SQUARE,
    // zig fmt: on
    //
    pub fn index(self: square) usize {
        return @intFromEnum(self);
    }

    pub inline fn toU6(self: square) u6 {
        return @as(u6, @truncate(@intFromEnum(self)));
    }
};

pub const square_number = [_]usize{
    0,  1,  2,  3,  4,  5,  6,  7,
    8,  9,  10, 11, 12, 13, 14, 15,
    16, 17, 18, 19, 20, 21, 22, 23,
    24, 25, 26, 27, 28, 29, 30, 31,
    32, 33, 34, 35, 36, 37, 38, 39,
    40, 41, 42, 43, 44, 45, 46, 47,
    48, 49, 50, 51, 52, 53, 54, 55,
    56, 57, 58, 59, 60, 61, 62, 63,
};

pub const SquareString = struct {
    pub const SquareToString = [_][:0]const u8{ "a1", "b1", "c1", "d1", "e1", "f1", "g1", "h1", "a2", "b2", "c2", "d2", "e2", "f2", "g2", "h2", "a3", "b3", "c3", "d3", "e3", "f3", "g3", "h3", "a4", "b4", "c4", "d4", "e4", "f4", "g4", "h4", "a5", "b5", "c5", "d5", "e5", "f5", "g5", "h5", "a6", "b6", "c6", "d6", "e6", "f6", "g6", "h6", "a7", "b7", "c7", "d7", "e7", "f7", "g7", "h7", "a8", "b8", "c8", "d8", "e8", "f8", "g8", "h8", "None" };

    pub fn getSquareToString(sq: square) []const u8 {
        const idx: usize = @intFromEnum(sq);
        return SquareToString[idx];
    }
};

// FEN positions
pub const empty_board: []const u8 = "8/8/8/8/8/8/8/8 w - - ";
pub const start_position: []const u8 = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1";
pub const tricky_position: []const u8 = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1";
pub const killer_position: []const u8 = "rnbqkb1r/pp1p1pPp/8/2p1pP2/1P1P4/3P3P/P1P1P3/RNBQKBNR w KQkq e6 0 1";
pub const cmk_position: []const u8 = "r2q1rk1/ppp2ppp/2n1bn2/2b1p3/3pP3/3P1NPP/PPP1NPB1/R1BQ1RK1 b - - 0 9 ";

pub const PieceString = "PNBRQK~>pnbrqk.";

pub const Color = enum {
    White,
    Black,
    both,
};

pub const PieceType = enum(u8) {
    Pawn,
    Knight,
    Bishop,
    Rook,
    Queen,
    King,

    pub inline fn toU3(self: PieceType) u3 {
        return @intFromEnum(self);
    }
};

pub const Piece = enum(u8) {
    WHITE_PAWN,
    WHITE_KNIGHT,
    WHITE_BISHOP,
    WHITE_ROOK,
    WHITE_QUEEN,
    WHITE_KING,
    BLACK_PAWN,
    BLACK_KNIGHT,
    BLACK_BISHOP,
    BLACK_ROOK,
    BLACK_QUEEN,
    BLACK_KING,
    NO_PIECE,

    pub inline fn toU4(self: Piece) u4 {
        return @as(u4, @intFromEnum(self));
    }
};

pub const unicodePice = &[_][]const u8{
    // zig fmt: off
    "♟︎", "♞", "♝", "♜", "♛", "♚",
    "♙", "♘", "♗", "♖", "♕", "♔", ".",
    // zig fmt: on
};

pub const MoveFlags = enum(u4) {
    QUIET = 0b0000, // 0
    DOUBLE_PUSH = 0b0001, // 1
    OO = 0b0010, // 2 can castle to the king side
    OOO = 0b0011, // 3 can castle to the queen side
    CAPTURE = 0b1000, // 8
    CAPTURES = 0b1011, // 11
    EN_PASSANT = 0b1010, // 10

    // Promotions (no capture)
    PR_KNIGHT = 0b0100, // 4
    PR_BISHOP = 0b0101, // 5
    PR_ROOK = 0b0110, // 6
    PR_QUEEN = 0b0111, // 7
    PC_KNIGHT = 0b1100, // 12
    PC_BISHOP = 0b1101, // 13
    PC_ROOK = 0b1110, // 14
    PC_QUEEN = 0b1111, // 15
};

pub const Castle = enum(u8) {
    WK = 1,
    WQ = 2,
    BK = 4,
    BQ = 8,
};

pub const Board = struct {
    pub const PieceCount = @intFromEnum(Piece.NO_PIECE) + 1;

    pieces: [PieceCount]Bitboard,
    board: [64]Piece,
    side: Color,
    enpassant: square,
    castle: u8, // bitmask of Castle.*

    pub fn pieces_combined(self: *const Board) Bitboard {
        var bb: Bitboard = 0;
        for (self.pieces) |p| bb |= p;
        return bb;
    }

    pub fn new() Board {
        var b: Board = undefined;

        @memset(b.pieces[0..], 0);

        b.side = Color.White;
        b.enpassant = square.NO_SQUARE;
        b.castle = 0;
        return b;
    }

    pub inline fn set_pieces(self: *Board, comptime c: Color) Bitboard {
        return if (c == Color.White) self.pieces[Piece.WHITE_PAWN.toU4()] * 8 | self.pieces[Piece.WHITE_KNIGHT.toU4()] | self.pieces[Piece.WHITE_BISHOP.toU4()] | self.pieces[Piece.WHITE_QUEEN.toU4()] | self.pieces[Piece.WHITE_KING.toU4()] else
            self.pieces[Piece.BLACK_PAWN.toU4()] * 8 | self.pieces[Piece.BLACK_KNIGHT.toU4()] | self.pieces[Piece.BLACK_BISHOP.toU4()] | self.pieces[Piece.BLACK_QUEEN.toU4()] | self.pieces[Piece.BLACK_KING.toU4()];
    }

    pub inline fn set_white(self: *Board) Bitboard {
        return self.pieces[Piece.WHITE_PAWN.toU4()] * 8 | self.pieces[Piece.WHITE_KNIGHT.toU4()] | self.pieces[Piece.WHITE_BISHOP.toU4()] | self.pieces[Piece.WHITE_QUEEN.toU4()] | self.pieces[Piece.WHITE_KING.toU4()];
    }

    pub inline fn set_black(self: *Board) Bitboard {
        return self.pieces[Piece.BLACK_PAWN.toU4()] * 8 | self.pieces[Piece.BLACK_KNIGHT.toU4()] | self.pieces[Piece.BLACK_BISHOP.toU4()] | self.pieces[Piece.BLACK_QUEEN.toU4()] | self.pieces[Piece.BLACK_KING.toU4()];
    }
};

// Attacking directions for the pieces
pub const Direction = enum(i32) {
    North = 8,
    NorthEast = 9,
    East = 1,
    SouthEast = 7,
    South = 8,
    SouthWest = 9,
    West = 1,
    NorthWest = 7,

    // Double Push
    NorthNorth = 16,
    SouthSouth = 16,
};

// prevent bits from wrapping around the bord example form a1 to h2
pub const MaskFile = enum(u64) {
    AFILE = 0x0101010101010101, // file A: a1, a2, ... a8
    BFILE = 0x0202020202020202, // file B: b1, b2, ... b8
    CFILE = 0x0404040404040404, // file C: c1, c2, ... c8
    DFILE = 0x0808080808080808, // file D: d1, d2, ... d8
    EFILE = 0x1010101010101010, // file E: e1, e2, ... e8
    FFILE = 0x2020202020202020, // file F: f1, f2, ... f8
    GFILE = 0x4040404040404040, // file G: g1, g2, ... g8
    HFILE = 0x8080808080808080, // file H: h1, h2, ... h8
};

pub const mask_file: [8]u64 = .{
    @intFromEnum(MaskFile.AFILE),
    @intFromEnum(MaskFile.BFILE),
    @intFromEnum(MaskFile.CFILE),
    @intFromEnum(MaskFile.DFILE),
    @intFromEnum(MaskFile.EFILE),
    @intFromEnum(MaskFile.FFILE),
    @intFromEnum(MaskFile.GFILE),
    @intFromEnum(MaskFile.HFILE),
};

pub const MaskRank = enum(u64) {
    RANK1 = 0x00000000000000FF, // rank 1: a1..h1
    RANK2 = 0x000000000000FF00, // rank 2: a2..h2
    RANK3 = 0x0000000000FF0000, // rank 3: a3..h3
    RANK4 = 0x00000000FF000000, // rank 4: a4..h4
    RANK5 = 0x000000FF00000000, // rank 5: a5..h5
    RANK6 = 0x0000FF0000000000, // rank 6: a6..h6
    RANK7 = 0x00FF000000000000, // rank 7: a7..h7
    RANK8 = 0xFF00000000000000, // rank 8: a8..h8
};

pub const mask_rank: [8]u64 = .{
    @intFromEnum(MaskRank.RANK1),
    @intFromEnum(MaskRank.RANK2),
    @intFromEnum(MaskRank.RANK3),
    @intFromEnum(MaskRank.RANK4),
    @intFromEnum(MaskRank.RANK5),
    @intFromEnum(MaskRank.RANK6),
    @intFromEnum(MaskRank.RANK7),
    @intFromEnum(MaskRank.RANK8),
};

// Precomputed diagonal masks
pub const MaskDiagonalNWSE = enum(u64) {
    DIAGONAL1 = 0x0000000000000080, // a2-h8 diagonal starting at b1
    DIAGONAL2 = 0x0000000000008040,
    DIAGONAL3 = 0x0000000000804020,
    DIAGONAL4 = 0x0000000080402010,
    DIAGONAL5 = 0x0000008040201008,
    DIAGONAL6 = 0x0000804020100804,
    DIAGONAL7 = 0x0080402010080402,
    DIAGONAL8 = 0x8040201008040201,
    DIAGONAL9 = 0x4020100804020100,
    DIAGONAL10 = 0x2010080402010000,
    DIAGONAL11 = 0x1008040201000000,
    DIAGONAL12 = 0x0804020100000000,
    DIAGONAL13 = 0x0402010000000000,
    DIAGONAL14 = 0x0201000000000000,
    DIAGONAL15 = 0x0100000000000000,
};

pub const mask_diagonal_nw_se: [15]u64 = .{
    @intFromEnum(MaskDiagonalNWSE.DIAGONAL1),
    @intFromEnum(MaskDiagonalNWSE.DIAGONAL2),
    @intFromEnum(MaskDiagonalNWSE.DIAGONAL3),
    @intFromEnum(MaskDiagonalNWSE.DIAGONAL4),
    @intFromEnum(MaskDiagonalNWSE.DIAGONAL5),
    @intFromEnum(MaskDiagonalNWSE.DIAGONAL6),
    @intFromEnum(MaskDiagonalNWSE.DIAGONAL7),
    @intFromEnum(MaskDiagonalNWSE.DIAGONAL8),
    @intFromEnum(MaskDiagonalNWSE.DIAGONAL9),
    @intFromEnum(MaskDiagonalNWSE.DIAGONAL10),
    @intFromEnum(MaskDiagonalNWSE.DIAGONAL11),
    @intFromEnum(MaskDiagonalNWSE.DIAGONAL12),
    @intFromEnum(MaskDiagonalNWSE.DIAGONAL13),
    @intFromEnum(MaskDiagonalNWSE.DIAGONAL14),
    @intFromEnum(MaskDiagonalNWSE.DIAGONAL15),
};

// Precomputed anti-diagonal masks
pub const MaskAntiDiagonalNESW = enum(u64) {
    ANTIDIAG1 = 0x0000000000000001,
    ANTIDIAG2 = 0x0000000000000102,
    ANTIDIAG3 = 0x0000000000010204,
    ANTIDIAG4 = 0x0000000001020408,
    ANTIDIAG5 = 0x0000000102040810,
    ANTIDIAG6 = 0x0000010204081020,
    ANTIDIAG7 = 0x0001020408102040,
    ANTIDIAG8 = 0x0102040810204080,
    ANTIDIAG9 = 0x2040810204080000,
    ANTIDIAG10 = 0x4081020408000000,
    ANTIDIAG11 = 0x8102040800000000,
    ANTIDIAG12 = 0x1020408000000000,
    ANTIDIAG13 = 0x2040800000000000,
    ANTIDIAG14 = 0x4080000000000000,
    ANTIDIAG15 = 0x8000000000000000,
};

pub const mask_anti_diagonal_ne_sw: [15]u64 = .{
    @intFromEnum(MaskAntiDiagonalNESW.ANTIDIAG1),
    @intFromEnum(MaskAntiDiagonalNESW.ANTIDIAG2),
    @intFromEnum(MaskAntiDiagonalNESW.ANTIDIAG3),
    @intFromEnum(MaskAntiDiagonalNESW.ANTIDIAG4),
    @intFromEnum(MaskAntiDiagonalNESW.ANTIDIAG5),
    @intFromEnum(MaskAntiDiagonalNESW.ANTIDIAG6),
    @intFromEnum(MaskAntiDiagonalNESW.ANTIDIAG7),
    @intFromEnum(MaskAntiDiagonalNESW.ANTIDIAG8),
    @intFromEnum(MaskAntiDiagonalNESW.ANTIDIAG9),
    @intFromEnum(MaskAntiDiagonalNESW.ANTIDIAG10),
    @intFromEnum(MaskAntiDiagonalNESW.ANTIDIAG11),
    @intFromEnum(MaskAntiDiagonalNESW.ANTIDIAG12),
    @intFromEnum(MaskAntiDiagonalNESW.ANTIDIAG13),
    @intFromEnum(MaskAntiDiagonalNESW.ANTIDIAG14),
    @intFromEnum(MaskAntiDiagonalNESW.ANTIDIAG15),
};

//Precomputed square masks
pub const squar_bb = [_]u64{
    0x1,                0x2,                0x4,                0x8,
    0x10,               0x20,               0x40,               0x80,
    0x100,              0x200,              0x400,              0x800,
    0x1000,             0x2000,             0x4000,             0x8000,
    0x10000,            0x20000,            0x40000,            0x80000,
    0x100000,           0x200000,           0x400000,           0x800000,
    0x1000000,          0x2000000,          0x4000000,          0x8000000,
    0x10000000,         0x20000000,         0x40000000,         0x80000000,
    0x100000000,        0x200000000,        0x400000000,        0x800000000,
    0x1000000000,       0x2000000000,       0x4000000000,       0x8000000000,
    0x10000000000,      0x20000000000,      0x40000000000,      0x80000000000,
    0x100000000000,     0x200000000000,     0x400000000000,     0x800000000000,
    0x1000000000000,    0x2000000000000,    0x4000000000000,    0x8000000000000,
    0x10000000000000,   0x20000000000000,   0x40000000000000,   0x80000000000000,
    0x100000000000000,  0x200000000000000,  0x400000000000000,  0x800000000000000,
    0x1000000000000000, 0x2000000000000000, 0x4000000000000000, 0x8000000000000000,
    0x0,
};
