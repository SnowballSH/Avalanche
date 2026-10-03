import assert from "node:assert/strict";
import { stat } from "node:fs/promises";
import { describe, it } from "node:test";
import { createCapturingEngine, nativeBenchSignature, parseBenchNodes, wasmUrl } from "./fixtures.ts";

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

  it("reports distinct MultiPV lines", async () => {
    const { run } = await createCapturingEngine();
    run("setoption name MultiPV value 3");
    run("position startpos");
    const final = run("go depth 6").filter((line) => line.startsWith("info depth 6 "));
    assert.deepEqual(
      final.map((line) => / multipv (\d+) /.exec(line)?.[1]),
      ["1", "2", "3"],
    );
    assert.equal(new Set(final.map((line) => / pv (\S+)/.exec(line)?.[1])).size, 3);
  });

  it("plays Chess960 castling in king-captures-rook notation", async () => {
    const { run } = await createCapturingEngine();
    run("setoption name UCI_Chess960 value true");
    run("position fen 4k3/8/8/8/8/8/8/5KR1 w G - 0 1");
    assert.match(run("go depth 1 searchmoves f1g1").at(-1) ?? "", /^bestmove f1g1/);
    assert.ok(run("perft 3").includes("Nodes: 1033"));
  });

  it("limits strength by skill level", async () => {
    const { run } = await createCapturingEngine();
    run("setoption name Skill Level value 1");
    run("position startpos");
    const depths = run("go depth 12")
      .map((line) => / depth (\d+) /.exec(line)?.[1])
      .filter((depth) => depth !== undefined)
      .map(Number);
    assert.ok(Math.max(...depths) <= 2, String(depths));
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

  it("embeds the network exactly once", async () => {
    const [module, network] = await Promise.all([
      stat(wasmUrl),
      stat(new URL("../../nets/dianguang-2.nnue", import.meta.url)),
    ]);
    assert.ok(module.size > network.size, "network missing from the module");
    assert.ok(
      module.size < network.size * 1.1,
      `module is ${String(module.size)} bytes for a ${String(network.size)}-byte network`,
    );
  });

  it("names the network when a search starts", async () => {
    const { run } = await createCapturingEngine();
    run("position startpos");
    const output = run("go depth 1");
    assert.match(
      output[0] ?? "",
      /^info string NNUE evaluation using dianguang-2 \(768x\d+->\d+->pairwise->\d+x2->\d+->1x\d+, \d+ MiB\)$/,
    );
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
