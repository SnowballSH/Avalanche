# Memory

Where the engine's large data lives, which of it is on huge pages, and why.

## What is large

| Data                         | Size                 | Owner                         | Access pattern                                            |
| ---------------------------- | -------------------- | ----------------------------- | --------------------------------------------------------- |
| Transposition table          | `Hash` (16 MiB default) | process                    | one random 16-byte entry per node, every thread           |
| Network weights              | 24.2 MiB             | process, read-only            | two or three random 2 KiB rows per perspective per node   |
| Continuation history         | 6.0 MiB              | each search thread            | a few 8 KiB sub-tables per node, chosen by the last moves |
| `Searcher` (other histories) | 473 KiB              | each search thread            | random: corrections 192 KiB, butterfly 32 KiB, PV 79 KiB  |
| Accumulator stack            | 1.0 MiB              | each `Position`               | two adjacent 4 KiB frames per node, by ply                |
| `Position` with Finny table  | 154 KiB              | each `Position`               | board state every node, one 2 KiB Finny entry per refresh |

A search thread therefore owns 7.6 MiB, not counting its 64 MiB of mostly untouched stack.

With 4 KiB pages the first three rows alone are thousands of pages, far beyond the 64 to 96
entries of a first-level data TLB and, with the hash table, beyond the second level as well. On
2 MiB pages the network is 13 entries and a thread's continuation history is 3.

## `large_memory` (`src/platform/large_memory.zig`)

One interface for memory that is large, long-lived and worth its own pages:

```zig
pub const ALIGNMENT: usize; // 2 MiB on Linux, the page size on macOS and Windows, a cache line on wasm
pub const Placement = *const fn (index: usize) void;
pub fn empty(comptime T: type) []align(ALIGNMENT) T;
pub fn alloc(comptime T: type, n: usize, comptime label: [:0]const u8) Error![]align(ALIGNMENT) T;
pub fn alloc_populated(comptime T: type, n: usize, comptime label: [:0]const u8, threads: usize, placement: ?Placement) Error![]align(ALIGNMENT) T;
pub fn free(comptime T: type, memory: []align(ALIGNMENT) T) void;
pub fn create(comptime T: type, comptime label: [:0]const u8) Error!*align(ALIGNMENT) T;
pub fn destroy(comptime T: type, item: *align(ALIGNMENT) T) void;
pub fn zero(bytes: []u8, threads: usize) void;
pub fn huge_page_bytes(bytes: []const u8) u64;
pub fn live_bytes() usize;
```

Blocks come straight from the OS (`mmap`, `NtAllocateVirtualMemory`), not from the C allocator, so
they are zeroed, page-aligned and returned to the OS when freed, whatever libc the build links.
The alignment is part of the pointer types, so handing `free` or `destroy` memory from another
allocator does not compile without a cast. `live_bytes` counts what is mapped, in Debug builds and
in tests, which is how the tests check that nothing is leaked.

| Target  | Backing                                                                                                   |
| ------- | --------------------------------------------------------------------------------------------------------- |
| Linux   | 2 MiB-aligned, a whole number of 2 MiB, `madvise(MADV_HUGEPAGE)`: transparent huge pages when the system allows them (`enabled` = `madvise` or `always`) |
| macOS   | ordinary pages (16 KiB on Apple Silicon); the OS offers no huge pages to ask for                          |
| Windows | ordinary 4 KiB pages; see "Not done"                                                                      |
| wasm    | the wasm allocator, zeroed by hand                                                                        |

2 MiB is the huge page of x86-64 and of arm64 with 4 KiB pages. An arm64 kernel built for 16 KiB
or 64 KiB pages has huge pages of 32 MiB or 512 MiB: blocks there stay on ordinary pages, and
nothing else changes.

Rounding a block up to whole huge pages matters: Linux only installs a huge page where the whole
2 MiB range belongs to the mapping, so an unrounded tail stays on 4 KiB pages. The price is up to
2 MiB of slack per block, which is why only data that fills its block well is given one.

### Who backs a block, and on which NUMA node

`alloc` backs nothing until a page is written, and Linux then puts the page on the node of the
thread that wrote it. That places the per-thread tables of a helper: the helper thread is bound to
its node first and then allocates and clears its own `Searcher` and continuation history
(docs/THREADS.md). The main searcher is the exception. The UCI thread creates it, and that thread
is not bound, so the main thread's tables are on whatever node the UCI thread ran on.

