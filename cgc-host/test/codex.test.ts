// codex.test.ts — Codex 这条 agent 记录：AGENTS.md 启动语、MCP 服务器改名、登录（auth_required / chat.authenticate）与优雅关闭
import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, readFileSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { realpath } from "node:fs/promises";
import { join } from "node:path";
import { clientApp, GRACEFUL_CLOSE_MS, spawnCodexAcp } from "../src/acp/client";
import { AGENTS_MD_MARKER, CODEX_MCP_SERVER_NAME, codexCommand, writeLearningAgentsMd } from "../src/agents/codex";
import { stateDir, workDir } from "../src/state";
import { chatHost, chatPage, cleanup, codexTestRecord, CONTEXT, COURSE, fakeAgent, helloed, ompTestRecord, pair, tempHome, until, USER_A } from "./helpers";

afterEach(cleanup);

const alive = (pid: number) => {
  try {
    process.kill(pid, 0);
    return true;
  } catch {
    return false;
  }
};

const app = () => clientApp({ update() {}, permission: async () => ({ outcome: { outcome: "cancelled" } }), question: async () => ({ action: "decline" }) });

describe("AGENTS.md 启动语（KTD5）", () => {
  test("幂等：内容不变就不动文件（mtime 不变）；学员写在标记之前的内容原样保留", () => {
    const cwd = tempHome();
    writeLearningAgentsMd(cwd);
    const file = join(cwd, "AGENTS.md");
    const first = readFileSync(file, "utf8");
    expect(first).toContain(AGENTS_MD_MARKER);
    expect(first).toContain("get_role_playbook");

    const mtime = statSync(file).mtimeMs;
    writeLearningAgentsMd(cwd);
    expect(readFileSync(file, "utf8")).toBe(first);
    expect(statSync(file).mtimeMs).toBe(mtime); // 没重写

    // 学员自己在同一个文件里写了笔记（在标记之前）：重写后仍在
    writeFileSync(file, `我的笔记\n\n${first}`);
    writeLearningAgentsMd(cwd);
    const third = readFileSync(file, "utf8");
    expect(third.startsWith("我的笔记")).toBe(true);
    expect(third.indexOf(AGENTS_MD_MARKER)).toBeGreaterThan(third.indexOf("我的笔记"));
    writeLearningAgentsMd(cwd);
    expect(readFileSync(file, "utf8")).toBe(third);
  });
});

describe("codexCommand：不把 Node 变成隐式依赖", () => {
  test("指向 npm 包入口（node shebang 的符号链接）时，用 Host 自己的 Bun 跑真实入口", async () => {
    const dir = tempHome();
    const entry = join(dir, "index.js");
    writeFileSync(entry, "#!/usr/bin/env node\n");
    const bin = join(dir, "codex-acp");
    symlinkSync(entry, bin);
    // 临时目录在 macOS 上本身经 /var → /private/var 这一层符号链接，期望值同样取 realpath
    expect(await codexCommand(bin)).toEqual([process.execPath, await realpath(entry)]);
  });

  test("非 JS 的启动脚本（学员自己包的一层）原样执行", async () => {
    const dir = tempHome();
    const bin = join(dir, "codex-acp");
    writeFileSync(bin, "#!/bin/sh\nexec /opt/codex-acp\n", { mode: 0o700 });
    expect(await codexCommand(bin)).toEqual([bin]);
  });
});

