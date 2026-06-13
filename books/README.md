# Opening books

The SPRT tooling (`tools/test`) defaults to an opening book at
`books/noob_4moves.epd`. Opening books are **not committed** (`*.epd` is
git-ignored), so drop the book here yourself:

```
books/noob_4moves.epd
```

`noob_4moves.epd` is a standard engine-testing book (one FEN/EPD opening per
line, played from both sides). Obtain it from your engine-testing book
collection — e.g. the Stockfish testing books at
<https://github.com/official-stockfish/books> — and place it at the path above.

To use a different book (any `.epd` or `.pgn`), pass `--book <path>` to
`tools/test`.