`alloc_populated` is for the table the search threads share. It splits the block into up to
`threads` parts of at least 32 MiB and backs each part by storing one byte to every page: the OS
hands out zeroed pages, so nothing has to be cleared a second time, but it has to be a store,
because reading a fresh page only maps the kernel's shared zero page. Given a `placement`, every
part gets a thread of its own, which calls `placement(index)` before it touches anything; the
calling thread only waits, since it must not be moved. The transposition table passes
`numa.place_current_thread`, so part `i` of a new table is backed on a thread bound like search
thread `i`. Threads fill the nodes in order (docs/THREADS.md), so a table for a few threads is on
the first node with them, and a table for many is spread over the nodes in proportion to the
threads on each.

Limits of that, as the code stands:

- The table asks for one part per search thread once `Threads` has been set. Before that it asks
  for one per CPU: how many threads will search is not known yet, and a large table is backed
  faster by many.
- A table is not moved afterwards. One created before `Threads` or `NumaPolicy` changed stays
  where it is until `Hash` is set again.
- Without a placement (a single node, `NumaPolicy none`, other operating systems) no thread is
  bound: the calling thread backs the last part itself, and a table under 64 MiB starts no thread
  at all, because engines under test are started thousands of times on busy machines. The 32 MiB
  per part is a judgement, not a measurement.
- A private table (`tt.Sharing.private`: datagen gives every game thread its own two) is backed
  and cleared by the thread that owns it.
- This placement has only run on single-node machines. The binding is covered by the tests of
  `numa.zig` and the mapping of parts to threads by tests with a recording placement, but no
  per-node page counts (`numa_maps`) have been looked at.

`zero` is the parallel `memset` for a table already in use; it moves no pages and binds no thread.

The threads that back or clear a part get a 2 MiB stack although they hardly use any. glibc takes
a thread's static thread-local block out of its stack, that block is about 256 KiB in this
executable, and `pthread_create` refuses a stack that cannot hold it, which `std.Thread.spawn`
treats as unreachable.

### What uses it

- **Transposition table** (`tt.zig`): `alloc_populated` on `Hash`, `zero` on `ucinewgame` and
  `Clear Hash`. Label `hash`.
- **Network weights** (`weights.zig`): `weights.MODEL` points at the embedded network, aligned in
  the executable, until `do_nnue` has copied it into one block; `EvalFile` overwrites that block
  in place. Label `network`. Wasm keeps running on the embedded image. Before, the weights were a
  2 MiB-aligned global with its own `madvise`, which left the last 168 KiB (the whole head) on
  4 KiB pages.
- **Continuation history** (`search.zig`): exactly 6 MiB, three huge pages with no slack. Label
  `search`.

### Checking it

`setoption name Hash` answers with what the kernel really granted:

```
info string Hash: 64 MB, 64 MB on huge pages
```

The number is read from `/proc/self/smaps` when it is asked for, no longer on every resize, so
start-up does not pay for it. For everything else, look at the process:

```sh
grep -A 22 'anon:avalanche' /proc/$(pidof Avalanche)/smaps | grep -E 'avalanche|AnonHugePages'
grep thp_fault /proc/vmstat        # thp_fault_alloc vs thp_fault_fallback
cat /sys/kernel/mm/transparent_hugepage/enabled
```

Blocks carry the names `[anon:avalanche-hash]`, `[anon:avalanche-network]` and
`[anon:avalanche-search]` on kernels built with `CONFIG_ANON_VMA_NAME` (5.17 and later; many
distributions enable it). Elsewhere they are anonymous `rw-p` mappings whose size is a multiple of
2048 kB and whose `VmFlags` include `hg`. Without names Linux merges neighbouring blocks into one
mapping; `huge_page_bytes` then counts the whole mapping and is capped at the block's own size,
so it is an upper bound there.

## Measurements

Linux with 4 KiB pages and transparent huge pages in `madvise` mode (an arm64 virtual machine on
an Apple M4, kernel 7.1), `bench` with the default 16 MiB hash and one thread. From
`/proc/<pid>/smaps` during the run:

| Data                 | Before                                           | After                    |
| -------------------- | ------------------------------------------------ | ------------------------ |
| Network weights      | 24,744 kB global, 24,576 kB of it huge           | 26,624 kB block, all huge |
| Transposition table  | 16,384 kB, all huge                              | 16,384 kB, all huge      |
| Continuation history | inside a 9,008 kB C-allocator mapping, none huge | 6,144 kB block, all huge |
| `AnonHugePages`      | 40,960 kB                                        | 49,152 kB                |
| Resident (`VmRSS`)   | 77,628 kB                                        | 79,336 kB                |
| Page tables (`VmPTE`) | 216 kB                                          | 204 kB                   |

The 1.6 MiB of extra resident memory is the rounding of the network to 13 whole huge pages.

Page faults and CPU time from `perf stat` (the fault counts are exact; the machine was heavily
loaded, so the CPU times are inflated for both and only their ratio means something; start-up
figures are the mean of 20 runs):

