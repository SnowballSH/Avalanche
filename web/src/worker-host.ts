import { Engine, EngineCrashError, type WasmSource } from "./engine.ts";
import type { ClientMessage, WorkerPort } from "./protocol.ts";
import { SearchSignals } from "./search-signals.ts";

export type WasmLoader = (url: string) => WasmSource | Promise<WasmSource>;

export function serveEngine(port: WorkerPort, load: WasmLoader): void {
  let engine: Engine | undefined;
  let signals: SearchSignals | null = null;
  let currentSeq = 0;
  let serving = true;
  let queue = Promise.resolve();

  const handle = async (message: ClientMessage): Promise<void> => {
    if (!serving) return;
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
        currentSeq = message.seq;
        if (engine.send(message.command) === "quit") {
          serving = false;
          port.postMessage({ type: "quit" });
        }
        return;
    }
  };

  const report = (error: unknown): void => {
    const message = error instanceof Error ? error.message : String(error);
    if (error instanceof EngineCrashError) {
      serving = false;
      port.postMessage({ type: "crash", message });
    } else {
      port.postMessage({ type: "error", message });
    }
  };

  port.onMessage((message) => {
    queue = queue.then(() => handle(message)).catch(report);
  });
}
