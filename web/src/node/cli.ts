#!/usr/bin/env node
import { createInterface } from "node:readline";
import { pathToFileURL } from "node:url";
import { startNodeClient } from "./client.ts";

const [wasmPath] = process.argv.slice(2);
if (!wasmPath) {
  console.error("usage: avalanche-wasm <path/to/avalanche.wasm>");
  process.exit(2);
}

const client = await startNodeClient(pathToFileURL(wasmPath), {
  onLine: (line) => {
    process.stdout.write(`${line}\n`);
  },
});

let quitSent = false;
for await (const line of createInterface({ input: process.stdin })) {
  client.send(line);
  quitSent = line.trim() === "quit";
  if (quitSent) break;
}
if (!quitSent) client.send("quit");
await client.whenClosed;
// Leaving the readline loop does not release stdin; a GUI keeps the pipe open
// after "quit", so stdin would otherwise keep the process alive.
process.stdin.destroy();
