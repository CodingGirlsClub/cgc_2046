// agents.test.ts — agent 注册表与多 agent 的协议面（A 批只有 OMP 一种 kind；Codex 随它自己的记录加入）
import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { createRegistry, type AgentKind } from "../src/agents/registry";
import { clientApp } from "../src/acp/client";
import { stateDir, workDir } from "../src/state";
import { chatPage, cleanup, CONTEXT, COURSE, fakeAgent, tempHome, until, USER_A } from "./helpers";

afterEach(cleanup);

const stateOf = (home: string) => JSON.parse(readFileSync(join(stateDir(home), "state.json"), "utf8"));

describe("agent 注册表", () => {
  test("status 只报记录里的 kind，present 与 envError 取定位器缓存；没有记录就抛错（fail-closed）", () => {
    const registry = createRegistry([
      {
        kind: "omp",
        label: "OMP",
        locator: { locate: async () => ({ path: null, env: {}, envError: "timeout" }), present: () => false, envError: () => "timeout" },
        start: async () => {
          throw new Error("这条用例不该拉起进程");
        },
      },
    ]);
    expect(registry.kinds()).toEqual(["omp"]);
    expect(registry.status()).toEqual([{ kind: "omp", present: false, envError: "timeout" }]);

    // 故意的白名单外取值：注册表必须 fail-closed，而不是回落到某条记录
    const unknown = "plug" as AgentKind;
    const app = clientApp({
      update() {},
      permission: async () => ({ outcome: { outcome: "cancelled" } }),
      question: async () => ({ action: "decline" }),
    });
    expect(() => registry.start(unknown, app, new AbortController().signal)).toThrow("没有 plug 这条 agent 记录");
  });
});

test("缺省走 omp 且不写记忆值；页面显式选过的 agent 才落盘、并随 history 回包给出；未知 agent 一律拒绝", async () => {
  const fake = fakeAgent();
  const { host, page } = await chatPage(fake);

  // 不带 agent（回滚期的旧页面就是这样）：走缺省，且不留下记忆值
  const attached = await page.call("chat.attach", { courseId: COURSE });
  expect(attached).toMatchObject({ method: "history", params: { agent: null } });
  expect(stateOf(host.home).agents[COURSE]).toBeUndefined();

  // 显式选：记进状态文件；下次不带 agent 的 attach 由回包给出它（供页面做初选，不改路由）
  await page.call("chat.attach", { courseId: COURSE, agent: "omp" });
  await until(() => stateOf(host.home).agents[COURSE] === "omp");
  expect(await page.call("chat.attach", { courseId: COURSE })).toMatchObject({ params: { agent: "omp" } });

  // 白名单外（本批还没有 Codex 这条记录）：协议层直接拒，不进对话层
  expect(await page.call("chat.send", { courseId: COURSE, agent: "codex", text: "喂", context: CONTEXT })).toMatchObject({
    method: "error",
    params: { code: "bad_request" },
  });
});

test("旧形状的 state.json 读时迁移：指针转到缺省 agent 下、文件落成新形状、已有对话照常加载", async () => {
  const home = tempHome();
  mkdirSync(stateDir(home), { recursive: true });
  writeFileSync(join(stateDir(home), "state.json"), JSON.stringify({ pairing: null, sessions: { [COURSE]: "session-1" } }));
  const fake = fakeAgent();
  // 这批对话在 agent 侧还在（学员上次聊到一半）
  fake.store.set("session-1", { cwd: workDir(home, USER_A, COURSE), history: [], updatedAt: new Date().toISOString() });

  const { page } = await chatPage(fake, { home });
  expect(await page.call("chat.attach", { courseId: COURSE })).toMatchObject({ method: "history" });

  expect(fake.calledWith("session/load")[0]).toMatchObject({ sessionId: "session-1" }); // 旧指针没丢
  expect(stateOf(home).sessions[COURSE]).toEqual({ omp: "session-1" }); // 已落成新形状
});