| Workload                                   | Before               | After                |
| ------------------------------------------ | -------------------- | -------------------- |
| `bench`                                    | 7,611 faults         | 5,904 faults         |
| `uci`, `isready`, `quit`                   | 3,064 faults, 31.5 ms | 1,345 faults, 29.0 ms |
| the same with `setoption name Hash value 256` | 3,196 faults, 63.3 ms | 1,548 faults, 38.5 ms |
| the same with `setoption name Threads value 4` | 8,254 faults, 43.4 ms | 1,940 faults, 33.6 ms |

Start-up got cheaper for three reasons: a new hash table is touched instead of cleared a second
time, the default 16 MiB table no longer starts a thread per CPU to do it, and `smaps` is no
longer parsed on every resize.

The speed of the search itself could not be told apart there: the virtual machine exposes no
performance counters, so there are no TLB-miss counts, and alternating `bench` runs used 27.9,
29.1, 33.9 and 32.0 s of CPU before against 29.5, 29.4, 29.3 and 33.4 s after. What the continuation
history on huge pages is worth has to be read from `perf stat -e dTLB-load-misses` on real
hardware.

macOS on the same Apple M4 (16 KiB pages, no huge pages to ask for) is unchanged, as it should be:
`bench` retired 113.47, 113.62 and 113.02 billion instructions before and 113.26, 113.05 and
112.80 billion after, in alternating runs, and the three start-up sessions above took the same
time within noise (medians of 15 runs: 20.9 against 21.2 ms, 43.6 against 42.9 ms, 26.8 against
26.1 ms).

## The per-thread data, reviewed for cache and TLB behaviour

`Searcher` is about 473 KiB. Zig orders the fields of a struct by alignment, not by use, so the
scalars the search touches at every node (`nodes`, `ply`, `seldepth`, `stop`, the `ttable` and
`continuation` pointers) end up on several different 4 KiB pages, with cold arrays between them:
108 KiB of MultiPV `lines` and the root-only `node_spent_table` of 32 KiB. That costs TLB entries,
not cache: each scalar's line stays in L1.

The tables a thread reads at random, besides the continuation history, are the correction
histories (`pawn_correction` 64 KiB, `nonpawn_correction` 128 KiB, six lookups per evaluation),
the butterfly history (32 KiB of `i32`; every other history is `i16`), counter moves (16 KiB),
capture history (9 KiB) and the rows of `pv` in use (400 bytes per ply). Together about 250 KiB:
more than L1, well inside L2, and about 65 pages of 4 KiB.

The accumulator stack is touched two frames at a time, and a frame is exactly 4 KiB, so on small
pages it needs two to four TLB entries that change slowly. The Finny table is touched one 2 KiB
entry per king-bucket refresh.

One thing for whoever owns thread scaling: with a node limit (`go nodes`, soft nodes) every helper
adds to the main searcher's `shared_nodes` on every node, and that counter shares a cache line with
the main thread's `timer`, `ttable` and limits.

## Not done

- **One block per search thread.** `Searcher` (473 KiB), a `Position` (154 KiB) and its
  accumulator stack (1,032 KiB) together are 1.6 MiB and would fit one huge page next to the
  continuation history: 8 MiB per thread, all of it huge. Today they come from the C allocator on
  4 KiB pages. Giving each its own block would cost 2 MiB apiece, 12 MiB per thread instead of
  7.6, and a huge page is resident in full once one byte of it is written. Packing them needs one
  owner for the three, and there is none: a helper searches its `Searcher`'s `root_board`, the main
  thread searches the UCI layer's `Position`, `bench` and datagen bring their own, and a
  `Searcher` is created by value in several places. Worth doing if a measurement on 4 KiB-page
  hardware shows that the `Searcher` tables or the stack matter.
- **Windows large pages.** `VirtualAlloc(MEM_LARGE_PAGES)` needs `SeLockMemoryPrivilege`, which an
  administrator must grant to the account and the process must then enable in its token. The
  fallback when it is missing is easy; the path where it is present cannot be exercised by this
  project's CI, so Windows stays on ordinary pages.
- **Explicit huge pages on Linux** (`MAP_HUGETLB`, 1 GiB pages): they need a pool reserved by the
  administrator. Transparent huge pages need nothing.
- **A copy of the network per NUMA node.** `weights.MODEL` is now a pointer to a block, which is
  the shape that needs, but every evaluation would have to take the pointer of its thread's node.
- **Huge pages for the engine's own globals.** About 1.5 MiB of precomputed tables (the attack
  tables among them) are resident in `.bss` on 4 KiB pages. They could be gathered into one
  2 MiB-aligned global with its own `madvise`, as the network was before, or allocated here. Not
  measured.
