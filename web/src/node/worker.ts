import { readFile } from "node:fs/promises";
import { parentPort } from "node:worker_threads";
import type { ClientMessage } from "../protocol.ts";
import { serveEngine } from "../worker-host.ts";

if (!parentPort) throw new Error("Must be run as a worker thread");
const port = parentPort;

serveEngine(
  {
    postMessage: (message) => {
      port.postMessage(message);
    },
    onMessage: (listener) => {
      port.on("message", (message: ClientMessage) => {
        listener(message);
      });
    },
  },
  async (url) => new Uint8Array(await readFile(new URL(url))),
);
