import assert from "node:assert/strict";
import { it } from "node:test";
import { StopSignal } from "../src/stop-signal.ts";

it("interrupts only commands sent before the stop", () => {
  const signal = new StopSignal();
  assert.equal(signal.isRequestedDuring(1), false);
  signal.request(3);
  assert.equal(signal.isRequestedDuring(2), true);
  assert.equal(signal.isRequestedDuring(3), false);
  assert.equal(signal.isRequestedDuring(4), false);
});

it("is shared across views of the same buffer", () => {
  const client = new StopSignal();
  const worker = new StopSignal(client.buffer);
  client.request(10);
  assert.equal(worker.isRequestedDuring(9), true);
});
