// cards.test.ts — 审批与提问卡片（R19、R20）：假 OMP 发出录制转录里的真实请求，页面经 WS 作答；
// 断言 OMP 收到的应答结构、谁能作答、刷新后卡片重现、无人在场的收尾从不按允许、非 form 模式被拒
import { afterEach, describe, expect, test } from "bun:test";
import { chatPage, cleanup, connect, CONTEXT, COURSE, fakeAgent, fixture, helloed, pair, type Msg, refused, type Turn, until, USER_A } from "./helpers";

afterEach(cleanup);

type Page = Awaited<ReturnType<typeof helloed>>;
const live = fixture("live-turn.ndjson").map((l) => l.msg);
/** 录制转录里 OMP 发出的那条审批请求（bash，四个选项）与那条提问（ask 工具，form 模式） */
const PERMISSION = live.find((m) => m.method === "session/request_permission")!.params;
const QUESTION = live.find((m) => m.method === "elicitation/create")!.params;

const start = async (page: Page) => {
  await page.call("chat.attach", { courseId: COURSE });
  return page.call("chat.send", { courseId: COURSE, text: "开始", context: CONTEXT });
};
const card = (page: Page) => page.next((m) => m.method === "turn.card");
const answer = (page: Page, params: Record<string, unknown>) => page.call("card.answer", { courseId: COURSE, ...params });

/** 一轮里依次发出 asks（每个等到作答），全部答完后结束回合 */
const asking = (...asks: [method: "session/request_permission" | "elicitation/create", params: object][]) =>
  async (t: Turn) => {
    for (const [method, params] of asks) await t.ask(method, { ...params, sessionId: t.sessionId });
    return { stopReason: "end_turn" as const, usage: { inputTokens: 1, outputTokens: 1, totalTokens: 2 } };
  };

test("AE6 审批卡片：选项原样转交；四个选项各自回填成嵌套的 {outcome: {outcome: selected, optionId}}", async () => {
  const fake = fakeAgent();
  const { page } = await chatPage(fake);
  fake.script = asking(...PERMISSION.options.map(() => ["session/request_permission", PERMISSION] as ["session/request_permission", object]));
  await start(page);
  for (const option of PERMISSION.options) {
    const c = await card(page);
    expect(c.params).toEqual({
      courseId: COURSE,
      cardId: c.params.cardId,
      kind: "permission",
      toolCallId: PERMISSION.toolCall.toolCallId,
      title: "echo cgc-probe",
      toolKind: "execute",
      input: '{"command":"echo cgc-probe"}',
      options: PERMISSION.options,
    });
    expect(await answer(page, { cardId: c.params.cardId, optionId: option.optionId })).toMatchObject({
      method: "turn.card.closed",
      params: { courseId: COURSE, cardId: c.params.cardId, reason: "answered" },
    });
  }
  await page.next((m) => m.method === "turn.end");
  expect(fake.answers).toEqual(PERMISSION.options.map((o: { optionId: string }) => ({ outcome: { outcome: "selected", optionId: o.optionId } })));
  expect(PERMISSION.options.map((o: { kind: string }) => o.kind)).toEqual(["allow_once", "allow_always", "reject_once", "reject_always"]);
});

test("回合结束后才到的审批不开卡：以 cancelled 应答，页面收不到 turn.card", async () => {
  const fake = fakeAgent();
  const { page } = await chatPage(fake);
  let lateAsk: (() => void) | null = null;
  fake.script = async (t) => {
    lateAsk = () => void t.ask("session/request_permission", { sessionId: t.sessionId, toolCall: { toolCallId: "late", title: "late", kind: "execute" }, options: PERMISSION.options });
    return { stopReason: "end_turn", usage: { inputTokens: 1, outputTokens: 1, totalTokens: 2 } };
  };
  await start(page);
  await page.next((m) => m.method === "turn.end");

  lateAsk!();
  await until(() => fake.answers.length === 1);
  expect(fake.answers).toEqual([{ outcome: { outcome: "cancelled" } }]);
  expect(page.inbox.filter((m) => m.method === "turn.card")).toEqual([]);
});

