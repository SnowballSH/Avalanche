import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { createCapturingEngine, nativeBenchSignature, parseBenchNodes } from "./fixtures.ts";

const KIWIPETE = "r3k2r/p1ppqpb1/bn2pnp1/3PN3/1p2P3/2N2Q1p/PPPBBPPP/R3K2R w KQkq - 0 1";

describe("wasm engine", () => {
  it("completes the UCI handshake", async () => {
    const { run } = await createCapturingEngine();
    const output = run("uci");
    assert.match(output[0] ?? "", /^id name Avalanche /);
    assert.equal(output.at(-1), "uciok");
    assert.deepEqual(run("isready"), ["readyok"]);
  });

  for (const { name, fen, depth, nodes } of [
    { name: "startpos", fen: "startpos", depth: 4, nodes: 197281 },
    { name: "kiwipete", fen: `fen ${KIWIPETE}`, depth: 3, nodes: 97862 },
  ]) {
    it(`matches perft ${String(depth)} on ${name}`, async () => {
      const { run } = await createCapturingEngine();
      run(`position ${fen}`);
      assert.ok(run(`perft ${String(depth)}`).includes(`Nodes: ${String(nodes)}`));
    });
  }

  it("returns a legal bestmove for a fixed-depth search", async () => {
    const { run } = await createCapturingEngine();
    run("position startpos moves e2e4 e7e5");
    const output = run("go depth 8");
    assert.ok(output.some((line) => line.startsWith("info depth 8 ")));
    assert.match(output.at(-1) ?? "", /^bestmove [a-h][1-8][a-h][1-8][qrbn]?( ponder \S+)?$/);
  });

  it("stops at the requested node budget", async () => {
    const { run } = await createCapturingEngine();
    run("position startpos");
    const output = run("go nodes 5000");
    assert.match(output.at(-1) ?? "", /^bestmove /);
  });

  it("rejects commands that overflow the input buffer", async () => {
    const { engine } = await createCapturingEngine();
    assert.throws(() => engine.send("x".repeat(1 << 16)), RangeError);
    assert.equal(engine.send("isready"), true);
  });

  it("advertises only the options wasm supports", async () => {
    const { run } = await createCapturingEngine();
    const options = run("uci").filter((line) => line.startsWith("option name "));
    assert.ok(options.includes("option name Threads type spin default 1 min 1 max 1"));
    assert.ok(!options.some((line) => line.includes("Syzygy")));
  });

  it("reports quit to the host", async () => {
    const { engine } = await createCapturingEngine();
    assert.equal(engine.send("isready"), true);
    assert.equal(engine.send("quit"), false);
  });

  it("searches exactly the same tree as the native build", { timeout: 300_000 }, async (t) => {
    const expected = nativeBenchSignature();
    if (expected === null) {
      t.skip("native binary not built (zig build --release=fast)");
      return;
    }
    const { engine, lines } = await createCapturingEngine();
    engine.bench();
    assert.equal(parseBenchNodes(lines.join("\n")), expected);
  });
});
