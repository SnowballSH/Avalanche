export type SearchSignal = "stop" | "ponderhit";

const SLOTS: Readonly<Record<SearchSignal, number>> = { stop: 0, ponderhit: 1 };

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
