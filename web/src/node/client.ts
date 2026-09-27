import { Worker } from "node:worker_threads";
import { AvalancheClient, type ClientOptions } from "../client.ts";
import type { ClientPort, WorkerMessage } from "../protocol.ts";

const ownExtension = new URL(import.meta.url).pathname.endsWith(".ts") ? ".ts" : ".js";
const workerUrl = new URL(`./worker${ownExtension}`, import.meta.url);

export function nodeWorkerPort(worker: Worker): ClientPort {
  let terminated = false;
  return {
    postMessage: (message) => {
      worker.postMessage(message);
    },
    onMessage: (listener) => {
      worker.on("message", (message: WorkerMessage) => {
        listener(message);
      });
    },
    onFailure: (listener) => {
      worker.on("error", listener);
      worker.on("exit", (code) => {
        if (!terminated) listener(new Error(`Engine worker exited with code ${String(code)}`));
      });
    },
    terminate: () => {
      terminated = true;
      void worker.terminate();
    },
  };
}

export function startNodeClient(wasmUrl: URL, options: ClientOptions = {}): Promise<AvalancheClient> {
  return AvalancheClient.start(nodeWorkerPort(new Worker(workerUrl)), wasmUrl, options);
}
