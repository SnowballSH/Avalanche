cutechess-cli -tournament gauntlet -concurrency 6 \
  -engine name="Old" dir=. cmd="./old_binaries/Avalanche" tc="10+1" timemargin=500 proto="uci" \
  -engine name="New" dir=. cmd="./zig-out/bin/Avalanche" tc="10+1" timemargin=500 proto="uci" \
  -recover \
  -event SELF_PLAY_GAMES \
  -draw movenumber=30 movecount=20 score=20 \
  -resign movecount=10 score=800 \
  -resultformat per-color \
  -openings order=random policy=round file="./noob_4moves.epd" format="epd" \
  -rounds 40