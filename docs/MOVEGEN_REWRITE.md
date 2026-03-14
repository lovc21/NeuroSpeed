# NeuroSpeed Movegen Rewrite: Technical Deep-Dive

> **Author:** Jakob Dekleva
> **Engine:** [NeuroSpeed](https://github.com/lovc21/NeuroSpeed) — UCI chess engine in Zig
> **Branch:** `movegen-gigantua-rewrite`
> **Date:** March 2026

---

## 1. Overview

### Goal

Replace NeuroSpeed's pseudo-legal move generator with a Gigantua-style **legal move generator** using checkmask + pinmask, and optimize every layer of the perft/search stack for maximum throughput.

### Results

| Metric | Before | After | Improvement |
|--------|--------|-------|-------------|
| Perft speed (depth 5, startpos) | 27 MN/s | **227 MN/s** | **8.4x** |
| Perft speed (depth 7, startpos) | ~27 MN/s | **215 MN/s** | **~8x** |
| vs. Lambergar (depth 5) | — | +53% faster | — |
| vs. Lambergar (depth 7) | — | +42% faster | — |
| Move struct size | 3 bytes | **2 bytes** (packed) | -33% |
| Perft undo struct | ~200 bytes (full BoardState) | **4 bytes** (PerftUndo) | **-98%** |
| Search undo struct | ~200 bytes (full BoardState) | **29 bytes** (SearchUndo) | **-86%** |
| Old movegen code removed | — | 868 lines deleted | — |

### Summary of Optimizations Applied

1. **Gigantua-style legal movegen** — checkmask + pinmask replaces make-then-check-legality
2. **Bulk counting at leaf nodes** — skip make/unmake at depth 1
3. **PerftUndo struct** — 4-byte undo instead of 200-byte BoardState copy
4. **Occupancy caching in LegalInfo** — avoid recomputing 12-OR chains
5. **Aggressive inlining** — mark hot-path functions `inline`
6. **Pawn movegen restructuring** — bulk shifts for common case, per-piece loops only for pinned pawns
7. **Packed 16-bit Move struct** — halves MoveList cache footprint
8. **Branchless castling rights** — `castle_mask[64]` lookup table
9. **SearchUndo struct** — 29-byte undo for search (Zobrist + eval, no full board copy)
10. **Code cleanup** — file consolidation, naming fixes, dead code removal

### Optimization Progression

The following table shows cumulative perft speed at key milestones during the rewrite. All measurements are single-threaded, no hash, startpos depth 5, ReleaseFast.

| Milestone | Perft Speed | Speedup vs. Previous |
|-----------|------------|---------------------|
| Before (pseudo-legal movegen) | ~27 MN/s | — |
| Legal movegen wired in | ~100 MN/s (est.) | ~3.7x |
| + Bulk counting + inlining + PerftUndo | **175 MN/s** | ~1.8x |
| + Pawn restructure + packed Move + occupancy caching | **227 MN/s** | 1.3x |
| + SearchUndo (search path only) | 227 MN/s (perft unchanged) | — |

The single biggest jump came from switching to legal movegen (eliminating wasted make/unmake on illegal moves). Bulk counting was the second-largest gain. The remaining optimizations (packing, caching, inlining) combined for another ~30% on top.

---

## 2. How NeuroSpeed Compares to Other Engines

The table below shows perft speeds for various engines. All numbers are **single-threaded, no hash** unless noted. Perft speed depends heavily on CPU, compiler, and measurement methodology, so treat these as rough comparisons.

### Dedicated Perft Counters (Purpose-Built for Speed)

| Engine | Language | Perft Speed (MN/s) | Notes | Source |
|--------|----------|-------------------|-------|--------|
| Chessbit | C++ | ~4,000 | AMD Ryzen 7 9800X3D, AVX2/PEXT, Intel C++ 2025 | [TalkChess](https://talkchess.com/viewtopic.php?t=85453) |
| ZeroLogic | C++ | ~913 (i9-9900K), ~3,350 (fast CPU + TT) | ~913 MN/s on i9-9900K per FireFather; higher numbers on newer CPUs with TT | [GitHub](https://github.com/0xwurm/ZeroLogic), [perft-times](https://github.com/FireFather/perft-times) |
| Gigantua | C++ | ~1,473 (d7), ~2,050 (Kiwi d6) | PEXT bitboards, visitor pattern, `if constexpr` | [GitHub](https://github.com/Gigantua/Gigantua) |
| Gargantua | C++ | ~1,120 (d7), ~1,630 (Kiwi d5) | Specialized perft engine, hard to adapt for real search | [TalkChess](https://talkchess.com/viewtopic.php?t=83043) |
| Gigantua (Zen 1) | C++ | ~152 (d7) | Ryzen 1700X — slow PEXT kills performance | [TalkChess](https://talkchess.com/viewtopic.php?t=78352) |

### Full Chess Engines

| Engine | Language | Perft Speed (MN/s) | Notes | Source |
|--------|----------|-------------------|-------|--------|
| MidnightMoveGen | C++ | ~420 | Single-header library, M1 Pro, no hash | [GitHub](https://github.com/archishou/MidnightMoveGen) |
| cozy-chess | Rust | ~318 | Library; d7 in 10.05s | [GitHub](https://github.com/analog-hors/cozy-chess) |
| Surge | C++ | ~294 | Legal movegen, bulk counting, i9-9900K | [perft-times](https://github.com/FireFather/perft-times) |
| Fire | C++ | ~235 | i9-9900K | [perft-times](https://github.com/FireFather/perft-times) |
| Stockfish 16 | C++ | ~232 | AVX2, single-thread, Linux | [TalkChess](https://talkchess.com/viewtopic.php?t=83043) |
| **NeuroSpeed** | **Zig** | **~227 (d5), ~215 (d7)** | **Magic bitboards, legal movegen, bulk counting** | **This project** |
| qperft | C | ~190 | Mailbox + piece list, gcc -O3, no hash | [Blog](https://peterellisjones.com/posts/generating-legal-chess-moves-efficiently/) |
| Lambergar | Zig | ~148 (d5), ~152 (d7) | Reference Zig engine | Local benchmarks |
| Tinker | ? | ~95 | 3.6 GHz CPU | [TalkChess](https://talkchess.com/viewtopic.php?t=83043) |
| Rustic (no TT) | Rust | ~58 | Ryzen 7950X, no hash, no bulk counting | [TalkChess](https://talkchess.com/viewtopic.php?t=83043&start=10) |
| Stockfish 8 (no bulk) | C++ | ~15 | Older version, bulk counting disabled | [TalkChess](https://talkchess.com/viewtopic.php?t=74153) |

### FireFather Perft Rankings (i9-9900K, depth 7 startpos)

The [FireFather perft-times](https://github.com/FireFather/perft-times) benchmark ranks 74 engines on an Intel i9-9900K @ 3.60GHz. Depth 7 startpos = 3,195,901,860 nodes. Top 15:

| Rank | Engine | Time (s) | ~MN/s |
|------|--------|----------|-------|
| 1 | Gigantua | 2.70 | 1,184 |
| 2 | ZeroLogic | 3.50 | 913 |
| 3 | Osama | 5.19 | 616 |
| 4 | Chessbit | 5.28 | 605 |
| 5 | Paladin | 5.48 | 583 |
| 6 | Xiphos | 6.23 | 513 |
| 7 | Kobol | 8.34 | 383 |
| 8 | Spark | 9.51 | 336 |
| 9 | perft | 10.62 | 301 |
| 10 | Surge | 10.88 | 294 |
| 11 | Stockfish 7 | 12.00 | 266 |
| 12 | Anka | 12.40 | 258 |
| 13 | Kobra | 12.83 | 249 |
| 14 | Fire | 13.62 | 235 |
| 15 | Octochess | 14.30 | 224 |

NeuroSpeed's ~215-227 MN/s would place it around rank 15-16 on this hardware — competitive with established C++ engines like Fire and Octochess, and ahead of many others in the 74-engine list.

**Why perft speed ≠ playing strength.** Perft measures raw move generation throughput — how fast you can enumerate all legal positions to a given depth. But a chess engine spends most of its time in evaluation, transposition table probes, and search pruning, not move generation. In practice, move generation typically consumes a small fraction of total search time — most time is spent in evaluation and hash probes ([CPW: Move Generation](https://www.chessprogramming.org/Move_Generation)). A fast movegen helps, but diminishing returns set in quickly.

**Where does NeuroSpeed sit?** At ~215-227 MN/s, NeuroSpeed is **competitive with Stockfish 16** (~232 MN/s on similar hardware), and **42-53% faster than Lambergar** (another Zig engine). It's far behind dedicated perft counters like Gigantua (~1,473 MN/s), Gargantua (~1,120 MN/s), and Chessbit (~4,000 MN/s), but those use PEXT instructions, C++ template specialization, and visitor patterns — techniques not yet applied in NeuroSpeed. Among full chess engines, NeuroSpeed's perft speed is in the top tier.

**Bulk counting is the biggest single optimization.** Without bulk counting, engines are dramatically slower: Stockfish 8 measured only ~15 MN/s with it disabled, compared to ~232 MN/s in Stockfish 16 with it enabled. Even accounting for version differences, bulk counting alone typically yields a 5-10x speedup since it eliminates make/unmake at the leaf level, which contains the vast majority of nodes.

---

## 3. Architecture Overview

### File Structure

```
src/
├── move.zig          # Move struct (16-bit packed), make/unmake, PerftUndo, SearchUndo
├── movegen.zig       # Legal move generation (checkmask, pinmask, king danger)
├── types.zig         # Board struct, Piece/Color/Square enums, castle_mask[64]
├── attacks.zig       # Magic bitboards, pre-computed attack tables
├── tables.zig        # Raw magic numbers, attack masks, index bits
├── search.zig        # Negamax + PVS, quiescence, iterative deepening
├── evaluation.zig    # Tapered eval, PSQT, material, king safety
├── score_moves.zig   # Move ordering: MVV-LVA, SEE, killers, history
├── uci.zig           # UCI protocol, FEN parsing, time management
├── util.zig          # Perft functions (perft_legal, perft_detailed)
├── bitboard.zig      # Board printing, FEN parsing, square attack checks
├── zobrist.zig       # Comptime Zobrist hash keys
├── tt.zig            # Transposition table
├── lists.zig         # MoveList, ScoreList
├── nnue.zig          # NNUE stub (not implemented)
└── main.zig          # Entry point, bench
```

### Data Flow

```
  FEN string
      │
      ▼
  parse_fen()          [bitboard.zig]
      │
      ▼
  Board struct         [types.zig]
  ┌─────────────────────────────┐
  │ pieces[15]: Bitboard (u64)  │  ← 12 piece bitboards + NO_PIECE sentinel (indices 6,7 unused)
  │ board[64]: Piece            │  ← mailbox (O(1) piece lookup)
  │ side: Color                 │
  │ enpassant: square           │
  │ castle: u8                  │
  │ hash: u64                   │  ← Zobrist hash
  └─────────────────────────────┘
      │
      ▼
  compute_legal_info()  [movegen.zig]
      │
      ├── checkmask    (which squares can pieces move to?)
      ├── pin_hv       (horizontal/vertical pin rays)
      ├── pin_d12      (diagonal pin rays)
      ├── king_ban     (squares attacked by enemy)
      ├── us_bb        (our occupancy, cached)
      └── them_bb      (their occupancy, cached)
      │
      ▼
  generate_legal_moves()  [movegen.zig]
      │
      ▼
  MoveList (up to 255 moves, each 2 bytes)
      │
      ├──[perft]──► make_move_perft / unmake_move_perft   [move.zig]
      │              (4-byte PerftUndo, no hash/eval)
      │
      └──[search]──► make_move_search / unmake_move_search [move.zig]
                     (29-byte SearchUndo, with hash+eval)
```

### Move Struct: 16-Bit Packed Layout

```
  Bit:  15  14  13  12  11  10   9   8   7   6   5   4   3   2   1   0
       ├────flags────┤├─────────to──────────┤├──────────from─────────┤
        [3] [2] [1] [0] [5] [4] [3] [2] [1] [0] [5] [4] [3] [2] [1] [0]
             u4              u6                        u6

  Total: 16 bits = 2 bytes per move
  MoveList of 255 moves = 510 bytes (fits in ~8 cache lines)
```

The old Move was a regular Zig struct with `from: u6`, `to: u6`, `flags: MoveFlags` — which the compiler stored in 3 bytes due to alignment. The new `packed struct` forces exactly 16 bits.

### Board Struct Layout

```
  Board (types.zig)
  ═══════════════════════════════════════════════════
  pieces[0..5]   = White: Pawn, Knight, Bishop, Rook, Queen, King
  pieces[6..7]   = (unused gap — Piece enum skips 6,7)
  pieces[8..13]  = Black: Pawn, Knight, Bishop, Rook, Queen, King
  pieces[14]     = NO_PIECE (always 0, used as sentinel)
  (PieceCount = 15 total array elements)
  ─────────────────────────────────────────────────
  board[0..63]   = Mailbox: piece on each square (O(1) lookup)
  ─────────────────────────────────────────────────
  side           = White or Black to move
  enpassant      = Target square for en passant (or NO_SQUARE)
  castle         = Bitmask: WK=1, WQ=2, BK=4, BQ=8
  hash           = Zobrist hash (incrementally updated)
  ═══════════════════════════════════════════════════

  Square mapping: Little-Endian Rank-File (LERF)
  ┌────┬────┬────┬────┬────┬────┬────┬────┐
  │ 56 │ 57 │ 58 │ 59 │ 60 │ 61 │ 62 │ 63 │  Rank 8
  ├────┼────┼────┼────┼────┼────┼────┼────┤
  │ 48 │ 49 │ 50 │ 51 │ 52 │ 53 │ 54 │ 55 │  Rank 7
  ├────┼────┼────┼────┼────┼────┼────┼────┤
  │ 40 │ 41 │ 42 │ 43 │ 44 │ 45 │ 46 │ 47 │  Rank 6
  ├────┼────┼────┼────┼────┼────┼────┼────┤
  │ 32 │ 33 │ 34 │ 35 │ 36 │ 37 │ 38 │ 39 │  Rank 5
  ├────┼────┼────┼────┼────┼────┼────┼────┤
  │ 24 │ 25 │ 26 │ 27 │ 28 │ 29 │ 30 │ 31 │  Rank 4
  ├────┼────┼────┼────┼────┼────┼────┼────┤
  │ 16 │ 17 │ 18 │ 19 │ 20 │ 21 │ 22 │ 23 │  Rank 3
  ├────┼────┼────┼────┼────┼────┼────┼────┤
  │  8 │  9 │ 10 │ 11 │ 12 │ 13 │ 14 │ 15 │  Rank 2
  ├────┼────┼────┼────┼────┼────┼────┼────┤
  │  0 │  1 │  2 │  3 │  4 │  5 │  6 │  7 │  Rank 1
  └────┴────┴────┴────┴────┴────┴────┴────┘
    a     b     c     d     e     f     g     h
```

---

## 4. Change-by-Change Walkthrough

Each optimization is presented in the order it was applied, with commit references from the branch history.

### 4.1 Gigantua-Style Legal Move Generation

**Commit:** `d00deaa` — Wire legal movegen into search
**Commit:** `6d4cb7d` — Add Gigantua-style legal move generation

**What changed:**

The old approach generated **pseudo-legal moves** (moves that obey piece movement rules but may leave the king in check), then validated each move by making it on the board and checking if the king was attacked:

```zig
// OLD: Pseudo-legal approach (move_generation.zig)
generate_moves(&board, &move_list, color);     // generate ALL moves
for (0..move_list.count) |i| {
    const state = board.save_state();           // copy ~200 bytes
    if (!make_move(&board, move)) {             // make + check legality
        board.restore_state(state);             // illegal → restore
        continue;
    }
    // ... search ...
    board.restore_state(state);                 // undo
}
```

The new approach computes **checkmask** and **pinmask** once per position, then generates only legal moves directly:

```zig
// NEW: Legal movegen (movegen.zig)
generate_legal_moves(&board, &move_list, color);  // only legal moves
for (0..move_list.count) |i| {
    const undo = make_move_search(&board, move);  // always legal
    // ... search ...
    unmake_move_search(&board, move, undo);        // undo with 29 bytes
}
```

**Why it's faster:**

- No wasted work on illegal moves (in check positions, most pseudo-legal moves are illegal)
- No need to make/unmake just to test legality
- The checkmask/pinmask computation happens once, then AND-masks prune all piece moves cheaply
- In double check, only king moves are generated (immediate early return)

**Where this comes from:** The Gigantua move generator by Daniel Inführ ([GitHub](https://github.com/Gigantua/Gigantua), [TalkChess](https://talkchess.com/viewtopic.php?t=78352)) popularized this approach for maximum perft speed. The core idea — using check and pin masks to filter moves at generation time — is described on the [Chess Programming Wiki](https://www.chessprogramming.org/Checks_and_Pinned_Pieces_%28Bitboards%29).

### 4.2 Bulk Counting at Leaf Nodes

**Commit:** `bcc8a0b` — Optimize perft to 175 MN/s with bulk counting

**What changed:**

Old perft recursed all the way to depth 0, making and unmaking every single move:

```zig
// OLD: recurse to depth 0
fn perft(board, depth) u64 {
    if (depth == 0) return 1;
    for each move {
        make_move(board, move);
        nodes += perft(board, depth - 1);
        unmake_move(board, move);
    }
    return nodes;
}
```

New perft uses **bulk counting** — at depth 1, just count the legal moves without making any of them:

```zig
// NEW: bulk counting at depth 1
pub fn perft_legal(comptime color: types.Color, board: *types.Board, depth: u8) u64 {
    if (depth == 0) return 1;
    var move_list: lists.MoveList = .{};
    movegen.generate_legal_moves(board, &move_list, color);

    // Bulk counting: at depth 1, just return the count
    if (depth == 1) return move_list.count;

    var nodes: u64 = 0;
    for (0..move_list.count) |i| {
        const undo = move_gen.make_move_perft(board, move);
        nodes += perft_legal(opponent, board, depth - 1);
        move_gen.unmake_move_perft(board, move, undo);
    }
    return nodes;
}
```

**Why it's faster:** At the leaf level of the perft tree, you avoid make/unmake for every single terminal node. Since the leaf level has the most nodes (typically 20-30x more than depth-2), this eliminates the majority of make/unmake calls. For startpos depth 7, depth-1 has ~3.2 billion nodes — all of which skip make/unmake entirely.

**Where this comes from:** Bulk counting is a standard perft optimization described on the [Chess Programming Wiki - Perft](https://www.chessprogramming.org/Perft). Most engines that report high perft speeds use it.

### 4.3 Perft-Specific Make/Unmake (PerftUndo)

**Commit:** `bcc8a0b` — Optimize perft

**What changed:**

The old approach copied the entire `BoardState` (~200 bytes) before every move:

```zig
// OLD: BoardState — full board copy
pub const BoardState = struct {
    pieces: [15]Bitboard,  // 120 bytes (15 × 8)
    board: [64]Piece,      //  64 bytes (64 × 1)
    side: Color,           //   1 byte
    enpassant: square,     //   1 byte
    castle: u8,            //   1 byte
    hash: u64,             //   8 byte
};                         // Total: ~200 bytes with alignment
```

The new approach saves only what changes — a 4-byte `PerftUndo`:

```zig
// NEW: PerftUndo — minimal undo info
pub const PerftUndo = struct {
    captured: types.Piece,  // 1 byte — captured piece (NO_PIECE if quiet)
    castle: u8,             // 1 byte — old castling rights
    enpassant: types.square, // 1 byte — old EP square
};                          // Total: ~4 bytes with alignment
```

The XOR trick makes this possible. Instead of clearing a bit then setting another:

```zig
// OLD: clear source, set target (2 operations, each with a branch)
board.pieces[idx] = clear_bit(board.pieces[idx], from);
board.pieces[idx] = set_bit(board.pieces[idx], to);
```

XOR toggles both bits in one operation:

```zig
// NEW: XOR from|to (1 operation, branchless)
board.pieces[idx] ^= square_bb[from] | square_bb[to];
```

This works because XOR is its own inverse: `x ^ y ^ y = x`. To undo, just XOR the same mask again.

**The promotion phantom pawn bug:** During development, a subtle bug was found in promotion unmake. The make step does:

1. XOR `from|to` (moves pawn from source to target)
2. XOR `to` (removes pawn from target)
3. XOR `to` (adds promoted piece at target)

During unmake, naively XOR-ing `from|to` would leave a "phantom pawn" on `to`. The fix: for promotions, only XOR `from` to restore the pawn at its source square:

```zig
if (is_promotion_move(flags)) {
    board.pieces[piece_idx] ^= square_bb[to]; // remove promoted piece
    // Restore pawn at source ONLY (not from|to — that would leave phantom pawn at to)
    board.pieces[pawn_idx] ^= square_bb[from];
} else {
    board.pieces[piece_idx] ^= square_bb[from] | square_bb[to]; // normal undo
}
```

### 4.4 Occupancy Caching in LegalInfo

**Commit:** `649db93` — Restructure movegen

The `set_pieces()` function ORs together 6 bitboards to compute one side's occupancy. This was called multiple times per position (once in `compute_legal_info`, again in `generate_legal_moves`). Now `LegalInfo` caches `us_bb` and `them_bb`:

```zig
pub const LegalInfo = struct {
    checkmask: u64,
    pin_hv: u64,
    pin_d12: u64,
    king_ban: u64,
    us_bb: u64,    // cached: avoids recomputing 6 ORs
    them_bb: u64,  // cached: avoids recomputing 6 ORs
    num_checkers: u2,
};
```

This avoids 2 × 6 = 12 unnecessary bitboard OR operations per position.

### 4.5 Inlining the Hot Path

**Commit:** `bcc8a0b` — Optimize perft (41% improvement from inlining alone)

**What changed:** Key functions were marked `inline`:

- `make_move_perft` / `unmake_move_perft`
- `compute_legal_info`
- `generate_legal_moves` / `generate_legal_moves_with_info`
- `update_castling_rights`
- helper functions like `is_promotion_move`, `get_promoted_piece`

**Why inlining helps so much in movegen:** Move generation is a tight loop that calls small functions millions of times per second. Without inlining, each call has overhead:

- Push/pop caller-saved registers
- Set up the stack frame
- Branch to the function and back
- The compiler can't optimize across the function boundary

With inlining, the compiler sees the entire hot path as one block of code and can:

- Eliminate redundant loads/stores
- Keep values in registers across what were function calls
- Apply constant propagation through the call chain
- Reorder instructions for better pipelining

In Zig, `inline` is a strong hint (the compiler must inline). This is different from C++ where `inline` is only a suggestion. Zig also supports `comptime` parameters, which when combined with `inline` enables the compiler to specialize the function at compile time (similar to C++ templates with `if constexpr`).

The 41% improvement from inlining alone (before other optimizations) shows how significant call overhead is in this tight inner loop.

### 4.6 Pawn Movegen Restructuring

**Commit:** `649db93` — Restructure movegen and pack Move to 16-bit

**What changed:**

The old pseudo-legal movegen iterated over every pawn individually:

```zig
// OLD: per-pawn iteration
while (pawns != 0) {
    const from = lsb_index(pawns);
    pawns &= pawns - 1;
    // ... generate moves for this single pawn ...
}
```

The new legal movegen splits pawns into three categories:

```zig
// NEW: bulk shifts for the common case
const free_pawns = our_pawns & ~(pin_hv | pin_d12);  // not pinned (95%+ of the time)

// 1. Free pawns: single bulk shift handles ALL non-pinned pawns at once
const single_push = (free_pawns << 8) & empty;        // all pawns push one square
const double_push = ((single_push & rank3) << 8) & empty;  // eligible pawns push two
const left_cap = ((free_pawns & ~file_a) << 7) & them_bb;  // all left captures
const right_cap = ((free_pawns & ~file_h) << 9) & them_bb; // all right captures

// 2. HV-pinned pawns (rare): can only push along vertical pin ray
const hv_pawns = our_pawns & pin_hv;
// push targets must also be on pin_hv

// 3. D12-pinned pawns (rare): can only capture along diagonal pin ray
const d12_pawns = our_pawns & pin_d12;
// capture targets must also be on pin_d12
```

**Why handling the common case first matters:** In a typical middlegame position:

- 6-8 pawns per side
- 0-1 pawns are pinned
- The bulk shift handles 5-8 pawns in 1-2 instructions per direction
- The pinned-pawn loop only runs for 0-1 pieces

The old approach did per-pawn iteration for ALL pawns regardless of pin status, with complex bit operations for each one.

**ASCII diagram — pinned pawn example:**

```
  8  .  .  .  .  .  .  .  .
  7  .  .  .  .  .  .  .  .
  6  .  .  .  .  .  .  .  .
  5  .  .  .  .  r  .  .  .    r = black rook (pinner)
  4  .  .  .  .  .  .  .  .
  3  .  .  .  .  P  .  .  .    P = white pawn (pinned on e-file)
  2  .  .  .  .  .  .  .  .
  1  .  .  .  .  K  .  .  .    K = white king
     a  b  c  d  e  f  g  h

  pin_hv includes: e2, e3, e4, e5 (the ray between king and rook)
  The pawn on e3 is HV-pinned: it CAN push to e4 (on the pin ray)
  but CANNOT capture on d4 or f4 (would leave the king in check)
```

### 4.7 Packed Move Struct (3 Bytes → 2 Bytes)

**Commit:** `649db93` — Restructure movegen and pack Move to 16-bit

**What changed:**

```zig
// OLD: regular struct (3 bytes due to alignment)
pub const Move = struct {
    from: u6,
    to: u6,
    flags: types.MoveFlags,  // u4
};

// NEW: packed struct (exactly 2 bytes)
pub const Move = packed struct {
    from: u6,
    to: u6,
    flags: types.MoveFlags,  // u4
};
```

**Why smaller moves = faster:**

A `MoveList` holds up to 255 moves. The size difference:

- Old: 255 × 3 = 765 bytes (~12 cache lines)
- New: 255 × 2 = 510 bytes (~8 cache lines)

At depth 7, the perft tree has billions of positions. Each position generates a MoveList that gets iterated. Fewer cache lines per MoveList means:

- Better L1/L2 cache utilization
- Fewer cache misses during move iteration
- More positions' move lists fit in cache simultaneously

The measured improvement at depth 7 was **37%** — larger than at depth 5, because deeper searches amplify cache effects (the working set grows, and cache pressure increases).

### 4.8 Branchless Castling Rights Update

**Commit:** `649db93` — Restructure movegen

**What changed:**

The old code used a chain of if/else comparisons to update castling rights:

```zig
// OLD: branchy castling rights update
if (source_square == e1) {
    board.castle &= ~(WK | WQ);
} else if (source_square == e8) {
    board.castle &= ~(BK | BQ);
}
if (source_square == a1 or target_square == a1) board.castle &= ~WQ;
if (source_square == h1 or target_square == h1) board.castle &= ~WK;
// ... 4 more comparisons for black rooks ...
```

The new code uses a pre-computed lookup table:

```zig
// NEW: branchless lookup table (types.zig, comptime-initialized)
pub const castle_mask: [64]u8 = blk: {
    var m: [64]u8 = .{0xFF} ** 64;  // all squares: keep all rights
    m[a1] = ~WQ;     // 0xFD — moving from/to a1 removes WQ
    m[e1] = ~(WK|WQ); // 0xFC — moving from/to e1 removes WK+WQ
    m[h1] = ~WK;     // 0xFE — moving from/to h1 removes WK
    m[a8] = ~BQ;     // 0xF7
    m[e8] = ~(BK|BQ); // 0xF3
    m[h8] = ~BK;     // 0xFB
    break :blk m;
};

// Usage: single AND operation
board.castle &= castle_mask[from] & castle_mask[to];
```

This replaces 6+ branches with a single AND of two table lookups. The table is only 64 bytes (fits in one cache line) and is initialized at compile time.

### 4.9 Search Make/Unmake (SearchUndo)

**Commit:** `853eeb8` — Replace full BoardState save/restore with compact undo structs in search

**What changed:**

The old search saved/restored the entire `BoardState` (~200 bytes) for every move:

```zig
// OLD: full board copy for search
const board_state = board.save_state();     // copy ~200 bytes
const saved_eval = eval.global_evaluator;   // copy ~18 bytes
if (!make_move(board, move)) {              // make + legality check
    board.restore_state(board_state);       // illegal → restore ~200 bytes
    eval.global_evaluator = saved_eval;
    continue;
}
// ... search ...
board.restore_state(board_state);           // restore ~200 bytes
eval.global_evaluator = saved_eval;
```

The new search uses a compact `SearchUndo` (29 bytes):

```zig
// NEW: compact undo for search
pub const SearchUndo = struct {
    captured: types.Piece,    //  1 byte
    castle: u8,               //  1 byte
    enpassant: types.square,  //  1 byte
    hash: u64,                //  8 bytes
    evaluator: eval.Evaluator, // 18 bytes (2×i32 + 2×u8 + 2×i32)
};                            // Total: ~29 bytes
```

**Why search make/unmake is different from perft:** Search needs to maintain:

- **Zobrist hash** — for transposition table lookups
- **Evaluator state** — for incremental eval (material, phase)
- **Mailbox** — for O(1) piece-at-square queries (used by SEE, eval)

Perft needs none of these, so it uses the lighter 4-byte `PerftUndo`.

The `make_move_search` function incrementally updates the Zobrist hash and evaluator:

```zig
// Zobrist: remove piece from source, add to target
board.hash ^= piece_keys[pi][from];
board.hash ^= piece_keys[pi][to];

// Eval: update material for captures
if (captured != NO_PIECE) {
    eval.global_evaluator.remove_piece_phase(captured);
    eval.global_evaluator.remove_piece_material(captured);
}
```

The `unmake_move_search` simply restores from the undo struct:

```zig
board.hash = undo.hash;
eval.global_evaluator = undo.evaluator;
```

**Null move pruning** was also updated: instead of saving/restoring the full `BoardState`, only `hash` and `enpassant` are saved (the only fields that change during a null move).

### 4.10 Code Cleanup and Consolidation

**Commits:** `d8f6b1c`, `fb9e66a` — Cleanup rounds

**Files renamed:**

- `move_generation.zig` → `move.zig` (Move struct + make/unmake)
- `movegen_legal.zig` → `movegen.zig` (legal move generation)
- `tabeles.zig` → `tables.zig` (raw lookup tables)

**Naming fixes:**

- `tabele`/`tabeles` → `tables` (import aliases)
- `init_rook_attackes` → `init_rook_attacks`
- `init_bishop_attackes` → `init_bishop_attacks`
- `initialise_pseudo_legal` → `init_pseudo_legal`
- `Rook_attacks` → `rook_attacks_table`
- `Bishop_attacks` → `bishop_attacks_table`
- `White_pawn_attacks_tabele` → `white_pawn_attacks`
- `squar_bb` → `square_bb`
- `empty_Bitboard` → `empty_bitboard`
- `unicodePice` → `unicode_piece`
- `Evaluat` → `Evaluator`
- `fan_pars` → `parse_fen`
- `Print_move_list.is_capture(move)` → `move.is_capture()` (instance methods)

**Dead code removed:**

- `Direction` enum (never used)
- `square_bb_rotated` (never used)
- `MoveFlags.CAPTURES` (unused flag value 0b1011)
- `square_number` array (replaced with `0..64` range)
- `white_pieces()` / `black_pieces()` / `set_white()` / `set_black()` (duplicated `set_pieces()`)
- `print_attacked_squares()` / `print_attacked_squares_new()` (debug functions)
- `BoardState` struct + `save_state()` / `restore_state()` (replaced by undo structs)
- `ScoredMoveList` (unused alternative to MoveList+ScoreList)
- Duplicate perft helper functions in util.zig
- Old `generate_moves()`, `generate_capture_moves()`, `make_move()`, `make_capture_only()`, `try_make_move()`
- `casteling_rights` constant and related castling bitboard constants

---

## 5. Key Algorithms Explained

### 5.1 Legal Move Generation with Checkmask and Pinmask

The core insight of the Gigantua approach is: instead of generating all pseudo-legal moves and testing each for legality, compute **three masks** that encode all the legality constraints, then AND-mask them into every piece's move generation.

#### What is a checkmask?

The **checkmask** is a bitboard of squares that non-king pieces can move to in order to resolve a check:

- **No check:** checkmask = `0xFFFFFFFFFFFFFFFF` (all squares — no restriction)
- **Single check by slider:** checkmask = squares between king and checker + checker's square (block or capture)
- **Single check by knight/pawn:** checkmask = checker's square only (must capture it)
- **Double check:** only king moves are legal (skip all other pieces)

```zig
// Compute checkmask for slider checks
const rook_atk = get_rook_attacks(king_sq, occ);
const checkers = rook_atk & enemy_rook_queen;
while (checkers != 0) {
    const checker_sq = @ctz(checkers);
    checkmask |= between_table[king_sq][checker_sq] | (1 << checker_sq);
    num_checkers += 1;
}
```

#### What are pinmasks?

Pinmasks identify pieces that are pinned to the king. There are two separate masks because a piece pinned on a rank/file behaves differently from one pinned on a diagonal:

- **pin_hv:** horizontal/vertical pin rays (rook/queen pins)
- **pin_d12:** diagonal pin rays (bishop/queen pins)

A rook pinned on a file can still move along that file. A bishop pinned on a diagonal can still move along that diagonal. But a knight pinned anywhere cannot move at all.

**How pins are detected:** Using X-ray attacks:

```zig
// X-ray: remove our pieces, see if slider now attacks more squares
const occ_without_us = occ & ~us_bb;
const xray_atk = get_rook_attacks(king_sq, occ_without_us);
// Pinners = sliders that are now visible but weren't before
var pinners = (xray_atk & ~rook_atk) & enemy_rook_queen;
while (pinners != 0) {
    const pinner_sq = @ctz(pinners);
    const pin_ray = between_table[king_sq][pinner_sq] | (1 << pinner_sq);
    // Only a pin if exactly one of our pieces is on the ray
    if (@popCount(pin_ray & us_bb) == 1) {
        pin_hv |= pin_ray;
    }
}
```

#### How they combine

For each piece type, the mask is applied:

```zig
// Knight: must be unpinned (pinned knights can never move)
var knights = our_knights & ~(pin_hv | pin_d12);
var targets = knight_attacks(from) & ~us_bb & checkmask;

// Rook (unpinned): standard attack & movable
var targets = get_rook_attacks(from, occ) & ~us_bb & checkmask;

// Rook (HV-pinned): constrained to pin ray
var targets = get_rook_attacks(from, occ) & ~us_bb & checkmask & pin_hv;
```

#### ASCII diagram: checkmask + pinmask in action

```
  Position: White to move, black rook on e8 checks the king

  8  .  .  .  .  r  .  .  .    r = black rook (checker)
  7  .  .  .  .  .  .  .  .
  6  .  .  .  .  B  .  .  .    B = white bishop (on the check ray)
  5  .  .  .  .  .  .  .  .
  4  .  .  .  .  .  .  .  .
  3  .  .  .  .  .  .  .  .
  2  .  .  .  .  .  .  .  .
  1  .  .  .  .  K  .  .  .    K = white king
     a  b  c  d  e  f  g  h

  checkmask = e2 | e3 | e4 | e5 | e6 | e7 | e8
              (between king and checker, plus checker)

  Legal responses (pieces must move TO a square in checkmask):
  - King moves away (checked against king_ban)
  - Bishop on e6 can capture rook on e8 (e8 is in checkmask)
  - Any piece can block on e7 (e7 is in checkmask)
  - Knight (if on c7) could capture on e8 (in checkmask)
  - Pawn (if on d7) could capture on e8 (in checkmask)
```

#### Pseudo-legal vs. legal comparison

| Aspect | Pseudo-legal + legality check | Legal (checkmask+pinmask) |
|--------|-------------------------------|---------------------------|
| Moves generated | All piece moves | Only legal moves |
| Legality test | make → king_attacked? → unmake | None needed |
| Wasted work | High in check positions | None |
| Double check | All moves generated, all fail | Only king moves generated |
| Cost per position | ~200 byte save/restore per move | One-time mask computation |

**References:**

- [Chess Programming Wiki: Checks and Pinned Pieces](https://www.chessprogramming.org/Checks_and_Pinned_Pieces_%28Bitboards%29)
- [Gigantua](https://github.com/Gigantua/Gigantua) by Daniel Inführ
- [TalkChess: Gigantua thread](https://talkchess.com/viewtopic.php?t=78352)

### 5.2 Magic Bitboards for Sliding Pieces

Magic bitboards are a **perfect hashing** technique for computing sliding piece (rook, bishop) attacks in one table lookup.

**The algorithm:**

1. **Mask** the occupancy to only relevant squares (exclude board edges, which don't affect the attack ray):

   ```
   masked = occupancy & attack_mask[square]
   ```

2. **Multiply** by a "magic number" — a 64-bit constant that scrambles the relevant bits into the top N bits of the result:

   ```
   index = (masked * magic_number) >> (64 - N)
   ```

3. **Look up** the pre-computed attack bitboard:

   ```
   attacks = attack_table[square][index]
   ```

**In NeuroSpeed** (attacks.zig):

```zig
pub inline fn get_rook_attacks(square: u6, occ: u64) u64 {
    const mask = tables.rook_attack_masks[square];
    const magic = tables.rook_magics[square];
    const shift: u6 = @intCast(64 - tables.rook_index_bits[square]);
    const relevant = occ & mask;
    const idx: usize = @intCast((relevant *% magic) >> shift);
    return rook_attacks_table[square][idx];
}
```

Queens are computed as the union of rook and bishop attacks:

```zig
pub inline fn get_queen_attacks(square: u6, occ: u64) u64 {
    return get_rook_attacks(square, occ) | get_bishop_attacks(square, occ);
}
```

**Memory:** NeuroSpeed uses plain magic bitboards:

- Rook table: 64 squares × 4096 entries × 8 bytes = **2 MB**
- Bishop table: 64 squares × 512 entries × 8 bytes = **256 KB**

**References:**

- [Chess Programming Wiki: Magic Bitboards](https://www.chessprogramming.org/Magic_Bitboards)
- [Rhys Rustad-Elliott: Fast Chess Move Generation with Magic Bitboards](https://rhysre.net/fast-chess-move-generation-with-magic-bitboards.html)

### 5.3 Bitboard Tricks

**XOR for toggling pieces:**

```zig
// Move piece from 'from' to 'to' in one operation
board.pieces[idx] ^= square_bb[from] | square_bb[to];

// This works because:
//   bit at 'from' was 1 → XOR with 1 → becomes 0 (piece removed)
//   bit at 'to' was 0   → XOR with 1 → becomes 1 (piece placed)
```

**popcount for counting:**

```zig
// Count number of pieces in a bitboard
pub inline fn popcount(n: u64) u7 {
    return @popCount(n);  // Zig → hardware POPCNT instruction
}
```

**ctz (count trailing zeros) for finding the least significant bit:**

```zig
// Find the index of the lowest set bit
pub inline fn lsb_index(n: u64) u7 {
    return @ctz(n);  // Zig → hardware TZCNT/BSF instruction
}
```

**Bulk shifting for pawn moves:**

```zig
// All white pawns push one square forward — ONE instruction
const single_push = (free_pawns << 8) & empty;

// All white pawn left-captures — ONE instruction
const left_captures = ((free_pawns & ~file_a) << 7) & them_bb;
```

This processes all 8 pawns simultaneously instead of looping over each one.

**Bit iteration pattern:**

```zig
// Process each set bit in a bitboard
while (bb != 0) {
    const sq: u6 = @intCast(@ctz(bb));  // get lowest bit
    bb &= bb - 1;                        // clear lowest bit (Kernighan's trick)
    // ... do something with sq ...
}
```

---

## 6. How to Contribute / What to Work on Next

### High Priority

| Task | Difficulty | Description |
|------|-----------|-------------|
| **Merge to main** | Easy | This branch is ready. All tests pass, perft verified. |
| **Playing strength evaluation** | Easy | Run actual games (cutechess-cli) to verify search correctness and measure Elo. |

### Movegen Optimizations

| Task | Difficulty | Description | Resource |
|------|-----------|-------------|----------|
| **PEXT bitboards** | Medium | Use BMI2 PEXT instruction for faster slider attacks (replaces magic multiply+shift with hardware bit extraction). Gigantua gets ~1,470 MN/s with this. Beware: PEXT is slow on AMD Zen 1/2 (microcoded). | [CPW: PEXT Bitboards](https://www.chessprogramming.org/BMI2#PEXTBitboards) |
| **Comptime board state specialization** | Medium | Encode EP availability and castling rights as comptime parameters (like Gigantua's `if constexpr` template approach). Eliminates runtime branches for EP and castling in the common case. | [Gigantua source](https://github.com/Gigantua/Gigantua) |
| **Replace `get_piece_type_at`/`get_piece_at` with mailbox** | Easy | Some callsites still scan bitboards instead of using the `board[sq]` mailbox. O(1) instead of O(12). | — |

### Search & Eval Improvements

NeuroSpeed already has: LMR, null move pruning, futility pruning, reverse futility pruning, aspiration windows, singular extensions, razoring, late move pruning, history heuristic, killer moves, countermove heuristic, SEE, check extensions, mate distance pruning, repetition detection, 50-move rule, and IIR. The following are **not yet implemented**:

| Task | Difficulty | Description | Resource |
|------|-----------|-------------|----------|
| **Continuation history** | Medium | 5-dimensional history indexed by previous moves (not just from-to). Pawnocchio's biggest search improvement. | [Pawnocchio source](https://github.com/JonathanHallstrom/pawnocchio) |
| **History-based pruning** | Medium | Prune quiet moves with terrible history scores at shallow depths. | [CPW: History Heuristic](https://www.chessprogramming.org/History_Heuristic) |
| **Cut node tracking** | Easy-Medium | Track whether a node is expected to be a cut-node and adjust pruning/reductions. | [CPW: Node Types](https://www.chessprogramming.org/Node_Types) |
| **SE enhancements** | Medium | Double/triple extensions, negative extensions, lower depth threshold (currently depth >= 8). | [CPW: Extensions](https://www.chessprogramming.org/Extensions) |

### Aspirational

| Task | Difficulty | Description | Resource |
|------|-----------|-------------|----------|
| **NNUE evaluation** | Hard | Replace hand-crafted eval with NNUE (efficiently updatable neural network). This is the single biggest Elo gain available — potentially 200-400 Elo. | [CPW: NNUE](https://www.chessprogramming.org/NNUE) |
| **Lazy SMP** | Hard | Multi-threaded search. Each thread searches the same position with slight randomization; share TT. Typical gain: 50-80 Elo per doubling of threads. | [CPW: Lazy SMP](https://www.chessprogramming.org/Lazy_SMP) |
| **Syzygy tablebase support** | Medium | Query endgame tablebases for perfect play in positions with ≤7 pieces. | [CPW: Syzygy](https://www.chessprogramming.org/Syzygy_Bases) |
| **Opening book** | Easy | Use polyglot or custom format to skip early opening moves. | [CPW: Opening Book](https://www.chessprogramming.org/Opening_Book) |

---

## 7. References

### Project Links

- **NeuroSpeed:** <https://github.com/lovc21/NeuroSpeed>
- **Pawnocchio** (strongest Zig engine, CCRL 40/15: 3623 4CPU): <https://github.com/JonathanHallstrom/pawnocchio>

### Engine References

- **Gigantua** (fastest single-thread perft): <https://github.com/Gigantua/Gigantua>
- **Stockfish:** <https://github.com/official-stockfish/Stockfish>
- **Surge** (legal movegen, 16-bit moves): <https://github.com/nkarve/surge>
- **cozy-chess** (Rust movegen library): <https://github.com/analog-hors/cozy-chess>
- **MidnightMoveGen** (C++ single-header): <https://github.com/archishou/MidnightMoveGen>
- **FireFather perft-times** (74-engine benchmark): <https://github.com/FireFather/perft-times>
- **JuddPerft:** <https://github.com/jniemann66/juddperft>

### Chess Programming Resources

- **Chess Programming Wiki:** <https://www.chessprogramming.org/>
  - [Perft](https://www.chessprogramming.org/Perft)
  - [Magic Bitboards](https://www.chessprogramming.org/Magic_Bitboards)
  - [Encoding Moves](https://www.chessprogramming.org/Encoding_Moves)
  - [Checks and Pinned Pieces](https://www.chessprogramming.org/Checks_and_Pinned_Pieces_%28Bitboards%29)
  - [Move Generation](https://www.chessprogramming.org/Move_Generation)
  - [Copy-Make](https://www.chessprogramming.org/Copy-Make)
  - [Unmake Move](https://www.chessprogramming.org/Unmake_Move)
  - [NNUE](https://www.chessprogramming.org/NNUE)
- **Rhys Rustad-Elliott:** [Fast Chess Move Generation with Magic Bitboards](https://rhysre.net/fast-chess-move-generation-with-magic-bitboards.html)
- **Peter Ellis Jones:** [Generating Legal Chess Moves Efficiently](https://peterellisjones.com/posts/generating-legal-chess-moves-efficiently/) — checkmask/pinmask explanation, qperft benchmark
- **Daniel Inführ:** Gigantua — [GitHub](https://github.com/Gigantua/Gigantua), [TalkChess discussion](https://talkchess.com/viewtopic.php?t=78352)
- **johns.codes:** [Making a Chess Engine in Zig](https://johns.codes/blog/making-a-chess-engine-in-zig) — chess engine development in Zig (board representation, search, UCI)

### Forum Discussions

- **TalkChess:** <https://talkchess.com/>
  - [What is a good perft speed?](https://talkchess.com/viewtopic.php?t=83043)
  - [Writing the fastest move generator, 4BNodes/s](https://talkchess.com/viewtopic.php?t=85453)
  - [Gigantua discussion](https://talkchess.com/viewtopic.php?t=78352)
  - [Perft speed and depth questions](https://talkchess.com/viewtopic.php?t=74153)
