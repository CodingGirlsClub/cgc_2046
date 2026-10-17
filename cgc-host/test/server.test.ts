// server.test.ts — HTTP 与 WS 入口：/health、帧信封、方法白名单、未配对连接的限制、课程持有者、单实例
import { afterEach, describe, expect, test } from "bun:test";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { hostname, tmpdir } from "node:os";
import { join } from "node:path";
import protocol from "../protocol.json";
import { HOST_VERSION, PORT, SITE_ORIGIN } from "../src/config";
import { sanitizeDeviceName } from "../src/security";
import { PAGE_METHODS } from "../src/server";
import { COURSE, cleanup, connect, helloed, HOST_ROOT, identity, pair, refused, startHost, USER_A } from "./helpers";

afterEach(cleanup);

const OPEN = ["hello", "pair.request", "pair.cancel"];

test("分发白名单与 protocol.json 的 pageToHost 完全一致", () => {
  expect(new Set(PAGE_METHODS)).toEqual(new Set(protocol.methods.pageToHost));
});

describe("/health", () => {
  test("返回 {version, ompPresent, paired, agents, capabilities}，CORS 只给站点来源", async () => {
    const host = startHost({ agents: () => [{ kind: "omp", present: true }] });
    const get = () => fetch(`http://127.0.0.1:${host.port}/health`, { headers: { Origin: SITE_ORIGIN } });
    const res = await get();
    expect(res.status).toBe(200);
    expect(res.headers.get("access-control-allow-origin")).toBe(SITE_ORIGIN);
    expect(res.headers.get("vary")).toBe("Origin");
    expect(await res.json()).toEqual({ version: HOST_VERSION, ompPresent: true, paired: false, agents: [{ kind: "omp", present: true }], capabilities: [] });

    await pair(host);
    expect(await (await get()).json()).toMatchObject({ paired: true });
  });

  test("CORS 预检只对站点来源应答", async () => {
    const { port } = startHost();
    const preflight = (origin: string) =>
      fetch(`http://127.0.0.1:${port}/health`, { method: "OPTIONS", headers: { Origin: origin, "Access-Control-Request-Method": "GET" } });
    const ok = await preflight(SITE_ORIGIN);
    expect(ok.status).toBe(204);
    expect(ok.headers.get("access-control-allow-origin")).toBe(SITE_ORIGIN);
    expect(ok.headers.get("vary")).toBe("Origin");
    expect((await preflight("https://evil.example")).status).toBe(403);
  });

  test("只有 GET /health 与根路径的 WS 升级，其余 404", async () => {
    const { port } = startHost();
    for (const [method, path] of [["GET", "/"], ["GET", "/status"], ["POST", "/health"]]) {
      const res = await fetch(`http://127.0.0.1:${port}${path}`, { method, headers: { Origin: SITE_ORIGIN } });
      expect(res.status).toBe(404);
    }
  });
});

test("连接后先推送 status：未配对的连接也读得到", async () => {
  const host = startHost({ agents: () => [{ kind: "omp", present: true }] });
  const c = await connect(host.port);
  expect(await c.next((m) => m.method === "status")).toEqual({
    method: "status",
    params: {
      state: "unpaired",
      pairedUserId: null,
      pairedDisplayName: null,
      deviceName: sanitizeDeviceName(hostname()),
      tokenId: null,
      ompPresent: true,
      agents: [{ kind: "omp", present: true }],
      capabilities: [],
      version: HOST_VERSION,
      protocolVersion: protocol.protocolVersion,
    },
  });

  const { tokenId } = await pair(host);
  const other = await connect(host.port);
  expect(await other.next((m) => m.method === "status")).toMatchObject({
    params: { state: "paired", pairedUserId: USER_A, pairedDisplayName: "学员甲", tokenId },
  });
});

