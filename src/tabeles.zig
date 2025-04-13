const types = @import("types.zig");

// Tables for attacks

pub const White_pawn_attacks_tabele = [64]types.Bitboard{
    0x200,              0x500,              0xa00,              0x1400,
    0x2800,             0x5000,             0xa000,             0x4000,
    0x20000,            0x50000,            0xa0000,            0x140000,
    0x280000,           0x500000,           0xa00000,           0x400000,
    0x2000000,          0x5000000,          0xa000000,          0x14000000,
    0x28000000,         0x50000000,         0xa0000000,         0x40000000,
    0x200000000,        0x500000000,        0xa00000000,        0x1400000000,
    0x2800000000,       0x5000000000,       0xa000000000,       0x4000000000,
    0x20000000000,      0x50000000000,      0xa0000000000,      0x140000000000,
    0x280000000000,     0x500000000000,     0xa00000000000,     0x400000000000,
    0x2000000000000,    0x5000000000000,    0xa000000000000,    0x14000000000000,
    0x28000000000000,   0x50000000000000,   0xa0000000000000,   0x40000000000000,
    0x200000000000000,  0x500000000000000,  0xa00000000000000,  0x1400000000000000,
    0x2800000000000000, 0x5000000000000000, 0xa000000000000000, 0x4000000000000000,
    0x0,                0x0,                0x0,                0x0,
    0x0,                0x0,                0x0,                0x0,
};

pub const Black_pawn_attacks_tabele = [64]types.Bitboard{
    0x0,              0x0,              0x0,              0x0,
    0x0,              0x0,              0x0,              0x0,
    0x2,              0x5,              0xa,              0x14,
    0x28,             0x50,             0xa0,             0x40,
    0x200,            0x500,            0xa00,            0x1400,
    0x2800,           0x5000,           0xa000,           0x4000,
    0x20000,          0x50000,          0xa0000,          0x140000,
    0x280000,         0x500000,         0xa00000,         0x400000,
    0x2000000,        0x5000000,        0xa000000,        0x14000000,
    0x28000000,       0x50000000,       0xa0000000,       0x40000000,
    0x200000000,      0x500000000,      0xa00000000,      0x1400000000,
    0x2800000000,     0x5000000000,     0xa000000000,     0x4000000000,
    0x20000000000,    0x50000000000,    0xa0000000000,    0x140000000000,
    0x280000000000,   0x500000000000,   0xa00000000000,   0x400000000000,
    0x2000000000000,  0x5000000000000,  0xa000000000000,  0x14000000000000,
    0x28000000000000, 0x50000000000000, 0xa0000000000000, 0x40000000000000,
};

pub const Knight_attackes_tabele = [64]types.Bitboard{
    0x20400,            0x50800,            0xa1100,            0x142200,
    0x284400,           0x508800,           0xa01000,           0x402000,
    0x2040004,          0x5080008,          0xa110011,          0x14220022,
    0x28440044,         0x50880088,         0xa0100010,         0x40200020,
    0x204000402,        0x508000805,        0xa1100110a,        0x1422002214,
    0x2844004428,       0x5088008850,       0xa0100010a0,       0x4020002040,
    0x20400040200,      0x50800080500,      0xa1100110a00,      0x142200221400,
    0x284400442800,     0x508800885000,     0xa0100010a000,     0x402000204000,
    0x2040004020000,    0x5080008050000,    0xa1100110a0000,    0x14220022140000,
    0x28440044280000,   0x50880088500000,   0xa0100010a00000,   0x40200020400000,
    0x204000402000000,  0x508000805000000,  0xa1100110a000000,  0x1422002214000000,
    0x2844004428000000, 0x5088008850000000, 0xa0100010a0000000, 0x4020002040000000,
    0x400040200000000,  0x800080500000000,  0x1100110a00000000, 0x2200221400000000,
    0x4400442800000000, 0x8800885000000000, 0x100010a000000000, 0x2000204000000000,
    0x4020000000000,    0x8050000000000,    0x110a0000000000,   0x22140000000000,
    0x44280000000000,   0x0088500000000000, 0x0010a00000000000, 0x20400000000000,
};

