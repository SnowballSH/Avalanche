# Threads and NUMA

Avalanche uses Lazy SMP: the main search thread and `Threads - 1` helpers
search the same root with a shared transposition table. Odd-numbered helpers
search one ply deeper to diversify the trees.

## Persistent thread pool (`src/engine/thread_pool.zig`)

Helpers are created once, when `Threads` is set, and then wait for jobs. Each
aspiration re-search posts a `search` job to every helper and `stop_helpers`
waits for them to go idle again, instead of spawning and joining one OS thread
(with a 64 MiB stack) per helper per re-search, which happened dozens of times
per move and became the dominant cost at high thread counts.

A worker owns its `Searcher`: the worker thread allocates and initialises it
after NUMA placement, so its 8.7 MiB of tables are first touched, and
therefore physically allocated, on the node the thread runs on. The largest
of them, the 6 MiB continuation history, is on huge pages where the OS has
them; docs/MEMORY.md lists what lives where. The main thread's `Searcher` is
created by the UCI thread, which is not bound, so its tables are not placed.
`ucinewgame` resets all helpers' heuristics in parallel on their own threads.
Lowering `Threads` shuts down surplus workers and frees their tables.

A helper takes over the root once per search, not per job: the main thread
copies the game state (`Position.copy_game_state`: the piece bitboards, the
occupancy, the mailbox, the keys, the side to move, the ply counters, the
castling setup, the Chess960 flag and the current undo entry, 458 bytes in
all), the game's hash history and the root move list, and the helper rebuilds
its accumulator on its own thread from its own Finny table before its first
job. Every job unwinds back to the root, so an aspiration re-search costs each
helper the excluded MultiPV moves, its stop flag and the job itself. Copying
the whole `Position` instead cost 157 KB per helper per re-search (80 MB at
512 threads; a `Position` is 244 KB today) and replaced each helper's warm
Finny table with the main thread's. After a network is loaded (`EvalFile`), a
helper drops its Finny table and its evaluation cache when it next rebuilds
its root: both carry the generation of the network they were filled with.

The search contract is unchanged: helpers run a fixed-depth root search per
job and stop when the main thread tells them to. On wasm
(`platform.has_threads == false`) the pool is never started and `Threads` is
capped at 1.

### Job handoff

A worker and its controller meet through two `std.Io.Event`s that live next
to the job in the `Worker`: `job_posted` (controller to worker) and `idle`
(worker to controller). A worker sleeps on the futex between jobs, as it did
on the mutex and condition variable this replaced, and posting a job costs the
same (typically 6 to 8 µs for three sleeping helpers on an M4, measured both
ways); there is only less state. `Worker` is aligned to the cache line, so
two workers never share one.

The pool has one controller at a time: the thread that posts jobs and waits
for workers. That is the search thread during a search and the UCI thread for
`Threads`, `ucinewgame` and shutdown, which the UCI loop only runs when no
search is active. `std.Io.Event.reset` requires that nobody is waiting on the
event, so two threads must never wait for the same worker.

Tried and removed: spinning on the event for 4096 pause instructions (49 µs on
an M4) before sleeping, on the argument that consecutive jobs of one search
are microseconds apart. Posting a job to a spinning helper cost a third of
posting to a sleeping one (2 to 3 µs for three helpers), and at 4 threads on a
busy M4 the spin spared most but not all sleeps (0.3 to 2.3 per job instead
of 4.3). But a count of pause instructions is anywhere between 10 and 190 µs
across x86 microarchitectures, spinning is wasted on a machine with fewer
CPUs than threads, and helpers that spin all start a job within microseconds
of each other, where sleeping ones are woken one after the other. What it
does to a search at 16 or more threads could not be measured: on a 64-core
EPYC 9R14, nodes per second of 1 to 3 s searches moved by about 8% from round
to round, and the version with the spin came out between 0.91 and 1.04 of the
code before this work at 16 and 32 threads. A spin has to show a gain in time
to depth there before it comes back, with a bound in time rather than in
instructions.

## Shared state on the search path

What a search thread shares with the others decides how the engine scales.
Everything another thread reads or writes in a searcher while it searches is
in `Searcher.shared` (`CrossThreadState`).

| State | Written by | Read by | How often |
| --- | --- | --- | --- |
| Transposition table entry | any thread (`set`) | any thread (`get`) | once or twice per node, by design |
| `shared.stop` | main thread (helpers'), UCI thread or wasm host (main's) | the owner, every 16 nodes | written twice per job |
| `shared.nodes` | the owner, every node | main thread | per `info` line; every 1024 main-thread nodes under `go nodes` |
| `shared.tbhits` | the owner, per tablebase hit | main thread | per `info` line |
| `shared.pondering` | UCI thread (`go ponder`, `ponderhit`) | main thread | every 1024 nodes, and while it holds back `bestmove` |
| `shared.is_searching` | UCI thread before the search, main thread after it | UCI thread | per UCI command |
| `Worker` events and job | controller and worker | controller and worker | per job |
| Standard output | main thread (`info`, `bestmove`), UCI thread (`readyok`, refusals) | | whole lines through two buffered writers |
| Network weights, attack tables, `CONTEMPT`, options | nobody during a search | every thread, every node | read-only |

