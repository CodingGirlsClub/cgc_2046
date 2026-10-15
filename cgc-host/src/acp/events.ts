// acp/events.ts — 把 ACP 的 session/update 归一化成页面事件（R9），存进每个会话的有界缓冲：供重连回放，只在内存里（R25）
import type { SessionUpdate, ToolCallContent, Usage } from "@agentclientprotocol/sdk";

export type ToolStatus = "pending" | "in_progress" | "completed" | "failed" | "stopped";
export type ModelError = "auth" | "quota" | "unknown";
export type ToolEvent = {
  kind: "tool";
  toolCallId: string;
  title: string;
  toolKind: string;
  status: ToolStatus;
  input?: string;
  output?: string;
};
/** 页面事件：turn.delta 的载荷与 history 的条目同一形状（cgc-host/AGENTS.md） */
export type ChatEvent =
  | { kind: "user"; text: string; messageId?: string }
  | { kind: "message" | "thought"; text: string; messageId?: string }
  | ToolEvent
  | { kind: "usage"; used: number; size: number; cost?: { amount: number; currency: string } }
  | { kind: "end"; stopReason: string; modelError?: ModelError };

const EVENT_LIMIT = 500; // 缓冲上限（条）：超出丢最早的
const TEXT_LIMIT = 16_000; // 工具的输入、输出各自的字符上限，防止一次大输出撑满内存与帧
// 认得、但对话栏不显示的变体：直接跳过，不记日志
const IGNORED = new Set(["available_commands_update", "current_mode_update", "config_option_update", "session_info_update", "plan"]);
// 未识别的变体每种只记一次日志：只记类型名，不记内容（R25）
const unknownLogged = new Set<string>();

// Host 在消息开头附的页面上下文块（session.ts）。回放的用户消息里会带着它，显示前去掉
const CONTEXT_BLOCK = /^<cgc-page-context>[^<]*<\/cgc-page-context>\s*/;

const clip = (s: string) => (s.length > TEXT_LIMIT ? `${s.slice(0, TEXT_LIMIT)}…` : s);

function contentText(content: ToolCallContent[]): string {
  const parts = content.map((c) => (c.type === "content" ? (c.content.type === "text" ? c.content.text : "") : c.type === "diff" ? `diff: ${c.path}` : ""));
  return clip(parts.filter(Boolean).join("\n"));
}

export type Transcript = ReturnType<typeof createTranscript>;

