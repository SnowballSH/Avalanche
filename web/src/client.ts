import type { ClientPort, WorkerMessage } from "./protocol.ts";
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

function verbOf(command: string): string {
  const line = command.replace(/^[\r\n]+|[\r\n]+$/g, "");
  return line.split(" ").find((token) => token !== "") ?? "";
}

export class AvalancheClient {
  readonly #port: ClientPort;
  readonly #signals: SearchSignals | null;
  #seq = 0;
  #closed = false;
  #searchesAwaitingBestmove = 0;
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
      if (line.startsWith("bestmove")) {
        client.#searchesAwaitingBestmove = Math.max(0, client.#searchesAwaitingBestmove - 1);
      }
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
          case "crash":
            failFatally(new Error(message.message));
            return;
        }
      });
      port.postMessage({ type: "init", wasmUrl: String(wasmUrl), signalBuffer: signals?.buffer ?? null });
    });
  }

  get canInterrupt(): boolean {
    return this.#signals !== null;
  }

  get closed(): boolean {
    return this.#closed;
  }

  get whenClosed(): Promise<void> {
    return this.#whenClosed.promise;
  }

  send(command: string): void {
    if (this.#closed) throw new Error("Engine client is closed");
    const seq = ++this.#seq;
    const verb = verbOf(command);
    if (verb === "isready" && this.#searchesAwaitingBestmove > 0) {
      queueMicrotask(() => {
        this.#onLine("readyok");
      });
      return;
    }
    if (verb === "go") this.#searchesAwaitingBestmove++;
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
      worker.addEventListener("message", (event: MessageEvent<WorkerMessage>) => {
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