test("AE6 提问卡片：form 的 schema 原样给页面；作答回填 {action, content}，拒绝回填 {action}", async () => {
  const fake = fakeAgent();
  const { page } = await chatPage(fake);
  fake.script = asking(["elicitation/create", QUESTION], ["elicitation/create", QUESTION]);
  await start(page);

  const first = await card(page);
  expect(first.params).toMatchObject({ kind: "question", message: QUESTION.message, schema: QUESTION.requestedSchema });
  expect(await answer(page, { cardId: first.params.cardId, action: "accept", content: { q0: "甲" } })).toMatchObject({ method: "turn.card.closed" });
  const second = await card(page);
  expect(await answer(page, { cardId: second.params.cardId, action: "decline" })).toMatchObject({ method: "turn.card.closed" });
  await page.next((m) => m.method === "turn.end");
  expect(fake.answers).toEqual([{ action: "accept", content: { q0: "甲" } }, { action: "decline" }]);
});

test("不合法的作答回 bad_request，卡片保持原样、还能正常作答；已收起的卡片同样 bad_request", async () => {
  const fake = fakeAgent();
  const { page } = await chatPage(fake);
  fake.script = asking(["session/request_permission", PERMISSION], ["elicitation/create", QUESTION]);
  await start(page);

  const p = await card(page);
  for (const bad of [{ optionId: "allow_everything" }, { optionId: 1 }, {}]) {
    expect(await answer(page, { cardId: p.params.cardId, ...bad })).toMatchObject(refused("bad_request"));
  }
  await answer(page, { cardId: p.params.cardId, optionId: "reject_once" });
  expect(await answer(page, { cardId: p.params.cardId, optionId: "allow_once" })).toMatchObject(refused("bad_request"));

  const q = await card(page);
  for (const bad of [{ action: "accept", content: { other: "x" } }, { action: "accept" }, { action: "accept", content: { q0: { nested: 1 } } }, { action: "maybe" }]) {
    expect(await answer(page, { cardId: q.params.cardId, ...bad })).toMatchObject(refused("bad_request"));
  }
  await answer(page, { cardId: q.params.cardId, action: "accept", content: { q0: "乙", q0__other: "补充" } });
  await page.next((m) => m.method === "turn.end");
  expect(fake.answers).toEqual([{ outcome: { outcome: "selected", optionId: "reject_once" } }, { action: "accept", content: { q0: "乙", q0__other: "补充" } }]);
});

test("只有持有会话的连接能作答：被接管的旧连接作答被拒，新持有者拿到重发的卡片并作答", async () => {
  const fake = fakeAgent();
  const { host, page, browserKey } = await chatPage(fake);
  fake.script = asking(["session/request_permission", PERMISSION]);
  await start(page);
  const c = await card(page);

  const other = await helloed(host, browserKey);
  expect(await other.call("chat.attach", { courseId: COURSE })).toMatchObject({ method: "history", params: { running: true } });
  expect((await card(other)).params.cardId).toBe(c.params.cardId);
  await page.next((m) => m.method === "chat.evicted");

  expect(await answer(page, { cardId: c.params.cardId, optionId: "allow_once" })).toMatchObject(refused("not_holder"));
  expect(await answer(other, { cardId: c.params.cardId, optionId: "reject_once" })).toMatchObject({ method: "turn.card.closed" });
  await other.next((m) => m.method === "turn.end");
  expect(fake.answers).toEqual([{ outcome: { outcome: "selected", optionId: "reject_once" } }]);
});

test("带着未答卡片刷新页面：重新 attach 后卡片重新出现，答了照常生效", async () => {
  const fake = fakeAgent();
  const { host, page, browserKey } = await chatPage(fake);
  fake.script = asking(["elicitation/create", QUESTION]);
  await start(page);
  const c = await card(page);
  await page.close();

  const reloaded = await helloed(host, browserKey);
  const history = await reloaded.call("chat.attach", { courseId: COURSE });
  expect(history.params).toMatchObject({ running: true, events: [{ kind: "user", text: "开始" }] });
  const again = await card(reloaded);
  expect(again.params).toEqual(c.params);
  await answer(reloaded, { cardId: c.params.cardId, action: "accept", content: { q0: "甲" } });
  await reloaded.next((m) => m.method === "turn.end");
  expect(fake.answers).toEqual([{ action: "accept", content: { q0: "甲" } }]);
});

