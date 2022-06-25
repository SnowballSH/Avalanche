.DEFAULT_GOAL := default

MV=mv bin/Avalanche $(EXE)

default:
	zig build -Drelease-fast --prefix ./ -Dtarget-name="Avalanche"

ifdef EXE
	$(MV)
endif