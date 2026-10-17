// agents/registry.ts — agent 注册表（KTD1）：kind 是协议与状态文件里的键；每条记录回答两件事——装好了没、怎么拉起。
// 加一种 agent = 加一条记录；路由、会话指针与状态上报都不认识具体是哪个 agent。
import type { ClientApp } from "@agentclientprotocol/sdk";
import type { Agent } from "../acp/client";
import type { EnvError } from "../shell-env";

/** 支持的 agent。协议与状态文件都用这些字符串做键（Codex 随它自己的记录一起加入） */
export const AGENT_KINDS = ["omp"] as const;
export type AgentKind = (typeof AGENT_KINDS)[number];
/** 页面不带 agent 时的缺省：存量页面与只装 OMP 的学员行为不变 */
export const DEFAULT_AGENT: AgentKind = "omp";

export const isAgentKind = (value: unknown): value is AgentKind =>
  typeof value === "string" && (AGENT_KINDS as readonly string[]).includes(value);

/** 一次定位的结果：入口路径（找不到为 null）、登录 shell 的环境、解析失败的原因 */
export interface AgentLocation {
  path: string | null;
  env: Record<string, string>;
  envError: EnvError | null;
}

/** 上报给页面的 agent 状态（status.agents / /health.agents）；envError 只在解析失败时出现 */
export interface AgentStatus {
  kind: AgentKind;
  present: boolean;
  envError?: EnvError;
}

/** 缓存最近一次解析的定位器：status 与 /health 同步读缓存；还没找到时在后台按需重解析并限频——学员装上后不必重启 Host */
export interface Locator {
  locate(): Promise<AgentLocation>;
  present(): boolean;
  envError(): EnvError | null;
}

export function agentLocator(resolve: () => Promise<AgentLocation>, retryMs = 10_000): Locator {
  let last: AgentLocation | null = null;
  let at = 0;
  let pending: Promise<AgentLocation> | null = null;
  const locate = () =>
    (pending ??= resolve()
      .then((found) => {
        last = found;
        at = Date.now();
        return found;
      })
      .finally(() => {
        pending = null;
      }));
  return {
    locate,
    present(): boolean {
      if (!last?.path && !pending && Date.now() - at >= retryMs) void locate();
      return Boolean(last?.path);
    },
    envError: () => last?.envError ?? null,
  };
}

export interface AgentRecord {
  kind: AgentKind;
  /** 人读的名字：日志与页面标签 */
  label: string;
  locator: Locator;
  /** 拉起该 agent 的进程；找不到或起不来就抛错（详情只进 Host 日志） */
  start(app: ClientApp, signal: AbortSignal): Promise<Agent>;
}

export interface Registry {
  kinds(): readonly AgentKind[];
  status(): AgentStatus[];
  /** 拉起指定 agent 的进程；这个 kind 没有记录就抛错 */
  start(kind: AgentKind, app: ClientApp, signal: AbortSignal): Promise<Agent>;
}

export function createRegistry(records: readonly AgentRecord[]): Registry {
  const byKind: Partial<Record<AgentKind, AgentRecord>> = {};
  for (const record of records) byKind[record.kind] = record;
  return {
    kinds: () => records.map((record) => record.kind),
    status: () =>
      records.map(({ kind, locator }) => {
        const envError = locator.envError();
        return { kind, present: locator.present(), ...(envError && { envError }) };
      }),
    start(kind, app, signal) {
      const record = byKind[kind];
      if (!record) throw new Error(`没有 ${kind} 这条 agent 记录`);
      return record.start(app, signal);
    },
  };
}
