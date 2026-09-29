.DEFAULT_GOAL := default

ZIG ?= zig
EXE ?= Avalanche
NET_FLAG := $(if $(EVALFILE),-Dnet=$(EVALFILE),)

# OpenBench passes CC=<compiler>; the Zig build selects its own toolchain, so CC is intentionally unused.
default:
	$(ZIG) build --release=fast --prefix ./ -Dtarget-name=Avalanche $(NET_FLAG)
	@if [ "$(EXE)" != "Avalanche" ]; then mv bin/Avalanche "$(EXE)"; fi

.PHONY: default
