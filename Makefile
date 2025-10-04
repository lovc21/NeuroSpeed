.PHONY: all
all: build

.PHONY: build
build:
	zig build --release=fast -Dcpu=x86_64

$(EXE):
	zig build --release=fast -Dcpu=x86_64
	@if [ -f "zig-out/bin/NeuroSpeed" ]; then \
		cp zig-out/bin/NeuroSpeed $(EXE); \
	else \
		echo "Build failed!"; \
		exit 1; \
	fi

.PHONY: clean
clean:
	rm -rf zig-out zig-cache

.PHONY: help
help:
	@echo "Makefile targets:"
	@echo "  all      - Build the engine (default)"
	@echo "  build    - Build the engine"
	@echo "  clean    - Remove build artifacts"
	@echo "  help     - Show this help message"
