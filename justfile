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
