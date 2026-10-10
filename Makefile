.DEFAULT_GOAL := default

ZIG ?= zig
NET_FLAG := $(if $(EVALFILE),-Dnet="$(EVALFILE)",)
BUILT := bin/Avalanche

default:
	$(ZIG) build --release=fast --prefix ./ -Dtarget-name=Avalanche $(NET_FLAG)
ifdef EXE
	@[ $(BUILT) -ef "$(EXE)" ] || mv $(BUILT) "$(EXE)"
endif

.PHONY: default