pub const King_attackes_tabele = [64]types.Bitboard{
    0x302,              0x705,              0xe0a,              0x1c14,
    0x3828,             0x7050,             0xe0a0,             0xc040,
    0x30203,            0x70507,            0xe0a0e,            0x1c141c,
    0x382838,           0x705070,           0xe0a0e0,           0xc040c0,
    0x3020300,          0x7050700,          0xe0a0e00,          0x1c141c00,
    0x38283800,         0x70507000,         0xe0a0e000,         0xc040c000,
    0x302030000,        0x705070000,        0xe0a0e0000,        0x1c141c0000,
    0x3828380000,       0x7050700000,       0xe0a0e00000,       0xc040c00000,
    0x30203000000,      0x70507000000,      0xe0a0e000000,      0x1c141c000000,
    0x382838000000,     0x705070000000,     0xe0a0e0000000,     0xc040c0000000,
    0x3020300000000,    0x7050700000000,    0xe0a0e00000000,    0x1c141c00000000,
    0x38283800000000,   0x70507000000000,   0xe0a0e000000000,   0xc040c000000000,
    0x302030000000000,  0x705070000000000,  0xe0a0e0000000000,  0x1c141c0000000000,
    0x3828380000000000, 0x7050700000000000, 0xe0a0e00000000000, 0xc040c00000000000,
    0x203000000000000,  0x507000000000000,  0xa0e000000000000,  0x141c000000000000,
    0x2838000000000000, 0x5070000000000000, 0xa0e0000000000000, 0x40c0000000000000,
};

pub const Rook_attackes_tabele = [64]types.Bitboard{
    0x101010101017e,    0x202020202027c,    0x404040404047a,    0x8080808080876,
    0x1010101010106e,   0x2020202020205e,   0x4040404040403e,   0x8080808080807e,
    0x1010101017e00,    0x2020202027c00,    0x4040404047a00,    0x8080808087600,
    0x10101010106e00,   0x20202020205e00,   0x40404040403e00,   0x80808080807e00,
    0x10101017e0100,    0x20202027c0200,    0x40404047a0400,    0x8080808760800,
    0x101010106e1000,   0x202020205e2000,   0x404040403e4000,   0x808080807e8000,
    0x101017e010100,    0x202027c020200,    0x404047a040400,    0x8080876080800,
    0x1010106e101000,   0x2020205e202000,   0x4040403e404000,   0x8080807e808000,
    0x1017e01010100,    0x2027c02020200,    0x4047a04040400,    0x8087608080800,
    0x10106e10101000,   0x20205e20202000,   0x40403e40404000,   0x80807e80808000,
    0x17e0101010100,    0x27c0202020200,    0x47a0404040400,    0x8760808080800,
    0x106e1010101000,   0x205e2020202000,   0x403e4040404000,   0x807e8080808000,
    0x7e010101010100,   0x7c020202020200,   0x7a040404040400,   0x76080808080800,
    0x6e101010101000,   0x5e202020202000,   0x3e404040404000,   0x7e808080808000,
    0x7e01010101010100, 0x7c02020202020200, 0x7a04040404040400, 0x7608080808080800,
    0x6e10101010101000, 0x5e20202020202000, 0x3e40404040404000, 0x7e80808080808000,
};

