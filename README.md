<div align="center">
    <h1>NeuroSpeed</h1>
    <img src="https://github.com/lovc21/NeroSpeed/blob/main/.docs/img/nerospeed.jpg"
         width="400" height="400" alt="Nero speed image">
</div>

<div align="center">
NeuroSpeed is a UCI chess engine that is optimized for extreme time controls. The goal of this chess engine is to see what can be optimized so it can beat other chess engines when it comes to low time, for example, bullet games or ultra-bullet games.
</div>

## Releases

This chess engine is still in development. When I have it in working order and with some results, I will release it as version 1 (v1)

## Strength

**TODO:**

- Update the strength table:

| Version | Release Date | CCRL Blitz | CCRL 40/15 |
|---------|--------------|------------|------------|
| v1.0    | 2024-01-01   | 3000       | 3050       |
| v1.1    | 2024-03-15   | 3100       | 3150       |
| v2.0    | 2024-06-10   | 3200       | 3250       |

## Features

  These are the features that were implemented so far:

    Bitboard board representation 
    Pre-calculated attack tables 
    Magic bitboards

## How to Build

**TODO:**

- Add a "How to Build" section

## Thanks and Acknowledgements

- Huge shout-out to [Maksim Korzh](https://github.com/maksimKorzh) for his [chess programming series](https://www.youtube.com/playlist?list=PLmN0neTso3Jxh8ZIylk74JpwfiWNI76Cs). It's a great help in explaining complex topics in chess engine development.
- Big thanks to the [Avalanche](https://github.com/SnowballSH/Avalanche) chess engine and [Lambergar](https://github.com/jabolcni/Lambergar) chess engine, where I got a lot of inspiration and a better idea of how to write Zig code, as these chess engines were implemented in Zig.
- Huge shout-out to the [Stockfish Discord](https://discord.com/invite/GWDRS3kU6R) for being helpful when it comes to questions, and to the [Stockfish](https://github.com/official-stockfish/Stockfish) engine for its great implementation and clean code
- And just like 99% of chess engines, a big thanks to the [Chess Programming Wiki](https://www.chessprogramming.org/Main_Page) for being such a well-structured base of knowledge when it comes to chess engine design
