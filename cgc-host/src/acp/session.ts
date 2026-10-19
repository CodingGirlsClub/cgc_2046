// acp/session.ts — 对话处理器（U6）：每门课每个 agent 一条 ACP 会话（KTD6）；每个 agent kind 一个进程，按需拉起、空闲回收（KTD13）；
// session/update 归一化成页面事件（events.ts），审批与提问交给持有者作答（cards.ts），设置项见 settings.ts，页面上下文见 page-context.ts。
// 载荷契约见 cgc-host/AGENTS.md。
import { mkdirSync } from "node:fs";
import {
  RequestError,
  type ClientApp,
  type ContentBlock,
  type McpServer,
  type PromptResponse,
} from "@agentclientprotocol/sdk";
import protocol from "../../protocol.json";
import { type AgentKind, DEFAULT_AGENT, isAgentKind, type Registry } from "../agents/registry";
import type { ChatContext, ChatMethod, Message } from "../server";
import { setPointer, workDir } from "../state";
import { createAgentRuntimes } from "./agent-runtimes";
import { authenticateAgent, createAuthMethods } from "./auth";
import { type Course, createCourse, type Turn } from "./course";
import { type Agent, clientApp } from "./client";
import { message, OpenError } from "./errors";
import { classifyModelError, type ChatEvent } from "./events";
import { pageContext } from "./page-context";
import { type Preparation } from "./runtime";
import { pickSettings, SETTING_IDS, SETTING_VALUE_MAX } from "./settings";

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

/** ACP 的 auth_required（-32000）：这个 agent 要求学员先登录（页面的登录卡与 chat.authenticate 都是围绕它） */
const isAuthRequired = (e: unknown) => e instanceof RequestError && e.code === -32000;
/** bySession 的键：sessionId 只在它自己的 agent 进程里有意义，两个 agent 的 id 空间互不相干 */
const sessionKey = (kind: AgentKind, sessionId: string) => `${kind}:${sessionId}`;

