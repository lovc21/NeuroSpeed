zig-fmt:
  zig fmt . --ast-check --color on

run: zig-fmt
  zig build run

test: zig-fmt
  zig build test --summary all

# build for my laptop
build: zig-fmt
  zig build --release=fast -Dcpu=znver1 -Dtarget=x86_64-linux
