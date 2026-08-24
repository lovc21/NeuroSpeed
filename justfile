zig-fmt:
  zig fmt . --ast-check --color on

run: zig-fmt
  zig build run

test: zig-fmt
  zig build test --summary all

build: zig-fmt
  zig build --release=fast -Dcpu=native

start: build
  ./zig-out/bin/NeuroSpeed

clean:
  rm -rf zig-out .zig-cache

# llvm-bolt layout optimization -> zig-out/bin/NeuroSpeed.bolt (re-profile after engine changes)
build-bolt bolt-depth="17": build
  #!/usr/bin/env bash
  set -euo pipefail
  BIN=zig-out/bin/NeuroSpeed
  DEPTH={{bolt-depth}}
  W=$(mktemp -d)
  trap 'rm -rf "$W"' EXIT
  printf "bench $DEPTH\nquit\n" | perf record -b -e cycles:u -F 3000 -o "$W/perf.data" -- $BIN > /dev/null 2>&1
  perf2bolt -p "$W/perf.data" -o "$W/ns.fdata" $BIN
  llvm-bolt $BIN -o $BIN.bolt -data "$W/ns.fdata" -reorder-blocks=ext-tsp
  FP=$(printf 'bench 6\nquit\n' | $BIN.bolt 2>/dev/null | tail -1 | awk '{print $1}')
  if [ "$FP" != "56024" ]; then echo "FINGERPRINT MISMATCH: $FP != 56024 — discard $BIN.bolt"; exit 1; fi
  echo "OK: $BIN.bolt (bench fingerprint $FP verified)"
