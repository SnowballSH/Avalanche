# Threads and NUMA

Avalanche uses Lazy SMP: the main search thread and `Threads - 1` helpers
search the same root with a shared transposition table. Odd-numbered helpers
search one ply deeper to diversify the trees.

## Persistent thread pool (`src/engine/thread_pool.zig`)

Helpers are created once, when `Threads` is set (or lazily before the first
search), and then park on a condition variable. Each aspiration re-search
posts a `search` job to every helper and `stop_helpers` waits for them to go
idle again, instead of spawning and joining one OS thread (with a 64 MiB
stack) per helper per re-search, which happened dozens of times per move and
became the dominant cost at high thread counts.

A worker owns its `Searcher`: the worker thread allocates and initialises it
after NUMA placement, so its 7.6 MiB of tables are first touched, and
therefore physically allocated, on the node the thread runs on. The largest
of them, the 6 MiB continuation history, is on huge pages where the OS has
them; docs/MEMORY.md lists what lives where. The main thread's `Searcher` is
created by the UCI thread, which is not bound, so its tables are not placed.
`ucinewgame` resets all helpers' heuristics in parallel on their own threads.
Lowering `Threads` shuts down surplus workers and frees their tables.

A helper takes over the root once per search, not per job: the main thread
copies only the game state (`Position.copy_game_state`, about 400 bytes) and
the game's hash history, and the helper rebuilds its accumulator on its own
thread from its own Finny table before its first job. Every job unwinds back
to the root, so an aspiration re-search costs each helper a few scalars and
the root move list. Copying the whole `Position` instead cost 157 KB per
helper per re-search (80 MB at 512 threads) and replaced each helper's warm
Finny table with the main thread's. After a network is loaded (`EvalFile`), a
helper drops its Finny table and its evaluation cache when it next rebuilds its
root: both carry the generation of the network they were filled with.

The search contract is unchanged: helpers run a fixed-depth root search per
job, observe the main thread's stop flag and share the node budget for
`go nodes`. On wasm (`platform.has_threads == false`) the pool is never
started and `Threads` is capped at 1.

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
(Stockfish-style). The 25 MB network is shared and read-only, so remote
accesses mostly hit caches, but a replica per node would remove the remaining
cross-node traffic on large machines. The weights are one block of large
memory behind the `weights.MODEL` pointer (docs/MEMORY.md), first touched by
the UCI thread. The transposition table is shared by design: part `i` of a new
table is backed on a thread bound like search thread `i`, with the limits
docs/MEMORY.md lists.
