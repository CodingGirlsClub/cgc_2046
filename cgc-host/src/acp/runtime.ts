import { type ClientApp, type InitializeResponse, PROTOCOL_VERSION } from "@agentclientprotocol/sdk";
import type { Agent } from "./client";

/** SDK cancellation is cooperative; stop waiting locally even if the peer never responds. */
function abortable<T>(task: Promise<T>, signal: AbortSignal): Promise<T> {
  return new Promise((resolve, reject) => {
    const aborted = () => { signal.removeEventListener("abort", aborted); reject(signal.reason); };
    if (signal.aborted) aborted();
    else signal.addEventListener("abort", aborted, { once: true });
    task.then(
      (value) => { signal.removeEventListener("abort", aborted); if (signal.aborted) reject(signal.reason); else resolve(value); },
      (error) => { signal.removeEventListener("abort", aborted); reject(error); },
    );
  });
}

type Generation = {
  abort: AbortController;
  agent: Agent | null;
  initialized: boolean;
  phase: string;
  ready: Promise<Agent>;
};

export interface Preparation {
  agent(): Promise<Agent>;
  wait<T>(phase: string, action: (signal: AbortSignal) => Promise<T>): Promise<T>;
  check(): void;
}

/** 一个 agent 进程代的对外形状：会话层按 kind 各持一个（KTD1） */
export interface Runtime {
  /** 已握完手、可用的 agent 进程；没有就为 null */
  readonly agent: Agent | null;
  /** 回收当前进程代（空闲回收、换代）；退代的收尾由 createRuntime 的 reset 回调负责 */
  close(): void;
  /** 在总预算内准备一条可用通道：拉起进程、initialize、list/load/new 都算在里面；超时即废弃这一代 */
  prepare<T>(timeoutMs: number, operation: (run: Preparation) => Promise<T>): Promise<T>;
}

/** One shared process generation. Retiring it cannot affect a later replacement. */
export function createRuntime(opts: {
  start(app: ClientApp, signal: AbortSignal): Promise<Agent>;
  app(active: () => boolean): ClientApp;
  reset(): void;
  ready(): void;
  /** 握手应答：会话层用它取这个 agent 播报的登录方式（chat.authenticate 的取值来源） */
  initialized?(response: InitializeResponse): void;
}): Runtime {
  let current: Generation | null = null;

  function retire(g: Generation, reason: unknown) {
    if (g.abort.signal.aborted) return;
    const owned = current === g;
    if (owned) current = null;
    g.abort.abort(reason);
    g.agent?.close();
    if (owned) opts.reset();
  }

  function acquire(): Generation {
    if (current) return current;
    const g: Generation = { abort: new AbortController(), agent: null, initialized: false, phase: "spawn", ready: null! };
    current = g;
    const active = () => current === g && !g.abort.signal.aborted;
    g.ready = (async () => {
      const a = await opts.start(opts.app(active), g.abort.signal);
      if (!active()) { a.close(); throw g.abort.signal.reason; }
      g.agent = a;
      void a.closed.then(() => retire(g, new Error("agent connection closed")));
      g.phase = "initialize";
      const init = await abortable(a.rpc.request("initialize", {
        protocolVersion: PROTOCOL_VERSION, clientCapabilities: { elicitation: { form: {} } },
      }, { cancellationSignal: g.abort.signal }), g.abort.signal);
      g.abort.signal.throwIfAborted();
      // 协议不兼容的适配器不能当成可用：抛错会让本次 prepare 失败并按换代回收
      if (init.protocolVersion !== PROTOCOL_VERSION) {
        throw new Error(`agent 协定的 ACP 协议版本 ${init.protocolVersion} 与 Host 支持的 ${PROTOCOL_VERSION} 不一致`);
      }
      g.initialized = true;
      opts.initialized?.(init);
      opts.ready();
      return a;
    })().catch((error) => { retire(g, error); throw error; });
    return g;
  }

  return {
    get agent() { return current?.initialized ? current.agent : null; },
    close() { if (current) retire(current, new Error("OMP retired")); },
    async prepare<T>(timeoutMs: number, operation: (run: Preparation) => Promise<T>): Promise<T> {
      const budget = new AbortController();
      let generation: Generation | null = null;
      let phase = "queue";
      const deadline = performance.now() + timeoutMs;
      const expire = () => {
        if (budget.signal.aborted) return;
        const stage = generation && !generation.initialized ? generation.phase : phase;
        const error = new Error(`OMP preparation timed out (${stage}, ${timeoutMs}ms); retry to start a new process`);
        budget.abort(error);
        // A request still waiting in its course queue owns no process and must not kill another course's agent.
        if (generation) retire(generation, error);
      };
      const check = () => {
        if (performance.now() >= deadline) expire();
        budget.signal.throwIfAborted();
        generation?.abort.signal.throwIfAborted();
      };
      const signal = () => generation ? AbortSignal.any([budget.signal, generation.abort.signal]) : budget.signal;
      const timer = setTimeout(expire, timeoutMs);
      const run: Preparation = {
        check,
        async agent() {
          check();
          generation ??= acquire();
          const a = await abortable(generation.ready, signal());
          check();
          return a;
        },
        async wait<T>(stage: string, action: (signal: AbortSignal) => Promise<T>) {
          check();
          phase = stage;
          const s = signal();
          const value = await abortable(action(s), s);
          check();
          return value;
        },
      };
      try {
        return await abortable(operation(run), budget.signal);
      } finally {
        clearTimeout(timer);
      }
    },
  };
}
