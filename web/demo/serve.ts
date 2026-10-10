import { startDemoServer } from "./static-server.ts";

const port = Number(process.env["PORT"] ?? 8080);

await startDemoServer(port);
console.log(`Avalanche demo: http://localhost:${String(port)}`);
