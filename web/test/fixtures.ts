import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { Engine } from "../src/engine.ts";

export const wasmUrl = new URL("../../zig-out/web/avalanche.wasm", import.meta.url);
const nativeBinary = fileURLToPath(new URL("../../zig-out/bin/Avalanche", import.meta.url));

let compiled: Promise<WebAssembly.Module> | undefined;

export function compileEngineModule(): Promise<WebAssembly.Module> {
  compiled ??= readFile(wasmUrl).then((bytes) => WebAssembly.compile(bytes));
  return compiled;
}

export interface CapturingEngine {
  readonly engine: Engine;
  readonly lines: string[];
  readonly run: (command: string) => string[];
}

export async function createCapturingEngine(): Promise<CapturingEngine> {
  const lines: string[] = [];
  const engine = await Engine.create(await compileEngineModule(), { onLine: (line) => lines.push(line) });
  return {
    engine,
    lines,
    run: (command) => {
      const start = lines.length;
      engine.send(command);
      return lines.slice(start);
    },
  };
}

let nativeSignature: string | null | undefined;

export function nativeBenchSignature(): string | null {
  if (nativeSignature === undefined) {
    nativeSignature = existsSync(nativeBinary)
      ? parseBenchNodes(execFileSync(nativeBinary, ["bench"], { encoding: "utf8" }))
      : null;
  }
  return nativeSignature;
}

export function parseBenchNodes(output: string): string | null {
  return /^(\d+) nodes \d+ nps$/m.exec(output)?.[1] ?? null;
}
