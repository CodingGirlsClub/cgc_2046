// acp/session.ts — 对话处理器（U6）：每门课一条 ACP 会话（KTD6）；一个 OMP 进程服务全部会话，按需拉起、空闲回收（KTD13）；
// session/update 归一化成页面事件（events.ts），审批与提问交给持有者作答（cards.ts）。载荷契约见 cgc-host/AGENTS.md。
import { mkdirSync } from "node:fs";
import {
  RequestError,
  type ClientApp,
  type ContentBlock,
  type McpServer,
  type PromptResponse,
  type SessionConfigOption,
} from "@agentclientprotocol/sdk";
import protocol from "../../protocol.json";
import { type AgentKind, DEFAULT_AGENT, isAgentKind, type Registry } from "../agents/registry";
import type { ChatContext, ChatMethod, Message } from "../server";
import { isUuid } from "../security";
import { setPointer, workDir } from "../state";
import { type Cards, createCards } from "./cards";
import { type Agent, clientApp } from "./client";
import { type ChatEvent, classifyModelError, createTranscript, type Transcript } from "./events";
import { createRuntime, type Preparation, type Runtime } from "./runtime";

export interface ChatOptions {
  home: string;
  /** 平台 API 地址：下发给 agent 的 cgc-2046 MCP 服务器是 `${apiBase}/mcp` */
  apiBase: string;
  /** agent 注册表：按 kind 拉起进程；main.ts 用真实注册表，测试接进程内的假 agent；找不到或起不来就抛错 */
  registry: Registry;
  /** 包含课程排队、进程启动、initialize 与 list/load/new 的总预算；测试可缩短 */
  preparationTimeoutMs?: number;
  /** KTD13：没有页面持有这门课、卡片待答超过它，就取消本轮；默认 5 分钟 */
  graceMs?: number;
  /** KTD13：没有页面连着、也没有在跑的回合超过它，就回收 OMP 进程；默认 10 分钟 */
  idleMs?: number;
}

/** sessionId 在 session/prompt 发出时才填：之前（含拉起会话时 session/load 的回放）收到的更新只进缓冲，不推给页面 */
type Turn = { stopping: boolean; sessionId: string | null; text: string };

interface Course {
  id: string;
  /** 这段对话现在由哪个 agent 驱动；换成另一个 agent 就是换一段会话（见 handle 与 course） */
  agent: AgentKind;
  /** 发给这门课当前的持有者（server.ts 的 ctx.push）；绑定失效时丢弃，事件仍在缓冲里 */
  send(message: Message): void;
  held: boolean;
  /** 已在当前 agent 进程里 new / load 的会话，以及加载它用的账号与凭证 */
  sessionId: string | null;
  userId: string;
  token: string;
  transcript: Transcript;
  cards: Cards;
  turn: Turn | null;
  /** 上一次随消息附带的页面上下文（KTD8）：没变就不再附 */
  lastContext: string | null;
  /** OMP 给的会话设置项（模型、思考等级，收窄后）：新一轮会话从 OMP 回包里刷新 */
  settings: ConfigOption[];
  /** 上一次推给页面的设置（JSON）：内容没变就不重复推；null 表示还没同步过 */
  settingsKey: string | null;
  graceTimer: Timer | null;
  /** 同一门课的会话操作（new / load）排队执行 */
  queue: Promise<unknown>;
}

const UNIT_ID = /^[A-Za-z0-9_.-]{1,64}$/;

/** 页面可改的会话设置（OMP 的 configId）：模型与思考等级；mode（plan）是 agent 执行策略，不透出 */
const SETTING_IDS: Record<string, true> = { model: true, thinking: true };
/** 单个设置项的取值上限：OMP 的值是 provider/model 这类短标识 */
const SETTING_VALUE_MAX = 256;

/**
 * 透给页面的会话设置项：ACP 的 configOptions 收窄成只剩模型与思考等级，分组形状摊平成一层
 * （页面自己按 provider 前缀分组显示），值只取 string。
 */
export interface ConfigOption {
  id: string;
  name: string;
  category: string;
  currentValue: string;
  options: { value: string; name: string; description?: string }[];
}

