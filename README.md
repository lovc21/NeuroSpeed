<div align="center">
    <h1>NeuroSpeed</h1>
    <img src="https://github.com/lovc21/NeroSpeed/blob/main/.docs/img/nerospeed.jpg"
         width="400" height="400" alt="Nero speed image">
</div>

<div align="center">
NeuroSpeed is a UCI chess engine that is optimized for extreme time controls. The goal of this chess engine is to see what can be optimized so it can beat other chess engines when it comes to low time, for example, bullet games or ultra-bullet games.
</div>

## Releases

This chess engine is still in development (pre-1.0). A stable v1.0 release will follow once testing and tuning are complete.

## Strength

| Version | Date       | Estimated Elo |
|---------|------------|---------------|
| pre-1.0 | 2026-03-03 | 2100 - 2300   |

## Features

These are the features that were implemented so far:

```
Bitboard board representation (LERF mapping)
Pre-calculated attack tables
Magic bitboards for sliding piece attacks
Negamax alpha-beta search
PVS
Quiescence search
Iterative deepening
Mate distance pruning
Delta pruning in quiescence
Check extensions in quiescence
PV move ordering
MVV-LVA
Static Exchange Evaluation
Killer move heuristic
History heuristic
Tapered evaluation
Piece-square tables
Material evaluation
Pawn structure
Piece mobility
King safety
Threat evaluation
Bishop pair bonus
Bad bishop penalty
Knight outpost bonus
Knight on rim penalty
Rook on open/semi-open file bonus
Rook on 7th rank bonus
Tempo bonus
KBN vs K corner mating and king distance
Insufficient material draw detection
```

## How to build

Requires [Zig](https://ziglang.org/download/) (0.14+) and [just](https://github.com/casey/just).

```bash
# Build optimized binary for your machine
just build

# Build and run the engine in fast mode
just start

```

## Thanks and Acknowledgements

- Huge shout-out to [Maksim Korzh](https://github.com/maksimKorzh) for his [chess programming series](https://www.youtube.com/playlist?list=PLmN0neTso3Jxh8ZIylk74JpwfiWNI76Cs). It's a great help in explaining complex topics in chess engine development.
- Big thanks to the [Avalanche](https://github.com/SnowballSH/Avalanche) chess engine and [Lambergar](https://github.com/jabolcni/Lambergar) chess engine, where I got a lot of inspiration and a better idea of how to write Zig code, as these chess engines were implemented in Zig.
- Huge shout-out to the [Stockfish Discord](https://discord.com/invite/GWDRS3kU6R) for being helpful when it comes to questions, and to the [Stockfish](https://github.com/official-stockfish/Stockfish) engine for its great implementation and clean code
- And just like 99% of chess engines, a big thanks to the [Chess Programming Wiki](https://www.chessprogramming.org/Main_Page) for being such a well-structured base of knowledge when it comes to chess engine design
