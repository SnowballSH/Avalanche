import assert from "node:assert/strict";
import { it } from "node:test";
import { LineDecoder } from "../src/line-decoder.ts";

const encode = (text: string): Uint8Array => new TextEncoder().encode(text);

it("emits complete lines across chunk boundaries", () => {
  const lines: string[] = [];
  const decoder = new LineDecoder((line) => lines.push(line));
  decoder.push(encode("info depth 1\r\nbest"));
  assert.deepEqual(lines, ["info depth 1"]);
  decoder.push(encode("move e2e4\n"));
  assert.deepEqual(lines, ["info depth 1", "bestmove e2e4"]);
});

it("reassembles multi-byte characters split between chunks", () => {
  const lines: string[] = [];
  const decoder = new LineDecoder((line) => lines.push(line));
  const bytes = encode("é\n");
  decoder.push(bytes.subarray(0, 1));
  decoder.push(bytes.subarray(1));
  assert.deepEqual(lines, ["é"]);
});
