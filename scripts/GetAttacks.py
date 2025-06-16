import chess

# A diverse set of FEN positions for testing
fen_positions = [
    "8/8/8/8/8/8/8/8 w - - ",
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
    "rnbqkb1r/pp1p1pPp/8/2p1pP2/1P1P4/3P3P/P1P1P3/RNBQKBNR w KQkq e6 0 1",
    "r2q1rk1/ppp2ppp/2n1bn2/2b1p3/3pP3/3P1NPP/PPP1NPB1/R1BQ1RK1 b - - 0 9 ",
    "r3k2r/8/8/8/3pPp2/8/8/R3K1RR b KQkq e3 0 1",
    "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
    "8/7p/p5pb/4k3/P1pPn3/8/P5PP/1rB2RK1 b - d3 0 28",
    "8/3K4/2p5/p2b2r1/5k2/8/8/1q6 b - - 1 67",
    "rnbqkb1r/ppppp1pp/7n/4Pp2/8/8/PPPP1PPP/RNBQKBNR w KQkq f6 0 3",
    "n1n5/PPPk4/8/8/8/8/4Kppp/5N1N b - - 0 1",
    "r3k2r/p6p/8/B7/1pp1p3/3b4/P6P/R3K2R w KQkq - 0 1",
    "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
    "r6r/1b2k1bq/8/8/7B/8/8/R3K2R b KQ - 3 2",
    "8/8/8/2k5/2pP4/8/B7/4K3 b - d3 0 3",
    "r1bqkbnr/pppppppp/n7/8/8/P7/1PPPPPPP/RNBQKBNR w KQkq - 2 2",
    "r3k2r/p1pp1pb1/bn2Qnp1/2qPN3/1p2P3/2N5/PPPBBPPP/R3K2R b KQkq - 3 2",
    "2kr3r/p1ppqpb1/bn2Qnp1/3PN3/1p2P3/2N5/PPPBBPPP/R3K2R b KQ - 3 2",
    "rnb2k1r/pp1Pbppp/2p5/q7/2B5/8/PPPQNnPP/RNB1K2R w KQ - 3 9",
]


def to_zig_hex(bb: int) -> str:
    """Converts a python-chess bitboard (big-endian) to a little-endian hex string for Zig."""
    raw_be = bb.to_bytes(8, byteorder="big")
    raw_le = raw_be[::-1]
    zig_int = int.from_bytes(raw_le, byteorder="big")
    return f"0x{zig_int:016x}"


white_attacks_bb_arr = []
black_attacks_bb_arr = []

for fen in fen_positions:
    board = chess.Board(fen)
    print(f"FEN: {fen}")
    print(board)

    white_attacks_bb = 0
    black_attacks_bb = 0

    # Iterate over all 64 squares to build the attack maps
    for sq in chess.SQUARES:
        # Check if the square is attacked by white
        if board.is_attacked_by(chess.WHITE, sq):
            white_attacks_bb |= 1 << sq

        # Check if the square is attacked by black
        if board.is_attacked_by(chess.BLACK, sq):
            black_attacks_bb |= 1 << sq

    white_attacks_bb_arr.append(white_attacks_bb)
    black_attacks_bb_arr.append(black_attacks_bb)

    print(f"White Attacks: {to_zig_hex(white_attacks_bb)}")
    print(f"Black Attacks: {to_zig_hex(black_attacks_bb)}")
    print("-" * 40)

print(f"White Attacks list: {white_attacks_bb_arr} \n")
print(f"Black Attacks list: {black_attacks_bb_arr} \n")
