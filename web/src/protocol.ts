export type ClientMessage =
  | { readonly type: "init"; readonly wasmUrl: string; readonly stopBuffer: SharedArrayBuffer | null }
  | { readonly type: "command"; readonly seq: number; readonly command: string };

export type WorkerMessage =
  | { readonly type: "ready" }
  | { readonly type: "line"; readonly line: string }
  | { readonly type: "quit" }
  | { readonly type: "error"; readonly message: string };

export interface Port<Outgoing, Incoming> {
  postMessage(message: Outgoing): void;
  onMessage(listener: (message: Incoming) => void): void;
}

export interface ClientPort extends Port<ClientMessage, WorkerMessage> {
  /** Reports failures outside the message protocol: worker load errors, crashes, unexpected exits. */
  onFailure(listener: (error: Error) => void): void;
  terminate(): void;
}

export type WorkerPort = Port<WorkerMessage, ClientMessage>;
