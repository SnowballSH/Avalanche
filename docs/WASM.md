# WebAssembly build

Avalanche compiles to a single self-contained `avalanche.wasm` that runs in browsers, Node and Bun.
It searches exactly the same tree as the native engine: `bench` reports the same node count on both.

```sh
zig build wasm --release=fast   # -> zig-out/web/avalanche.wasm
cd web && npm ci && npm run check && npm run lint && npm test   # test builds wasm + native release first
```

The `web/` package needs Node 26 or later.

## Target choice

Zig offers three WebAssembly routes:

| Target                | Runtime needs                        | Verdict                                                                                                            |
| --------------------- | ------------------------------------ | ------------------------------------------------------------------------------------------------------------------ |
| `wasm32-emscripten`   | Emscripten JS runtime                | Broken when the port was written, on Zig 0.16.0 ([`std.os.emscripten` fails to compile](https://github.com/gdzig/gdzig/pull/244)); heavy runtime. |
| `wasm32-wasi`         | WASI preview 1 shim in the browser   | Tier 2 with full `std`, but browsers need a polyfill, and stdin-driven UCI blocks the loop.                        |
| `wasm32-freestanding` | Nothing: the module declares its ABI | **Chosen.** Smallest glue, no shim, every host call is one we designed.                                            |

The build follows the Zig language reference's recipe for freestanding modules: an executable with
`entry = .disabled` and `rdynamic = true`, so the functions marked `export` form the module interface.
It targets the `generic` CPU (bulk memory, sign-ext, non-trapping float conversions, multivalue,
reference types) plus `simd128`. Every evergreen browser supports this set (Safari since 16.4, March 2023).

## Host ABI

`src/wasm.zig` is the wasm root module and `web/src/abi.ts` is its typed mirror. The two must change together.
`assertAvalancheExports` checks at load time that the module exports `memory` and every function the mirror
names; its list of names cannot fall behind the interface, because a missing or unknown name does not compile.

Imports (`env`):

| Name                              | Signature          | Contract                                                                                      |
| --------------------------------- | ------------------ | --------------------------------------------------------------------------------------------- |
| `avalanche_write(ptr, len)`       | `(i32, i32) -> ()` | The next `len` bytes of engine output at `memory[ptr..+len]`, readable only during the call.  |
| `avalanche_now_ms()`              | `() -> f64`        | Monotonic milliseconds, e.g. `performance.now()`.                                             |
| `avalanche_stop_requested()`      | `() -> i32`        | 1 to interrupt the running search, 0 otherwise. Polled every 1024 nodes.                      |
| `avalanche_ponderhit_requested()` | `() -> i32`        | 1 once `ponderhit` arrived for the running `go ponder` search, 0 otherwise.                   |

The output is one UTF-8 stream of `\n`-terminated UCI lines, and `avalanche_write` hands it over in
arbitrary chunks: a call can carry several lines or stop in the middle of one, so the host has to
buffer up to the next newline (`LineDecoder` in the TypeScript host). The module declares the two
request imports as returning `bool` and reads nothing but 0 and 1 from them; any other value may be
taken for either.

Exports:

| Name                        | Contract                                                                                                              |
| --------------------------- | --------------------------------------------------------------------------------------------------------------------- |
| `memory`                    | The module's own linear memory. It grows, so re-derive views after calls.                                             |
| `avalanche_init()`          | Call once before anything else.                                                                                       |
| `avalanche_input_ptr/cap()` | Buffer the host writes one UCI command into.                                                                          |
| `avalanche_command(len)`    | Executes the command synchronously. Returns 0 once `quit` was received. Internal errors print `info string error: …`. |
| `avalanche_bench()`         | Runs the fixed bench and prints `<nodes> nodes <nps> nps`.                                                            |

`avalanche_bench` searches with the instance's transposition table and options as it finds them, so its
node count equals the native `bench` only on a fresh instance.

## Host bindings (`web/`)

- `Engine`: instantiates the module and exposes a blocking `send(command)`, which returns `"quit"` once the engine
  has received `quit` and `"running"` until then. Use it directly for scripts and tests.
- `serveEngine` + `worker.ts`: runs an `Engine` inside a dedicated Web Worker (or a Node worker thread) and executes
  the client's messages strictly in order.
- `AvalancheClient`: the non-blocking main-thread handle. Output arrives through `onLine`. After the engine processes
  `quit` the client closes itself; `whenClosed` resolves once it is closed, whether by `quit`, by `terminate()` or by
  a fatal failure (see "Failures").
- `src/node/cli.ts`: stdio UCI adapter (`avalanche-wasm path/to/avalanche.wasm`), so the wasm build can be driven by
  any UCI GUI or match runner. It does not interpret the commands it forwards. When the client closes it closes
  its line reader, which is what lets the process exit while a GUI keeps the pipe open after `quit`; when stdin
  ends first it sends `quit` itself.
- `demo/`: a minimal browser page and a static server that sends the cross-origin isolation headers (`npm run demo`).
  The server listens on `localhost` only.

### Stopping a search and `ponderhit`

`go` runs synchronously inside the worker, so the worker cannot receive a `stop` or `ponderhit` message until
the search ends. Instead, the client and the worker share an 8-byte `SharedArrayBuffer`, the `SearchSignals`,
with one slot per signal:

1. The client numbers each command it posts (`seq`).
2. For `stop` and `quit` it stores that command's `seq` in the stop slot; for `ponderhit`, in the ponderhit slot.
3. The worker answers `avalanche_stop_requested()` / `avalanche_ponderhit_requested()` with
   `latest seq in that slot > seq of the command being executed`.

A signal therefore affects only a search that was requested before it. A stale stop cannot cancel a later
`go`, which a plain boolean flag would do. The engine latches each request into its own state (the stop flag,
or leaving ponder mode), so all later checks in that search agree. While a `go ponder` or `go infinite`
search holds back its `bestmove`, the engine busy-polls these imports, since wasm has no sleep.

### `isready` during a search

For the same reason the worker cannot answer `isready` while `go` runs, yet UCI requires an immediate `readyok`
while the engine is thinking. `AvalancheClient` therefore answers it itself while a search is outstanding: it counts
`go` commands sent and `bestmove` lines received, and while more have been sent than answered it emits `readyok`
without forwarding the command. This relies on every `go` the worker executes producing exactly one `bestmove`,
which holds because the worker runs commands strictly in order, so a `go` can never arrive while another search is
running (the engine's "ignored while searching" path is unreachable on wasm). The client finds the command word the
way the engine does, as the first space-separated token of the line, so the two cannot disagree on which lines are
a `go`. A consequence GUIs may notice: after `stop`, the `readyok` for an `isready` sent before the `bestmove`
arrived can precede that `bestmove`.

`SharedArrayBuffer` requires a
[cross-origin isolated](https://developer.mozilla.org/docs/Web/API/Window/crossOriginIsolated) page
(`Cross-Origin-Opener-Policy: same-origin`, `Cross-Origin-Embedder-Policy: require-corp`). Without it,
`AvalancheClient.canInterrupt` is `false`, and searches end only at their limits (`depth`, `nodes`,
`movetime`, clock). `go infinite` and `go ponder` then never return, so avoid them in that mode.

Serve `avalanche.wasm` as `application/wasm` so `WebAssembly.instantiateStreaming` can compile it while it downloads.

### Failures

Three kinds of failure reach the client, and only the first leaves the engine usable:

- **A command the host refuses.** `Engine.send` throws a `RangeError` for a command that does not fit the input
  buffer, before the module is entered. The worker posts it as an `error` message, the client hands it to
  `onError`, and the engine keeps running.
- **A crash.** Anything thrown out of a call into the module, whether a trap (a Zig panic prints
  `info string panic: …` and then traps) or an exception from a host import, abandons the module's stack in
  the middle of the call, and the instance must not be entered again. `Engine` wraps the cause in an
  `EngineCrashError` and throws it again for every later call. The worker posts a `crash` message and stops
  serving.
- **A failure outside the message protocol.** `ClientPort.onFailure` reports what never arrives as a message:
  a worker script that fails to load, an uncaught exception in the worker, an undecodable message, an
  unexpected exit.

The last two are fatal: the client terminates the worker, resolves `whenClosed` and reports the error once.
Until the worker has answered `ready`, every failure is fatal and rejects `start()` instead, including a module
that cannot be loaded. `onError` defaults to rethrowing, so under the stdio adapter, which sets no handler, an
error ends the process rather than leaving a dead engine behind a GUI.

## Platform layer

`src/platform.zig` is the only place that knows which target it is running on:

- `allocator`: libc `malloc` natively, `std.heap.wasm_allocator` (a `memory.grow` bump/size-class allocator) on wasm.
- `now_ns`, `Stdout`, `print`: `std.Io` natively, host imports on wasm. `print` backs the debug commands (`d`, `perft`,
  `perftdiv`): natively it writes to stderr, on wasm it shares the single UCI output channel.
- `atomic_load`/`atomic_store`/`atomic_rmw`: real atomics natively. On wasm they are plain memory
  operations, because the build is single-threaded and Zig caps wasm32 atomic operands at 32 bits, which
  would reject the transposition table's 64-bit lock words.
- `has_threads`: comptime-false on wasm. Thread spawns (search helpers, TT clearing, bench) run inline instead, and
  the `Threads` option is advertised with `max 1`.

All of these are comptime-resolved, so a native build contains none of the wasm paths.

`std.heap.wasm_allocator` never returns memory to the host. It takes a large allocation from a slot of a
power-of-two number of 64 KiB pages and reserves one word of its own in every slot, so a table of exactly 2^k
bytes lands in the next slot size: the default `Hash 16` reserves 32 MiB and `Hash 64` reserves 128 MiB, while
`Hash 15` and `Hash 63` fit 16 MiB and 64 MiB slots. The engine writes only the table itself, so the rest of the
slot is grown but left untouched while the table is in use. A table of 2 GiB or more would need a 4 GiB slot,
which a wasm32 module cannot address, so no `Hash` above 2047 can be allocated.

A resize allocates the new table before freeing the old one, and a freed slot serves only a later allocation of
the same slot size. A `Hash` change therefore grows linear memory for good unless a slot of that size was freed
earlier; even setting the current size again grows it once. Set `Hash` once.

## Wasm-specific performance work

- The single-layer head's `madd_i16` lowers to `i32x4.dot_i16x8_s` via the `llvm.wasm.dot` intrinsic (+36% nps).
- The multi-layer head, which the default net uses, has its own wasm paths for every stage (pairwise
  `q15mulr_sat_s`, L1 `extadd_pairwise`, L2 `dot_i16x8_s`); see
  "Inference paths" in [NNUE.md](NNUE.md). `bench` under Node 26 on an Apple M4: 1.00M to 1.50M nps
  (+50%) against the portable paths, same node count.
- Timing a stage in isolation under V8 needs `node --no-liftoff`: wasm functions are not replaced on
  the stack, so a loop inside one long-running call stays in the baseline compiler's code. `bench`
  is not affected, the search calls its functions many times.
- Release builds are stripped: ~300 KB of code next to the 25 MB network. The network is in the module
  once and in linear memory once. The engine reads it in place from the data segment through
  `embedded_model` rather than copying it into a second 25 MB buffer, and touches the `@embedFile`
  bytes at runtime in no other way, which would emit a second copy into the module (a web test asserts
  the module stays under 1.1x the network size). Linear memory is about 88 MiB in total at the default
  `Hash`.
- `build_all_v3.sh` (and the tagged-release CI job) ships the module as `Avalanche-<version>-wasm.wasm`. It needs a
  host: build the `web/` package (`npm run build`) or implement the small ABI above.
- `TranspositionTable.index` uses two 64-bit multiplies on 32-bit targets. The `u128` product would lower
  to a `__multi3` libcall; the replacement returns the identical index.

## Not supported on wasm

- **Syzygy tablebases.** Pyrrhic needs libc file I/O, so `syzygy.supported` is false, all probe paths are compiled
  out, and the Syzygy options are not advertised.
- **Threads > 1.** Lazy SMP would need shared memory, a `wasi-threads`-style spawn import backed by Web
  Workers, and 64-bit atomics for the TT. Zig rejects 64-bit atomics on wasm32, so the TT lock words
  would first have to be split into 32-bit halves.
- `datagen`, `genfens`, `tbfilter`: offline tooling with filesystem needs; not referenced by the wasm root.
