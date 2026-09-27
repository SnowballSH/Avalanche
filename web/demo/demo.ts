import { AvalancheClient, webWorkerPort } from "../src/index.ts";

function element<T extends HTMLElement>(id: string, type: new () => T): T {
  const found = document.getElementById(id);
  if (!(found instanceof type)) throw new Error(`Missing #${id}`);
  return found;
}

const status = element("status", HTMLParagraphElement);
const output = element("output", HTMLPreElement);
const form = element("command-form", HTMLFormElement);
const input = element("command", HTMLInputElement);
const stopButton = element("stop", HTMLButtonElement);

const print = (line: string): void => {
  output.append(`${line}\n`);
  output.scrollTop = output.scrollHeight;
};

const worker = new Worker(new URL("../src/worker.js", import.meta.url), { type: "module" });
const client = await AvalancheClient.start(webWorkerPort(worker), new URL("/avalanche.wasm", location.href), {
  onLine: print,
  onError: (error) => {
    print(`error: ${error.message}`);
  },
});

status.textContent = client.canInterrupt
  ? "Ready. Stop interrupts searches (cross-origin isolated)."
  : "Ready. Not cross-origin isolated: searches run to their limits.";

const send = (command: string): void => {
  print(`> ${command}`);
  client.send(command);
};

form.addEventListener("submit", (event) => {
  event.preventDefault();
  send(input.value);
});
stopButton.addEventListener("click", () => {
  send("stop");
});

for (const command of ["uci", "isready", "position startpos"]) send(command);
