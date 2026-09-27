import type { ClientMessage, WorkerMessage } from "./protocol.ts";
import { serveEngine } from "./worker-host.ts";

interface DedicatedWorkerScope {
  postMessage(message: WorkerMessage): void;
  addEventListener(type: "message", listener: (event: MessageEvent<ClientMessage>) => void): void;
}

const scope = globalThis as unknown as DedicatedWorkerScope;

serveEngine(
  {
    postMessage: (message) => {
      scope.postMessage(message);
    },
    onMessage: (listener) => {
      scope.addEventListener("message", (event) => {
        listener(event.data);
      });
    },
  },
  (url) => fetch(url),
);