test("未知方法与坏帧一律拒绝，不产生任何副作用", async () => {
  const host = startHost();
  const c = await connect(host.port);
  for (const method of ["status", "pair.result", "__proto__", "constructor", "toString", "hasOwnProperty", "eval"]) {
    expect(await c.call(method, { token: "cgch_x", courseId: COURSE })).toMatchObject(refused("unknown_method"));
  }
  for (const frame of ["not json", "[]", "null", JSON.stringify({ method: 1 }), JSON.stringify({ method: "hello", id: 7 }), JSON.stringify({ method: "hello", params: [] })]) {
    c.send(frame);
    expect(await c.next((m) => m.method === "error")).toEqual({ method: "error", params: { code: "bad_request" } });
  }
  expect(host.dialog.calls).toEqual([]);
  expect(host.platform.calls).toEqual([]);
  expect(host.chatCalls).toEqual([]);
});

test("R24. 未配对的连接只能 hello / pair.request / pair.cancel：chat.send 被拒，pair.request 被受理", async () => {
  const host = startHost();
  const c = await connect(host.port);
  for (const method of PAGE_METHODS.filter((m) => !OPEN.includes(m))) {
    expect(await c.call(method, { courseId: COURSE })).toMatchObject(refused("unauthorized"));
  }
  expect(host.chatCalls).toEqual([]);

  host.platform.tokens.set("cgch_unpaired", identity(USER_A, "token-id-x"));
  expect(await c.call("pair.request", { token: "cgch_unpaired" })).toMatchObject({ method: "pair.result", params: { allowed: false } });
  expect(host.dialog.calls).toHaveLength(1);
});

test("courseId 不是 UUID（如 ../../etc）时拒绝，处理器不被调用，也不产生路径", async () => {
  const host = startHost();
  const { browserKey } = await pair(host);
  const c = await helloed(host, browserKey);
  for (const courseId of ["../../etc", `${COURSE}/../x`, 42, undefined]) {
    expect(await c.call("chat.attach", { courseId })).toMatchObject(refused("bad_request"));
  }
  expect(host.chatCalls).toEqual([]);
  expect(existsSync(join(host.home, "cgc2046_workspace"))).toBe(false);
});

test("R12. 同一门课两个连接：后到者持有，先到者收到 chat.evicted、不能再发", async () => {
  const host = startHost();
  const { browserKey } = await pair(host);
  const first = await helloed(host, browserKey);
  const second = await helloed(host, browserKey);

  expect(await first.call("chat.attach", { courseId: COURSE })).toMatchObject(refused("chat_unavailable"));
  expect(await second.call("chat.attach", { courseId: COURSE })).toMatchObject(refused("chat_unavailable"));
  expect(await first.next((m) => m.method === "chat.evicted")).toEqual({ method: "chat.evicted", params: { courseId: COURSE } });

  expect(await first.call("chat.send", { courseId: COURSE, text: "先到者" })).toMatchObject(refused("not_holder"));
  expect(await second.call("chat.send", { courseId: COURSE, text: "后到者" })).toMatchObject(refused("chat_unavailable"));
  expect(host.chatCalls.map((x) => [x.method, x.params.text])).toEqual([
    ["chat.attach", undefined],
    ["chat.attach", undefined],
    ["chat.send", "后到者"],
  ]);
});

test("端口被占：判定已有实例在跑，记下原因并以 0 退出（launchd 不反复拉起）", () => {
  let blocker: ReturnType<typeof Bun.serve> | undefined;
  try {
    blocker = Bun.serve({ hostname: "127.0.0.1", port: PORT, fetch: () => new Response(null) });
  } catch {} // 端口已被别的进程（例如本机正跑着的 Host）占着，前提同样成立
  const home = mkdtempSync(join(tmpdir(), "cgc-host-main-"));
  try {
    const r = Bun.spawnSync([process.execPath, "src/main.ts", "serve"], { cwd: HOST_ROOT, env: { ...process.env, HOME: home }, timeout: 10_000 });
    expect(r.stderr.toString()).toContain("已被占用");
    expect(r.exitCode).toBe(0);
  } finally {
    blocker?.stop(true);
    rmSync(home, { recursive: true, force: true });
  }
});

