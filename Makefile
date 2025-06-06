.DEFAULT_GOAL := default

MV=mv bin/Avalanche $(EXE)

default:
	zig build --release=fast -Dtarget-name="Avalanche"

ifdef EXE
	$(MV)
endif