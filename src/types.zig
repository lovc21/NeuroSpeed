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

// bit counting routine
/// Fastest population count, using hardware acceleration if available
pub inline fn popcount(n: u64) u32 {
    return @popCount(n);
}

// get the last bit
pub inline fn lsb_index(n: u64) u6 {
    return @ctz(n);
}