test("两种 agent 各走各的：MCP 服务器名不同、Codex 写课程目录的 AGENTS.md、会话指针各记一条", async () => {
  const omp = fakeAgent();
  const codex = fakeAgent();
  const home = tempHome();
  const { page } = await chatPage(omp, { home, records: [ompTestRecord(omp), codexTestRecord(codex)] });
  await page.call("chat.attach", { courseId: COURSE, agent: "omp" }); // 先当上这门课的持有者（server.ts 的 not_holder 门）

  await page.call("chat.send", { courseId: COURSE, agent: "omp", text: "用 OMP 学", context: CONTEXT });
  await page.next((m) => m.method === "turn.end");
  expect(omp.calledWith("session/new")[0]).toMatchObject({ mcpServers: [{ name: "cgc-2046" }] });

  await page.call("chat.send", { courseId: COURSE, agent: "codex", text: "用 Codex 学", context: CONTEXT });
  await page.next((m) => m.method === "turn.end");
  expect(codex.calledWith("session/new")[0]).toMatchObject({ mcpServers: [{ name: CODEX_MCP_SERVER_NAME }] });
  expect(readFileSync(join(workDir(home, USER_A, COURSE), "AGENTS.md"), "utf8")).toContain(AGENTS_MD_MARKER);

  const sessions = JSON.parse(readFileSync(join(stateDir(home), "state.json"), "utf8")).sessions;
  expect(Object.keys(sessions[COURSE]).sort()).toEqual(["codex", "omp"]);
  expect(omp.calledWith("session/new").length).toBe(1);
  expect(codex.calledWith("session/new").length).toBe(1);
});

test("Codex 未登录：回 auth_required + 登录方式；chat.authenticate 转发给该 agent，成功后回 chat.authenticated", async () => {
  const omp = fakeAgent();
  const codex = fakeAgent();
  const { page } = await chatPage(omp, { records: [ompTestRecord(omp), codexTestRecord(codex)] });
  codex.authMethods = [
    { id: "api-key", name: "API Key" },
    { id: "chat-gpt", name: "ChatGPT" },
  ];
  codex.authFor.add("session/new");
  await page.call("chat.attach", { courseId: COURSE, agent: "codex" }); // 持有者（not_holder 门）

  expect(await page.call("chat.send", { courseId: COURSE, agent: "codex", text: "在吗", context: CONTEXT })).toMatchObject({
    method: "error",
    params: { code: "auth_required", methods: [{ id: "api-key", name: "API Key" }, { id: "chat-gpt", name: "ChatGPT" }] },
  });

  codex.authFails = true;
  expect(await page.call("chat.authenticate", { courseId: COURSE, agent: "codex", methodId: "chat-gpt" })).toMatchObject({
    method: "error",
    params: { code: "auth_failed" },
  });

  codex.authFails = false;
  expect(await page.call("chat.authenticate", { courseId: COURSE, agent: "codex", methodId: "chat-gpt" })).toMatchObject({
    method: "chat.authenticated",
    params: { agent: "codex" },
  });
  expect(codex.calledWith("authenticate")).toEqual([{ methodId: "chat-gpt" }, { methodId: "chat-gpt" }]);

  // 登录成功后再发消息就能真的跑起来
  codex.authFor.clear();
  expect(await page.call("chat.send", { courseId: COURSE, agent: "codex", text: "开始学", context: CONTEXT })).toMatchObject({
    method: "turn.delta",
    params: { kind: "user" },
  });
  await page.next((m) => m.method === "turn.end");
});

test("两个 agent 的第一条会话 id 相同也不串：事件只回到各自那门课", async () => {
  const OTHER = "dddddddd-3333-4333-8333-333333333333";
  const omp = fakeAgent();
  const codex = fakeAgent();
  const host = chatHost(codex, { records: [ompTestRecord(omp), codexTestRecord(codex)] });
  const { browserKey } = await pair(host);
  const pageA = await helloed(host, browserKey); // 课程 A：OMP
  const pageB = await helloed(host, browserKey); // 课程 B：Codex

  await pageA.call("chat.attach", { courseId: COURSE, agent: "omp" });
  await pageB.call("chat.attach", { courseId: OTHER, agent: "codex" });
  await pageA.call("chat.send", { courseId: COURSE, agent: "omp", text: "甲", context: CONTEXT });
  await pageB.call("chat.send", { courseId: OTHER, agent: "codex", text: "乙", context: CONTEXT });

  // 两个 agent 各自的第一条会话都叫 session-1（假 agent 的 id 空间互不相干，真实情况同理）
  expect(omp.calledWith("session/new").length).toBe(1);
  expect(codex.calledWith("session/new").length).toBe(1);

  // 各自的回合都在自己那门课上收尾（串了的话，A 的 turn.end 会被推到 B 的连接上、这里就超时）
  await pageA.next((m) => m.method === "turn.end" && m.params.courseId === COURSE);
  await pageB.next((m) => m.method === "turn.end" && m.params.courseId === OTHER);
});

