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
pub const ALIGNMENT: usize;                                 // 2 MiB on Linux, the page size elsewhere
pub fn alloc(comptime T: type, n: usize, comptime label: [:0]const u8) Error![]align(ALIGNMENT) T;
pub fn alloc_populated(comptime T: type, n: usize, comptime label: [:0]const u8, threads: usize) Error![]align(ALIGNMENT) T;
pub fn free(memory: anytype) void;
pub fn create(comptime T: type, comptime label: [:0]const u8) Error!*align(ALIGNMENT) T;
pub fn destroy(ptr: anytype) void;
pub fn zero(bytes: []u8, threads: usize) void;
pub fn huge_page_bytes(bytes: []const u8) u64;
```

Blocks come straight from the OS (`mmap`, `NtAllocateVirtualMemory`), not from the C allocator, so
they are zeroed, page-aligned and returned to the OS when freed, whatever libc the build links.

| Target  | Backing                                                                                                   |
| ------- | --------------------------------------------------------------------------------------------------------- |
| Linux   | 2 MiB-aligned, a whole number of 2 MiB, `madvise(MADV_HUGEPAGE)`: transparent huge pages when the system allows them (`enabled` = `madvise` or `always`) |
| macOS   | ordinary pages (16 KiB on Apple Silicon); the OS offers no huge pages to ask for                          |
| Windows | ordinary 4 KiB pages; see "Not done"                                                                      |
| wasm    | the wasm allocator, zeroed by hand                                                                        |

Rounding a block up to whole huge pages matters: Linux only installs a huge page where the whole
2 MiB range belongs to the mapping, so an unrounded tail stays on 4 KiB pages. The price is up to
2 MiB of slack per block, which is why only data that fills its block well is given one.

`alloc` backs nothing until a page is written, and Linux then places the page on the NUMA node of
the writing thread. A search thread allocates and clears its own tables after it has been bound to
its node (docs/THREADS.md), so they end up there. `alloc_populated` is for memory shared by all
threads: up to `threads` threads write one byte to every page, which backs the block before the
first search and spreads it over the nodes those threads run on. Writing a byte per page is enough
because the OS hands out zeroed pages; the previous code cleared a new hash table a second time
with `memset`. The write has to be a store: reading a fresh page only maps the kernel's shared
zero page. `zero` is the parallel `memset` for clearing a table that is already in use.

### What uses it

- **Transposition table** (`tt.zig`): `alloc_populated` on `Hash`, `zero` on `ucinewgame` and
  `Clear Hash`. Label `hash`.
- **Network weights** (`weights.zig`): `weights.MODEL` points at one block that receives the
  embedded network at start-up and is overwritten in place by `EvalFile`. Label `network`. Wasm
  still reads the embedded bytes in place. Before, the weights were a 2 MiB-aligned global with its
  own `madvise`, which left the last 168 KiB (the whole head) on 4 KiB pages.
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
mapping; `huge_page_bytes` then counts the whole mapping and is capped at the block's own size.

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
| Resident (`VmRSS`)   | 77,636 kB                                        | 79,296 kB                |
| Page tables (`VmPTE`) | 220 kB                                          | 204 kB                   |

The 1.6 MiB of extra resident memory is the rounding of the network to 13 whole huge pages.

Page faults and CPU time from `perf stat` (the fault counts are exact; the machine was heavily
loaded, so the CPU times are inflated for both and only their ratio means something; start-up
figures are the mean of 20 runs):

| Workload                                   | Before               | After                |
| ------------------------------------------ | -------------------- | -------------------- |
| `bench`                                    | 7,607 faults         | 5,894 faults         |
| `uci`, `isready`, `quit`                   | 3,065 faults, 29.6 ms | 1,348 faults, 19.5 ms |
| the same with `setoption name Hash value 256` | 3,195 faults, 131.0 ms | 1,476 faults, 56.4 ms |
| the same with `setoption name Threads value 4` | 8,254 faults, 50.7 ms | 1,942 faults, 33.7 ms |

Start-up got cheaper for three reasons: a new hash table is touched instead of cleared a second
time, the default 16 MiB table no longer starts a thread per CPU to do it (a thread is used per
32 MiB, because starting one costs about as much as the kernel needs to zero a few huge pages, and
engines under test are started thousands of times on busy machines), and `smaps` is no longer
parsed on every resize.

The speed of the search itself could not be told apart there: the virtual machine exposes no
performance counters, so there are no TLB-miss counts, and three alternating `bench` runs used
27.9, 29.1 and 33.9 s of CPU before against 29.5, 29.4 and 29.3 s after. What the continuation
history on huge pages is worth has to be read from `perf stat -e dTLB-load-misses` on real
hardware.

macOS on the same Apple M4 (16 KiB pages, no huge pages to ask for) is unchanged, as it should be:
`bench` retired 113.47, 113.62 and 113.02 billion instructions before and 113.26, 113.05 and
112.80 billion after, in alternating runs, and the three start-up sessions above took the same
time within noise (medians of 15 runs: 20.9 against 21.2 ms, 43.6 against 42.9 ms, 26.8 against
26.1 ms).

## The per-thread data, reviewed for cache and TLB behaviour

`Searcher` is 484,368 bytes. Zig orders its fields by alignment, so the hot scalars are spread over
the struct: `nodes`, `ttable` and the limits in the first two cache lines, `continuation` at
143,200, `ply` at 144,000 (in the first line of the butterfly history), `seldepth` at 178,388 and
`stop` in the last line. That is five 4 KiB pages for a handful of scalars, with the cold
`lines` (108 KiB of MultiPV output) and `node_spent_table` (32 KiB, root only) in between. It costs
TLB entries, not cache: each scalar's line stays in L1.

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
  tables among them) are resident in `.bss` on 4 KiB pages. They would need the linker to align
  the section; nothing in the source can ask for it.