describe("KTD13 无人在场的收尾", () => {
  test("没有页面持有会话、卡片等待超过宽限期：本轮被取消，审批以 cancelled、提问以 cancel 结束，从不按允许", async () => {
    const fake = fakeAgent();
    const { page } = await chatPage(fake, { graceMs: 50 });
    fake.script = async (t: Turn) => {
      void t.ask("session/request_permission", { ...PERMISSION, sessionId: t.sessionId });
      void t.ask("elicitation/create", { ...QUESTION, sessionId: t.sessionId });
      await t.cancelled;
      return { stopReason: "cancelled" };
    };
    await start(page);
    await card(page);
    await card(page);
    await page.close();

    await until(() => fake.answers.length === 2);
    expect(fake.answers).toContainEqual({ outcome: { outcome: "cancelled" } });
    expect(fake.answers).toContainEqual({ action: "cancel" });
    expect(fake.calledWith("session/cancel")).toEqual([{ sessionId: "session-1" }]);
  });

  test("宽限期内有页面重新持有：不收尾，卡片照常等学员作答", async () => {
    const fake = fakeAgent();
    const { host, page, browserKey } = await chatPage(fake, { graceMs: 150 });
    fake.script = asking(["session/request_permission", PERMISSION]);
    await start(page);
    const c = await card(page);
    await page.close();
    const back = await helloed(host, browserKey);
    await back.call("chat.attach", { courseId: COURSE });
    await card(back);
    await Bun.sleep(250);
    expect(fake.answers).toEqual([]);
    await answer(back, { cardId: c.params.cardId, optionId: "allow_once" });
    await until(() => fake.answers.length === 1);
    expect(fake.answers).toEqual([{ outcome: { outcome: "selected", optionId: "allow_once" } }]);
  });
});

test("非 form 模式的提问一律拒绝（decline），不出卡片", async () => {
  const fake = fakeAgent();
  const { page } = await chatPage(fake);
  fake.script = asking(
    ["elicitation/create", { mode: "url", elicitationId: "e1", url: "https://example.com/oauth", message: "打开这个链接授权" }],
    ["elicitation/create", { mode: "telepathy", message: "未知模式" }],
  );
  await start(page);
  await page.next((m) => m.method === "turn.end");
  expect(fake.answers).toEqual([{ action: "decline" }, { action: "decline" }]);
  expect(page.inbox.filter((m: Msg) => m.method === "turn.card")).toEqual([]);
});

// 配对消失或换发密钥后，旧连接仍然开着，但已不再是能回答卡片的持有者。
test.each(["forget", "invalid", "replace"] as const)("配对 %s：释放持有权，已有卡片与之后才出现的卡片都会在宽限期后取消", async (change) => {
  const fake = fakeAgent();
  const { host, page, token, browserKey } = await chatPage(fake, { graceMs: 40 });
  let showLater!: () => void;
  const later = new Promise<void>((resolve) => { showLater = resolve; });
  fake.script = async (t: Turn) => {
    void t.ask("session/request_permission", { ...PERMISSION, sessionId: t.sessionId });
    await later;
    void t.ask("elicitation/create", { ...QUESTION, sessionId: t.sessionId });
    await t.cancelled;
    return { stopReason: "cancelled" };
  };
  await start(page);
  const first = await card(page);
  if (change === "forget") {
    page.send({ method: "pair.forget" });
  } else if (change === "invalid") {
    host.platform.tokens.delete(token);
    const checking = await connect(host.port);
    expect(await checking.call("hello", { userId: USER_A, browserKey })).toMatchObject({ params: { state: "unpaired" } });
  } else {
    await pair(host);
  }
  await page.next((m) => m.method === "status" && m.params.state !== "ready");
  expect(await answer(page, { cardId: first.params.cardId, optionId: "allow_once" })).toMatchObject(refused("unauthorized"));
  showLater();
  await until(() => fake.answers.length === 2);
  expect(fake.answers).toContainEqual({ outcome: { outcome: "cancelled" } });
  expect(fake.answers).toContainEqual({ action: "cancel" });
  expect(fake.calledWith("session/cancel")).toEqual([{ sessionId: "session-1" }]);
  expect(page.inbox.some((m) => m.method === "turn.card" && m.params.kind === "question")).toBe(false);
});

test("换发密钥后新连接重新 attach：恢复持有权，宽限期不取消待答卡片", async () => {
  const fake = fakeAgent();
  const { host, page } = await chatPage(fake, { graceMs: 100 });
  fake.script = asking(["session/request_permission", PERMISSION]);
  await start(page);
  const first = await card(page);
  const paired = await pair(host);
  const back = await helloed(host, paired.browserKey);
  await back.call("chat.attach", { courseId: COURSE });
  expect((await card(back)).params.cardId).toBe(first.params.cardId);
  await Bun.sleep(150);
  expect(fake.answers).toEqual([]);
  await answer(back, { cardId: first.params.cardId, optionId: "reject_once" });
  await back.next((m) => m.method === "turn.end");
  expect(fake.answers).toEqual([{ outcome: { outcome: "selected", optionId: "reject_once" } }]);
});
