import { Engine, type WasmSource } from "./engine.ts";
import type { ClientMessage, WorkerPort } from "./protocol.ts";
import { SearchSignals } from "./search-signals.ts";

export type WasmLoader = (url: string) => WasmSource | Promise<WasmSource>;

/** Runs the engine inside a worker, executing client messages strictly in order. */
export function serveEngine(port: WorkerPort, load: WasmLoader): void {
  let engine: Engine | undefined;
  let signals: SearchSignals | null = null;
  let currentSeq = 0;
  let quit = false;
  let queue = Promise.resolve();

  const handle = async (message: ClientMessage): Promise<void> => {
    switch (message.type) {
      case "init":
        signals = message.signalBuffer ? new SearchSignals(message.signalBuffer) : null;
        engine = await Engine.create(await load(message.wasmUrl), {
          onLine: (line) => {
            port.postMessage({ type: "line", line });
          },
          stopRequested: () => signals?.isRequestedDuring("stop", currentSeq) ?? false,
          ponderhitRequested: () => signals?.isRequestedDuring("ponderhit", currentSeq) ?? false,
        });
        port.postMessage({ type: "ready" });
        return;
      case "command":
        if (!engine) throw new Error("Command received before init");
        if (quit) return;
        currentSeq = message.seq;
        if (!engine.send(message.command)) {
          quit = true;
          port.postMessage({ type: "quit" });
        }
        return;
    }
  };

  port.onMessage((message) => {
    queue = queue
      .then(() => handle(message))
      .catch((error: unknown) => {
        port.postMessage({ type: "error", message: error instanceof Error ? error.message : String(error) });
      });
  });
}
