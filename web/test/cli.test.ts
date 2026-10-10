import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import { wasmUrl } from "./fixtures.ts";

const cliPath = fileURLToPath(new URL("../src/node/cli.ts", import.meta.url));
const EXIT_DEADLINE_MS = 10_000;

interface CliRun {
  readonly code: number | null;
  readonly output: string;
}

async function runCli(input: string, stdin: "kept open" | "ended"): Promise<CliRun> {
  const cli = spawn(process.execPath, [cliPath, fileURLToPath(wasmUrl)], {
    stdio: ["pipe", "pipe", "inherit"],
  });
  let output = "";
  cli.stdout.setEncoding("utf8");
  cli.stdout.on("data", (chunk: string) => {
    output += chunk;
  });
  const exited = once(cli, "exit");

  cli.stdin.write(input);
  if (stdin === "ended") cli.stdin.end();
  const deadline = setTimeout(() => cli.kill(), EXIT_DEADLINE_MS);
  await exited;
  clearTimeout(deadline);
  cli.stdin.destroy();

  return { code: cli.exitCode, output };
}

describe("stdio adapter", () => {
  it("exits on quit while the GUI keeps stdin open", async () => {
    const { code, output } = await runCli("isready\nquit\n", "kept open");
    assert.equal(code, 0);
    assert.match(output, /readyok/);
  });

  it("exits when the engine quits on a line that is more than the bare word", async () => {
    const { code } = await runCli("quit now\n", "kept open");
    assert.equal(code, 0);
  });

  it("keeps reading after a line the engine does not take for quit", async () => {
    const { code, output } = await runCli("quit\t\nisready\nquit\n", "kept open");
    assert.equal(code, 0);
    assert.match(output, /readyok/);
  });

  it("quits the engine when stdin ends", async () => {
    const { code, output } = await runCli("isready\n", "ended");
    assert.equal(code, 0);
    assert.match(output, /readyok/);
  });
});
