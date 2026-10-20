// Real Host WS + in-process ACP agent; gates hold the two previously leaking async windows.
import { afterEach, expect, test } from "bun:test";
import type { ChatContext } from "../src/server";
import {
  chatPage, cleanup, CONTEXT, COURSE, fakeAgent, fixture, helloed,
  pair, startHost, type Msg, until, USER_A, USER_B,
} from "./helpers";

afterEach(cleanup);

function gate() {
  let release!: () => void;
  const promise = new Promise<void>((resolve) => { release = resolve; });
  return { promise, release };
}

const attach = (page: Awaited<ReturnType<typeof helloed>>) => page.call("chat.attach", { courseId: COURSE });
const ended = (page: Awaited<ReturnType<typeof helloed>>) => page.next((m) => m.method === "turn.end");
const send = (page: Awaited<ReturnType<typeof helloed>>, text: string) =>
  page.call("chat.send", { courseId: COURSE, text, context: CONTEXT });
const chatFrames = (inbox: Msg[]) => inbox.filter((m) => /^(history|turn\.)/.test(m.method));
const permission = fixture("live-turn.ndjson").find((l) => l.msg.method === "session/request_permission")!.msg.params;

test.each([false, true])("pending history cannot cross accounts (reuse socket: %s)", async (reuseSocket) => {
  const fake = fakeAgent();
  const { host, page } = await chatPage(fake);
  await attach(page);
  await send(page, "PRIVATE_USER_A_HISTORY");
  await ended(page);
  const a = await pair(host);
  const loadingPage = await helloed(host, a.browserKey);
  const load = gate();
  let loading = false;
  const request = fake.conn!.agent.request.bind(fake.conn!.agent);
  fake.conn!.agent.request = (async (...args: Parameters<typeof request>) => {
    const result = await request(...args);
    if (args[0] === "session/load") { loading = true; await load.promise; }
    return result;
  }) as typeof request;
  loadingPage.send({ method: "chat.attach", id: "old-history", params: { courseId: COURSE } });
  await until(() => loading);
  try {
    const b = await pair(host, USER_B);
    const pageB = reuseSocket ? loadingPage : await helloed(host, b.browserKey, USER_B);
    if (reuseSocket) {
      expect(await pageB.call("hello", { userId: USER_B, browserKey: b.browserKey })).toMatchObject({ params: { state: "ready" } });
    }
    // Ensure B has reached the handler and replaced the holder before releasing A's load.
    const attaching = attach(pageB);
    expect(await pageB.call("hello", { userId: USER_B, browserKey: b.browserKey })).toMatchObject({ params: { state: "ready" } });
    load.release();
    expect(await attaching).toMatchObject({ method: "history", params: { running: false, events: [] } });
    expect(chatFrames(pageB.inbox)).toEqual([]);
    expect(chatFrames(loadingPage.inbox)).toEqual([]);
  } finally {
    load.release();
  }
});

test("cold start cannot deliver A's send acknowledgement to B after B attaches", async () => {
  const fake = fakeAgent();
  const starting = gate();
  let started = false;
  const start = fake.start;
  fake.start = async (app) => { started = true; await starting.promise; return start(app); };
  const { host, page } = await chatPage(fake);
  // attach 现在自己就会拉起进程：不 await（重新配对后它的 history 回包会作废），先把冷启动挂住再发消息。
  // catch 掉可能的 rejection：这里只关心「发出去了」，回复由后续断言接管，不能让悬空 promise 变成未处理异常。
  void attach(page).catch(() => {});
  page.send({ method: "chat.send", id: "old-send", params: { courseId: COURSE, text: "PRIVATE_USER_A_MESSAGE", context: CONTEXT } });
  await until(() => started);
  try {
    const b = await pair(host, USER_B);
    const pageB = await helloed(host, b.browserKey, USER_B);
    expect(await attach(pageB)).toMatchObject({ method: "error", params: { code: "busy" } });
    starting.release();
    let history: Msg | undefined;
    await until(() => fake.calledWith("session/new").length === 1);
    for (let i = 0; i < 100; i++) {
      history = await attach(pageB);
      if (history.method === "history") break;
      await Bun.sleep(5);
    }
    expect(history).toMatchObject({ method: "history", params: { events: [], running: false } });
    expect(fake.calledWith("session/prompt")).toEqual([]);
    expect(chatFrames(pageB.inbox)).toEqual([]);
    expect(chatFrames(page.inbox)).toEqual([]);
  } finally {
    starting.release();
  }
});

test("same-account takeover keeps pending replies on their original socket", async () => {
  const fake = fakeAgent();
  const starting = gate();
  let started = false;
  const start = fake.start;
  fake.start = async (app) => { started = true; await starting.promise; return start(app); };
  const { host, page, browserKey } = await chatPage(fake);
  // attach 自己会拉起进程：不 await，先让冷启动挂住，再让消息赶在 history 提交之前发出
  const firstAttach = attach(page);
  page.send({ method: "chat.send", id: "original-send", params: { courseId: COURSE, text: "hello", context: CONTEXT } });
  await until(() => started);
  try {
    const other = await helloed(host, browserKey);
    const attaching = attach(other);
    await page.next((m) => m.method === "chat.evicted");
    starting.release();
    await firstAttach; // 同一配对：旧连接的 history 回包照常送达
    await attaching;
    await ended(other);
    expect(await page.next((m) => m.id === "original-send")).toMatchObject({ method: "turn.delta", params: { kind: "user", text: "hello" } });
    expect(other.inbox.some((m) => m.id === "original-send")).toBe(false);
    expect(other.inbox).toContainEqual({ method: "turn.delta", params: { courseId: COURSE, kind: "message", text: "好的" } });
  } finally {
    starting.release();
  }
});