describe("一键安装（期 2 / R2）", () => {
  const INSTALL_CAPS = ["agent.install"];

  test("能力只在声明时出现：/health 与 status 都带上它", async () => {
    const host = startHost({ capabilities: INSTALL_CAPS });
    const res = await fetch(`http://127.0.0.1:${host.port}/health`, { headers: { Origin: SITE_ORIGIN } });
    expect(await res.json()).toMatchObject({ capabilities: INSTALL_CAPS });

    // status（hello 的应答）也带着它：页面据此决定给不给「安装」入口
    const { browserKey } = await pair(host);
    const c = await helloed(host, browserKey);
    const status = await c.call("hello", { userId: USER_A, browserKey });
    expect(status.params.capabilities).toEqual(INSTALL_CAPS);
  });

  test("agent.install：先回 started，再推进度与结果；装完刷新定位器并推 status", async () => {
    let refreshed = false;
    const host = startHost({
      capabilities: INSTALL_CAPS,
      agents: () => [{ kind: "codex", present: refreshed }],
      install: async (_kind, progress) => {
        progress("installing");
        await Bun.sleep(10);
        refreshed = true;
        return { version: "2.2.2" };
      },
      refresh: async () => {
        refreshed = true;
      },
    });
    const { browserKey } = await pair(host);
    const c = await helloed(host, browserKey);

    expect(await c.call("agent.install", { kind: "codex" })).toMatchObject({ method: "agent.install.started", params: { started: true } });
    expect(await c.next((m) => m.method === "agent.install.progress")).toMatchObject({
      method: "agent.install.progress",
      params: { kind: "codex", phase: "installing" },
    });
    expect(await c.next((m) => m.method === "agent.done")).toMatchObject({
      method: "agent.done",
      params: { kind: "codex", ok: true, version: "2.2.2" },
    });
    // 装完的 status 让页面不必自己猜：codex 已 present
    const status = await c.next((m) => m.method === "status" && (m.params?.agents as { kind: string; present: boolean }[] | undefined)?.some((a) => a.kind === "codex" && a.present) === true);
    expect(status.params.agents).toEqual([{ kind: "codex", present: true }]);
  });

  test("安装失败：done 带错误码（InstallError 的 code 原样回给页面）", async () => {
    const { InstallError } = await import("../src/agents/install");
    const host = startHost({
      capabilities: INSTALL_CAPS,
      install: async () => {
        throw new InstallError("version_mismatch", "x");
      },
      refresh: async () => {},
    });
    const { browserKey } = await pair(host);
    const c = await helloed(host, browserKey);
    await c.call("agent.install", { kind: "codex" });
    expect(await c.next((m) => m.method === "agent.done")).toMatchObject({ params: { ok: false, code: "version_mismatch" } });
  });

  test("并发安装拿 busy；没声明能力拿 unsupported；kind 不认识拿 bad_request", async () => {
    const host = startHost({
      capabilities: INSTALL_CAPS,
      install: () => new Promise(() => {}), // 永不结束：占住安装位
      refresh: async () => {},
    });
    const { browserKey } = await pair(host);
    const c = await helloed(host, browserKey);
    await c.call("agent.install", { kind: "codex" });
    expect(await c.call("agent.install", { kind: "codex" })).toMatchObject({ method: "error", params: { code: "busy" } });
    expect(await c.call("agent.install", { kind: "nope" })).toMatchObject({ method: "error", params: { code: "bad_request" } });

    const plain = startHost({});
    const p = await pair(plain);
    const pc = await helloed(plain, p.browserKey);
    expect(await pc.call("agent.install", { kind: "codex" })).toMatchObject({ method: "error", params: { code: "unsupported" } });
  });
});
