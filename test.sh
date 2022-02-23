cutechess-cli -tournament gauntlet -concurrency 4 \
  -engine name="Old" dir=. cmd="./old_binaries/Avalanche" st=0.5 timemargin=100 proto="uci" \
  -engine name="New" dir=. cmd="./zig-out/bin/Avalanche" st=0.5 timemargin=100 proto="uci" \
  -recover \
  -event SELF_PLAY_GAMES \
  -draw movenumber=30 movecount=10 score=20 \
  -resign movecount=4 score=500 \
  -resultformat per-color \
  -openings order=random policy=round file="./book.epd" format="epd" \
  -rounds 50