/** OMP 没给 configOptions（旧版本）或项目的形状不合约时返回空数组：页面据此不渲染设置控件 */
function pickSettings(configOptions: readonly SessionConfigOption[] | null | undefined): ConfigOption[] {
  const picked: ConfigOption[] = [];
  for (const option of configOptions ?? []) {
    if (option.type !== "select" || !Object.hasOwn(SETTING_IDS, option.id)) continue;
    const items = option.options.flatMap((item) => ("group" in item ? item.options : [item]));
    picked.push({
      id: option.id,
      name: option.name,
      category: option.category ?? option.id,
      currentValue: option.currentValue,
      options: items.map(({ value, name, description }) => ({ value, name, ...(description ? { description } : {}) })),
    });
  }
  return picked;
}

/**
 * KTD8 的页面上下文：只带标识，不带 tutor 撰写的文本（如课程、单元标题）。单元 id 只认短的 ASCII 标识，
 * null 表示课程总览；courseVersion 是页面显示的课程版本号，null 表示未知。返回块内的 JSON，不合法返回 null。
 */
function pageContext(raw: unknown, courseId: string): string | null {
  if (typeof raw !== "object" || raw === null) return null;
  const { workspaceId, courseVersion, unitId, locale } = raw as Record<string, unknown>;
  const ok =
    isUuid(workspaceId) &&
    (courseVersion === null || (Number.isInteger(courseVersion) && (courseVersion as number) > 0)) &&
    (unitId === null || (typeof unitId === "string" && UNIT_ID.test(unitId))) &&
    (locale === "zh-CN" || locale === "en");
  return ok ? JSON.stringify({ workspace_id: workspaceId, course_id: courseId, course_version: courseVersion, unit_id: unitId, locale }) : null;
}

/** 一行错误摘要：message + ACP 错误的 data（诊断详情，如 load 失败的真实原因「Could not restore model …」），超长截断 */
export const message = (e: unknown) => {
  const base = String((e as Error)?.message ?? e);
  const data = (e as { data?: unknown })?.data;
  if (data === undefined) return base;
  let details: string;
  try {
    details = JSON.stringify(data);
  } catch {
    details = String(data);
  }
  return `${base} ${details.length > 500 ? `${details.slice(0, 500)}…` : details}`;
};

/** chat.open 的可诊断失败：bad_request = 目标不属于本课程工作目录（客户端问题）；session_unavailable = load 失败（持久指针保持不变） */
class OpenError extends Error {
  constructor(public code: "bad_request" | "session_unavailable") {
    super(code);
  }
}