test("chat.open 遇到需要登录的 agent：原样回 auth_required（不是 session_unavailable）", async () => {
  const omp = fakeAgent();
  const codex = fakeAgent();
  const { page } = await chatPage(omp, { records: [ompTestRecord(omp), codexTestRecord(codex)] });
  await page.call("chat.attach", { courseId: COURSE, agent: "codex" });
  await page.call("chat.send", { courseId: COURSE, agent: "codex", text: "先建一条会话", context: CONTEXT });
  await page.next((m) => m.method === "turn.end");
  await page.call("chat.new", { courseId: COURSE, agent: "codex" }); // 当前会话变成 session-2，下面才会真的去 load

  codex.authFor.add("session/load");
  // 假 agent 的第一条会话就叫 session-1（与真实 OMP/Codex 的不透明 id 同理）
  const opened = await page.call("chat.open", { courseId: COURSE, agent: "codex", sessionId: "session-1" });
  expect(opened).toMatchObject({ method: "error", params: { code: "auth_required" } });
});

describe("关闭（KTD9：优雅优先，SIGKILL 兜底）", () => {
  test("启动阶段被取消也走优雅关闭：子进程收到 stdin EOF 并自己退出（不是被 Bun 直接 SIGKILL）", async () => {
    const dir = tempHome();
    const marker = join(dir, "exited");
    const script = join(dir, "fake-codex-acp");
    writeFileSync(script, '#!/bin/sh\ncat >/dev/null\necho exited > "$MARKER"\n', { mode: 0o700 });

    const abort = new AbortController();
    const a = spawnCodexAcp([script], { MARKER: marker, PATH: "/bin:/usr/bin" }, app(), dir, abort.signal);
    abort.abort(); // 准备阶段超时/取消：不能把 signal 交给 Bun，那会 SIGKILL 掉适配器、留下它的 Codex 子进程
    await until(() => existsSync(marker));
    expect(existsSync(marker)).toBe(true);
    a.close();
  });
  test("关 stdin 后子进程自己退出（写了标记）——不是直接 SIGKILL", async () => {
    const dir = tempHome();
    const marker = join(dir, "exited");
    const script = join(dir, "fake-codex-acp");
    writeFileSync(script, '#!/bin/sh\ncat >/dev/null\necho exited > "$MARKER"\n', { mode: 0o700 });

    const a = spawnCodexAcp([script], { MARKER: marker, PATH: "/bin:/usr/bin" }, app(), dir, new AbortController().signal);
    a.close();
    await until(() => existsSync(marker));
    expect(existsSync(marker)).toBe(true);
  });

  test("宽限期内没退（忽略 stdin EOF）就 SIGKILL 收掉，不留孤儿", async () => {
    const dir = tempHome();
    const pidFile = join(dir, "pid");
    const script = join(dir, "fake-codex-acp");
    writeFileSync(script, '#!/bin/sh\ntrap "" TERM\necho $$ > "$PID"\nexec /bin/sleep 60\n', { mode: 0o700 });

    const a = spawnCodexAcp([script], { PID: pidFile, PATH: "/bin:/usr/bin" }, app(), dir, new AbortController().signal);
    await until(() => existsSync(pidFile));
    const pid = Number(readFileSync(pidFile, "utf8").trim());
    expect(alive(pid)).toBe(true);

    a.close();
    await until(() => !alive(pid), GRACEFUL_CLOSE_MS + 2_000);
    expect(alive(pid)).toBe(false);
  });
});
