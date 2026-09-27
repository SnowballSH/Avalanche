export interface AvalancheImports extends WebAssembly.Imports {
  readonly env: {
    readonly avalanche_write: (ptr: number, len: number) => void;
    readonly avalanche_now_ms: () => number;
    readonly avalanche_stop_requested: () => boolean;
    readonly avalanche_ponderhit_requested: () => boolean;
  };
}

export interface AvalancheExports {
  readonly memory: WebAssembly.Memory;
  readonly avalanche_init: () => void;
  readonly avalanche_input_ptr: () => number;
  readonly avalanche_input_cap: () => number;
  readonly avalanche_command: (len: number) => number;
  readonly avalanche_bench: () => void;
}

const REQUIRED_FUNCTIONS = [
  "avalanche_init",
  "avalanche_input_ptr",
  "avalanche_input_cap",
  "avalanche_command",
  "avalanche_bench",
] as const satisfies readonly (keyof AvalancheExports)[];

export function assertAvalancheExports(
  exports: WebAssembly.Exports,
): asserts exports is WebAssembly.Exports & AvalancheExports {
  const missing: string[] = REQUIRED_FUNCTIONS.filter((name) => typeof exports[name] !== "function");
  if (!(exports["memory"] instanceof WebAssembly.Memory)) missing.push("memory");
  if (missing.length > 0) {
    throw new TypeError(`Not an Avalanche wasm module; missing exports: ${missing.join(", ")}`);
  }
}
