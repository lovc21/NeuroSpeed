//! Bench: fixed-position search node counts — the engine's reproducibility
//! fingerprint. Two entry points share this module:
//!   - UCI `bench <depth>` command (uci.zig): all 20 positions —
//!     `bench 6` = the identity signature used by the SPRT/validation
//!     workflow (56024 nodes for the tri2 champion config).
//!   - UCI bare `bench` (uci.zig): first 5 positions at depth 11 (311432
//!     for the champion config) — a quick in-loop check.
//! The node count is a bit-identity gate: any search/eval change that is
//! supposed to be behavior-neutral must reproduce it exactly.

const std = @import("std");
const types = @import("types.zig");
const bitboard = @import("bitboard.zig");
const search = @import("search.zig");

pub const positions = [_][]const u8{
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
    "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1",
    "8/2p5/3p4/KP5r/1R3p1k/8/4P1P1/8 w - - 0 1",
    "r3k2r/Pppp1ppp/1b3nbN/nP6/BBP1P3/q4N2/Pp1P2PP/R2Q1RK1 w kq - 0 1",
    "rnbq1k1r/pp1Pbppp/2p5/8/2B5/8/PPP1NnPP/RNBQK2R w KQ - 1 8",
    "r4rk1/1pp1qppp/p1np1n2/2b1p1B1/2B1P1b1/3P1N1P/PPP1NPP1/R2Q1RK1 w - - 0 10",
    "r1bqkbnr/pppppppp/2n5/8/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 1 2",
    "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R w KQkq - 4 4",
    "r1bqk2r/pppp1ppp/2n2n2/2b1p3/2B1P3/2N2N2/PPPP1PPP/R1BQK2R w KQkq - 6 5",
    "r2q1rk1/ppp2ppp/2np1n2/2b1p1B1/2B1P1b1/2NP1N2/PPP2PPP/R2QR1K1 w - - 4 8",
    "r1bq1rk1/pp2ppbp/2np1np1/8/3NP3/2N1BP2/PPPQ2PP/R3KB1R w KQ - 3 8",
    "2r3k1/pp3ppp/2n1bn2/3pp3/4P3/2N2N2/PPP2PPP/R1B1R1K1 w - - 0 12",
    "r1bqkbnr/pp1ppppp/2n5/2p5/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq c6 0 3",
    "r1bqk2r/ppp2ppp/2n1pn2/3p4/1bPP4/2N2N2/PP2PPPP/R1BQKB1R w KQkq - 2 5",
    "rnbqk2r/pppp1ppp/4pn2/8/1bPP4/2N5/PP2PPPP/R1BQKBNR w KQkq - 2 4",
    "r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3",
    "8/8/4kpp1/3p1b2/p6P/2B5/6P1/6K1 w - - 0 47",
    "8/5pk1/7p/3p1R2/p1p5/2P2PP1/1P4KP/3r4 w - - 0 38",
    "1r4k1/5ppp/p1qr1n2/3p4/NP1P4/P4Q2/5PPP/1RR3K1 w - - 0 23",
    "r2qk2r/ppp1bppp/5n2/3p4/3Pn3/3B1N2/PPP2PPP/RNBQ1RK1 w kq - 0 8",
};

/// Search the first `count` bench positions to `depth` and return the total
/// node count. The caller owns timing, TT/attack initialization and printing;
/// the TT is cleared before every position so results are order-independent.
pub fn run_nodes(board: *types.Board, count: usize, depth: u8) u64 {
    var total: u64 = 0;
    for (positions[0..count]) |fen| {
        board.* = types.Board.new();
        bitboard.parse_fen(fen, board) catch continue;

        search.init_search();
        if (search.global_tt) |*tt| tt.clear();

        if (board.side == types.Color.White) {
            search.search_position(board, depth, 0, 0, types.Color.White);
        } else {
            search.search_position(board, depth, 0, 0, types.Color.Black);
        }
        total += search.global_search.nodes;
    }
    return total;
}
