import assert from "node:assert/strict";
import type { Server } from "node:http";
import { isIP } from "node:net";
import { describe, it, type TestContext } from "node:test";
import { startDemoServer } from "../demo/static-server.ts";

const LOOPBACK_ADDRESSES: readonly string[] = ["127.0.0.1", "::1"];

interface RunningServer {
  readonly address: string;
  readonly origin: string;
}

async function startServer(t: TestContext): Promise<RunningServer> {
  const server: Server = await startDemoServer(0);
  t.after(() => {
    server.close();
    server.closeAllConnections();
  });
  const bound = server.address();
  if (bound === null || typeof bound === "string") throw new Error("demo server is not bound to a port");
  const host = isIP(bound.address) === 6 ? `[${bound.address}]` : bound.address;
  return { address: bound.address, origin: `http://${host}:${String(bound.port)}` };
}

describe("demo server", () => {
  it("answers malformed request paths with 404 and keeps serving", async (t) => {
    const { origin } = await startServer(t);
    for (const path of ["/%", "//"]) {
      const response = await fetch(`${origin}${path}`);
      assert.equal(response.status, 404, path);
    }
    const page = await fetch(`${origin}/`);
    assert.equal(page.status, 200);
    assert.equal(page.headers.get("cross-origin-opener-policy"), "same-origin");
    assert.match(await page.text(), /<title>Avalanche WebAssembly<\/title>/);
  });

  it("refuses paths outside the built tree", async (t) => {
    const { origin } = await startServer(t);
    const response = await fetch(`${origin}/..%2Fpackage.json`);
    assert.equal(response.status, 404);
  });

  it("listens on the loopback interface only", async (t) => {
    const { address } = await startServer(t);
    assert.ok(LOOPBACK_ADDRESSES.includes(address), address);
  });
});
