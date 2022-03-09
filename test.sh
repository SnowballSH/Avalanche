cutechess-cli -tournament gauntlet -concurrency 5 \
  -engine name="New" dir=. cmd="./zig-out/bin/Avalanche" tc="5+1" timemargin=1000 proto="uci" \
  -engine name="Old" dir=. cmd="./old_binaries/Avalanche" tc="5+1" timemargin=1000 proto="uci" \
  -recover \
  -event Avalanche_testing \
  -draw movenumber=30 movecount=20 score=20 \
  -resign movecount=10 score=800 \
  -resultformat per-color \
  -openings order=random policy=round file="./noob_4moves.epd" format="epd" \
  -rounds 100