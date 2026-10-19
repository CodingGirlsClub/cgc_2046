// capabilities.ts — agent 在 ACP initialize 里播报的能力：Host 只记会话生命周期真正用到的几项。
// 兼容性：字段缺失按「支持」处理（旧适配器不播报），显式 false / 显式缺 list 才降级。
import type { InitializeResponse } from "@agentclientprotocol/sdk";
import type { AgentKind } from "../agents/registry";

export interface AgentCapabilities {
  protocolVersion: number;
  /** 是否支持 session/load */
  loadSession: boolean;
  /** 是否支持 session/list（用于核实会话目录归属、列历史对话） */
  listSessions: boolean;
  /** 是否支持 HTTP MCP 服务器（CGC 工具的下发方式） */
  httpMcp: boolean;
}

/** SDK 1.8 的类型没有 sessionCapabilities；按 JSON 原值用窄类型读，字段来源是 ACP 1.x 协议 */
type RawCapabilities = {
  loadSession?: unknown;
  mcpCapabilities?: { http?: unknown } | null;
  sessionCapabilities?: { list?: unknown } | null;
};

export function readCapabilities(response: InitializeResponse): AgentCapabilities {
  const caps = (response.agentCapabilities ?? {}) as RawCapabilities;
  const sessionCaps = caps.sessionCapabilities;
  return {
    protocolVersion: response.protocolVersion,
    loadSession: caps.loadSession !== false,
    listSessions: sessionCaps == null ? true : sessionCaps.list != null,
    httpMcp: caps.mcpCapabilities == null ? true : caps.mcpCapabilities.http !== false,
  };
}

/** 各 agent 最近一次握手的能力；还没握手时按「都支持」处理（与旧行为一致） */
export function createAgentCapabilities() {
  const caps = new Map<AgentKind, AgentCapabilities>();
  return {
    remember: (kind: AgentKind, response: InitializeResponse) => caps.set(kind, readCapabilities(response)),
    of: (kind: AgentKind): AgentCapabilities => caps.get(kind) ?? { protocolVersion: 1, loadSession: true, listSessions: true, httpMcp: true },
  };
}
