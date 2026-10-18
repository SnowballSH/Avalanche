# Syzygy tablebases

`src/syzygy` probes Syzygy WDL (`.rtbw`) and DTZ (`.rtbz`) tables. It is a Zig port of the parts of
[Pyrrhic](https://github.com/AndyGrant/Pyrrhic) that Avalanche used, and Pyrrhic is in turn derived from Fathom
and from Ronald de Man's probing code. The licence of that code is `src/syzygy/LICENSE` (`LICENSE-pyrrhic` in a
release package). `src/engine/syzygy.zig` is the engine's side: the UCI settings, and the probes in terms of
`position.Position` (docs/SEARCH.md, "Tablebases"). The engine has no C code.

## Layout

| File | Contents |
|---|---|
| `tablebases.zig` | `Tablebases`: finding the files, loading a table on its first probe, and the probes `probe_wdl`, `probe_root_dtz` and `probe_root_wdl` |
| `board.zig` | `Board`, the position a probe works on, and the move generation and make-move the probes need. The attacks come from `src/chess/tables.zig` |
| `encoding.zig` | The index of a position in a table, and the per-table parameters of that index that a file's header holds |
| `pairs.zig` | Decompression of a subtable's values: canonical Huffman codes over symbols that expand to pairs of symbols |

`Tablebases.open` takes a list of directories separated by `:` (`;` on Windows) and registers every table of up
to seven pieces whose WDL file is there and complete (16 bytes longer than a multiple of 64). Nothing is mapped
until a probe needs a table: its file is then memory-mapped read-only (`std.Io.File.MemoryMap`, with
`MADV_RANDOM` outside Windows) and its headers parsed into a `Table`, under a mutex, and published to the other
threads through an atomic state per table and kind. A table whose file cannot be mapped or parsed is marked failed,
and its probes fail from then on without taking the lock.

The lookup tables of the index (binomial coefficients, pawn indices and factors) are computed at compile time.

## What is left out

Only what Avalanche calls is ported. Left out of Pyrrhic are the DTM tables (`.rtbm`) and the rank
encoding that only they use, `tb_probe_root` (the Fathom-style root probe that returns one move), the loader for
tables that are not files, and the `<embedded>` path.

## Differences from Pyrrhic

The results are the same; these are the places where the behaviour around them differs.

- **A failed table fails alone.** Pyrrhic removes a table's whole entry from its hash when either of its files
  fails to load, so a corrupt DTZ file also stops the WDL probes of that material. Here the WDL and the DTZ table
  of an entry fail separately.
- **The fifty-move counter saturates.** Pyrrhic keeps the counter in a byte, so a counter of 256 becomes 0 and 255
  plus a move becomes 0, which reads as a capture or pawn move. The engine passes `@min(fifty, 255)` and a move
  adds to it saturating, so only a zeroing move gives 0.
- **Messages go to standard error only.** Pyrrhic also writes `info string Incomplete tablebase file` to
  standard output, outside the engine's UCI writer.
- **Reads are byte-wise.** Pyrrhic reads the 16- and 32-bit fields of a file through casted pointers, some of them
  misaligned, which a Debug build of the C code reports as undefined behaviour (`setup_pairs`). The port reads
  them with `std.mem.readInt`, and slices carry the table's regions, so a Debug build checks every access.

## Verification

The port was checked against the C Pyrrhic it replaces, compiled with `-O3` as `build.zig` used to compile it and
linked into one test binary with the port, on all 3-, 4- and 5-piece tables and twelve 6-piece ones (KPPPPvK,
KNNvKNN, KRPPPvK, KBBvKBB, KNPPPvK, KBPPPvK, KQQQQvK, KQPPPvK, KRRRRvK, KNNPPvK, KBNvKNN, KQQQvKN):

- 3.6 million random positions of 3 to 6 pieces, en-passant squares included, probed for WDL, and 600,000 of them
  also through `probe_root_dtz` and `probe_root_wdl` with random fifty-move counters, repetition flags and
  `Syzygy50MoveRule`; then 210,000 positions of the twelve 6-piece materials the same way. Every value, move list
  and rank was identical, failures included. A changed constant in the DTZ decoding made 123 of 20,000 positions
  differ. Part of the runs were Debug builds, with every safety check on.
- Fourteen endgame searches to depth 16 with `SyzygyPath` set, from 4 to 7 pieces, one with an en-passant square
  and two with fifty-move counters of 60 and 37: the same node counts, tbhits, scores and best moves as the
  engine built with the C code.

One branch was checked by reading only: DTZ value maps of 16-bit entries (flag 16). No table of up to six pieces
has them, and of the 1,001 seven-piece tables only KQBNvKQB, KQBNvKQN, KRBNvKQN and KRBBPvKQ do, whose DTZ files
are 25 to 57 GB.

The unit tests (`src/tests/syzygy.zig`) probe small tables kept in `src/tests/syzygy` (their origin and
checksums are in its README). One enumerates every legal placement of each of them with the white king on four
squares and compares the counts of WDL results and a hash of the root DTZ ranks with the values the C Pyrrhic
gave for the same positions (`src/tests/syzygy_enumeration.zig`).

Speed, on a two-core Neoverse-N1, with the same binary and positions for both, the tables in the page cache and
the WDL rounds alternating which went first: a WDL probe of a random 3- to 5-piece position took 859 to 881 ns
against 878 to 897 ns for the C code, one of 3 or 4 pieces 479 to 497 ns against 503 to 507 ns, and a root DTZ
probe 82 to 109 µs against 84 to 113 µs. The C code called the engine's attack functions through exported
callbacks that the compiler could not inline; the port calls them directly. With tables loaded, the fourteen
searches above took 3.86 s at best (of eight runs to depth 20) against 3.89 s for the C build, and `bench`, which
loads no tables, prints the same node count at the same speed within the spread between runs.
