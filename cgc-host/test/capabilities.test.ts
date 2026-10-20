// capabilities.test.ts — ACP initialize 能力协商：协议版本 / session load / session list / HTTP MCP。
// 缺字段按「支持」处理（旧适配器兼容）；显式 false / 显式缺 list 才降级。
import { afterEach, describe, expect, test } from "bun:test";
import { loadState, ownerHash, saveState, workDir } from "../src/state";
import { chatPage, cleanup, COURSE, fakeAgent, tempHome, USER_A, USER_B } from "./helpers";

afterEach(cleanup);

/** 预置一条会话指针（模拟 Host 重启后状态文件里的旧指针） */
const seededHome = () => {
  const home = tempHome();
  saveState(home, { pairing: null, sessions: { [COURSE]: { omp: "old-session" } }, agents: {}, sessionOwners: {} });
  return home;
};

describe("协议版本", () => {
  test("initialize 回的协议版本与 Host 不一致：回 chat_unavailable，不建会话", async () => {
    const fake = fakeAgent();
    fake.protocolVersion = 99;
    const { page } = await chatPage(fake);
    expect(await page.call("chat.attach", { courseId: COURSE })).toMatchObject({ method: "error", params: { code: "chat_unavailable" } });
    expect(fake.calledWith("session/new")).toEqual([]);
  });
});

describe("HTTP MCP", () => {
  test("明确不支持 HTTP MCP：回 chat_unavailable（CGC 工具无法下发），日志可诊断", async () => {
    const fake = fakeAgent();
    fake.capabilities = { mcpCapabilities: { http: false } };
    const { page } = await chatPage(fake);
    const errors: string[] = [];
    const orig = console.error;
    console.error = (...args: unknown[]) => void errors.push(args.map(String).join(" "));
    try {
      expect(await page.call("chat.attach", { courseId: COURSE })).toMatchObject({ method: "error", params: { code: "chat_unavailable" } });
    } finally {
      console.error = orig;
    }
    expect(fake.calledWith("session/new")).toEqual([]);
    expect(errors.join("\n")).toContain("HTTP MCP");
  });
});

describe("session/load", () => {
  test("明确不支持 session/load：指针存在也不调用 load，清指针并从新会话开始", async () => {
    const fake = fakeAgent();
    fake.capabilities = { loadSession: false };
    const home = seededHome();
    const { page } = await chatPage(fake, { home });
    expect(await page.call("chat.attach", { courseId: COURSE })).toMatchObject({ method: "history" });
    expect(fake.calledWith("session/load")).toEqual([]);
    expect(fake.calledWith("session/list")).toEqual([]); // 不能 load 时也不必有 list
    expect(fake.calledWith("session/new")).toHaveLength(1);
    expect(loadState(home).sessions[COURSE]?.omp).toBe("session-1"); // 指针换成新建的会话
  });
});

describe("缺能力字段（旧适配器兼容）", () => {
  const seededSession = (home: string) => {
    const cwd = workDir(home, USER_A, COURSE);
    return { cwd, history: [{ sessionUpdate: "user_message_chunk" as const, content: { type: "text" as const, text: "旧对话" } }], updatedAt: new Date().toISOString() };
  };

  test("initialize 完全不带 agentCapabilities：按支持处理，指针照常 load 并回放", async () => {
    const fake = fakeAgent();
    fake.omitAgentCapabilities = true;
    const home = seededHome();
    fake.store.set("old-session", seededSession(home));
    const { page } = await chatPage(fake, { home });
    const history = await page.call("chat.attach", { courseId: COURSE });
    expect(history.method).toBe("history");
    expect(JSON.stringify(history.params.events)).toContain("旧对话");
    expect(fake.calledWith("session/load")).toHaveLength(1);
  });

  test("agentCapabilities 为空对象：同样按支持处理", async () => {
    const fake = fakeAgent();
    fake.capabilities = {};
    const home = seededHome();
    fake.store.set("old-session", seededSession(home));
    const { page } = await chatPage(fake, { home });
    const history = await page.call("chat.attach", { courseId: COURSE });
    expect(history.method).toBe("history");
    expect(JSON.stringify(history.params.events)).toContain("旧对话");
    expect(fake.calledWith("session/load")).toHaveLength(1);
  });
});

