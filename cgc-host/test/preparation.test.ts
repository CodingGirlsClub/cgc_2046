import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { chatPage, cleanup, CONTEXT, COURSE, fakeAgent, helloed, until } from "./helpers";
import { stateDir } from "../src/state";

afterEach(cleanup);
const OTHER = "dddddddd-3333-4333-8333-333333333333";
function gate() {
  let release!: () => void;
  const promise = new Promise<void>((r) => { release = r; });
  return { promise, release };
}
const pointers = (home: string) => JSON.parse(readFileSync(join(stateDir(home), "state.json"), "utf8")).sessions;
const send = (page: Awaited<ReturnType<typeof helloed>>, text: string, courseId = COURSE) =>
  page.call("chat.send", { courseId, text, context: CONTEXT });
const ended = (page: Awaited<ReturnType<typeof helloed>>, courseId = COURSE) => page.next((m) => m.method === "turn.end" && m.params.courseId === courseId);

function stalledAgent(stage: string) {
  const fake = fakeAgent(), blocked = gate();
  const start = fake.start;
  const control = { armed: true, entered: false, returned: false, attempts: 0, blockedAttempt: 0, closed: [] as number[], blockedSignal: null as AbortSignal | null };
  fake.start = async (app, signal?: AbortSignal) => {
    const attempt = ++control.attempts;
    const hold = stage === "spawn" && control.armed;
    if (hold) { control.armed = false; control.entered = true; control.blockedAttempt = attempt; control.blockedSignal = signal ?? null; await blocked.promise; }
    const a = await start(app);
    const close = a.close;
    a.close = () => { control.closed.push(attempt); close(); };
    const request = a.rpc.request.bind(a.rpc);
    a.rpc.request = (async (...args: Parameters<typeof request>) => {
      const hold = args[0] === stage && control.armed;
      if (hold) { control.armed = false; control.entered = true; control.blockedAttempt = attempt; control.blockedSignal = args[2]?.cancellationSignal ?? null; }
      const result = await request(...args);
      // Deliberately ignore cancellation and return a late success, like an uncooperative peer.
      if (hold) { await blocked.promise; control.returned = true; }
      return result;
    }) as typeof request;
    if (hold) control.returned = true;
    return a;
  };
  return { fake, blocked, control };
}

test.each(["spawn", "initialize", "session/list", "session/load", "session/new"])("bounded %s: late success cannot prompt, overwrite retry state, or close the new agent", async (stage) => {
  const { fake, blocked, control } = stalledAgent(stage);
  control.armed = false;
  const { host, page } = await chatPage(fake, { preparationTimeoutMs: 80 });
  await page.call("chat.attach", { courseId: COURSE });
  if (stage === "session/list" || stage === "session/load") {
    await send(page, "seed history");
    await ended(page);
    const old = fake.conn!;
    old.close();
    await old.closed;
  }
  control.armed = true;
  const pending = send(page, "MUST_NOT_RUN");
  await until(() => control.entered);
  try {
    const result = await Promise.race([pending, Bun.sleep(500).then(() => ({ method: "missing-timeout" }))]);
    expect(result).toMatchObject({ method: "error", params: { code: "chat_unavailable" } });
    expect(control.blockedSignal?.aborted).toBe(true);
    expect(await page.call("chat.attach", { courseId: COURSE })).toMatchObject({ method: "history", params: { running: false } });
    await send(page, "retry succeeds");
    await ended(page);
    const retryAttempt = control.attempts;
    const saved = pointers(host.home);
    blocked.release();
    await until(() => control.returned);
    await page.call("chat.attach", { courseId: COURSE });
    expect(pointers(host.home)).toEqual(saved);
    expect(control.closed).toContain(control.blockedAttempt);
    expect(control.closed).not.toContain(retryAttempt);
    await send(page, "still works");
    await ended(page);
    expect(fake.calledWith("session/prompt").some((p) => JSON.stringify(p.prompt).includes("MUST_NOT_RUN"))).toBe(false);
    expect(fake.calledWith("session/prompt").some((p) => JSON.stringify(p.prompt).includes("retry succeeds"))).toBe(true);
  } finally {
    blocked.release();
    await pending;
  }
});

test("a preparation timeout resets the shared agent, ends other active turns, and both courses can retry", async () => {
  const { fake, blocked, control } = stalledAgent("session/new");
  control.armed = false;
  const active = gate();
  fake.script = async (t) => {
    if (JSON.stringify(t.prompt).includes("active course")) await active.promise;
    return { stopReason: "end_turn" };
  };
  const { host, page, browserKey } = await chatPage(fake, { preparationTimeoutMs: 80 });
  await page.call("chat.attach", { courseId: COURSE });
  await send(page, "active course");
  const other = await helloed(host, browserKey);
  await other.call("chat.attach", { courseId: OTHER });
  control.armed = true;
  const pending = send(other, "MUST_NOT_RUN", OTHER);
  await until(() => control.entered);
  try {
    expect(await Promise.race([pending, Bun.sleep(500).then(() => ({ method: "missing-timeout" }))]))
      .toMatchObject({ method: "error", params: { code: "chat_unavailable" } });
    expect(await ended(page)).toMatchObject({ params: { stopReason: "error" } });
    await other.call("chat.attach", { courseId: OTHER });
    await send(other, "retry B", OTHER);
    expect(await ended(other, OTHER)).toMatchObject({ params: { stopReason: "end_turn" } });
    await page.call("chat.attach", { courseId: COURSE });
    await send(page, "retry A");
    expect(await ended(page)).toMatchObject({ params: { stopReason: "end_turn" } });
    const saved = pointers(host.home), retryAttempt = control.attempts;
    blocked.release(); active.release();
    await until(() => control.returned);
    await other.call("chat.attach", { courseId: OTHER });
    expect(pointers(host.home)).toEqual(saved);
    expect(control.closed).not.toContain(retryAttempt);
    expect(fake.calledWith("session/prompt").some((p) => JSON.stringify(p.prompt).includes("MUST_NOT_RUN"))).toBe(false);
  } finally {
    blocked.release(); active.release();
    await pending;
  }
});

test.each(["chat.attach", "chat.new"] as const)("%s also times out without a late history reply or pointer overwrite", async (method) => {
  const { fake, blocked, control } = stalledAgent(method === "chat.attach" ? "session/load" : "session/new");
  control.armed = false;
  const { host, page } = await chatPage(fake, { preparationTimeoutMs: 80 });
  await page.call("chat.attach", { courseId: COURSE });
  if (method === "chat.attach") {
    await send(page, "seed"); await ended(page);
    const old = fake.conn!; old.close(); await old.closed;
  }
  control.armed = true;
  const pending = page.call(method, { courseId: COURSE });
  await until(() => control.entered);
  try {
    expect(await pending).toMatchObject({ method: "error", params: { code: "chat_unavailable" } });
    expect(await page.call(method, { courseId: COURSE })).toMatchObject({ method: "history" });
    const saved = pointers(host.home);
    blocked.release();
    await until(() => control.returned);
    await page.call("chat.attach", { courseId: COURSE });
    expect(pointers(host.home)).toEqual(saved);
    expect(page.inbox.filter((m) => m.method === "history")).toEqual([]);
  } finally { blocked.release(); await pending; }
});
