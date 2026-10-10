import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { setImmediate as nextTurn } from "node:timers/promises";
import { serveEngine } from "../src/worker-host.ts";
import { compileEngineModule } from "./fixtures.ts";
import { ScriptedWorkerPort, until } from "./scripted-ports.ts";

async function startServing(port: ScriptedWorkerPort): Promise<void> {
  serveEngine(port, compileEngineModule);
  port.deliver({ type: "init", wasmUrl: "", signalBuffer: null });
  await until(() => port.has("ready"));
}

describe("engine worker", { timeout: 30_000 }, () => {
  it("reports a crash and stops serving when a call into the module is abandoned", async () => {
    const port = new ScriptedWorkerPort(
      (message) => message.type === "line" && message.line.startsWith("info depth 2 "),
    );
    await startServing(port);

    port.deliver({ type: "command", seq: 1, command: "go depth 4" });
    await until(() => port.has("crash") || port.has("error"));
    assert.equal(port.posted.at(-1)?.type, "crash");

    const postedBeforeNextCommand = port.posted.length;
    port.deliver({ type: "command", seq: 2, command: "isready" });
    await nextTurn();
    assert.equal(port.posted.length, postedBeforeNextCommand);
  });

  it("keeps serving after refusing a command that overflows the input buffer", async () => {
    const port = new ScriptedWorkerPort();
    await startServing(port);

    port.deliver({ type: "command", seq: 1, command: "x".repeat(1 << 16) });
    port.deliver({ type: "command", seq: 2, command: "isready" });
    await until(() => port.lines.includes("readyok"));
    assert.equal(port.has("error"), true);
    assert.equal(port.has("crash"), false);
  });
});