Between jobs, while a helper is parked, the main thread also writes that
helper's root (game state, hash history, root moves once per search, excluded
moves per job) and zeroes its counters at the start of a search.

The search writes no global, and a helper never reads another searcher. The
Syzygy probing code was not part of this audit.

### Stop flag

Every searcher has one `stop` flag. A thread reads its own flag at the entry
of a node, every `STOP_CHECK_INTERVAL` (16) nodes; the main thread also checks
the clock and the node budget every `LIMIT_CHECK_INTERVAL` (1024) nodes.
`stop_helpers` raises every helper's flag and waits for the workers.

Before, helpers looked at their flag (and, through a pointer, at the main
thread's) only every 1024 nodes, so after every aspiration attempt the main
thread waited up to 1024 nodes of the slowest helper while the other helpers
sat idle. 1024 nodes are half a millisecond on an M4 performance core and
3.5 ms at the 290 k nodes per second per thread of a 512-thread machine. A
3 to 4 s search made 16 to 45 attempts, a long one makes more, and most of
them fall into the first second of a move.
Reading the flag at every node would add a load and a branch to every node
entry; sampling it keeps the entry check at the three instructions it had
(load `nodes`, test, branch), and 16 nodes are a few microseconds.

Measured with 4 threads on a busy M4 (3 s searches from two positions): after
a stop request a helper searched 315 to 450 more nodes before and 4 to 7 now,
and the main thread waited 0.8 to 5 ms per aspiration attempt before and 0.02
to 1.7 ms now. What remains is helpers that were not on a CPU when the flag
was raised.

### Node counts and `go nodes`

`nodes` is a plain per-thread counter that only its owner writes (a relaxed
load and store: load, add, store on AArch64, as for `+= 1`). The main thread
sums the helpers' counters for `info` lines and, under a node budget, in its
limit check; helpers do not know the budget and simply obey the stop flag.
With no helpers the total is the main thread's own counter, so
single-threaded `go nodes N` stops exactly where it did.

With helpers a search overshoots its budget, typically by about 1024 nodes
per thread as before: what the helpers search between two limit checks of the
main thread. Helpers no longer stop themselves, though. If the main thread
loses its CPU or blocks while writing output, they search on until its next
limit check or the end of their fixed-depth job, whichever comes first, so
the overshoot has no fixed bound; the search always terminates.

Before, a search with a node budget did an atomic add on one shared counter
for every node of every thread (`ldadd` on ARM, `lock xadd` on x86), which
moves that cache line between all cores once per node. The main thread and
datagen paid the atomic add even when single-threaded. On a 64-core EPYC
9R14, `go nodes 20000000` ran at 7.95M, 22.2M and 25.5M nodes per second with
8, 32 and 64 threads before and at 11.5M, 47.1M and 77.6M after (1.45, 2.14
and 3.04 times as fast), and at the same speed with one thread.

### Searcher layout

`Searcher` is 484 KB of per-ply stacks and history tables, and Zig is free to
order its fields: today by alignment and, within one alignment, in an order
that changes whenever a field is added or removed. `CrossThreadState` is a
nested struct, so its five fields stay together whatever the compiler does
with the rest; it is aligned to the cache line and a compile-time check keeps
it within one, on every target. A searcher therefore starts on a cache line of
its own and, while it searches, other threads touch exactly one line of it.
The rest of that line holds fields of the same searcher that only its owner
uses.

Everything else a node touches belongs to the owner alone and is placed by the
compiler: the scalars `ply`, `seldepth`, `nmp_min_ply` and `time_stop`, the
read-mostly `ttable`, `continuation`, `root_board`, `thread_id` and
`root_history_len`, `hash_history`, and the per-ply arrays (`pv_size`,
`exclude_move`, `eval_history`, `raw_eval_history`, `move_history`,
`moved_piece_history`, `killer`, `pv`). Pulling the scalars to the front by
over-aligning them, and nesting them next to the cross-thread state, were both
tried for the shorter addressing they allow on AArch64 (a field beyond 4 KB
for byte loads or 32 KB for word loads needs its address built first).
Neither could be told apart from the plain layout. In four interleaved rounds
each on an M4, `bench` retired 0.997 to 1.002 times the instructions of the
code before this work with the scalars over-aligned, 0.999 to 1.004 with them
nested, and 0.998 to 1.000 with the layout described here. The counts that
`/usr/bin/time -l` reports on a busy machine move with the cycles a run takes
(113.19 G in a run of 43.9 G cycles, 112.67 G in one of 28.7 G, same binary),
which is more than the layouts differ by. All of these builds are commit
870eeab with only this work on top: the absolute counts are not those of a
build that also has the other changes of pull requests #104 to #111. `ply`
alone is used on 74 lines of `negamax` and `quiescence_search`, so nesting it
has a cost in the source and no measured gain.

### Transposition table

An entry is two 64-bit words. `set` takes a lock bit in the second word with
an atomic OR (`ldseta`, `lock or` on x86), reads the old entry, and stores
both words, the second with a new 15-bit sequence number. `get` reads the
second word, the first, and the second again (`ldapr`, plain loads on x86)
and rejects an entry whose second word changed or is locked. A reader can
therefore not see words from two different stores, short of exactly 32768
stores to that entry between its two reads of the second word.

A lockless variant was built and measured: the first word is stored XORed
with a 64-bit mix of the second (`(w1 * K) ^ ((w1 * K) >> 64)`), so that words
from two different stores decode to a different key. It needs no atomic
read-modify-write and no sequence number, returns the same hits
single-threaded (`bench` is unchanged at 15472869 nodes), and lets a torn
entry through only when 32 bits of the mix coincide, which is the rate at
which the 32-bit key already accepts a different position. It was not
adopted:

- Single-threaded it could not be told apart from the lock: `bench` retired
  113.99 G instructions against 113.75 G in one run each, on a machine where
  repeated runs of one binary differ by more than that. Both builds are
  commit 870eeab with only this work on top: the absolute counts are not
  those of a build that also has the other changes of pull requests #104 to
  #111. The atomic OR works on a line the core already holds; `lock or` is
  usually quoted at about 20 cycles, around 1% of a node on a current x86
  core, which bounds what removing it can give there. That has not been
  measured on x86.
- It does not scale differently. The lock is per entry and the line has to
  come to the storing core in exclusive state for a plain store just the
  same; two threads meet on one entry only when they store the same position
  at the same time, and then the lock makes the second one skip its store.

The cost of the table at many threads is the cache and TLB miss of the probe,
not its concurrency scheme.

### Smaller items

- The time check runs on the main thread only, every 1024 nodes, and costs
  one clock read through the `std.Io` vtable.
- Helper stacks are 64 MiB of address space each; only the touched pages are
  backed by memory, and a `negamax` frame is 3 to 4 KB, so a 200-ply line
  stays under 1 MB.
- `helpers_live`, a debugging flag written twice per job, sat on the cache
  line that holds `CONTEMPT`, the Syzygy switch and `platform.io`, which
  every thread reads on every node. It is gone; `helpers_are_live` asks the
  pool.

## NUMA placement (`src/engine/numa.zig`)

On Linux the topology is read once from `/sys/devices/system/node`
(`online` and each node's `cpulist`). With `NumaPolicy auto` (default) and
more than one node, search thread `i` (0 = main) is bound with
`sched_setaffinity` to the node that owns the `i`-th CPU when nodes are filled
in order, wrapping when threads outnumber CPUs. Small thread counts therefore
stay on one node, and large ones spread across all nodes in proportion to
their CPU counts. `NumaPolicy none` leaves placement to the OS scheduler;
changing the policy restarts the helpers so the new placement applies.

On single-node machines and on other operating systems, placement is a no-op.

Not done (possible future work): replicating the network weights per node
(Stockfish-style). The 25 MB network is shared and read-only: one block of
large memory behind the `weights.MODEL` pointer (docs/MEMORY.md), first
touched by the UCI thread. On a two-socket machine half of the threads fetch
it from the other node whenever a row has left their cache, and with several
MiB of private tables per thread competing for each shared L3 that happens
often; a replica per node would turn those fetches into local ones. The rows
are read sequentially, so the prefetcher hides most of the extra latency; the
gain has not been measured. It needs the evaluator to reach the weights
through a per-searcher pointer instead of a global. The transposition table
is shared by design: part `i` of a new table is backed on a thread bound like
search thread `i`, with the limits docs/MEMORY.md lists.

Also not done: helpers that keep searching across the main thread's
aspiration attempts and iterations (as in Stockfish) instead of running one
fixed-depth job per attempt. A helper whose job ends before the main thread's
(a fail-high or fail-low at the root is enough) has nothing to do until the
next job: in 26 searches of 3 s with 4 threads on a busy M4, helpers spent
between 0.5% and 29% of the search waiting for a job (0.5 to 17% before this
work, 0.7 to 29% after it, with no difference the noise would allow). And a
restarted helper walks back down from the root through the transposition
table. Changing this changes search behaviour and needs its
own strength test at high thread counts.
