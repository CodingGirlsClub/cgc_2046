// cgc-play.test.ts — /cgc play 启动路径 + 游戏 socket 桥（事件 → sendUserMessage，game_apply → socket）
//
// 启动路径用注入的 deps 断言命令形状；socket 桥用临时 HOME 下的真实 Unix socket 做行为级测试。

import { afterEach, describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync } from "fs";
import { join } from "path";

const MODULE_PATH = new URL("../extensions/cgc-play.ts", import.meta.url).pathname;

type Call = { method: string; args: unknown[] };

function stubPi() {
  const calls: Call[] = [];
  const tools: Record<string, any> = {};
  const pi = {
    registerCommand: (name: string) => calls.push({ method: "registerCommand", args: [name] }),
    registerTool: (def: any) => {
      tools[def.name] = def;
    },
    sendUserMessage: (msg: string, opts: unknown) => calls.push({ method: "sendUserMessage", args: [msg, opts] }),
  };
  return { pi, calls, tools };
}

function stubCtx() {
  const notes: string[] = [];
  return { ctx: { cwd: "/tmp", ui: { notify: (m: string) => notes.push(m) } }, notes };
}

describe("launchPlay", () => {
  test("在 Herdr 内：从当前 pane 向右 split，再在新 pane 里运行 cgc-play", async () => {
    const { launchPlay } = await import(MODULE_PATH);
    const runs: string[][] = [];
    const { ctx, notes } = stubCtx();
    await launchPlay(ctx, {
      env: { HERDR_ENV: "1", HERDR_PANE_ID: "w1:p1", HERDR_BIN_PATH: "/opt/herdr" },
      which: () => "/usr/local/bin/cgc-play",
      run: (cmd: string[]) => {
        runs.push(cmd);
        return { ok: true, stdout: cmd[2] === "split" ? '{"result":{"pane":{"pane_id":"w1:p9"}}}' : "{}", stderr: "" };
      },
    });
    expect(runs).toEqual([
      ["/opt/herdr", "pane", "split", "w1:p1", "--direction", "right"],
      ["/opt/herdr", "pane", "run", "w1:p9", "/usr/local/bin/cgc-play"],
    ]);
    expect(notes.join()).toContain("已在右侧打开");
  });

  test("不在 Herdr 内：不执行任何命令，提示新开标签页运行 cgc-play", async () => {
    const { launchPlay } = await import(MODULE_PATH);
    const runs: string[][] = [];
    const { ctx, notes } = stubCtx();
    await launchPlay(ctx, { env: {}, which: () => "/usr/local/bin/cgc-play", run: (c: string[]) => (runs.push(c), { ok: true, stdout: "", stderr: "" }) });
    expect(runs).toEqual([]);
    expect(notes.join()).toContain("/usr/local/bin/cgc-play");
    expect(notes.join()).toContain("新开一个终端标签页");
  });

  test("找不到 cgc-play：明确报错，不执行任何命令", async () => {
    const { launchPlay } = await import(MODULE_PATH);
    const runs: string[][] = [];
    const { ctx, notes } = stubCtx();
    await launchPlay(ctx, { env: { HERDR_ENV: "1", HERDR_PANE_ID: "w1:p1" }, which: () => null, run: (c: string[]) => (runs.push(c), { ok: true, stdout: "", stderr: "" }) });
    expect(runs).toEqual([]);
    expect(notes.join()).toContain("没找到 cgc-play");
  });

  test("herdr split 失败：报出 herdr 的错误，不继续 run", async () => {
    const { launchPlay } = await import(MODULE_PATH);
    const runs: string[][] = [];
    const { ctx, notes } = stubCtx();
    await launchPlay(ctx, {
      env: { HERDR_ENV: "1", HERDR_PANE_ID: "w1:p1" },
      which: () => "/bin/cgc-play",
      run: (c: string[]) => (runs.push(c), { ok: false, stdout: "", stderr: "pane not found" }),
    });
    expect(runs.length).toBe(1);
    expect(notes.join()).toContain("pane not found");
  });
});