pub const rook_magics = [_]u64{
    0x0080001020400080, 0x0040001000200040, 0x0080081000200080, 0x0080040800100080,
    0x0080020400080080, 0x0080010200040080, 0x0080008001000200, 0x0080002040800100,
    0x0000800020400080, 0x0000400020005000, 0x0000801000200080, 0x0000800800100080,
    0x0000800400080080, 0x0000800200040080, 0x0000800100020080, 0x0000800040800100,
    0x0000208000400080, 0x0000404000201000, 0x0000808010002000, 0x0000808008001000,
    0x0000808004000800, 0x0000808002000400, 0x0000010100020004, 0x0000020000408104,
    0x0000208080004000, 0x0000200040005000, 0x0000100080200080, 0x0000080080100080,
    0x0000040080080080, 0x0000020080040080, 0x0000010080800200, 0x0000800080004100,
    0x0000204000800080, 0x0000200040401000, 0x0000100080802000, 0x0000080080801000,
    0x0000040080800800, 0x0000020080800400, 0x0000020001010004, 0x0000800040800100,
    0x0000204000808000, 0x0000200040008080, 0x0000100020008080, 0x0000080010008080,
    0x0000040008008080, 0x0000020004008080, 0x0000010002008080, 0x0000004081020004,
    0x0000204000800080, 0x0000200040008080, 0x0000100020008080, 0x0000080010008080,
    0x0000040008008080, 0x0000020004008080, 0x0000800100020080, 0x0000800041000080,
    0x00FFFCDDFCED714A, 0x007FFCDDFCED714A, 0x003FFFCDFFD88096, 0x0000040810002101,
    0x0001000204080011, 0x0001000204000801, 0x0001000082000401, 0x0001FFFAABFAD1A2,
};

pub const Bishops_attackes_tabele = [64]types.Bitboard{
    0x40201008040200, 0x402010080400,   0x4020100a00,     0x40221400,
    0x2442800,        0x204085000,      0x20408102000,    0x2040810204000,
    0x20100804020000, 0x40201008040000, 0x4020100a0000,   0x4022140000,
    0x244280000,      0x20408500000,    0x2040810200000,  0x4081020400000,
    0x10080402000200, 0x20100804000400, 0x4020100a000a00, 0x402214001400,
    0x24428002800,    0x2040850005000,  0x4081020002000,  0x8102040004000,
    0x8040200020400,  0x10080400040800, 0x20100a000a1000, 0x40221400142200,
    0x2442800284400,  0x4085000500800,  0x8102000201000,  0x10204000402000,
    0x4020002040800,  0x8040004081000,  0x100a000a102000, 0x22140014224000,
    0x44280028440200, 0x8500050080400,  0x10200020100800, 0x20400040201000,
    0x2000204081000,  0x4000408102000,  0xa000a10204000,  0x14001422400000,
    0x28002844020000, 0x50005008040200, 0x20002010080400, 0x40004020100800,
    0x20408102000,    0x40810204000,    0xa1020400000,    0x142240000000,
    0x284402000000,   0x500804020000,   0x201008040200,   0x402010080400,
    0x2040810204000,  0x4081020400000,  0xa102040000000,  0x14224000000000,
    0x28440200000000, 0x50080402000000, 0x20100804020000, 0x40201008040200,
};

pub const bishop_magics = [_]u64{
    0x0002020202020200, 0x0002020202020000, 0x0004010202000000, 0x0004040080000000,
    0x0001104000000000, 0x0000821040000000, 0x0000410410400000, 0x0000104104104000,
    0x0000040404040400, 0x0000020202020200, 0x0000040102020000, 0x0000040400800000,
    0x0000011040000000, 0x0000008210400000, 0x0000004104104000, 0x0000002082082000,
    0x0004000808080800, 0x0002000404040400, 0x0001000202020200, 0x0000800802004000,
    0x0000800400A00000, 0x0000200100884000, 0x0000400082082000, 0x0000200041041000,
    0x0002080010101000, 0x0001040008080800, 0x0000208004010400, 0x0000404004010200,
    0x0000840000802000, 0x0000404002011000, 0x0000808001041000, 0x0000404000820800,
    0x0001041000202000, 0x0000820800101000, 0x0000104400080800, 0x0000020080080080,
    0x0000404040040100, 0x0000808100020100, 0x0001010100020800, 0x0000808080010400,
    0x0000820820004000, 0x0000410410002000, 0x0000082088001000, 0x0000002011000800,
    0x0000080100400400, 0x0001010101000200, 0x0002020202000400, 0x0001010101000200,
    0x0000410410400000, 0x0000208208200000, 0x0000002084100000, 0x0000000020880000,
    0x0000001002020000, 0x0000040408020000, 0x0004040404040000, 0x0002020202020000,
    0x0000104104104000, 0x0000002082082000, 0x0000000020841000, 0x0000000000208800,
    0x0000000010020200, 0x0000000404080200, 0x0000040404040400, 0x0002020202020200,
};