export function createChat(opts: ChatOptions) {
  const graceMs = opts.graceMs ?? 5 * 60_000;
  const idleMs = opts.idleMs ?? 10 * 60_000;
  const courses = new Map<string, Course>();
  const bySession = new Map<string, Course>();
  let connections = 0;
  /** 每个 agent kind 自己的空闲回收计时器（KTD13）：一种 agent 的空闲不回收另一种的进程 */
  const idleTimers = new Map<AgentKind, Timer>();

  const delta = (c: Course, event: ChatEvent) => c.send({ method: "turn.delta", params: { courseId: c.id, ...event } });

  /** 设置已随 history 的回复同步给页面（attach / new / open）：记下内容，避免随后重复推 */
  const settingsSynced = (c: Course) => {
    c.settingsKey = JSON.stringify(c.settings);
  };

  /** 会话设置变化时推给这门课的持有者；与上一次同步的内容相同就不推 */
  function publishSettings(c: Course) {
    const key = JSON.stringify(c.settings);
    if (key === c.settingsKey) return;
    c.settingsKey = key;
    c.send({ method: "chat.settings", params: { courseId: c.id, settings: c.settings } });
  }

  /** 每个 agent kind 一个进程代（KTD1）：拉起、回收、换代都按 kind 独立，一种 agent 崩了不影响另一种 */
  const runtimes = new Map<AgentKind, Runtime>();
  function runtimeFor(kind: AgentKind) {
    let runtime = runtimes.get(kind);
    if (!runtime) {
      runtime = createRuntime({ start: (app, signal) => opts.registry.start(kind, app, signal), ready: checkIdle, reset: () => resetAgent(kind), app: (active) => clientApp({
        update({ sessionId, update }) {
          if (!active()) return;
          const c = bySession.get(sessionId);
          // agent 改了会话设置（config_option_update）：转成 chat.settings 推给持有者，不落进对话缓冲
          if (c && update.sessionUpdate === "config_option_update") {
            c.settings = pickSettings(update.configOptions);
            publishSettings(c);
            return;
          }
          const event = c?.transcript.apply(update);
          if (!c || !event || !c.turn?.sessionId) return;
          if (event.kind === "message") c.turn.text += event.text;
          delta(c, event);
        },
        permission(req, signal) {
          if (!active()) return Promise.resolve({ outcome: { outcome: "cancelled" } });
          const c = bySession.get(req.sessionId);
          if (!c) return Promise.resolve({ outcome: { outcome: "cancelled" } });
          const answer = c.cards.permission(req, signal);
          checkGrace(c);
          return answer;
        },
        question(req, signal) {
          if (!active()) return Promise.resolve({ action: "decline" });
          const c = "sessionId" in req && typeof req.sessionId === "string" ? bySession.get(req.sessionId) : undefined;
          if (!c) return Promise.resolve({ action: "decline" });
          const answer = c.cards.question(req, signal);
          checkGrace(c);
          return answer;
        },
      }) });
      runtimes.set(kind, runtime);
    }
    return runtime;
  }

  /** 这个 kind 的进程被废弃（空闲回收、崩溃换代）：它名下课程的会话作废、在跑的事情收尾；其他 kind 不受影响 */
  function resetAgent(kind: AgentKind) {
    for (const [id, c] of courses) {
      if (c.agent !== kind) continue;
      if (c.sessionId) bySession.delete(c.sessionId);
      c.sessionId = null;
      // 下一个进程会重新给 settings（session/new 或 load 的回包），先清掉等它
      c.settings = [];
      c.settingsKey = null;
      c.cards.cancelAll();
      // 共享进程被废弃时，其他已开始的回合立即收尾；准备中的请求由其自身的取消路径回复失败。
      if (c.turn?.sessionId) finish(c, c.turn, null);
      if (!c.held && !c.turn && c.cards.size === 0) courses.delete(id);
    }
    checkIdle();
  }

  const cgcServer = (token: string): McpServer => ({
    type: "http",
    name: "cgc-2046", // 与终端插件同名
    url: `${opts.apiBase}/mcp`,
    headers: [{ name: "authorization", value: `Bearer ${token}` }],
  });

  /** KTD6：指针指向的会话必须登记在这门课的工作目录下才加载——比如换了账号，指针还指着上一个账号的对话 */
  async function belongs(a: Agent, cwd: string, sessionId: string, run: Preparation): Promise<boolean> {
    let cursor: string | undefined;
    do {
      const page = await run.wait("session/list", (signal) => a.rpc.request("session/list", { cwd, ...(cursor && { cursor }) }, { cancellationSignal: signal }));
      if (page.sessions.some((s) => s.sessionId === sessionId)) return true;
      cursor = page.nextCursor ?? undefined;
    } while (cursor);
    return false;
  }

  /**
   * 让这门课在当前 agent 进程里有一条可用的会话（KTD6）：
   * - attach：已有指针才拉起进程并 session/load（回放历史）；没有对话就不为空历史拉起进程（KTD13）；
   * - send：有指针加载，没有就 session/new 并记下指针；
   * - new：「新开对话」，总是 session/new，指针改指新会话。
   * session/new 与每次 session/load 都下发含当前凭证的 mcpServers；换了账号或凭证就重新加载。
   */
  async function ensureSession(c: Course, ctx: ChatContext, mode: "attach" | "send" | "new" | "open", run: Preparation, openTarget?: string) {
    run.check();
    const runtime = runtimeFor(c.agent);
    // 有一轮正在跑时不重新加载：重新 load 会让 agent 把历史整段再回放一遍
    const current = runtime.agent && c.sessionId && (c.turn?.sessionId || (c.userId === ctx.userId && c.token === ctx.token)) ? c.sessionId : null;
    if (mode === "open" && current === openTarget) return { a: await run.agent(), sessionId: current }; // 打开的就是当前会话：短接，不再回放
    if ((mode === "attach" || mode === "send") && current) return { a: await run.agent(), sessionId: current };
    // 不再沿用当前会话（新开、切换、换了账号或凭证、OMP 重启过）：先卸下并清空缓冲——上一段对话不能出现在接下来的历史里
    if (c.sessionId) bySession.delete(c.sessionId);
    c.sessionId = null;
    c.lastContext = null;
    // 设置也属于上一段会话：换账号时不能把上一个账号会话的当前值下发给新页面（等这一轮 load/new 刷新）
    c.settings = [];
    c.settingsKey = null;
    c.transcript.reset();
    const target = mode === "new" ? undefined : mode === "open" ? openTarget : ctx.sessions[c.id]?.[c.agent];
    if (mode === "attach" && !target) return null;
    const a = await run.agent();
    run.check();
    const cwd = workDir(opts.home, ctx.userId, c.id);
    const mcpServers = [cgcServer(ctx.token)];
    const load = target ? await belongs(a, cwd, target, run) : false;
    run.check();
    if (target && load) {
      bySession.set(target, c);
      try {
        const loaded = await run.wait("session/load", (signal) => a.rpc.request("session/load", { sessionId: target, cwd, mcpServers }, { cancellationSignal: signal }));
        c.settings = pickSettings(loaded.configOptions);
        c.settingsKey = null;
      } catch (e) {
        bySession.delete(target);
        // chat.open 的目标加载失败：报可诊断的错误；持久指针不动，原会话不受影响。
        // 原始 ACP 错误（如「Could not restore model …」）会随 OpenError 丢失，所以先记日志
        if (mode === "open") {
          console.error(`cgc-host: 切换对话失败：${message(e)}`);
          throw new OpenError("session_unavailable");
        }
        throw e;
      }
      run.check();
      Object.assign(c, { sessionId: target, userId: ctx.userId, token: ctx.token });
      if (mode === "open") {
        setPointer(ctx.sessions, c.id, c.agent, target);
        ctx.save();
      }
      return { a, sessionId: target };
    }
    if (mode === "open") throw new OpenError("bad_request"); // 目标不属于这门课的工作目录
    if (target) {
      console.error("cgc-host: 会话指针不在这门课的工作目录下，拒绝加载");
      setPointer(ctx.sessions, c.id, c.agent, null);
      ctx.save();
      if (mode === "attach") return null;
    }
    mkdirSync(cwd, { recursive: true });
    const created = await run.wait("session/new", (signal) => a.rpc.request("session/new", { cwd, mcpServers }, { cancellationSignal: signal }));
    const { sessionId } = created;
    c.settings = pickSettings(created.configOptions);
    c.settingsKey = null;
    run.check();
    bySession.set(sessionId, c);
    Object.assign(c, { sessionId, userId: ctx.userId, token: ctx.token });
    setPointer(ctx.sessions, c.id, c.agent, sessionId);
    ctx.save();
    return { a, sessionId };
  }

  // Keep preparation and its synchronous state/reply/prompt commit in the same course queue slot.
  const prepare = (c: Course, ctx: ChatContext, mode: "attach" | "send" | "new" | "open", commit: (ready: Awaited<ReturnType<typeof ensureSession>>) => void, openTarget?: string) =>
    runtimeFor(c.agent).prepare(opts.preparationTimeoutMs ?? protocol.preparationTimeoutMs, (run) => serial(c, async () => {
      const ready = await ensureSession(c, ctx, mode, run, openTarget);
      run.check();
      commit(ready);
    }));

  function serial<T>(c: Course, op: () => Promise<T>): Promise<T> {
    const run = c.queue.then(op);
    c.queue = run.catch(() => {});
    return run;
  }

  /** 回合结束：未答的卡片以取消收起、没跑完的工具标为已停止，R27 归类，推 turn.end（KTD14 据此重取学习详情） */
  function finish(c: Course, turn: Turn, res: PromptResponse | null) {
    if (c.turn !== turn) return;
    const stopReason = res?.stopReason ?? "error";
    c.cards.cancelAll();
    for (const step of c.transcript.stopTools()) delta(c, step);
    const modelError = stopReason === "end_turn" ? classifyModelError(turn.text, res?.usage) : undefined;
    c.transcript.push({ kind: "end", stopReason, ...(modelError && { modelError }) });
    c.turn = null;
    c.send({ method: "turn.end", params: { courseId: c.id, stopReason, ...(res?.usage && { usage: res.usage }), ...(modelError && { modelError }) } });
    checkGrace(c);
    checkIdle();
  }

  /** R29：发 session/cancel；待答审批以 cancelled 结束、提问清掉，在跑的工具标为已停止；turn.end 随 agent 的 cancelled 应答而来 */
  function stop(c: Course) {
    const turn = c.turn;
    if (!turn || turn.stopping) return;
    turn.stopping = true;
    const active = runtimeFor(c.agent).agent;
    if (active && turn.sessionId) void active.rpc.notify("session/cancel", { sessionId: turn.sessionId }).catch(() => {});
    c.cards.cancelAll();
    for (const step of c.transcript.stopTools()) delta(c, step);
    checkGrace(c);
  }

  /** KTD13：没有页面持有这门课、卡片又在等人作答，超过宽限期就取消本轮——卡片以取消（拒绝）结束，从不按允许 */
  function checkGrace(c: Course) {
    const due = !c.held && c.cards.size > 0;
    if (due && !c.graceTimer) {
      c.graceTimer = setTimeout(() => {
        c.graceTimer = null;
        if (c.held || c.cards.size === 0) return;
        console.error("cgc-host: 卡片无人作答超过宽限期，取消本轮");
        stop(c);
        c.cards.cancelAll();
      }, graceMs);
      c.graceTimer.unref();
    } else if (!due && c.graceTimer) {
      clearTimeout(c.graceTimer);
      c.graceTimer = null;
    }
  }

  /** KTD13：没有页面连着、也没有在跑的回合，超过空闲期就回收该 agent 的进程；下次需要时再拉起并 session/load */
  function checkIdle() {
    for (const [kind, runtime] of runtimes) {
      const idle = () => runtime.agent !== null && connections === 0 && ![...courses.values()].some((c) => c.agent === kind && c.turn);
      const timer = idleTimers.get(kind);
      if (idle() && !timer) {
        const armed = setTimeout(() => {
          idleTimers.delete(kind);
          if (!idle()) return;
          console.log(`cgc-host: 空闲，回收 ${kind} 进程`);
          runtime.close();
        }, idleMs);
        armed.unref();
        idleTimers.set(kind, armed);
      } else if (!idle() && timer) {
        clearTimeout(timer);
        idleTimers.delete(kind);
      }
    }
  }

  function course(id: string, ctx: ChatContext, agent: AgentKind): Course {
    let c = courses.get(id);
    if (!c) {
      const created: Course = {
        id,
        agent,
        send: ctx.push,
        held: true,
        sessionId: null,
        userId: ctx.userId,
        token: ctx.token,
        transcript: createTranscript(),
        cards: createCards((method, params) => created.send({ method, params: { courseId: id, ...params } })),
        turn: null,
        lastContext: null,
        settings: [],
        settingsKey: null,
        graceTimer: null,
        queue: Promise.resolve(),
      };
      courses.set(id, (c = created));
    } else if (c.agent !== agent) {
      // 换 agent 就是换一段会话（KTD8）：旧进程里那条会话作废，缓冲、设置与待答卡片一起清掉；
      // 在跑的回合已由 handle 先停掉，这里只把它摘下来，免得旧回合的收尾再推一条 turn.end 给新页面。
      if (c.sessionId) bySession.delete(c.sessionId);
      c.agent = agent;
      c.sessionId = null;
      c.lastContext = null;
      c.settings = [];
      c.settingsKey = null;
      c.transcript.reset();
      c.turn = null;
      c.cards.cancelAll();
    }
    // 能调到这里的连接就是这门课的持有者（server.ts 已判定）
    c.send = ctx.push;
    c.held = true;
    checkGrace(c);
    return c;
  }

  async function handle(method: ChatMethod, params: Record<string, unknown> & { courseId: string }, ctx: ChatContext) {
    // 页面显式指定的 agent 优先（server.ts 已按白名单校验过）；省略就是缺省 agent——回滚期的旧页面不带这个字段，
    // 不能让 Host 按「记忆值」替它改走别的 agent（KTD3）。记忆值只作为页面初选，经 history 回包给出。
    const agent: AgentKind = isAgentKind(params.agent) ? params.agent : DEFAULT_AGENT;
    // 本机换了账号（重新配对给另一个人）时上一个账号的回合还在跑：先取消它（卡片以取消作答），收尾期间它的事件不再发出——
    // 消息只路由给这门课当前的持有者，也就是新账号。新账号这次回 busy，回合结束后重试即接上自己的对话
    const previous = courses.get(params.courseId);
    if (previous?.turn && previous.userId !== ctx.userId) {
      previous.send = () => {};
      previous.held = false;
      stop(previous);
      return ctx.reply({ method: "error", params: { code: "busy" } });
    }
    // 换 agent（KTD8）走同一条收尾路径：旧 agent 的回合先取消，本次回 busy，页面停了再切
    if (previous?.turn && previous.agent !== agent) {
      previous.send = () => {};
      previous.held = false;
      stop(previous);
      return ctx.reply({ method: "error", params: { code: "busy" } });
    }
    const c = course(params.courseId, ctx, agent);
    // 记忆值只记「真的切过去了」的那次显式选择（被 busy 挡回的不记），供下一次页面初选
    if (isAgentKind(params.agent) && ctx.agents[c.id] !== agent) {
      ctx.agents[c.id] = agent;
      ctx.save();
    }
    const reply = (m: string, p: Record<string, unknown>) => ctx.reply({ method: m, params: { courseId: c.id, ...p } });
    const fail = (code: string) => ctx.reply({ method: "error", params: { code } });

    if (method === "chat.attach") {
      try {
        await prepare(c, ctx, "attach", () => {
          reply("history", { running: c.turn !== null, events: c.transcript.events, settings: c.settings, agent: ctx.agents[c.id] ?? null });
          settingsSynced(c);
          for (const view of c.cards.views()) c.send({ method: "turn.card", params: { courseId: c.id, ...view } });
        });
      } catch (e) {
        console.error(`cgc-host: 加载对话失败：${message(e)}`);
        return fail("chat_unavailable");
      }
    } else if (method === "chat.send") {
      const { text } = params;
      const context = pageContext(params.context, c.id);
      if (typeof text !== "string" || !text.trim() || context === null) return fail("bad_request");
      if (c.turn) return fail("busy");
      const turn: Turn = { stopping: false, sessionId: null, text: "" };
      c.turn = turn;
      checkIdle();
      try {
        await prepare(c, ctx, "send", (ready) => {
          const { a, sessionId } = ready!;
          // KTD8：上下文块只在会话的首条消息与单元切换时附带
          const prompt: ContentBlock[] = [{ type: "text", text }];
          if (context !== c.lastContext) prompt.unshift({ type: "text", text: `<cgc-page-context>${context}</cgc-page-context>` });
          c.lastContext = context;
          c.transcript.push({ kind: "user", text });
          reply("turn.delta", { kind: "user", text });
          if (turn.stopping) return finish(c, turn, { stopReason: "cancelled" });
          turn.sessionId = sessionId;
          // attach 时还没有会话（空历史不拉起 OMP）：新建后把设置补推给页面
          publishSettings(c);
          a.rpc.request("session/prompt", { sessionId, prompt }).then(
            (res) => finish(c, turn, res),
            (e) => {
              console.error(`cgc-host: 本轮对话失败：${message(e)}`);
              finish(c, turn, null);
            },
          );
        });
      } catch (e) {
        console.error(`cgc-host: 无法开始对话：${message(e)}`);
        if (c.turn === turn) c.turn = null;
        checkIdle();
        return fail("chat_unavailable");
      }
    } else if (method === "chat.stop") {
      stop(c);
    } else if (method === "chat.new") {
      if (c.turn) return fail("busy");
      try {
        await prepare(c, ctx, "new", () => {
          reply("history", { running: false, events: [], settings: c.settings, agent: ctx.agents[c.id] ?? null });
          settingsSynced(c);
        });
      } catch (e) {
        console.error(`cgc-host: 新开对话失败：${message(e)}`);
        return fail("chat_unavailable");
      }
    } else if (method === "chat.sessions") {
      // 历史对话列表：只读，可以在有回合在跑时查询；元数据字段缺省即 null（OMP 版本差异）
      const { cursor } = params;
      if (cursor !== undefined && (typeof cursor !== "string" || cursor.length > 256)) return fail("bad_request");
      try {
        const cwd = workDir(opts.home, ctx.userId, c.id);
        const page = await runtimeFor(c.agent).prepare(opts.preparationTimeoutMs ?? protocol.preparationTimeoutMs, async (run) => {
          const a = await run.agent();
          return run.wait("session/list", (signal) =>
            a.rpc.request("session/list", { cwd, ...(cursor ? { cursor } : {}) }, { cancellationSignal: signal }),
          );
        });
        const sessions = (page.sessions ?? []).map((s) => ({
          sessionId: s.sessionId,
          updatedAt: (s as { updatedAt?: string }).updatedAt ?? null,
          messageCount: (s as { _meta?: { messageCount?: number } })._meta?.messageCount ?? null,
        }));
        reply("sessions", { sessions, current: ctx.sessions[c.id]?.[c.agent] ?? null, nextCursor: page.nextCursor ?? null });
      } catch (e) {
        console.error(`cgc-host: 读取历史对话列表失败：${message(e)}`);
        return fail("chat_unavailable");
      }
    } else if (method === "chat.open") {
      // 切换到某个历史会话：只在 load 成功后推进持久指针；失败报 session_unavailable 且原会话保持可用
      const { sessionId } = params;
      if (typeof sessionId !== "string" || !sessionId || sessionId.length > 128) return fail("bad_request");
      if (c.turn) return fail("busy");
      try {
        await prepare(c, ctx, "open", () => {
          reply("history", { running: false, events: c.transcript.events, settings: c.settings, agent: ctx.agents[c.id] ?? null });
          settingsSynced(c);
        }, sessionId);
      } catch (e) {
        if (e instanceof OpenError) return fail(e.code);
        console.error(`cgc-host: 切换对话失败：${message(e)}`);
        return fail("chat_unavailable");
      }
    } else if (method === "chat.set_setting") {
      // 学员在对话栏改本机 OMP 的设置（模型、思考等级）：只作用于当前会话，不写学员的 OMP 配置
      const { configId, value } = params;
      if (typeof configId !== "string" || !Object.hasOwn(SETTING_IDS, configId) || typeof value !== "string" || !value || value.length > SETTING_VALUE_MAX) {
        return fail("bad_request");
      }
      if (c.turn) return fail("busy");
      const active = runtimeFor(c.agent).agent;
      const sessionId = c.sessionId;
      if (!active || !sessionId) return fail("chat_unavailable");
      // 不进课程队列：设置请求可能在 OMP 侧长时间没有应答，不能占住 new / load / send 的队列。改为回包后校验会话没被换掉。
      try {
        const res = await active.rpc.request("session/set_config_option", { sessionId, configId, value });
        // 回包期间会话被换掉（新开 / 切换 / 换账号）：这份回包属于旧会话，作废并明确告诉页面，不写 c.settings
        if (c.sessionId !== sessionId) return fail("busy");
        c.settings = pickSettings(res.configOptions);
        reply("chat.settings", { settings: c.settings });
        settingsSynced(c);
      } catch (e) {
        // 会话已被换掉（新开 / 切换 / 换账号）：这是旧请求的失败，按作废处理，不能归到当前会话
        if (c.sessionId !== sessionId) return fail("busy");
        // OMP 明确拒绝这个值（如 `Unknown ACP model: …`）→ bad_request；传输中断、进程结束 → chat_unavailable
        console.error(`cgc-host: 修改对话设置失败：${message(e)}`);
        return fail(e instanceof RequestError ? "bad_request" : "chat_unavailable");
      }
    } else if (method === "card.answer") {
      if (!c.cards.answer(params, reply)) return fail("bad_request");
      checkGrace(c);
    }
  }

  return {
    handle,
    /** server.ts 的 onConnections：连接数变化，以及因断开而失去持有者的课程（KTD13） */
    connections(count: number, released: string[]) {
      connections = count;
      for (const id of released) {
        const c = courses.get(id);
        if (!c) continue;
        c.held = false;
        checkGrace(c);
      }
      checkIdle();
    },
  };
}
