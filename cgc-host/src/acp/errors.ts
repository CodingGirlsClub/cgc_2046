// errors.ts — 会话层的错误形状：一行摘要（只进 Host 日志）与 chat.open 的可诊断失败。
/** 日志脱敏：学习凭证（cgch_）/ 终端 token（cgc_）与 Bearer 头只在日志里留前缀 */
export const redact = (text: string): string =>
  text
    .replace(/\bBearer\s+[^\s"',}]+/gi, "Bearer ***")
    .replace(/\bcgc[h]?_[A-Za-z0-9_-]{6,}/g, (m) => `${m.slice(0, m.indexOf("_") + 1)}***`);

/** 一行错误摘要：message + ACP 错误的 data（诊断详情，如 load 失败的真实原因「Could not restore model …」），超长截断 */
export const message = (e: unknown) => {
  const base = String((e as Error)?.message ?? e);
  const data = (e as { data?: unknown })?.data;
  if (data === undefined) return redact(base);
  let details: string;
  try {
    details = JSON.stringify(data);
  } catch {
    details = String(data);
  }
  return redact(`${base} ${details.length > 500 ? `${details.slice(0, 500)}…` : details}`);
};

/**
 * chat.open 的可诊断失败：
 * - bad_request = 目标不属于本课程工作目录（客户端问题）；
 * - session_unavailable = load 失败（持久指针保持不变）；
 * - busy = 加载期间课程被切到别的 agent（本次切换作废，页面重试）；
 * - chat_unavailable = 该 agent 不支持 load/list（能力协商）。
 */
export class OpenError extends Error {
  constructor(public code: "bad_request" | "session_unavailable" | "busy" | "chat_unavailable") {
    super(code);
  }
}