describe("换账号后的历史列表", () => {
  test("current 不回别人的指针（Codex review P2）", async () => {
    const fake = fakeAgent();
    fake.capabilities = { mcpCapabilities: { http: false } }; // attach 在清指针之前失败，旧指针留在原地
    const home = tempHome();
    saveState(home, {
      pairing: null,
      sessions: { [COURSE]: { omp: "old-session" } },
      agents: {},
      sessionOwners: { "omp:old-session": ownerHash(USER_B) },
    });
    const { page } = await chatPage(fake, { home });
    expect(await page.call("chat.attach", { courseId: COURSE, agent: "omp" })).toMatchObject({
      method: "error",
      params: { code: "chat_unavailable" },
    });
    // B 的 attach 没走到「清掉别人的指针」那步：列表行被过滤时，current 也不能泄露 A 的 sessionId
    expect(await page.call("chat.sessions", { courseId: COURSE })).toMatchObject({
      method: "sessions",
      params: { sessions: [], current: null },
    });
  });
});

describe("能力门的握手时机", () => {
  test("冷进程上明确无 session/list：chat.sessions 回空列表，从不发 session/list", async () => {
    const fake = fakeAgent();
    fake.capabilities = { sessionCapabilities: {} };
    const { page } = await chatPage(fake);
    // 两帧背靠背：attach 触发握手，sessions 请求排在课程队列之后——能力门必须在握手后判定
    const attaching = page.call("chat.attach", { courseId: COURSE, agent: "omp" });
    const listing = page.call("chat.sessions", { courseId: COURSE });
    expect(await attaching).toMatchObject({ method: "history" });
    expect(await listing).toMatchObject({ method: "sessions", params: { sessions: [] } });
    expect(fake.calledWith("session/list")).toEqual([]);
  });

  test("list 有、load 无：历史列表可见，但 chat.open 回 chat_unavailable", async () => {
    const fake = fakeAgent();
    fake.capabilities = { loadSession: false }; // sessionCapabilities 缺省 = list 支持
    const home = seededHome();
    fake.store.set("old-session", { cwd: workDir(home, USER_A, COURSE), history: [], updatedAt: new Date().toISOString() });
    const { page } = await chatPage(fake, { home });
    await page.call("chat.attach", { courseId: COURSE });
    const list = await page.call("chat.sessions", { courseId: COURSE });
    expect((list.params?.sessions as unknown[]).length).toBeGreaterThan(0);
    expect(await page.call("chat.open", { courseId: COURSE, sessionId: "old-session" })).toMatchObject({
      method: "error",
      params: { code: "chat_unavailable" },
    });
  });
});

describe("session/list", () => {
  test("明确不支持 session/list：历史列表为空、chat.open 回 chat_unavailable、attach 从新会话开始", async () => {
    const fake = fakeAgent();
    fake.capabilities = { sessionCapabilities: {} }; // 对象在、缺 list
    const home = seededHome();
    const { page } = await chatPage(fake, { home });

    // 先 attach：握手后能力才确定，之后 chat.sessions / chat.open 才能按能力降级
    expect(await page.call("chat.attach", { courseId: COURSE })).toMatchObject({ method: "history" });
    expect(await page.call("chat.sessions", { courseId: COURSE })).toMatchObject({
      method: "sessions",
      params: { sessions: [], current: "session-1", nextCursor: null },
    });
    expect(await page.call("chat.open", { courseId: COURSE, sessionId: "old-session" })).toMatchObject({
      method: "error",
      params: { code: "chat_unavailable" },
    });
    expect(fake.calledWith("session/list")).toEqual([]);
    expect(fake.calledWith("session/load")).toEqual([]);
    expect(fake.calledWith("session/new")).toHaveLength(1);
    expect(loadState(home).sessions[COURSE]?.omp).toBe("session-1");
  });
});
