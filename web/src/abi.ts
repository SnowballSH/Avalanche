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

type FunctionExportName = {
  [Name in keyof AvalancheExports]: AvalancheExports[Name] extends (...args: never[]) => unknown
    ? Name
    : never;
}[keyof AvalancheExports];

const FUNCTION_EXPORTS = {
  avalanche_init: true,
  avalanche_input_ptr: true,
  avalanche_input_cap: true,
  avalanche_command: true,
  avalanche_bench: true,
} as const satisfies Record<FunctionExportName, true>;

export function assertAvalancheExports(
  exports: WebAssembly.Exports,
): asserts exports is WebAssembly.Exports & AvalancheExports {
  const missing = Object.keys(FUNCTION_EXPORTS).filter((name) => typeof exports[name] !== "function");
  if (!(exports["memory"] instanceof WebAssembly.Memory)) missing.push("memory");
  if (missing.length > 0) {
    throw new TypeError(`Not an Avalanche wasm module; missing exports: ${missing.join(", ")}`);
  }
}
