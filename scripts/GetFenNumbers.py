import chess


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
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
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
    raw_be = bb.to_bytes(8, byteorder="big")
    raw_le = raw_be[::-1]
    zig_int = int.from_bytes(raw_le, byteorder="big")
    return f"0x{zig_int:016x}"


for fen in fen_positions:
    board = chess.Board(fen)
    print(board)

    occ_all = board.occupied

    if board.ep_square is None:
        ep_str = "-"
    else:
        ep_str = chess.square_name(board.ep_square)

    castling_str = board.castling_xfen()

    print(f"FEN         : {fen}")
    print(f"Occupancy   : {to_zig_hex(occ_all)}")
    print(f"En-passant  : {ep_str}")
    print(f"Castling    : {castling_str}")
    print("-" * 30)