describe("游戏 socket 桥", () => {
  let home = "";
  let origHome: string | undefined;
  let dispose = () => {};
  let stopServer = () => {};

  afterEach(() => {
    dispose();
    stopServer();
    process.env.HOME = origHome;
    rmSync(home, { recursive: true, force: true });
  });

  // 假游戏端：记录收到的请求，按 NDJSON 回应答；暴露 push 以模拟引擎事件
  function fakeGame() {
    home = mkdtempSync("/tmp/cgc-ext-");
    origHome = process.env.HOME;
    process.env.HOME = home;
    mkdirSync(join(home, ".cgc2046"), { recursive: true });
    const received: any[] = [];
    const peers = new Set<any>();
    const server = Bun.listen({
      unix: join(home, ".cgc2046", "play.sock"),
      socket: {
        open: (s) => void peers.add(s),
        data(s, d) {
          for (const line of d.toString().split("\n").filter(Boolean)) {
            const req = JSON.parse(line);
            received.push(req);
            s.write(JSON.stringify({ id: req.id, ok: req.scene_state !== "dead", ...(req.op === "state" ? { state: { location: "c21" } } : {}) }) + "\n");
          }
        },
      },
    });
    stopServer = () => server.stop(true);
    return { received, peers, push: (e: unknown) => peers.forEach((p) => p.write(JSON.stringify(e) + "\n")) };
  }

  async function until(pred: () => boolean) {
    for (let i = 0; i < 200 && !pred(); i++) await Bun.sleep(10);
    expect(pred()).toBe(true);
  }

  test("注册 game_state / game_apply 两个工具与 /cgc-play 命令", async () => {
    fakeGame();
    const mod = await import(MODULE_PATH);
    const { pi, calls, tools } = stubPi();
    dispose = mod.default(pi).dispose;
    expect(Object.keys(tools).sort()).toEqual(["game_apply", "game_state"]);
    expect(calls).toContainEqual({ method: "registerCommand", args: ["cgc-play"] });
  });

  test("mouth_stage 事件 → sendUserMessage（带关卡、问题与判据，立即起 turn）", async () => {
    const game = fakeGame();
    const mod = await import(MODULE_PATH);
    const { pi, calls } = stubPi();
    dispose = mod.default(pi).dispose;
    await until(() => game.peers.size > 0);
    game.push({ ev: "mouth_stage", location: "c21", checklist: "c21-3", prompt: "你会停氧吗？", judge_questions: ["是否给出不应停氧的结论"] });
    await until(() => calls.some((c) => c.method === "sendUserMessage"));
    const [msg, opts] = calls.find((c) => c.method === "sendUserMessage")!.args as [string, any];
    expect(msg).toContain("c21-3");
    expect(msg).toContain("你会停氧吗？");
    expect(msg).toContain("是否给出不应停氧的结论");
    expect(msg).toContain("game_apply");
    expect(opts).toEqual({ deliverAs: "nextTurn", triggerTurn: true });
  });

  test("game_apply 把请求转发到 socket 并返回游戏的应答", async () => {
    const game = fakeGame();
    const mod = await import(MODULE_PATH);
    const { pi, tools } = stubPi();
    dispose = mod.default(pi).dispose;
    await until(() => game.peers.size > 0);
    const res = await tools.game_apply.execute("t1", { stage_result: { stage: "c21-3", met: true } });
    expect(game.received).toContainEqual(expect.objectContaining({ op: "apply", stage_result: { stage: "c21-3", met: true } }));
    expect(res.isError).toBeFalsy();
    const bad = await tools.game_apply.execute("t2", { scene_state: "dead" });
    expect(bad.isError).toBe(true);
  });

  test("游戏未运行：工具返回错误而不是挂起", async () => {
    home = mkdtempSync("/tmp/cgc-ext-");
    origHome = process.env.HOME;
    process.env.HOME = home;
    const mod = await import(MODULE_PATH);
    const { pi, tools } = stubPi();
    dispose = mod.default(pi).dispose;
    const res = await tools.game_state.execute("t1", {});
    expect(res.isError).toBe(true);
    expect(res.content[0].text).toContain("/cgc play");
  });
});
