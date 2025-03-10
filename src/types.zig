// empty Bitboard
pub const Bitboard = u64;

// the number of squares on a chess board
pub const number_of_squares = 64;

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
};

pub const Color = enum {
    White,
    Black,
};

// Attacking directions for the pieces
pub const Direction = enum(i32) {
    North = 8,
    NorthEast = 9,
    East = 1,
    SouthEast = -7,
    South = -8,
    SouthWest = -9,
    West = -1,
    NorthWest = 7,

    // Double Push
    NorthNorth = 16,
    SouthSouth = -16,
};

pub const MaskFile = [_]Bitboard{
    0x101010101010101,  0x202020202020202,  0x404040404040404,  0x808080808080808,
    0x1010101010101010, 0x2020202020202020, 0x4040404040404040, 0x8080808080808080,
};

// Attacking shifting moves
//
pub inline fn shift_bitboard(x: Bitboard, comptime d: Direction) Bitboard {
    return switch (d) {
        Direction.North => x << 8,
        Direction.South => x >> 8,
        Direction.NorthNorth => x << 16,
        Direction.SouthSouth => x >> 16,
        Direction.East => (x & ~MaskFile[@enumToInt(File.HFILE)]) << 1,
        Direction.West => (x & ~MaskFile[@enumToInt(File.AFILE)]) >> 1,
        Direction.NorthEast => (x & ~MaskFile[@enumToInt(File.HFILE)]) << 9,
        Direction.NorthWest => (x & ~MaskFile[@enumToInt(File.AFILE)]) << 7,
        Direction.SouthEast => (x & ~MaskFile[@enumToInt(File.HFILE)]) >> 7,
        Direction.SouthWest => (x & ~MaskFile[@enumToInt(File.AFILE)]) >> 9,
    };
}
