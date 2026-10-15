// events.test.ts — 回放用真实 omp acp 录的转录（test/fixtures），断言归一化后的页面事件：
// 思考与消息分开、同一工具调用合并成一段步骤、用量单列、未识别变体跳过；以及 R27 的模型错误归类
import { afterEach, describe, expect, spyOn, test } from "bun:test";
import type { SessionUpdate } from "@agentclientprotocol/sdk";
import { classifyModelError, createTranscript } from "../src/acp/events";
import { fixture, recordedTurn } from "./helpers";

const updates = (name: string): SessionUpdate[] =>
  fixture(name).flatMap((l) => (l.dir === "in" && l.msg.method === "session/update" ? [l.msg.params.update] : []));

function replay(list: SessionUpdate[]) {
  const t = createTranscript();
  const pushed = list.map((u) => t.apply(u)).filter((e) => e !== null);
  return { t, pushed };
}

const errors = spyOn(console, "error");
afterEach(() => errors.mockClear());

describe("live-turn.ndjson：一轮提问卡片 + 审批 + 命令，再一轮被停止", () => {
  const { t, pushed } = replay(updates("live-turn.ndjson"));

  test("缓冲里的事件序列：思考与消息各成一段，工具步骤各一段，用量单列", () => {
    expect(t.events.map((e) => (e.kind === "tool" ? `tool:${e.status}` : e.kind))).toEqual([
      "thought", // 461 个思考块合成一段
      "tool:completed", // ask：tool_call + 1 次更新
      "thought",
      "tool:completed", // bash：tool_call + 3 次更新
      "thought",
      "message",
      "usage",
      "thought", // 第二轮（被停止）
      "message",
    ]);
  });

  test("思考与消息分开：同一 messageId 的思考块与消息块各自合并", () => {
    const [, , , , thought, msg] = t.events as { kind: string; text: string; messageId?: string }[];
    expect(thought.kind).toBe("thought");
    expect(thought.messageId).toBeString();
    expect(thought.messageId).toBe(msg.messageId);
    expect(msg).toMatchObject({ kind: "message", text: "你选择了「甲」，我在当前目录执行 `echo cgc-probe`，输出为 `cgc-probe`。" });
    expect(t.events.at(-1)).toMatchObject({ kind: "message", text: "1\n2\n3\n4\n5" });
  });

  test("推给页面的是增量：每个思考块、消息块一条；工具每次更新推一份合并后的整段步骤", () => {
    const count = (kind: string) => pushed.filter((e) => e.kind === kind).length;
    expect(count("thought")).toBe(461 + 4 + 23 + 33);
    expect(count("message")).toBe(13 + 4);
    expect(count("tool")).toBe(2 + 4);
    expect(count("usage")).toBe(1);
  });

  test("同一 toolCallId 的多条更新合并成一段步骤：标题、类别取最新，输出取最后一次的内容", () => {
    const bash = t.events[3];
    expect(bash).toMatchObject({ kind: "tool", title: "$ echo cgc-probe", toolKind: "execute", status: "completed", input: '{"command":"echo cgc-probe"}' });
    expect((bash as { output?: string }).output).toContain("cgc-probe\n");
    expect(t.events[1]).toMatchObject({ kind: "tool", toolKind: "other", status: "completed", output: "User selected: 甲" });
  });

  test("用量单列：上下文占用与费用", () => {
    expect(t.events[6]).toEqual({ kind: "usage", used: 12840, size: 1000000, cost: { amount: 0.004886082, currency: "USD" } });
  });

  test("认得但不显示的变体（命令清单、会话信息）直接跳过，不记日志", () => {
    expect(pushed).toHaveLength(pushed.filter((e) => ["thought", "message", "tool", "usage"].includes(e.kind)).length);
    expect(errors).not.toHaveBeenCalled();
  });
});

test("未识别的变体跳过并记一条日志（只记类型名），其余事件照常产出", () => {
  const list = updates("live-turn.ndjson").slice(0, 8);
  const unknown = { sessionUpdate: "subagent_update", subagentId: "x", secret: "对话内容" } as unknown as SessionUpdate;
  const { t } = replay([...list.slice(0, 4), unknown, unknown, ...list.slice(4)]);
  expect(t.events).toHaveLength(1);
  expect(t.events[0]).toMatchObject({ kind: "thought" });
  expect(errors).toHaveBeenCalledTimes(1);
  expect(String(errors.mock.calls[0][0])).toContain("subagent_update");
  expect(String(errors.mock.calls[0][0])).not.toContain("对话内容");
});

test("load-replay.ndjson：session/load 回放的历史——用户消息去掉页面上下文块，工具步骤合并", () => {
  const { t } = replay(updates("load-replay.ndjson"));
  expect(t.events.map((e) => (e.kind === "tool" ? `tool:${e.status}` : e.kind))).toEqual([
    "user",
    "thought",
    "tool:completed",
    "thought",
    "tool:completed",
    "thought",
    "message",
    "user",
  ]);
  expect(t.events[0]).toMatchObject({ kind: "user", text: "请用 ask 工具问我一个单选题（选项：甲、乙），我回答后在当前目录运行命令 `echo cgc-probe`，最后用一句话告诉我结果。" });
  expect(t.events[7]).toMatchObject({ kind: "user", text: "从 1 数到 60，每行一个数字，不要调用工具。" });
});

test("停止时还没跑完的工具步骤标为已停止，跑完的不动", () => {
  const t = createTranscript();
  t.apply({ sessionUpdate: "tool_call", toolCallId: "a", title: "读文件", kind: "read", status: "completed" });
  t.apply({ sessionUpdate: "tool_call", toolCallId: "b", title: "$ sleep 60", kind: "execute", status: "pending" });
  t.apply({ sessionUpdate: "tool_call_update", toolCallId: "b", status: "in_progress" });
  expect(t.stopTools()).toEqual([{ kind: "tool", toolCallId: "b", title: "$ sleep 60", toolKind: "execute", status: "stopped" }]);
  expect(t.events.map((e) => e.kind === "tool" && e.status)).toEqual(["completed", "stopped"]);
});

describe("R27 模型错误归类：没有计费用量 + 文本特征", () => {
  test("model-auth-error.ndjson：401 文本、usage_update 照发、应答里没有 usage → auth", () => {
    const { t } = replay(updates("model-auth-error.ndjson"));
    const text = t.events.flatMap((e) => (e.kind === "message" ? [e.text] : [])).join("");
    expect(t.events.some((e) => e.kind === "usage")).toBe(true); // usage_update 不能当信号
    const { response } = recordedTurn("model-auth-error.ndjson");
    expect(response).toEqual({ stopReason: "end_turn" });
    expect(classifyModelError(text, response.usage)).toBe("auth");
  });

  test("live-turn.ndjson：正常回合带计费用量 → 不归类", () => {
    const { response } = recordedTurn("live-turn.ndjson");
    expect(response.usage?.totalTokens).toBeGreaterThan(0);
    expect(classifyModelError("401 Unauthorized 是 HTTP 状态码", response.usage)).toBeUndefined();
  });

  test.each([
    ["429 You exceeded your current quota, please check your plan and billing details.", "quota"],
    ["余额不足，请充值后重试", "quota"],
    ["Error: invalid x-api-key", "auth"],
    ["连接被重置", "unknown"],
    ["", "unknown"],
  ])("没有用量时：%p → %p", (text, kind) => {
    expect(classifyModelError(text, undefined)).toBe(kind as "auth" | "quota" | "unknown");
  });
});
