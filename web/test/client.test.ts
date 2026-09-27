import assert from "node:assert/strict";
import { describe, it } from "node:test";
import type { AvalancheClient } from "../src/client.ts";
import { startNodeClient } from "../src/node/client.ts";
import { wasmUrl } from "./fixtures.ts";

interface Session {
  readonly client: AvalancheClient;
  readonly nextLine: (predicate: (line: string) => boolean, timeoutMs?: number) => Promise<string>;
}

async function startSession(): Promise<Session> {
  const lines: string[] = [];
  const waiters = new Set<() => void>();
  const client = await startNodeClient(wasmUrl, {
    onLine: (line) => {
      lines.push(line);
      for (const wake of waiters) wake();
    },
  });
  let cursor = 0;
  const nextLine = (predicate: (line: string) => boolean, timeoutMs = 10_000): Promise<string> =>
    new Promise((resolve, reject) => {
      const check = () => {
        for (; cursor < lines.length; cursor++) {
          const line = lines[cursor];
          if (line !== undefined && predicate(line)) {
            cursor++;
            finish();
            resolve(line);
            return;
          }
        }
      };
      const timer = setTimeout(() => {
        finish();
        reject(new Error("Timed out waiting for engine output"));
      }, timeoutMs);
      const finish = () => {
        clearTimeout(timer);
        waiters.delete(check);
      };
      waiters.add(check);
      check();
    });
  return { client, nextLine };
}

describe("worker client", () => {
  it("rejects start when the wasm cannot be loaded", async () => {
    await assert.rejects(startNodeClient(new URL("file:///nonexistent/avalanche.wasm")), /ENOENT/);
  });

  it("closes after the engine quits", async () => {
    const { client, nextLine } = await startSession();
    client.send("isready");
    await nextLine((line) => line === "readyok");
    client.send("quit");
    await client.whenClosed;
    assert.throws(() => {
      client.send("isready");
    }, /quit/);
  });

  it("interrupts an infinite search", async (t) => {
    const { client, nextLine } = await startSession();
    t.after(() => {
      client.terminate();
    });
    assert.equal(client.canInterrupt, true);
    client.send("position startpos");
    client.send("go infinite");
    await nextLine((line) => line.startsWith("info depth 5 "));
    client.send("stop");
    await nextLine((line) => line.startsWith("bestmove "), 2_000);
  });

  it("withholds bestmove while pondering and releases it on ponderhit", async (t) => {
    const { client, nextLine } = await startSession();
    t.after(() => {
      client.terminate();
    });
    client.send("position startpos moves e2e4");
    client.send("go ponder wtime 2000 btime 2000");
    await nextLine((line) => line.startsWith("info depth 6 "));
    await assert.rejects(
      nextLine((line) => line.startsWith("bestmove "), 1_500),
      /Timed out/,
    );
    client.send("ponderhit");
    await nextLine((line) => line.startsWith("bestmove "), 5_000);
  });

  it("stops a ponder search on stop", async (t) => {
    const { client, nextLine } = await startSession();
    t.after(() => {
      client.terminate();
    });
    client.send("position startpos");
    client.send("go ponder wtime 60000 btime 60000");
    await nextLine((line) => line.startsWith("info depth 5 "));
    client.send("stop");
    await nextLine((line) => line.startsWith("bestmove "), 2_000);
  });

  it("does not let an earlier stop cancel a later search", async (t) => {
    const { client, nextLine } = await startSession();
    t.after(() => {
      client.terminate();
    });
    client.send("stop");
    client.send("go depth 6");
    await nextLine((line) => line.startsWith("info depth 6 "));
    await nextLine((line) => line.startsWith("bestmove "));
  });
});
