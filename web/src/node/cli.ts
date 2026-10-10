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

const commands = createInterface({ input: process.stdin });
void client.whenClosed.then(() => {
  commands.close();
});
for await (const command of commands) {
  if (client.closed) break;
  client.send(command);
}
if (!client.closed) client.send("quit");
await client.whenClosed;
