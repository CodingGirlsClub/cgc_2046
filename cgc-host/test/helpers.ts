// helpers.ts — 测试共用：真实 Bun.serve 上的 Host（临时 HOME）、假平台（/mcp/token）、可编排的弹窗、WS 客户端
import { expect } from "bun:test";
import { createHash } from "node:crypto";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import protocol from "../protocol.json";
import { SITE_ORIGIN } from "../src/config";
import type { DialogRunner } from "../src/pairing";
import { type ServerOptions, startServer } from "../src/server";

export const USER_A = "11111111-1111-4111-8111-111111111111";
export const USER_B = "22222222-2222-4222-8222-222222222222";
export const COURSE = "cccccccc-3333-4333-8333-333333333333"; // 含字母：大写形式与它不同
export const HOST_ROOT = join(import.meta.dir, "..");

export type Msg = { method: string; id?: string; params?: any };

const cleanups: (() => void)[] = [];
/** 每个测试文件 afterEach(cleanup)：关掉本测试起的服务、连接与临时目录 */
export const cleanup = () => {
  for (const f of cleanups.splice(0).reverse()) f();
};

export const sha256 = (s: string) => createHash("sha256").update(s).digest("hex");
export const refused = (code: string) => ({ method: "error", params: { code } });

export async function until(check: () => boolean, ms = 2000) {
  const deadline = Date.now() + ms;
  while (!check()) {
    if (Date.now() > deadline) throw new Error("等待条件超时");
    await Bun.sleep(5);
  }
}

type Reply = { status: number; body?: unknown };

/** 假平台：GET /mcp/token 按 Bearer token 查表应答（查不到即 401），DELETE 一律 204；每次调用都记下 */
function fakePlatform() {
  const tokens = new Map<string, Reply>();
  const calls: { method: string; token: string }[] = [];
  const server = Bun.serve({
    hostname: "127.0.0.1",
    port: 0,
    fetch(req) {
      const token = (req.headers.get("authorization") ?? "").replace(/^Bearer /, "");
      calls.push({ method: req.method, token });
      if (req.method === "DELETE") return new Response(null, { status: 204 });
      const reply = tokens.get(token) ?? { status: 401, body: { error: "invalid_token" } };
      return Response.json(reply.body ?? null, { status: reply.status });
    },
  });
  cleanups.push(() => server.stop(true));
  return { url: `http://127.0.0.1:${server.port}`, tokens, calls };
}

/** GET /mcp/token 的 200 应答（U3 的契约） */
export const identity = (userId: string, tokenId: string, extra: Record<string, unknown> = {}): Reply => ({
  status: 200,
  body: { token_id: tokenId, user_id: userId, kind: "learning_host", display_name: "学员甲", masked_identifier: "a***@example.com", ...extra },
});

/** 弹窗替身：记下 argv，按 answer 应答；answer 可以是一个等到被取消才返回的函数 */
function fakeDialog() {
  const dialog: { calls: string[][]; answer: string | ((signal: AbortSignal) => Promise<string>); run: DialogRunner } = {
    calls: [],
    answer: "deny",
    run: async (argv, signal) => {
      dialog.calls.push(argv);
      return typeof dialog.answer === "function" ? dialog.answer(signal) : dialog.answer;
    },
  };
  return dialog;
}

/** 弹窗一直开着，直到被 pair.cancel 关掉（真实 osascript 被杀时 stdout 为空） */
export const untilAborted = (signal: AbortSignal) => new Promise<string>((resolve) => signal.addEventListener("abort", () => resolve("")));

export type TestHost = ReturnType<typeof startHost>;

export function startHost(options: Partial<ServerOptions> = {}) {
  const home = mkdtempSync(join(tmpdir(), "cgc-host-test-"));
  const platform = fakePlatform();
  const dialog = fakeDialog();
  const chatCalls: { method: string; params: Record<string, unknown> }[] = [];
  const server = startServer({
    port: 0,
    home,
    apiBase: platform.url,
    runDialog: dialog.run,
    ompPresent: () => false,
    // 与 main.ts 在 U6 之前的处理器同一行为：记下调用，答「暂不可用」
    chat: (method, params, ctx) => {
      chatCalls.push({ method, params });
      ctx.send({ method: "error", id: ctx.id, params: { code: "chat_unavailable" } });
    },
    cooldownMs: 0,
    ...options,
  });
  cleanups.push(() => {
    server.stop(true);
    rmSync(home, { recursive: true, force: true });
  });
  return { port: server.port as number, home, platform, dialog, chatCalls };
}

// Bun 的 WebSocket 客户端支持自定请求头（运行时有），但 tsconfig 未排除 lib.dom，DOM 的类型里没有这个重载
const BunWebSocket = WebSocket as unknown as new (url: string, options: { headers: Record<string, string> }) => WebSocket;

/** 页面侧的 WS 客户端；默认带站点来源。升级被拒时 reject("upgrade refused") */
export async function connect(port: number, headers: Record<string, string> = { Origin: SITE_ORIGIN }) {
  const ws = new BunWebSocket(`ws://127.0.0.1:${port}/`, { headers });
  const inbox: Msg[] = [];
  const waiters: { match: (m: Msg) => boolean; resolve: (m: Msg) => void }[] = [];
  ws.onmessage = (e) => {
    const m = JSON.parse(String(e.data)) as Msg;
    const i = waiters.findIndex((w) => w.match(m));
    if (i >= 0) waiters.splice(i, 1)[0].resolve(m);
    else inbox.push(m);
  };
  await new Promise((resolve, reject) => {
    ws.onopen = resolve;
    ws.onerror = () => reject(new Error("upgrade refused"));
  });
  cleanups.push(() => ws.close());

  /** 取第一条符合条件的消息；Host 发来的每种消息都必须登记在 protocol.json 的 hostToPage */
  const next = async (match: (m: Msg) => boolean) => {
    const i = inbox.findIndex(match);
    const m = i >= 0 ? inbox.splice(i, 1)[0] : await new Promise<Msg>((resolve) => waiters.push({ match, resolve }));
    expect(protocol.methods.hostToPage).toContain(m.method);
    return m;
  };
  let seq = 0;
  return {
    next,
    send: (frame: unknown) => ws.send(typeof frame === "string" ? frame : JSON.stringify(frame)),
    call(method: string, params?: Record<string, unknown>) {
      const id = String(++seq);
      ws.send(JSON.stringify({ method, id, params }));
      return next((m) => m.id === id);
    },
  };
}

let tokenSeq = 0;

/** 走完一次「页面带凭证 pair.request → 平台核实 → 学员允许」，返回凭证与浏览器密钥 */
export async function pair(host: TestHost, userId = USER_A) {
  const n = ++tokenSeq;
  const token = `cgch_test-token-${n}`;
  const tokenId = `token-id-${n}`;
  host.platform.tokens.set(token, identity(userId, tokenId));
  host.dialog.answer = "allow";
  const c = await connect(host.port);
  const reply = await c.call("pair.request", { token });
  expect(reply).toMatchObject({ method: "pair.result", params: { allowed: true } });
  return { token, tokenId, browserKey: reply.params.browserKey as string };
}

/** 出示浏览器密钥完成 hello 的连接 */
export async function helloed(host: TestHost, browserKey: string, userId = USER_A) {
  const c = await connect(host.port);
  expect(await c.call("hello", { userId, browserKey })).toMatchObject({ method: "status", params: { state: "ready" } });
  return c;
}
