// helpers.ts — 测试共用：真实 Bun.serve 上的 Host（临时 HOME）、假平台（/mcp/token）、可编排的弹窗、WS 客户端
import { expect } from "bun:test";
import * as acp from "@agentclientprotocol/sdk";
import { createHash } from "node:crypto";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import protocol from "../protocol.json";
import { CODEX_MCP_SERVER_NAME, writeLearningAgentsMd } from "../src/agents/codex";
import { createRegistry, type AgentRecord, type Locator } from "../src/agents/registry";
import type { Agent } from "../src/acp/client";
import { createChat } from "../src/acp/session";
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

/** 临时 HOME：本测试结束时删掉。要模拟 Host 重启（同一份状态文件），先建好再传给 startHost */
export function tempHome() {
  const home = mkdtempSync(join(tmpdir(), "cgc-host-test-"));
  cleanups.push(() => rmSync(home, { recursive: true, force: true }));
  return home;
}

export function startHost(options: Partial<ServerOptions> = {}) {
  const home = options.home ?? tempHome();
  const platform = fakePlatform();
  const dialog = fakeDialog();
  const chatCalls: { method: string; params: Record<string, unknown> }[] = [];
  const server = startServer({
    port: 0,
    home,
    apiBase: platform.url,
    runDialog: dialog.run,
    agents: () => [{ kind: "omp", present: false }],
    // 弹窗命令形状的断言不随测试机漂移；跨平台形状在 pairing.test.ts 里各自注入
    platform: "darwin",
    // 与 main.ts 在 U6 之前的处理器同一行为：记下调用，答「暂不可用」
    chat: (method, params, ctx) => {
      chatCalls.push({ method, params });
      ctx.reply({ method: "error", params: { code: "chat_unavailable" } });
    },
    cooldownMs: 0,
    ...options,
  });
  cleanups.push(() => server.stop(true));
  return { port: server.port as number, home, platform, dialog, chatCalls, stop: () => server.stop(true) };
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
    /** 收件箱里还没被取走的消息（断言「没收到某种消息」用） */
    inbox,
    /** 关掉连接（页面关闭或刷新）；等 Host 那边的 close 处理完再返回 */
    async close() {
      const closed = new Promise((resolve) => (ws.onclose = resolve));
      ws.close();
      await closed;
      await Bun.sleep(20);
    },
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

// ---- 对话（U6）：进程内的假 OMP（SDK 的 agent 侧连接）与接上它的 Host ----

type Line = { dir: "in" | "out"; msg: any };

/** 用真实 omp acp 录的转录（test/fixtures，已脱敏）：dir 为 in 是 agent → Host，out 是 Host → agent */
export const fixture = (name: string): Line[] =>
  readFileSync(join(import.meta.dir, "fixtures", name), "utf8")
    .trim()
    .split("\n")
    .map((l) => JSON.parse(l));

/** 转录里第 n 个 session/prompt 之后、它的应答之前 agent 发来的消息（通知与请求），以及那个应答 */
export function recordedTurn(name: string, n = 0) {
  const lines = fixture(name);
  const prompt = lines.filter((l) => l.dir === "out" && l.msg.method === "session/prompt")[n];
  const start = lines.indexOf(prompt);
  const end = lines.findIndex((l, i) => i > start && l.dir === "in" && l.msg.id === prompt.msg.id && !l.msg.method);
  return { inbound: lines.slice(start + 1, end).flatMap((l) => (l.dir === "in" ? [l.msg] : [])), response: lines[end].msg.result as acp.PromptResponse };
}

export type Turn = {
  sessionId: string;
  prompt: acp.ContentBlock[];
  client: acp.AgentContext;
  /** 发一条 session/update，并记进这条会话的历史（session/load 时回放） */
  emit(update: acp.SessionUpdate): Promise<void>;
  /** 向 Host 发请求（审批、提问），应答记进 fake.answers */
  ask(method: "session/request_permission" | "elicitation/create", params: any): Promise<any>;
  /** 收到这条会话的 session/cancel 时完成 */
  cancelled: Promise<void>;
};

/** 假 OMP 的会话设置：形状与 OMP 实测一致（mode / model / thinking 三项 select） */
export type FakeConfigOption = {
  id: string;
  name: string;
  category: string;
  type: "select";
  currentValue: string;
  options: { value: string; name: string; description?: string }[];
};

/**
 * 假 OMP：会话存储跨连接保留（模拟 OMP 的会话文件），每次 start 是一条新连接（模拟拉起新进程）。
 * session/load 回放历史；session/prompt 交给 fake.script。calls 记下 agent 收到的每个请求与通知。
 */
export function fakeAgent() {
  let seq = 0;
  const fake = {
    /** 测试取号：让不同段落的消息文案唯一 */
    seqHint: 0,
    store: new Map<string, { cwd: string; history: acp.SessionUpdate[]; updatedAt: string }>(),
    /** 会话列表页大小（>0 时启用分页游标） */
    listPageSize: 0,
    /** session/load 对这些会话抛 Internal error（模拟跨 OMP 版本加载失败） */
    failLoadFor: new Set<string>(),
    calls: [] as { method: string; params: any }[],
    answers: [] as any[],
    /** OMP 的会话设置（ACP configOptions）：session/new、session/load 的回包带它；set_config_option 按它校验并更新 */
    configOptions: [
      { id: "mode", name: "Mode", category: "mode", type: "select", currentValue: "default", options: [{ value: "default", name: "Default" }, { value: "plan", name: "Plan" }] },
      {
        id: "model",
        name: "Model",
        category: "model",
        type: "select",
        currentValue: "alpha/one",
        options: [
          { value: "alpha/one", name: "Alpha One", description: "alpha/one" },
          { value: "beta/two", name: "Beta Two", description: "beta/two" },
        ],
      },
      {
        id: "thinking",
        name: "Thinking",
        category: "thought_level",
        type: "select",
        currentValue: "auto",
        options: [
          { value: "off", name: "Off" },
          { value: "auto", name: "Auto", description: "Auto-detect per prompt" },
          { value: "high", name: "high" },
        ],
      },
    ] as FakeConfigOption[],
    /** 应用 set_config_option 后由测试改写 configOptions（模拟 OMP 的连带调整，如切模型后思考等级回退） */
    onSetConfig: null as ((configId: string, value: string) => void) | null,
    /** 测试可注入：set_config_option 的应答前先等它，构造「设置请求在飞时又触发新开对话」的竞态 */
    beforeSetConfig: null as Promise<void> | null,
    /** initialize 播报的登录方式（chat.authenticate 的取值来源） */
    authMethods: [] as { id: string; name: string }[],
    /** 握手要求先登录时，这些 ACP 方法（如 "session/new"）抛 auth_required（-32000） */
    authFor: new Set<string>(),
    /** authenticate 失败（页面按 auth_failed 处理） */
    authFails: false,
    starts: 0,
    conn: null as acp.ClientConnection | null,
    /** 默认：回一句话，带用量 */
    script: async (t: Turn): Promise<acp.PromptResponse> => {
      await t.emit({ sessionUpdate: "agent_message_chunk", content: { type: "text", text: "好的" } });
      return { stopReason: "end_turn", usage: { inputTokens: 10, outputTokens: 2, totalTokens: 12 } };
    },
    /** 按录制的转录回放一轮：通知照发，请求等 Host 作答，最后回录下的应答 */
    replay: (turn: ReturnType<typeof recordedTurn>) => async (t: Turn) => {
      for (const m of turn.inbound) {
        if (m.method === "session/update") await t.emit(m.params.update);
        else if (m.method) await t.ask(m.method, { ...m.params, sessionId: t.sessionId });
      }
      return turn.response;
    },
    calledWith: (method: string) => fake.calls.filter((c) => c.method === method).map((c) => c.params),
    start: async (app: acp.ClientApp, _signal?: AbortSignal): Promise<Agent> => {
      fake.starts++;
      // OMP's persisted session list is not the set loaded in this process.
      const loaded = new Set<string>();
      const cancels = new Map<string, () => void>();
      const record = (method: string, params: unknown) => fake.calls.push({ method, params });
      const agentApp = acp
        .agent({ name: "fake-omp" })
        .onRequest("initialize", (c) => {
          record("initialize", c.params);
          return { protocolVersion: acp.PROTOCOL_VERSION, agentCapabilities: { loadSession: true, sessionCapabilities: { list: {} } }, authMethods: fake.authMethods };
        })
        .onRequest("authenticate", (c) => {
          record("authenticate", c.params);
          if (fake.authFails) throw acp.RequestError.authRequired();
          return {};
        })
        .onRequest("session/new", (c) => {
          record("session/new", c.params);
          if (fake.authFor.has("session/new")) throw acp.RequestError.authRequired();
          const sessionId = `session-${++seq}`;
          fake.store.set(sessionId, { cwd: c.params.cwd, history: [], updatedAt: new Date().toISOString() });
          loaded.add(sessionId);
          return { sessionId, configOptions: fake.configOptions };
        })
        .onRequest("session/list", (c) => {
          record("session/list", c.params);
          const all = [...fake.store].filter(([, s]) => s.cwd === c.params.cwd);
          const size = fake.listPageSize > 0 ? fake.listPageSize : all.length || 1;
          const offset = typeof c.params.cursor === "string" ? Number(c.params.cursor) || 0 : 0;
          const next = offset + size < all.length ? String(offset + size) : undefined;
          return {
            sessions: all.slice(offset, offset + size).map(([sessionId, s]) => ({
              sessionId,
              cwd: s.cwd,
              updatedAt: s.updatedAt,
              _meta: { messageCount: s.history.filter((h) => h.sessionUpdate === "user_message_chunk").length },
            })),
            ...(next ? { nextCursor: next } : {}),
          };
        })
        .onRequest("session/load", async (c) => {
          if (fake.authFor.has("session/load")) throw acp.RequestError.authRequired();
          record("session/load", c.params);
          if (fake.failLoadFor.has(c.params.sessionId)) throw acp.RequestError.internalError({ details: "fake restore failure" });
          const s = fake.store.get(c.params.sessionId);
          if (!s) throw acp.RequestError.resourceNotFound(c.params.sessionId);
          loaded.add(c.params.sessionId);
          for (const update of s.history) await c.client.notify("session/update", { sessionId: c.params.sessionId, update });
          return { configOptions: fake.configOptions };
        })
        .onRequest("session/set_config_option", async (c) => {
          record("session/set_config_option", c.params);
          if (fake.beforeSetConfig) await fake.beforeSetConfig;
          const { configId, value } = c.params;
          const option = fake.configOptions.find((o) => o.id === configId);
          // OMP 对不认识的值回 Internal error，细节正是页面看到 bad_request 时该记进日志的那句
          if (!option || typeof value !== "string" || !option.options.some((o) => o.value === value)) {
            throw acp.RequestError.internalError({ details: `Unknown ACP ${configId}: ${String(value)}` });
          }
          option.currentValue = value;
          fake.onSetConfig?.(configId, value);
          return { configOptions: fake.configOptions };
        })
        .onRequest("session/prompt", async (c) => {
          record("session/prompt", c.params);
          const { sessionId, prompt } = c.params;
          if (!loaded.has(sessionId)) throw acp.RequestError.resourceNotFound(sessionId);
          const s = fake.store.get(sessionId)!;
          const text = prompt.map((b) => (b.type === "text" ? b.text : "")).join("\n");
          s.history.push({ sessionUpdate: "user_message_chunk", content: { type: "text", text } });
          s.updatedAt = new Date().toISOString();
          const cancelled = new Promise<void>((resolve) => cancels.set(sessionId, resolve));
          return fake.script({
            sessionId,
            prompt,
            client: c.client,
            cancelled,
            async emit(update) {
              s.history.push(update);
              await c.client.notify("session/update", { sessionId, update });
            },
            async ask(method, params) {
              const answer = await c.client.request(method, params);
              fake.answers.push(answer);
              return answer;
            },
          });
        })
        .onNotification("session/cancel", (c) => {
          record("session/cancel", c.params);
          cancels.get(c.params.sessionId)?.();
        });
      const conn = app.connect(agentApp);
      fake.conn = conn;
      return { rpc: conn.agent, closed: conn.closed, close: () => conn.close() };
    },
  };
  return fake;
}

export type Fake = ReturnType<typeof fakeAgent>;

export const API = "http://cgc.test";

/** 测试里的定位器不找任何东西：present 由 startHost 的 agents 选项单独注入 */
const absentLocator = (): Locator => ({ locate: async () => ({ path: null, env: {}, envError: null }), present: () => false, envError: () => null });

/** 假 OMP 那条记录（mcpServerName 与真实记录一致：终端插件同名） */
export const ompTestRecord = (fake: Fake): AgentRecord => ({
  kind: "omp",
  mcpServerName: "cgc-2046",
  locator: absentLocator(),
  start: (app, signal) => fake.start(app, signal),
});

/** 假 Codex 那条记录：名字与 prepare 用真实值，只有进程是进程内的假 agent */
export const codexTestRecord = (fake: Fake): AgentRecord => ({
  kind: "codex",
  mcpServerName: CODEX_MCP_SERVER_NAME,
  locator: absentLocator(),
  prepare: async (courseDir) => writeLearningAgentsMd(courseDir),
  start: (app, signal) => fake.start(app, signal),
});

/** 接上假 OMP 的 Host：对话处理器是真的（createChat），home 可传入以模拟 Host 重启 */
export function chatHost(
  fake: Fake,
  opts: { home?: string; graceMs?: number; idleMs?: number; preparationTimeoutMs?: number; records?: AgentRecord[] } = {},
) {
  const home = opts.home ?? tempHome();
  const registry = createRegistry(opts.records ?? [ompTestRecord(fake)]);
  const chat = createChat({ home, apiBase: API, registry, graceMs: opts.graceMs, idleMs: opts.idleMs, preparationTimeoutMs: opts.preparationTimeoutMs });
  return startHost({ home, chat: chat.handle, onConnections: chat.connections });
}

/** 一个已配对、已 hello 的页面 */
export async function chatPage(fake: Fake, opts: Parameters<typeof chatHost>[1] = {}) {
  const host = chatHost(fake, opts);
  const paired = await pair(host);
  const page = await helloed(host, paired.browserKey);
  return { host, page, ...paired };
}

export const CONTEXT = { workspaceId: "44444444-4444-4444-8444-444444444444", courseVersion: 3, unitId: "py-first-program", locale: "zh-CN" };
