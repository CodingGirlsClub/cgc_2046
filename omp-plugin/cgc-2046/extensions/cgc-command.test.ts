// cgc-command.test.ts — /cgc 工作目录守卫的行为级测试
//
// 用 stub pi/ctx 驱动构建产物，断言：
//   - 不在工作目录时：ask 引导的 sendUserMessage 被调用（ask 提示词注入）
//   - 在工作目录时：汇总渲染的 sendUserMessage 被调用（正常流程）
// 变异验证：守卫禁用后（if (false)），不在工作目录时不再触发 ask 引导

import { describe, test, expect } from "bun:test";

interface StubCall {
  method: string;
  args: unknown[];
}

interface StubPi {
  registerCommand(name: string, def: { handler: Handler }): void;
  getAllTools(): Array<{ name: string }>;
  sendUserMessage(msg: string, opts: unknown): void;
  _calls: StubCall[];
  _handler: Handler | null;
}

interface StubCtx {
  cwd: string;
  ui: { notify(): void };
  getAllTools(): Array<{ name: string }>;
}

type Handler = (args: unknown, ctx: StubCtx) => Promise<void>;

const MODULE_PATH = new URL("../extensions/cgc-command.ts", import.meta.url).pathname;

function createStubPi(): StubPi {
  const calls: StubCall[] = [];
  const pi: StubPi = {
    registerCommand: (name, def) => {
      calls.push({ method: "registerCommand", args: [name] });
      pi._handler = def.handler;
    },
    getAllTools: () => [],
    sendUserMessage: (msg, opts) => {
      calls.push({ method: "sendUserMessage", args: [msg, opts] });
    },
    _calls: calls,
    _handler: null,
  };
  return pi;
}

function createStubCtx(cwd: string, tools: Array<{ name: string }>): StubCtx {
  return {
    cwd,
    ui: { notify: () => {} },
    getAllTools: () => tools,
  };
}

async function runHandler(pi: StubPi, ctx: StubCtx): Promise<void> {
  if (!pi._handler) throw new Error("handler not registered");
  await pi._handler(undefined, ctx);
}

const CGC_TOOLS = [
  { name: "mcp__cgc_2046_list_my_workspaces" },
  { name: "mcp__cgc_2046_confirm_operation" },
];

describe("/cgc workspace guard", () => {
  test("不在工作目录：触发 ask 引导（sendUserMessage 含「创建并切换」）", async () => {
    const mod = await import(MODULE_PATH);
    const pi = createStubPi();
    (mod as { default: (pi: StubPi) => void }).default(pi);
    const ctx = createStubCtx("/some/random/dir", CGC_TOOLS);
    await runHandler(pi, ctx);

    const sendCalls = pi._calls.filter(c => c.method === "sendUserMessage");
    expect(sendCalls.length).toBeGreaterThan(0);
    const msg = sendCalls[0].args[0] as string;
    expect(msg).toContain("创建并切换");
    expect(msg).toContain("不在 CGC 工作目录");
  });

  test("在工作目录：正常渲染汇总（sendUserMessage 含「状态汇总」而非「创建并切换」）", async () => {
    const mod = await import(MODULE_PATH);
    const pi = createStubPi();
    (mod as { default: (pi: StubPi) => void }).default(pi);
    const ctx = createStubCtx("/Users/test/cgc2046_workspace", CGC_TOOLS);
    await runHandler(pi, ctx);

    const sendCalls = pi._calls.filter(c => c.method === "sendUserMessage");
    expect(sendCalls.length).toBeGreaterThan(0);
    const msg = sendCalls[0].args[0] as string;
    expect(msg).toContain("状态汇总");
    expect(msg).not.toContain("创建并切换");
  });

  test("未连接：不触发 sendUserMessage（notify 显示未连接）", async () => {
    const mod = await import(MODULE_PATH);
    const pi = createStubPi();
    (mod as { default: (pi: StubPi) => void }).default(pi);
    const ctx = createStubCtx("/some/dir", []);
    await runHandler(pi, ctx);

    const sendCalls = pi._calls.filter(c => c.method === "sendUserMessage");
    expect(sendCalls.length).toBe(0);
  });
});

describe("/cgc version check", () => {
  // fixture HOME：构造 ~/.omp/plugins/ 目录结构，process.env.HOME 指向它
  function setupFixtureHome(installedVersion: string, catalogVersion: string): string {
    const { mkdirSync, writeFileSync, rmSync } = require("fs");
    const home = `/tmp/cgc-version-test-${Date.now()}`;
    const pluginsDir = `${home}/.omp/plugins`;
    const catalogDir = `${pluginsDir}/cache/marketplaces/cgc-omp-plugins/.omp-plugin`;
    mkdirSync(catalogDir, { recursive: true });

    // installed_plugins.json
    writeFileSync(
      `${pluginsDir}/installed_plugins.json`,
      JSON.stringify({
        version: 2,
        plugins: [
          { name: "cgc-2046", marketplace: "cgc-omp-plugins", version: installedVersion },
        ],
      }),
    );

    // catalog cache marketplace.json
    writeFileSync(
      `${catalogDir}/marketplace.json`,
      JSON.stringify({
        name: "cgc-omp-plugins",
        plugins: [{ name: "cgc-2046", version: catalogVersion }],
      }),
    );

    return home;
  }

  function cleanupFixtureHome(home: string): void {
    const { rmSync } = require("fs");
    rmSync(home, { recursive: true, force: true });
  }

  test("版本不一致：notify 含更新提示（有新版本可用）", async () => {
    const home = setupFixtureHome("0.1.4", "0.1.5");
    const origHome = process.env.HOME;
    process.env.HOME = home;

    try {
      const notifyMessages: string[] = [];
      const mod = await import(MODULE_PATH);
      const pi = createStubPi();
      // 拦截 notify 收集消息
      const origPi = pi;
      (mod as { default: (pi: StubPi) => void }).default(pi);
      const ctx = createStubCtx(`${home}/cgc2046_workspace`, CGC_TOOLS);
      // 临时替换 ctx.ui.notify 收集消息
      (ctx as Record<string, unknown>).ui = {
        notify: (msg: string) => { notifyMessages.push(msg); },
      };
      await runHandler(pi, ctx);

      // checkVersion 依赖 os.homedir()——Bun 下 os.homedir() 读 $HOME on Unix
      // 由于我们改了 process.env.HOME，os.homedir() 应返回 fixture home
      const hasUpdateHint = notifyMessages.some(m => m.includes("有新版本可用"));
      expect(hasUpdateHint).toBe(true);
    } finally {
      process.env.HOME = origHome;
      cleanupFixtureHome(home);
    }
  });

  test("版本一致：notify 无更新提示", async () => {
    const home = setupFixtureHome("0.1.5", "0.1.5");
    const origHome = process.env.HOME;
    process.env.HOME = home;

    try {
      const notifyMessages: string[] = [];
      const mod = await import(MODULE_PATH);
      const pi = createStubPi();
      (mod as { default: (pi: StubPi) => void }).default(pi);
      const ctx = createStubCtx(`${home}/cgc2046_workspace`, CGC_TOOLS);
      (ctx as Record<string, unknown>).ui = {
        notify: (msg: string) => { notifyMessages.push(msg); },
      };
      await runHandler(pi, ctx);

      const hasUpdateHint = notifyMessages.some(m => m.includes("有新版本可用"));
      expect(hasUpdateHint).toBe(false);
    } finally {
      process.env.HOME = origHome;
      cleanupFixtureHome(home);
    }
  });
});