test.each(["old-send", undefined])("same socket re-paired to A drops old-generation replies (id: %s)", async (id) => {
  const fake = fakeAgent();
  const starting = gate();
  let started = false;
  const start = fake.start;
  fake.start = async (app) => { started = true; await starting.promise; return start(app); };
  const { host, page } = await chatPage(fake);
  // attach 自己会拉起进程：不 await（重新配对后它的 history 回包作废），先把冷启动挂住再发消息。
  // catch 掉可能的 rejection：这里只关心「发出去了」，回复由后续断言接管。
  void attach(page).catch(() => {});
  page.send({ method: "chat.send", id, params: { courseId: COURSE, text: "old generation", context: CONTEXT } });
  await until(() => started);
  try {
    const a = await pair(host);
    expect(await page.call("hello", { userId: USER_A, browserKey: a.browserKey })).toMatchObject({ params: { state: "ready" } });
    const attaching = attach(page);
    await page.call("hello", { userId: USER_A, browserKey: a.browserKey });
    starting.release();
    await attaching;
    await ended(page);
    expect(page.inbox.filter((m) => m.method === "turn.delta" && m.params.kind === "user")).toEqual([]);
    expect(page.inbox).toContainEqual({ method: "turn.delta", params: { courseId: COURSE, kind: "message", text: "好的" } });
  } finally {
    starting.release();
  }
});

test.each([false, true])("same-account takeover preserves deltas, cards and turn.end (re-pair: %s)", async (repair) => {
  const fake = fakeAgent();
  const resume = gate();
  fake.script = async (t) => {
    await resume.promise;
    await t.emit({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "after takeover" } });
    await t.ask("session/request_permission", { ...permission, sessionId: t.sessionId });
    return { stopReason: "end_turn" };
  };
  const { host, page, browserKey } = await chatPage(fake);
  await attach(page);
  await send(page, "hello");
  await until(() => fake.calledWith("session/prompt").length === 1);
  const key = repair ? (await pair(host)).browserKey : browserKey;
  const other = await helloed(host, key);
  expect(await attach(other)).toMatchObject({ method: "history", params: { running: true } });
  resume.release();
  expect(await other.next((m) => m.method === "turn.delta")).toMatchObject({ params: { text: "after takeover" } });
  const card = await other.next((m) => m.method === "turn.card");
  expect(await other.call("card.answer", { courseId: COURSE, cardId: card.params.cardId, optionId: "reject_once" }))
    .toMatchObject({ method: "turn.card.closed", params: { reason: "answered" } });
  expect(await ended(other)).toMatchObject({ params: { stopReason: "end_turn" } });
  expect(fake.answers).toEqual([{ outcome: { outcome: "selected", optionId: "reject_once" } }]);
  expect(chatFrames(page.inbox)).toEqual([]);
});

// Retain the handler's old sender to exercise the WS boundary independently of session's cancellation guard.
test.each([USER_A, USER_B])("old push binding stays invalid after a new attach by %s", async (userId) => {
  const contexts: ChatContext[] = [];
  const host = startHost({ chat: (_method, _params, ctx) => {
    contexts.push(ctx);
    ctx.reply({ method: "history", params: { courseId: COURSE, events: [], running: false } });
  } });
  const a = await pair(host);
  const page = await helloed(host, a.browserKey);
  await attach(page);
  const nextPairing = await pair(host, userId);
  await page.call("hello", { userId, browserKey: nextPairing.browserKey });
  await attach(page);
  expect(contexts).toHaveLength(2);
  contexts[0].push({ method: "turn.delta", params: { courseId: COURSE, kind: "message", text: "stale push" } });
  contexts[1].push({ method: "turn.delta", params: { courseId: COURSE, kind: "message", text: "current push" } });
  expect(await page.next((m) => m.params?.text === "current push")).toEqual({
    method: "turn.delta", params: { courseId: COURSE, kind: "message", text: "current push" },
  });
  expect(chatFrames(page.inbox)).toEqual([]);
});

test("unexpected handler failure cannot reply into a new pairing on the same socket", async () => {
  const pending = gate();
  let entered = false;
  const host = startHost({ chat: async (method, _params, ctx) => {
    if (method === "chat.new") {
      entered = true;
      await pending.promise;
      throw new Error("test handler failure");
    }
    ctx.reply({ method: "history", params: { courseId: COURSE, events: [], running: false } });
  } });
  const a = await pair(host);
  const page = await helloed(host, a.browserKey);
  await attach(page);
  page.send({ method: "chat.new", id: "old-error", params: { courseId: COURSE } });
  await until(() => entered);
  try {
    const b = await pair(host, USER_B);
    await page.call("hello", { userId: USER_B, browserKey: b.browserKey });
    pending.release();
    // The new attach reply is a socket-order barrier after the old rejected promise's catch.
    await attach(page);
    expect(page.inbox.some((m) => m.id === "old-error")).toBe(false);
  } finally {
    pending.release();
  }
});
