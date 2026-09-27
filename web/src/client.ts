import type { ClientPort } from "./protocol.ts";
import { StopSignal } from "./stop-signal.ts";

export interface ClientOptions {
  readonly onLine?: (line: string) => void;
  readonly onError?: (error: Error) => void;
}

const rethrow = (error: Error): never => {
  throw error;
};

const INTERRUPTING_COMMANDS = new Set(["stop", "quit"]);

/** Non-blocking handle to an engine running in a worker. */
export class AvalancheClient {
  readonly #port: ClientPort;
  readonly #stopSignal: StopSignal | null;
  #seq = 0;
  #closed = false;
  readonly #whenClosed: PromiseWithResolvers<void> = Promise.withResolvers();

  private constructor(port: ClientPort, stopSignal: StopSignal | null) {
    this.#port = port;
    this.#stopSignal = stopSignal;
  }

  static start(
    port: ClientPort,
    wasmUrl: string | URL,
    { onLine, onError = rethrow }: ClientOptions = {},
  ): Promise<AvalancheClient> {
    const stopSignal = StopSignal.tryCreate();
    const client = new AvalancheClient(port, stopSignal);

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
            onLine?.(message.line);
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
      port.postMessage({ type: "init", wasmUrl: String(wasmUrl), stopBuffer: stopSignal?.buffer ?? null });
    });
  }

  /** False when "stop" can only take effect after the running search ends (no SharedArrayBuffer). */
  get canInterrupt(): boolean {
    return this.#stopSignal !== null;
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
    if (INTERRUPTING_COMMANDS.has(verb)) this.#stopSignal?.request(seq);
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
