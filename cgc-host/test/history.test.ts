// history.test.ts — 历史对话（Session History）：会话列表（归属过滤、元数据、分页）与切换
// （chat.open：事务性——指针只在 load 成功后更新、失败报 session_unavailable 且原会话可用）。
import { afterEach, expect, spyOn, test } from "bun:test";
import { loadState } from "../src/state";
import { chatPage, cleanup, CONTEXT, COURSE, fakeAgent, helloed, refused, type Turn, until } from "./helpers";

afterEach(cleanup);

type Page = Awaited<ReturnType<typeof chatPage>>["page"];
const OTHER_COURSE = "dddddddd-4444-4444-8444-444444444444";
const open = (page: Page, sessionId: unknown) => page.call("chat.open", { courseId: COURSE, sessionId });
const listOf = async (page: Page, cursor?: string) =>
  (await page.call("chat.sessions", { courseId: COURSE, ...(cursor ? { cursor } : {}) })).params as {
    sessions: { sessionId: string; updatedAt: string | null; messageCount: number | null }[];
    current: string | null;
    nextCursor: string | null;
  };
/** attach（幂等）后发一句，等这一轮收尾 */
const say = async (page: Page, text: string, courseId = COURSE) => {
  await page.call("chat.attach", { courseId });
  expect((await page.call("chat.send", { courseId, text, context: CONTEXT })).method).toBe("turn.delta");
  await page.next((m) => m.method === "turn.end");
};

test("chat.sessions：只列本课程工作目录下的会话，带时间与消息数，标出当前会话；其他课程目录不可见", async () => {
  const fake = fakeAgent();
  const { page } = await chatPage(fake);
  await say(page, "问题甲");
  const first = await listOf(page);
  expect(first.sessions).toHaveLength(1);
  expect(first.sessions[0]).toMatchObject({ sessionId: "session-1", messageCount: 1 });
  expect(typeof first.sessions[0].updatedAt).toBe("string");
  expect(first.current).toBe("session-1");

  await page.call("chat.new", { courseId: COURSE });
  await say(page, "乙段");
  const both = await listOf(page);
  expect(both.sessions.map((x) => x.sessionId).sort()).toEqual(["session-1", "session-2"]);
  expect(both.current).toBe("session-2");

  // 另一门课的会话在别的工作目录里，不出现在本课程列表
  await say(page, "别的课", OTHER_COURSE);
  const again = await listOf(page);
  expect(again.sessions.map((x) => x.sessionId).sort()).toEqual(["session-1", "session-2"]);
});

test("chat.sessions：分页游标原样透传，最后一页没有 nextCursor", async () => {
  const fake = fakeAgent();
  fake.listPageSize = 1;
  const { page } = await chatPage(fake);
  await say(page, "甲");
  await page.call("chat.new", { courseId: COURSE });
  await say(page, "乙");
  const p1 = await listOf(page);
  expect(p1.sessions.map((x) => x.sessionId)).toEqual(["session-1"]);
  expect(p1.nextCursor).toBe("1");
  const p2 = await listOf(page, "1");
  expect(p2.sessions.map((x) => x.sessionId)).toEqual(["session-2"]);
  expect(p2.nextCursor).toBeNull();
});

test("chat.open：切回旧会话回放其历史并推进指针；切当前会话不重复 load", async () => {
  const fake = fakeAgent();
  const { host, page } = await chatPage(fake);
  await say(page, "问题甲"); // session-1
  await page.call("chat.new", { courseId: COURSE });
  await say(page, "乙段"); // session-2
  const loadsBefore = fake.calledWith("session/load").length;

  const reply = await open(page, "session-1");
  expect(reply.method).toBe("history");
  const texts = (reply.params.events as { kind: string; text?: string }[]).filter((e) => e.kind === "user").map((e) => e.text);
  expect(texts).toContain("问题甲");
  expect(texts).not.toContain("乙段");
  expect(fake.calledWith("session/load").length).toBe(loadsBefore + 1);
  expect(loadState(host.home).sessions[COURSE]).toBe("session-1");
  expect((await listOf(page)).current).toBe("session-1");

  // 切到当前会话：短接，不再 load
  const again = await open(page, "session-1");
  expect(again.method).toBe("history");
  expect(fake.calledWith("session/load").length).toBe(loadsBefore + 1);
});

test("chat.open：不属于本课程目录的会话 id 回 bad_request（乱写的 id 与非字符串）", async () => {
  const fake = fakeAgent();
  const { page } = await chatPage(fake);
  await say(page, "甲");
  expect(await open(page, "session-999")).toMatchObject(refused("bad_request"));
  expect(await open(page, 42)).toMatchObject(refused("bad_request"));
});

test("chat.open：有回合在跑时拒绝（busy），不动任何状态", async () => {
  const fake = fakeAgent();
  const { page } = await chatPage(fake);
  await say(page, "第一段");
  fake.script = async (t: Turn) => {
    await t.emit({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "长的" } });
    await t.cancelled;
    return { stopReason: "cancelled" };
  };
  await page.call("chat.attach", { courseId: COURSE });
  await page.call("chat.send", { courseId: COURSE, text: "跑起来", context: CONTEXT });
  expect(await open(page, "session-1")).toMatchObject(refused("busy"));
  page.send({ method: "chat.stop", params: { courseId: COURSE } });
  await until(() => fake.calledWith("session/cancel").length === 1);
});

test("chat.open 加载失败：回 session_unavailable、指针不动、原会话仍可继续", async () => {
  const fake = fakeAgent();
  const { host, page, browserKey } = await chatPage(fake);
  await say(page, "问题甲"); // session-1
  await page.call("chat.new", { courseId: COURSE });
  await say(page, "当前这段"); // session-2
  expect(loadState(host.home).sessions[COURSE]).toBe("session-2");

  fake.failLoadFor.add("session-1");
  const errors = spyOn(console, "error");
  expect(await open(page, "session-1")).toMatchObject(refused("session_unavailable"));
  // 原始 ACP 错误（含 data 详情）进日志，便于诊断「为什么打不开」（如 Could not restore model …）
  expect(errors.mock.calls.some((c) => String(c[0]).includes('切换对话失败：Internal error {"details":"fake restore failure"}'))).toBe(true);
  errors.mockRestore();
  expect(loadState(host.home).sessions[COURSE]).toBe("session-2"); // 指针保持

  // 原会话仍可用：新连接（同浏览器密钥）attach 会加载 session-2 并回放“当前这段”
  const back = await helloed(host, browserKey);
  const history = await back.call("chat.attach", { courseId: COURSE });
  expect((history.params.events as { kind: string; text?: string }[]).some((e) => e.kind === "user" && e.text === "当前这段")).toBe(true);
});
