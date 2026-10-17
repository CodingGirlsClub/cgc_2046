// agent-runtimes.ts — 每个 agent kind 一个进程代（KTD1）与各自的空闲回收（KTD13）：一种 agent 的空闲不回收另一种的进程。
import type { ClientApp, InitializeResponse } from "@agentclientprotocol/sdk";
import type { AgentKind, Registry } from "../agents/registry";
import { createRuntime, type Runtime } from "./runtime";

export interface AgentRuntimesOptions {
  registry: Registry;
  /** 当前页面的连接数（server.ts 的 onConnections） */
  connections(): number;
  /** 这个 kind 名下还有回合在跑吗（有就不算空闲） */
  busy(kind: AgentKind): boolean;
  /** 进程换代（空闲回收、崩溃）后由会话层收尾它名下的会话 */
  retired(kind: AgentKind): void;
  /** 握手应答（会话层记这个 agent 播报的登录方式） */
  initialized(kind: AgentKind, response: InitializeResponse): void;
  app(kind: AgentKind, active: () => boolean): ClientApp;
  idleMs: number;
}

export interface AgentRuntimes {
  runtimeFor(kind: AgentKind): Runtime;
  /** KTD13：没有页面连着、也没有在跑的回合，超过空闲期就回收该 agent 的进程；下次需要时再拉起并 session/load */
  checkIdle(): void;
}

export function createAgentRuntimes(opts: AgentRuntimesOptions): AgentRuntimes {
  const runtimes = new Map<AgentKind, Runtime>();
  const idleTimers = new Map<AgentKind, Timer>();

  function runtimeFor(kind: AgentKind): Runtime {
    let runtime = runtimes.get(kind);
    if (!runtime) {
      runtime = createRuntime({
        start: (app, signal) => opts.registry.start(kind, app, signal),
        ready: checkIdle,
        reset: () => opts.retired(kind),
        initialized: (response) => opts.initialized(kind, response),
        app: (active) => opts.app(kind, active),
      });
      runtimes.set(kind, runtime);
    }
    return runtime;
  }

  function checkIdle(): void {
    for (const [kind, runtime] of runtimes) {
      const idle = () => runtime.agent !== null && opts.connections() === 0 && !opts.busy(kind);
      const timer = idleTimers.get(kind);
      if (idle() && !timer) {
        const armed = setTimeout(() => {
          idleTimers.delete(kind);
          if (!idle()) return;
          console.log(`cgc-host: 空闲，回收 ${kind} 进程`);
          runtime.close();
        }, opts.idleMs);
        armed.unref();
        idleTimers.set(kind, armed);
      } else if (!idle() && timer) {
        clearTimeout(timer);
        idleTimers.delete(kind);
      }
    }
  }

  return { runtimeFor, checkIdle };
}
