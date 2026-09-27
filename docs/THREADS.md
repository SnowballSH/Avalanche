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
after NUMA placement, so its ~12.6 MiB of history tables are first touched,
and therefore physically allocated, on the node the thread runs on.
`ucinewgame` resets all helpers' heuristics in parallel on their own threads.
Lowering `Threads` shuts down surplus workers and frees their tables.

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
cross-node traffic on large machines. The transposition table is shared by
design.
