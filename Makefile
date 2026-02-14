.DEFAULT_GOAL := default

ifndef EXE
EXE=NeuroSpeed
endif

default:
	zig build --release=fast -Dcpu=x86_64
	mv ./zig-out/bin/NeuroSpeed $(EXE)

.PHONY: clean
clean:
	rm -rf zig-out zig-cache
