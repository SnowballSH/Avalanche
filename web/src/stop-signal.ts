/**
 * Cross-thread stop channel. Commands are numbered in send order; a stop sent
 * as command N interrupts whichever command below N is currently executing, so
 * a stop can never cancel a "go" that was sent after it.
 */
export class StopSignal {
  readonly buffer: SharedArrayBuffer;
  readonly #latestStop: Int32Array;

  constructor(buffer: SharedArrayBuffer = new SharedArrayBuffer(Int32Array.BYTES_PER_ELEMENT)) {
    this.buffer = buffer;
    this.#latestStop = new Int32Array(buffer);
  }

  /** Null when SharedArrayBuffer is unavailable, e.g. a page without cross-origin isolation. */
  static tryCreate(): StopSignal | null {
    return typeof SharedArrayBuffer === "function" ? new StopSignal() : null;
  }

  request(commandSeq: number): void {
    Atomics.store(this.#latestStop, 0, commandSeq);
  }

  isRequestedDuring(commandSeq: number): boolean {
    return Atomics.load(this.#latestStop, 0) > commandSeq;
  }
}
