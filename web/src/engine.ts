import { type AvalancheExports, type AvalancheImports, assertAvalancheExports } from "./abi.ts";
import { LineDecoder } from "./line-decoder.ts";

export type WasmSource =
  | Response
  | PromiseLike<Response>
  | ArrayBuffer
  | Uint8Array<ArrayBuffer>
  | WebAssembly.Module;

export interface EngineOptions {
  readonly onLine?: (line: string) => void;
  readonly stopRequested?: () => boolean;
}

/** Synchronous UCI engine: send() blocks until the command, including any search, completes. */
export class Engine {
  readonly #exports: AvalancheExports;
  readonly #encoder = new TextEncoder();
  readonly #inputPtr: number;
  readonly #inputCap: number;

  private constructor(exports: AvalancheExports) {
    this.#exports = exports;
    this.#inputPtr = exports.avalanche_input_ptr();
    this.#inputCap = exports.avalanche_input_cap();
  }

  static async create(source: WasmSource, options: EngineOptions = {}): Promise<Engine> {
    const { onLine = () => undefined, stopRequested = () => false } = options;
    const decoder = new LineDecoder(onLine);
    const output: { memory?: WebAssembly.Memory } = {};

    const imports: AvalancheImports = {
      env: {
        avalanche_now_ms: () => performance.now(),
        avalanche_stop_requested: stopRequested,
        avalanche_write: (ptr, len) => {
          if (output.memory) decoder.push(new Uint8Array(output.memory.buffer, ptr, len));
        },
      },
    };

    const exports = (await instantiate(source, imports)).exports;
    assertAvalancheExports(exports);
    output.memory = exports.memory;
    exports.avalanche_init();
    return new Engine(exports);
  }

  /** Returns false once the engine has received "quit". */
  send(command: string): boolean {
    const input = new Uint8Array(this.#exports.memory.buffer, this.#inputPtr, this.#inputCap);
    const line = `${command}\n`;
    const { read, written } = this.#encoder.encodeInto(line, input);
    if (read < line.length) throw new RangeError(`UCI command exceeds ${String(this.#inputCap)} bytes`);
    return this.#exports.avalanche_command(written) !== 0;
  }

  bench(): void {
    this.#exports.avalanche_bench();
  }

  get memoryBytes(): number {
    return this.#exports.memory.buffer.byteLength;
  }
}

async function instantiate(source: WasmSource, imports: AvalancheImports): Promise<WebAssembly.Instance> {
  if (source instanceof WebAssembly.Module) return WebAssembly.instantiate(source, imports);
  if (source instanceof ArrayBuffer || source instanceof Uint8Array) {
    return (await WebAssembly.instantiate(source, imports)).instance;
  }
  const response = await source;
  if (!response.ok) throw new Error(`Failed to load wasm: HTTP ${String(response.status)}`);
  return (await WebAssembly.instantiateStreaming(response, imports)).instance;
}
