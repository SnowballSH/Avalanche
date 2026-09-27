export class LineDecoder {
  readonly #decoder = new TextDecoder();
  readonly #onLine: (line: string) => void;
  #pending = "";

  constructor(onLine: (line: string) => void) {
    this.#onLine = onLine;
  }

  push(bytes: Uint8Array): void {
    const lines = (this.#pending + this.#decoder.decode(bytes, { stream: true })).split("\n");
    this.#pending = lines.pop() ?? "";
    for (const line of lines) this.#onLine(line.replace(/\r$/, ""));
  }
}
