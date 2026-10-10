import { createReadStream } from "node:fs";
import { stat } from "node:fs/promises";
import { createServer, type Server, type ServerResponse } from "node:http";
import { extname, normalize, sep } from "node:path";
import { fileURLToPath } from "node:url";

const HOST = "localhost";

const webRoot = fileURLToPath(new URL("..", import.meta.url));
const wasmPath = fileURLToPath(new URL("../../zig-out/web/avalanche.wasm", import.meta.url));

const CONTENT_TYPES: Readonly<Record<string, string>> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".map": "application/json",
  ".wasm": "application/wasm",
};

const CROSS_ORIGIN_ISOLATION = {
  "Cross-Origin-Opener-Policy": "same-origin",
  "Cross-Origin-Embedder-Policy": "require-corp",
} as const;

function resolvePath(urlPath: string): string | null {
  if (urlPath === "/") return `${webRoot}demo${sep}index.html`;
  if (urlPath === "/avalanche.wasm") return wasmPath;
  const file = normalize(`${webRoot}dist${decodeURIComponent(urlPath)}`);
  return file.startsWith(`${webRoot}dist${sep}`) ? file : null;
}

async function sendFile(requestUrl: string, response: ServerResponse): Promise<void> {
  const file = resolvePath(new URL(requestUrl, `http://${HOST}`).pathname);
  if (file === null) throw new Error("outside the served tree");
  const info = await stat(file);
  if (!info.isFile()) throw new Error("not a file");
  response.writeHead(200, {
    ...CROSS_ORIGIN_ISOLATION,
    "Content-Type": CONTENT_TYPES[extname(file)] ?? "application/octet-stream",
    "Content-Length": info.size,
  });
  createReadStream(file).pipe(response);
}

export function startDemoServer(port: number): Promise<Server> {
  const server = createServer((request, response) => {
    sendFile(request.url ?? "/", response).catch(() => {
      response.writeHead(404, CROSS_ORIGIN_ISOLATION).end("Not found");
    });
  });
  return new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, HOST, () => {
      resolve(server);
    });
  });
}
