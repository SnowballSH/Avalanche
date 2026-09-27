import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { once } from "node:events";
import { it } from "node:test";
import { fileURLToPath } from "node:url";
import { wasmUrl } from "./fixtures.ts";

const cliPath = fileURLToPath(new URL("../src/node/cli.ts", import.meta.url));

it("exits on quit while the GUI keeps stdin open", async () => {
  const cli = spawn(process.execPath, [cliPath, fileURLToPath(wasmUrl)], {
    stdio: ["pipe", "pipe", "inherit"],
  });
  let output = "";
  cli.stdout.setEncoding("utf8");
  cli.stdout.on("data", (chunk: string) => {
    output += chunk;
  });
  const exited = once(cli, "exit");

  cli.stdin.write("isready\nquit\n");
  const timeout = setTimeout(() => cli.kill(), 10_000);
  const [code] = await exited;
  clearTimeout(timeout);
  cli.stdin.destroy();

  assert.equal(code, 0);
  assert.match(output, /readyok/);
});
