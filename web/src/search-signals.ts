/** Signals a synchronous wasm search polls while it runs. */
export type SearchSignal = "stop" | "ponderhit";

const SLOTS: Readonly<Record<SearchSignal, number>> = { stop: 0, ponderhit: 1 };

/**
 * Cross-thread signal channel. Commands are numbered in send order; a signal
 * sent as command N affects whichever command below N is currently executing,
 * so a "stop" can never cancel a "go" that was sent after it, and a
 * "ponderhit" only releases the ponder search it followed.
 */
export class SearchSignals {
  readonly buffer: SharedArrayBuffer;
  readonly #latest: Int32Array;

  constructor(
    buffer: SharedArrayBuffer = new SharedArrayBuffer(
      Object.keys(SLOTS).length * Int32Array.BYTES_PER_ELEMENT,
    ),
  ) {
    this.buffer = buffer;
    this.#latest = new Int32Array(buffer);
  }

  /** Null when SharedArrayBuffer is unavailable, e.g. a page without cross-origin isolation. */
  static tryCreate(): SearchSignals | null {
    return typeof SharedArrayBuffer === "function" ? new SearchSignals() : null;
  }

  request(signal: SearchSignal, commandSeq: number): void {
    Atomics.store(this.#latest, SLOTS[signal], commandSeq);
  }

  isRequestedDuring(signal: SearchSignal, commandSeq: number): boolean {
    return Atomics.load(this.#latest, SLOTS[signal]) > commandSeq;
  }
}
