# Opening books

Opening books are **not committed** (`*.epd` is git-ignored), so put them here yourself.

The match scripts `scripts/sprt.py`, `scripts/quick-test.sh` and `scripts/match.sh` play from

```
books/UHO_4060_v4.epd
```

an engine-testing book with one FEN/EPD opening per line, played from both
sides. It is one of the Stockfish testing books at
<https://github.com/official-stockfish/books>. `scripts/sprt.py` takes any
other book (`.epd` or `.pgn`) with `--book <path>`; the other two scripts use
this file only.

The bulk datagen schedule `scripts/datagen_a_lot.json` names the books of its
jobs by path, `books/<name>.epd`; a job whose book is missing fails when its
worker starts. Datagen checks every line of a book before it plays from it
(see "Openings" in [docs/DATAGEN.md](../docs/DATAGEN.md)).
