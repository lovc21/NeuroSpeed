<div align="center">
    <h1>NeuroSpeed</h1>
    <img src=".docs/img/nerospeed.jpg"
         width="400" height="400" alt="Nero speed image">
</div>

<div align="center">
NeuroSpeed is a UCI chess engine that is optimized for extreme time controls. The goal of this chess engine is to see what can be optimized so it can beat other chess engines when it comes to low time, for example, bullet games or ultra-bullet games.
</div>

## Releases

Prebuilt binaries for Windows, Linux and macOS (x86_64 and ARM64) are on the [releases page](https://github.com/lovc21/NeuroSpeed/releases). The NNUE nets are embedded, so the binary is all you need.

## Strength

| Version | Date       | Elo                                   |
| ------- | ---------- | ------------------------------------- |
| 1.0     | 2026-09-10 | ~3160 ±70 (internal Stockfish-anchored gauntlet, 8+0.08, measured on a pre-release build) |

## Features

These are the features that were implemented so far:

```
Board and move generation
  Bitboard board representation (LERF mapping) with a mailbox
  Pre-calculated attack tables
  Magic bitboards for sliding piece attacks
  Legal move generation with check and pin masks

Search
  Negamax alpha-beta with PVS
  Iterative deepening with aspiration windows
  Transposition table (4 entries per 64-byte cluster, prefetching, huge pages on Linux)
  Quiescence search with SEE pruning and check evasions
  Mate distance pruning
  Reverse futility pruning
  Razoring
  Null move pruning
  Futility pruning
  Late move pruning
  History pruning
  SEE pruning
  Late move reductions
  Singular extensions with multi-cut
  Check extensions
  Internal iterative reductions
  Repetition and 50-move rule detection

Move ordering
  TT move
  MVV-LVA and Static Exchange Evaluation
  Killer moves
  History heuristic with gravity
  Countermove heuristic
  Continuation history (1 and 2 plies back)

Evaluation
  NNUE: big net (640 hidden, 8 output buckets) and small net (128 hidden)
  Router: picks the big net, the small net or the handcrafted eval per position by material imbalance
  Handcrafted eval (tapered):
    Piece-square tables and material
    Pawn structure
    Piece mobility
    King safety
    Threat evaluation
    Bishop pair bonus and bad bishop penalty
    Knight outpost bonus and knight on rim penalty
    Rook on open/semi-open file and on 7th rank
    Tempo bonus
    KBN vs K corner mating and king distance
    Insufficient material draw detection

Time management
  Soft and hard time limits
  Soft limit scaled by best-move stability and score trend
  Less time in decided positions
  Instant move when only one legal move
```

## How to build

Requires [Zig](https://ziglang.org/download/) 0.16 or newer and [just](https://github.com/casey/just).

```bash
# Build optimized binary for your machine
just build

# Build and run the engine in fast mode
just start

# Without just
zig build -Doptimize=ReleaseFast -Dcpu=native
```

## Thanks and Acknowledgements

- Huge shout-out to [Maksim Korzh](https://github.com/maksimKorzh) for his [chess programming series](https://www.youtube.com/playlist?list=PLmN0neTso3Jxh8ZIylk74JpwfiWNI76Cs). It's a great help in explaining complex topics in chess engine development.
- Big thanks to the [Avalanche](https://github.com/SnowballSH/Avalanche) chess engine and [Lambergar](https://github.com/jabolcni/Lambergar) chess engine, where I got a lot of inspiration and a better idea of how to write Zig code, as these chess engines were implemented in Zig.
- Huge shout-out to the [Stockfish Discord](https://discord.com/invite/GWDRS3kU6R) for being helpful when it comes to questions, and to the [Stockfish](https://github.com/official-stockfish/Stockfish) engine for its great implementation and clean code
- And just like 99% of chess engines, a big thanks to the [Chess Programming Wiki](https://www.chessprogramming.org/Main_Page) for being such a well-structured base of knowledge when it comes to chess engine design
