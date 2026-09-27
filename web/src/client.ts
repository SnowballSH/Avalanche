import type { ClientPort } from "./protocol.ts";
import { type SearchSignal, SearchSignals } from "./search-signals.ts";

export interface ClientOptions {
  readonly onLine?: (line: string) => void;
  readonly onError?: (error: Error) => void;
}

const rethrow = (error: Error): never => {
  throw error;
};

const SIGNALLING_COMMANDS: ReadonlyMap<string, SearchSignal> = new Map([
  ["stop", "stop"],
  ["quit", "stop"],
  ["ponderhit", "ponderhit"],
]);

/** Non-blocking handle to an engine running in a worker. */
export class AvalancheClient {
  readonly #port: ClientPort;
  readonly #signals: SearchSignals | null;
  #seq = 0;
  #closed = false;
  // Searches sent but not yet answered by "bestmove". While one runs the worker
  // is blocked inside wasm, so the client itself answers "isready".
  #pendingSearches = 0;
  #onLine: (line: string) => void = () => undefined;
  readonly #whenClosed: PromiseWithResolvers<void> = Promise.withResolvers();

  private constructor(port: ClientPort, signals: SearchSignals | null) {
    this.#port = port;
    this.#signals = signals;
  }

  static start(
    port: ClientPort,
    wasmUrl: string | URL,
    { onLine, onError = rethrow }: ClientOptions = {},
  ): Promise<AvalancheClient> {
    const signals = SearchSignals.tryCreate();
    const client = new AvalancheClient(port, signals);
    client.#onLine = (line) => {
      if (line.startsWith("bestmove")) client.#pendingSearches = Math.max(0, client.#pendingSearches - 1);
      onLine?.(line);
    };

    return new Promise((resolve, reject) => {
      let ready = false;
      const report = (error: Error): void => {
        if (ready) onError(error);
        else reject(error);
      };
      const failFatally = (error: Error): void => {
        if (client.#closed) return;
        client.terminate();
        report(error);
      };

      port.onFailure(failFatally);
      port.onMessage((message) => {
        switch (message.type) {
          case "ready":
            ready = true;
            resolve(client);
            return;
          case "line":
            client.#onLine(message.line);
            return;
          case "quit":
            client.terminate();
            return;
          case "error":
            if (ready) report(new Error(message.message));
            else failFatally(new Error(message.message));
            return;
        }
      });
      port.postMessage({ type: "init", wasmUrl: String(wasmUrl), signalBuffer: signals?.buffer ?? null });
    });
  }

  /** False when "stop"/"ponderhit" can only take effect after the running search ends (no SharedArrayBuffer). */
  get canInterrupt(): boolean {
    return this.#signals !== null;
  }

  get closed(): boolean {
    return this.#closed;
  }

  /** Resolves once the client is closed, either by terminate() or by the engine processing "quit". */
  get whenClosed(): Promise<void> {
    return this.#whenClosed.promise;
  }

  send(command: string): void {
    if (this.#closed) throw new Error("Engine has quit");
    const seq = ++this.#seq;
    const verb = command.trim().split(/\s+/, 1)[0] ?? "";
    if (verb === "isready" && this.#pendingSearches > 0) {
      queueMicrotask(() => {
        this.#onLine("readyok");
      });
      return;
    }
    if (verb === "go") this.#pendingSearches++;
    const signal = SIGNALLING_COMMANDS.get(verb);
    if (signal) this.#signals?.request(signal, seq);
    this.#port.postMessage({ type: "command", seq, command });
  }

  terminate(): void {
    if (this.#closed) return;
    this.#closed = true;
    this.#port.terminate();
    this.#whenClosed.resolve();
  }
}

export function webWorkerPort(worker: Worker): ClientPort {
  return {
    postMessage: (message) => {
      worker.postMessage(message);
    },
    onMessage: (listener) => {
      worker.addEventListener("message", (event: MessageEvent<Parameters<typeof listener>[0]>) => {
        listener(event.data);
      });
    },
    onFailure: (listener) => {
      worker.addEventListener("error", (event) => {
        listener(new Error(event.message || "Engine worker failed to load"));
      });
      worker.addEventListener("messageerror", () => {
        listener(new Error("Engine worker sent an undecodable message"));
      });
    },
    terminate: () => {
      worker.terminate();
    },
  };
}
