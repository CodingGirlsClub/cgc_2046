// auth.ts — agent 的登录（KTD4）：握手时播报的登录方式由这里记住，页面发起的 chat.authenticate 由这里转发。
import type { InitializeResponse } from "@agentclientprotocol/sdk";
import type { AgentKind } from "../agents/registry";
import { message } from "./errors";
import type { Runtime } from "./runtime";

/** 登录方式：只留页面要用的 id 与显示名 */
export interface AuthMethod {
  id: string;
  name: string;
}

/** 各 agent 握手时播报的登录方式（空数组表示它不需要登录，或旧版本不播报） */
export function createAuthMethods() {
  const methods = new Map<AgentKind, AuthMethod[]>();
  return {
    remember: (kind: AgentKind, response: InitializeResponse) => {
      methods.set(kind, (response.authMethods ?? []).map(({ id, name }) => ({ id, name })));
    },
    of: (kind: AgentKind): AuthMethod[] => methods.get(kind) ?? [],
  };
}

/**
 * 把一个登录请求转给这个 agent 的 ACP `authenticate`（`chat-gpt` 这类由适配器在学员本机开浏览器）。
 * 不进课程队列：学员可能在浏览器里停留几十秒，不能占住 new / load / send（#1151 的口径）。
 * 作废键是**进程代**：登录期间进程被换掉（崩溃、空闲回收）就报 busy，让页面重试——它与某一条会话无关。
 */
export async function authenticateAgent(runtime: Runtime, methodId: string, timeoutMs: number): Promise<"ok" | "busy" | "failed"> {
  try {
    const agent = await runtime.prepare(timeoutMs, (run) => run.agent());
    await agent.rpc.request("authenticate", { methodId });
    return runtime.agent === agent ? "ok" : "busy";
  } catch (e) {
    console.error(`cgc-host: 登录失败：${message(e)}`);
    return "failed";
  }
}