export function createTranscript() {
  let events: ChatEvent[] = [];
  // toolCallId → 缓冲里的那一段步骤：同一工具调用的后续更新就地合并
  const tools = new Map<string, ToolEvent>();

  function push<E extends ChatEvent>(event: E): E {
    events.push(event);
    for (const dropped of events.splice(0, Math.max(0, events.length - EVENT_LIMIT))) {
      if (dropped.kind === "tool") tools.delete(dropped.toolCallId);
    }
    return event;
  }

  /** 消息、思考、回放的用户消息：与上一条同类且同一 messageId 就接在后面，缓冲里存整段，推给页面的是这次的增量 */
  function chunk(kind: "user" | "message" | "thought", text: string, messageId?: string | null): ChatEvent | null {
    if (!text) return null;
    const id = messageId ?? undefined;
    const last = events.at(-1);
    if (last && last.kind === kind && last.messageId === id) last.text += text;
    else push({ kind, text, messageId: id });
    return { kind, text, messageId: id };
  }

  function tool(u: Extract<SessionUpdate, { sessionUpdate: "tool_call" | "tool_call_update" }>): ToolEvent {
    let step = tools.get(u.toolCallId);
    if (!step) {
      step = push({ kind: "tool", toolCallId: u.toolCallId, title: "", toolKind: "other", status: "pending" });
      tools.set(u.toolCallId, step);
    }
    // tool_call_update 里出现的字段覆盖旧值，缺省（null / undefined）的保持不变
    if (u.title) step.title = u.title;
    if (u.kind) step.toolKind = u.kind;
    if (u.status) step.status = u.status;
    if (u.rawInput !== undefined) step.input = clip(JSON.stringify(u.rawInput) ?? "");
    if (u.content) step.output = contentText(u.content);
    return { ...step };
  }

  return {
    get events(): readonly ChatEvent[] {
      return events;
    },
    /** 新会话或重新加载（session/load 会把历史整段回放一遍）前清空 */
    reset() {
      events = [];
      tools.clear();
    },
    push,
    /** 归一化一条 update 并存进缓冲；返回该推给页面的事件（工具是合并后的整段步骤），跳过的返回 null */
    apply(u: SessionUpdate): ChatEvent | null {
      switch (u.sessionUpdate) {
        case "user_message_chunk":
          return u.content.type === "text" ? chunk("user", u.content.text.replace(CONTEXT_BLOCK, ""), u.messageId) : null;
        case "agent_message_chunk":
          return u.content.type === "text" ? chunk("message", u.content.text, u.messageId) : null;
        case "agent_thought_chunk":
          return u.content.type === "text" ? chunk("thought", u.content.text, u.messageId) : null;
        case "tool_call":
        case "tool_call_update":
          return tool(u);
        case "usage_update":
          return push({ kind: "usage", used: u.used, size: u.size, ...(u.cost && { cost: { amount: u.cost.amount, currency: u.cost.currency } }) });
        default:
          if (!IGNORED.has(u.sessionUpdate) && !unknownLogged.has(u.sessionUpdate)) {
            unknownLogged.add(u.sessionUpdate);
            console.error(`cgc-host: 跳过未识别的 session/update 变体 ${u.sessionUpdate}`);
          }
          return null;
      }
    },
    /** 停止或回合异常结束（R29）：还没跑完的工具步骤标为已停止，返回改动过的步骤；结果以平台为准 */
    stopTools(): ToolEvent[] {
      const stopped = [...tools.values()].filter((s) => s.status === "pending" || s.status === "in_progress");
      for (const s of stopped) s.status = "stopped";
      return stopped.map((s) => ({ ...s }));
    },
  };
}

// R27 的已知错误特征：常见服务商的英文报错与中文服务商的常见措辞
const AUTH = /\b40[13]\b|unauthori[sz]ed|authenticat|invalid[ _-]?(x-)?api[ _-]?key|incorrect api key|api key not valid|no api key|permission[ _]denied|鉴权|认证失败|密钥(无效|错误)/i;
const QUOTA = /\b40[29]\b|insufficient[ _]quota|quota|rate[ _-]?limit|too many requests|billing|credit balance|usage limit|payment required|余额不足|额度|欠费/i;

/**
 * R27 模型错误归类。OMP 把模型调用失败（密钥失效、额度用尽等）当成一段普通的 agent 消息发出，stopReason 仍是 end_turn，
 * 没有结构化信号（实测见 test/fixtures/model-auth-error.ndjson），所以组合两条信号：
 * 1. 本回合没有计费用量：session/prompt 的应答里没有 usage——OMP 只在本回合的 token 用量有增长时才带它。
 *    usage_update 不能当这条信号：它报的是上下文占用的估算，模型调用失败时照样发（同一份实测）。
 * 2. 本回合的 agent 文本命中上面的已知特征：先认认证（auth），再认额度（quota）。
 * 两条都成立才归为 auth / quota，页面换成看得懂的说明；只有第 1 条成立归为 unknown，页面照常显示原文，附一句「可能是模型配置问题」；
 * 有用量就不是模型配置错误，返回 undefined。
 * 局限：
 * - 特征只覆盖常见措辞，新的报错说法会落到 unknown；
 * - 不经过模型的回合（例如学员发了 OMP 的斜杠命令）同样没有用量，也会落到 unknown；
 * - 回合里先有用量、后来才出错（例如调了几轮工具后额度耗尽），第 1 条不成立，错误文本按普通回复显示；
 * - OMP 重启后经 session/load 回放的历史没有回合边界，过去回合的归类不再保留。
 */
export function classifyModelError(text: string, usage: Usage | null | undefined): ModelError | undefined {
  if (usage && usage.totalTokens > 0) return undefined;
  if (AUTH.test(text)) return "auth";
  if (QUOTA.test(text)) return "quota";
  return "unknown";
}
