import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { AvalancheClient } from "../src/client.ts";
import { ScriptedClientPort } from "./scripted-ports.ts";

interface Session {
  readonly port: ScriptedClientPort;
  readonly client: AvalancheClient;
  readonly lines: string[];
  readonly errors: string[];
}

async function startSession(): Promise<Session> {
  const port = new ScriptedClientPort();
  const lines: string[] = [];
  const errors: string[] = [];
  const starting = AvalancheClient.start(port, "file:///unused.wasm", {
    onLine: (line) => lines.push(line),
    onError: (error) => errors.push(error.message),
  });
  port.deliver({ type: "ready" });
  return { port, client: await starting, lines, errors };
}

describe("client protocol", () => {
  it("closes and reports once when the engine crashes", async () => {
    const { port, client, errors } = await startSession();
    port.deliver({ type: "crash", message: "Engine crashed: unreachable" });
    assert.equal(client.closed, true);
    assert.equal(port.terminated, true);
    await client.whenClosed;
    assert.deepEqual(errors, ["Engine crashed: unreachable"]);
    assert.throws(() => {
      client.send("isready");
    }, /closed/);
  });

  it("rejects start when the engine crashes while starting", async () => {
    const port = new ScriptedClientPort();
    const starting = AvalancheClient.start(port, "file:///unused.wasm");
    port.deliver({ type: "crash", message: "Engine crashed: out of memory" });
    await assert.rejects(starting, /out of memory/);
    assert.equal(port.terminated, true);
  });

  it("stays open after a recoverable error", async () => {
    const { port, client, errors } = await startSession();
    port.deliver({ type: "error", message: "UCI command exceeds 65536 bytes" });
    assert.deepEqual(errors, ["UCI command exceeds 65536 bytes"]);
    assert.equal(client.closed, false);
    client.send("isready");
    assert.deepEqual(port.commands, ["isready"]);
  });

  it("answers isready itself only while a go the engine recognises is outstanding", async () => {
    const { port, client, lines } = await startSession();
    client.send("go\tdepth 5");
    client.send("isready");
    assert.deepEqual(port.commands, ["go\tdepth 5", "isready"]);

    client.send("  go depth 5\r");
    client.send("isready");
    assert.deepEqual(port.commands, ["go\tdepth 5", "isready", "  go depth 5\r"]);
    await Promise.resolve();
    assert.deepEqual(lines, ["readyok"]);

    port.deliver({ type: "line", line: "bestmove e2e4" });
    client.send("isready");
    assert.equal(port.commands.at(-1), "isready");
  });
});
