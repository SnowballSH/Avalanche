import { setImmediate as nextTurn } from "node:timers/promises";
import type { ClientMessage, ClientPort, WorkerMessage, WorkerPort } from "../src/protocol.ts";

export class ScriptedClientPort implements ClientPort {
  readonly posted: ClientMessage[] = [];
  terminated = false;
  #deliver: (message: WorkerMessage) => void = () => undefined;
  #fail: (error: Error) => void = () => undefined;

  postMessage(message: ClientMessage): void {
    this.posted.push(message);
  }

  onMessage(listener: (message: WorkerMessage) => void): void {
    this.#deliver = listener;
  }

  onFailure(listener: (error: Error) => void): void {
    this.#fail = listener;
  }

  terminate(): void {
    this.terminated = true;
  }

  deliver(message: WorkerMessage): void {
    this.#deliver(message);
  }

  fail(error: Error): void {
    this.#fail(error);
  }

  get commands(): string[] {
    return this.posted.flatMap((message) => (message.type === "command" ? [message.command] : []));
  }
}

export class ScriptedWorkerPort implements WorkerPort {
  readonly posted: WorkerMessage[] = [];
  readonly #refuses: (message: WorkerMessage) => boolean;
  #deliver: (message: ClientMessage) => void = () => undefined;

  constructor(refuses: (message: WorkerMessage) => boolean = () => false) {
    this.#refuses = refuses;
  }

  postMessage(message: WorkerMessage): void {
    if (this.#refuses(message)) throw new Error("port refused the message");
    this.posted.push(message);
  }

  onMessage(listener: (message: ClientMessage) => void): void {
    this.#deliver = listener;
  }

  deliver(message: ClientMessage): void {
    this.#deliver(message);
  }

  has(type: WorkerMessage["type"]): boolean {
    return this.posted.some((message) => message.type === type);
  }

  get lines(): string[] {
    return this.posted.flatMap((message) => (message.type === "line" ? [message.line] : []));
  }
}

export async function until(condition: () => boolean): Promise<void> {
  while (!condition()) await nextTurn();
}