export function createChat(opts: ChatOptions) {
  const graceMs = opts.graceMs ?? 5 * 60_000;
  const idleMs = opts.idleMs ?? 10 * 60_000;
  const courses = new Map<string, Course>();
  const bySession = new Map<string, Course>();
  let connections = 0;

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

  /** 各 agent 握手时播报的登录方式：chat.authenticate 的取值来源，也是 auth_required 回包里的清单 */
  const authMethods = createAuthMethods();
  /** 每个 agent kind 一个进程代（KTD1）与各自的空闲回收（KTD13） */
  const runtimes = createAgentRuntimes({
    registry: opts.registry,
    connections: () => connections,
    busy: (kind) => [...courses.values()].some((c) => c.agent === kind && c.turn !== null),
    retired: resetAgent,
    initialized: (kind, response) => authMethods.remember(kind, response),
    idleMs,
    app: (kind, active) =>
      clientApp({
        update({ sessionId, update }) {
          if (!active()) return;
          const c = bySession.get(sessionKey(kind, sessionId));
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
          const c = bySession.get(sessionKey(kind, req.sessionId));
          if (!c) return Promise.resolve({ outcome: { outcome: "cancelled" } });
          const answer = c.cards.permission(req, signal);
          checkGrace(c);
          return answer;
        },
        question(req, signal) {
          if (!active()) return Promise.resolve({ action: "decline" });
          const c = "sessionId" in req && typeof req.sessionId === "string" ? bySession.get(sessionKey(kind, req.sessionId)) : undefined;
          if (!c) return Promise.resolve({ action: "decline" });
          const answer = c.cards.question(req, signal);
          checkGrace(c);
          return answer;
        },
      }),
  });
  const { runtimeFor, checkIdle } = runtimes;

  /** 这个 kind 的进程被废弃（空闲回收、崩溃换代）：它名下课程的会话作废、在跑的事情收尾；其他 kind 不受影响 */
  function resetAgent(kind: AgentKind) {
    for (const [id, c] of courses) {
      if (c.agent !== kind) continue;
      if (c.sessionId) bySession.delete(sessionKey(kind, c.sessionId));
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

  const cgcServer = (token: string, name: string): McpServer => ({
    type: "http",
    name, // Codex 侧不能用 cgc-2046：学员自己的 Codex 配置里已有同名服务器时，适配器会整条跳过带学习凭证的这份
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
   * - attach：有指针就拉起进程并 session/load（回放历史）；没有指针就 session/new——空历史也要建会话，
   *   这样 attach 的 history 回包就能带上模型/思考强度设置，首条消息之前页面就能选；进程仍按 KTD13 空闲回收；
   * - send：有指针加载，没有就 session/new 并记下指针；attach 建过的会话直接复用；
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
    if (c.sessionId) bySession.delete(sessionKey(c.agent, c.sessionId));
    c.sessionId = null;
    c.lastContext = null;
    // 设置也属于上一段会话：换账号时不能把上一个账号会话的当前值下发给新页面（等这一轮 load/new 刷新）
    c.settings = [];
    c.settingsKey = null;
    c.transcript.reset();
    const target = mode === "new" ? undefined : mode === "open" ? openTarget : ctx.sessions[c.id]?.[c.agent];
    const a = await run.agent();
    run.check();
    const cwd = workDir(opts.home, ctx.userId, c.id);
    const setup = opts.registry.setup(c.agent);
    const mcpServers = [cgcServer(ctx.token, setup.mcpServerName)];
    // 会话前的准备（Codex 要在课程目录写 AGENTS.md）：load 与 new 都要，写入是幂等的
    await run.wait("agent/prepare", async () => {
      mkdirSync(cwd, { recursive: true });
      await setup.prepare?.(cwd);
    });
    const load = target ? await belongs(a, cwd, target, run) : false;
    run.check();
    if (target && load) {
      bySession.set(sessionKey(c.agent, target), c);
      try {
        const loaded = await run.wait("session/load", (signal) => a.rpc.request("session/load", { sessionId: target, cwd, mcpServers }, { cancellationSignal: signal }));
        c.settings = pickSettings(loaded.configOptions);
        c.settingsKey = null;
      } catch (e) {
        bySession.delete(sessionKey(c.agent, target));
        // chat.open 的目标加载失败：报可诊断的错误；持久指针不动，原会话不受影响。
        // 原始 ACP 错误（如「Could not restore model …」）会随 OpenError 丢失，所以先记日志。
        // 「要求先登录」（auth_required）不算加载失败：原样冒泡，页面按登录卡处理。
        if (mode === "open" && !isAuthRequired(e)) {
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
      // KTD6：指针指向的会话不在课程目录下（例如换了账号）就不加载，清掉。attach 与 send 一样接着建新会话：
      // 不把上一个账号的对话带给新页面（缓冲已清），同时首条消息之前也能拿到设置。
      console.error("cgc-host: 会话指针不在这门课的工作目录下，拒绝加载");
      setPointer(ctx.sessions, c.id, c.agent, null);
      ctx.save();
    }
    const created = await run.wait("session/new", (signal) => a.rpc.request("session/new", { cwd, mcpServers }, { cancellationSignal: signal }));
    const { sessionId } = created;
    c.settings = pickSettings(created.configOptions);
    c.settingsKey = null;
    run.check();
    bySession.set(sessionKey(c.agent, sessionId), c);
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

  function course(id: string, ctx: ChatContext, agent: AgentKind): Course {
    let c = courses.get(id);
    if (!c) {
      courses.set(id, (c = createCourse(id, agent, ctx)));
    } else if (c.agent !== agent) {
      // 换 agent 就是换一段会话（KTD8）：旧进程里那条会话作废，缓冲、设置与待答卡片一起清掉；
      // 在跑的回合已由 handle 先停掉，这里只把它摘下来，免得旧回合的收尾再推一条 turn.end 给新页面。
      if (c.sessionId) bySession.delete(sessionKey(c.agent, c.sessionId));
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
    const requested: AgentKind = isAgentKind(params.agent) ? params.agent : DEFAULT_AGENT;
    const previous = courses.get(params.courseId);
    // 只有这四个方法在选择「哪段会话」；停止/作答/设置/登录/列表都作用在课程当前的 agent 上，
    // 绝不能因为缺省参数把课程切走（Codex 课程点停止曾因此切到 omp 并静音）。
    const selectsAgent = method === "chat.attach" || method === "chat.send" || method === "chat.new" || method === "chat.open";
    const agent: AgentKind = selectsAgent || !previous ? requested : previous.agent;
    // 本机换了账号（重新配对给另一个人）时上一个账号的回合还在跑：先取消它（卡片以取消作答），收尾期间它的事件不再发出——
    // 消息只路由给这门课当前的持有者，也就是新账号。新账号这次回 busy，回合结束后重试即接上自己的对话
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
    if (selectsAgent && isAgentKind(params.agent) && ctx.agents[c.id] !== agent) {
      ctx.agents[c.id] = agent;
      ctx.save();
    }
    const reply = (m: string, p: Record<string, unknown>) => ctx.reply({ method: m, params: { courseId: c.id, ...p } });
    const fail = (code: string) => ctx.reply({ method: "error", params: { code } });
    /** 这个 agent 要求先登录：回 auth_required + 它握手时播报的登录方式，页面据此出登录卡（chat.authenticate 完成登录） */
    const failAuth = () => ctx.reply({ method: "error", params: { code: "auth_required", methods: authMethods.of(c.agent) } });

    if (method === "chat.attach") {
      try {
        // 没有会话指针时也会建一条空会话：history 回包要带模型/思考强度设置（首条消息之前页面就得能选）。
        // 建会话失败（没装 agent、要求登录等）照旧回 chat_unavailable / auth_required；进程仍按 KTD13 空闲回收。
        await prepare(c, ctx, "attach", () => {
          reply("history", { running: c.turn !== null, events: c.transcript.events, settings: c.settings, agent: ctx.agents[c.id] ?? null });
          settingsSynced(c);
          for (const view of c.cards.views()) c.send({ method: "turn.card", params: { courseId: c.id, ...view } });
        });
      } catch (e) {
        console.error(`cgc-host: 加载对话失败：${message(e)}`);
        return isAuthRequired(e) ? failAuth() : fail("chat_unavailable");
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
          // 设置还没随 history 同步给页面（换账号后指针作废、进程被回收后重建等）：新建会话后补推
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
        return isAuthRequired(e) ? failAuth() : fail("chat_unavailable");
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
        return isAuthRequired(e) ? failAuth() : fail("chat_unavailable");
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
        return isAuthRequired(e) ? failAuth() : fail("chat_unavailable");
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
        return isAuthRequired(e) ? failAuth() : fail("chat_unavailable");
      }
    } else if (method === "chat.set_setting") {
      // 学员在对话栏改本机 agent 的设置（模型、OMP 的思考等级 / Codex 的推理强度）：只作用于当前会话，不写学员的 agent 配置
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
    } else if (method === "chat.authenticate") {
      // 学员在页面里发起登录（Codex 等）：转给该 agent 的 ACP authenticate；浏览器由适配器自己开（KTD4）
      const { methodId } = params;
      if (typeof methodId !== "string" || !methodId || methodId.length > 64) return fail("bad_request");
      const result = await authenticateAgent(runtimeFor(c.agent), methodId, opts.preparationTimeoutMs ?? protocol.preparationTimeoutMs);
      if (result === "ok") reply("chat.authenticated", { agent: c.agent });
      else return fail(result === "busy" ? "busy" : "auth_failed");
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
