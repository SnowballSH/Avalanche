import assert from "node:assert/strict";
import { it } from "node:test";
import { SearchSignals } from "../src/search-signals.ts";

it("interrupts only commands sent before the stop", () => {
  const signals = new SearchSignals();
  assert.equal(signals.isRequestedDuring("stop", 1), false);
  signals.request("stop", 3);
  assert.equal(signals.isRequestedDuring("stop", 2), true);
  assert.equal(signals.isRequestedDuring("stop", 3), false);
  assert.equal(signals.isRequestedDuring("stop", 4), false);
});

it("keeps stop and ponderhit independent", () => {
  const signals = new SearchSignals();
  signals.request("ponderhit", 5);
  assert.equal(signals.isRequestedDuring("ponderhit", 4), true);
  assert.equal(signals.isRequestedDuring("stop", 4), false);
});

it("is shared across views of the same buffer", () => {
  const client = new SearchSignals();
  const worker = new SearchSignals(client.buffer);
  client.request("stop", 10);
  assert.equal(worker.isRequestedDuring("stop", 9), true);
});
