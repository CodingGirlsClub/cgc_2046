// acp/session.ts — 对话处理器（U6）：每门课一条 ACP 会话（KTD6）；一个 OMP 进程服务全部会话，按需拉起、空闲回收（KTD13）；
// session/update 归一化成页面事件（events.ts），审批与提问交给持有者作答（cards.ts）。载荷契约见 cgc-host/AGENTS.md。
import { mkdirSync } from "node:fs";
import { type ClientApp, type ContentBlock, type McpServer, PROTOCOL_VERSION, type PromptResponse } from "@agentclientprotocol/sdk";
import type { ChatContext, ChatMethod, Message } from "../server";
import { isUuid } from "../security";
import { workDir } from "../state";
import { type Cards, createCards } from "./cards";
import { type Agent, clientApp } from "./client";
import { type ChatEvent, classifyModelError, createTranscript, type Transcript } from "./events";

export interface ChatOptions {
  home: string;
  /** 平台 API 地址：下发给 OMP 的 cgc-2046 MCP 服务器是 `${apiBase}/mcp` */
  apiBase: string;
  /** 连上 agent：main.ts 拉起 omp acp，测试接进程内的假 agent；找不到或起不来就抛错 */
  start(app: ClientApp): Promise<Agent>;
  /** KTD13：没有页面持有这门课、卡片待答超过它，就取消本轮；默认 5 分钟 */
  graceMs?: number;
  /** KTD13：没有页面连着、也没有在跑的回合超过它，就回收 OMP 进程；默认 10 分钟 */
  idleMs?: number;
}

/** sessionId 在 session/prompt 发出时才填：之前（含拉起会话时 session/load 的回放）收到的更新只进缓冲，不推给页面 */
type Turn = { stopping: boolean; sessionId: string | null; text: string };

interface Course {
  id: string;
  /** 发给这门课当前的持有者（server.ts 的 ctx.send）；没有持有者时丢弃，事件仍在缓冲里 */
  send(message: Message): void;
  held: boolean;
  /** 已在当前 OMP 进程里 new / load 的会话，以及加载它用的账号与凭证 */
  sessionId: string | null;
  userId: string;
  token: string;
  transcript: Transcript;
  cards: Cards;
  turn: Turn | null;
  /** 上一次随消息附带的页面上下文（KTD8）：没变就不再附 */
  lastContext: string | null;
  graceTimer: Timer | null;
  /** 同一门课的会话操作（new / load）排队执行 */
  queue: Promise<unknown>;
}

const UNIT_ID = /^[A-Za-z0-9_.-]{1,64}$/;

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

const message = (e: unknown) => String((e as Error)?.message ?? e);

export function createChat(opts: ChatOptions) {
  const graceMs = opts.graceMs ?? 5 * 60_000;
  const idleMs = opts.idleMs ?? 10 * 60_000;
  const courses = new Map<string, Course>();
  const bySession = new Map<string, Course>();
  let agent: Agent | null = null;
  let starting: Promise<Agent> | null = null;
  let connections = 0;
  let idleTimer: Timer | null = null;

  const delta = (c: Course, event: ChatEvent) => c.send({ method: "turn.delta", params: { courseId: c.id, ...event } });

  const app = clientApp({
    update({ sessionId, update }) {
      const c = bySession.get(sessionId);
      const event = c?.transcript.apply(update);
      if (!c || !event || !c.turn?.sessionId) return;
      if (event.kind === "message") c.turn.text += event.text;
      delta(c, event);
    },
    permission(req, signal) {
      const c = bySession.get(req.sessionId);
      if (!c) return Promise.resolve({ outcome: { outcome: "cancelled" } });
      const answer = c.cards.permission(req, signal);
      checkGrace(c);
      return answer;
    },
    question(req, signal) {
      const c = "sessionId" in req && typeof req.sessionId === "string" ? bySession.get(req.sessionId) : undefined;
      if (!c) return Promise.resolve({ action: "decline" });
      const answer = c.cards.question(req, signal);
      checkGrace(c);
      return answer;
    },
  });

  function ensureAgent(): Promise<Agent> {
    if (agent) return Promise.resolve(agent);
    starting ??= (async () => {
      const a = await opts.start(app);
      try {
        // KTD5：只声明 elicitation.form（OMP 据此注册 ask 工具、经 elicitation/create 提问）
        await a.rpc.request("initialize", { protocolVersion: PROTOCOL_VERSION, clientCapabilities: { elicitation: { form: {} } } });
      } catch (e) {
        a.close();
        throw e;
      }
      agent = a;
      void a.closed.then(() => {
        if (agent !== a) return;
        // 进程退出或被回收：会话随之卸下，下次需要时重新 session/load；在跑的 session/prompt 会以失败结束
        agent = null;
        bySession.clear();
        for (const [id, c] of courses) {
          c.sessionId = null;
          // Host 常驻数周：无人持有、没有在跑的回合与待答卡片的课程不再留在内存里（连同它的事件缓冲）；
          // 下次 chat.attach 重新建，历史从 OMP 的会话存储回放
          if (!c.held && !c.turn && c.cards.size === 0) courses.delete(id);
        }
        checkIdle();
      });
      checkIdle();
      return a;
    })().finally(() => {
      starting = null;
    });
    return starting;
  }

  const cgcServer = (token: string): McpServer => ({
    type: "http",
    name: "cgc-2046", // 与终端插件同名
    url: `${opts.apiBase}/mcp`,
    headers: [{ name: "authorization", value: `Bearer ${token}` }],
  });

  /** KTD6：指针指向的会话必须登记在这门课的工作目录下才加载——比如换了账号，指针还指着上一个账号的对话 */
  async function belongs(a: Agent, cwd: string, sessionId: string): Promise<boolean> {
    let cursor: string | undefined;
    do {
      const page = await a.rpc.request("session/list", { cwd, ...(cursor && { cursor }) });
      if (page.sessions.some((s) => s.sessionId === sessionId)) return true;
      cursor = page.nextCursor ?? undefined;
    } while (cursor);
    return false;
  }

  /**
   * 让这门课在当前 OMP 进程里有一条可用的会话（KTD6）：
   * - attach：已有指针才拉起 OMP 并 session/load（回放历史）；没有对话就不为空历史拉起进程（KTD13）；
   * - send：有指针加载，没有就 session/new 并记下指针；
   * - new：「新开对话」，总是 session/new，指针改指新会话。
   * session/new 与每次 session/load 都下发含当前凭证的 mcpServers；换了账号或凭证就重新加载。
   */
  async function ensureSession(c: Course, ctx: ChatContext, mode: "attach" | "send" | "new"): Promise<{ a: Agent; sessionId: string } | null> {
    // 有一轮正在 OMP 里跑时不重新加载：重新 load 会让 OMP 把历史整段再回放一遍
    const current = agent && c.sessionId && (c.turn?.sessionId || (c.userId === ctx.userId && c.token === ctx.token)) ? c.sessionId : null;
    if (mode !== "new" && current) return { a: agent!, sessionId: current };
    // 不再沿用当前会话（新开、换了账号或凭证、OMP 重启过）：先卸下并清空缓冲——上一段对话不能出现在接下来的历史里
    if (c.sessionId) bySession.delete(c.sessionId);
    c.sessionId = null;
    c.lastContext = null;
    c.transcript.reset();
    const pointer = mode === "new" ? undefined : ctx.sessions[c.id];
    if (mode === "attach" && !pointer) return null;
    const a = await ensureAgent();
    const cwd = workDir(opts.home, ctx.userId, c.id);
    const mcpServers = [cgcServer(ctx.token)];
    if (pointer && (await belongs(a, cwd, pointer))) {
      bySession.set(pointer, c);
      try {
        await a.rpc.request("session/load", { sessionId: pointer, cwd, mcpServers }); // 历史经 session/update 回放进缓冲
      } catch (e) {
        bySession.delete(pointer);
        throw e;
      }
      Object.assign(c, { sessionId: pointer, userId: ctx.userId, token: ctx.token });
      return { a, sessionId: pointer };
    }
    if (pointer) {
      console.error("cgc-host: 会话指针不在这门课的工作目录下，拒绝加载");
      delete ctx.sessions[c.id];
      ctx.save();
      if (mode === "attach") return null;
    }
    mkdirSync(cwd, { recursive: true });
    const { sessionId } = await a.rpc.request("session/new", { cwd, mcpServers });
    bySession.set(sessionId, c);
    Object.assign(c, { sessionId, userId: ctx.userId, token: ctx.token });
    ctx.sessions[c.id] = sessionId;
    ctx.save();
    return { a, sessionId };
  }

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

  /** R29：发 session/cancel；待答审批以 cancelled 结束、提问清掉，在跑的工具标为已停止；turn.end 随 OMP 的 cancelled 应答而来 */
  function stop(c: Course) {
    const turn = c.turn;
    if (!turn || turn.stopping) return;
    turn.stopping = true;
    if (agent && turn.sessionId) void agent.rpc.notify("session/cancel", { sessionId: turn.sessionId }).catch(() => {});
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

  /** KTD13：没有页面连着、也没有在跑的回合，超过空闲期就回收 OMP 进程；下次需要时再拉起并 session/load */
  function checkIdle() {
    const idle = () => agent !== null && connections === 0 && ![...courses.values()].some((c) => c.turn);
    if (idle() && !idleTimer) {
      idleTimer = setTimeout(() => {
        idleTimer = null;
        if (!idle()) return;
        console.log("cgc-host: 空闲，回收 OMP 进程");
        agent!.close();
      }, idleMs);
      idleTimer.unref();
    } else if (!idle() && idleTimer) {
      clearTimeout(idleTimer);
      idleTimer = null;
    }
  }

  function course(id: string, ctx: ChatContext): Course {
    let c = courses.get(id);
    if (!c) {
      const created: Course = {
        id,
        send: ctx.send,
        held: true,
        sessionId: null,
        userId: ctx.userId,
        token: ctx.token,
        transcript: createTranscript(),
        cards: createCards((method, params, replyId) => created.send({ method, id: replyId, params: { courseId: id, ...params } })),
        turn: null,
        lastContext: null,
        graceTimer: null,
        queue: Promise.resolve(),
      };
      courses.set(id, (c = created));
    }
    // 能调到这里的连接就是这门课的持有者（server.ts 已判定）
    c.send = ctx.send;
    c.held = true;
    checkGrace(c);
    return c;
  }

  async function handle(method: ChatMethod, params: Record<string, unknown> & { courseId: string }, ctx: ChatContext) {
    const c = course(params.courseId, ctx);
    const reply = (m: string, p: Record<string, unknown>) => ctx.send({ method: m, id: ctx.id, params: { courseId: c.id, ...p } });
    const fail = (code: string) => ctx.send({ method: "error", id: ctx.id, params: { code } });

    if (method === "chat.attach") {
      try {
        await serial(c, () => ensureSession(c, ctx, "attach"));
      } catch (e) {
        console.error(`cgc-host: 加载对话失败：${message(e)}`);
        return fail("chat_unavailable");
      }
      reply("history", { running: c.turn !== null, events: c.transcript.events });
      for (const view of c.cards.views()) c.send({ method: "turn.card", params: { courseId: c.id, ...view } }); // 未答的卡片重新出现
    } else if (method === "chat.send") {
      const { text } = params;
      const context = pageContext(params.context, c.id);
      if (typeof text !== "string" || !text.trim() || context === null) return fail("bad_request");
      if (c.turn) return fail("busy");
      const turn: Turn = { stopping: false, sessionId: null, text: "" };
      c.turn = turn;
      checkIdle();
      let ready: { a: Agent; sessionId: string } | null;
      try {
        ready = await serial(c, () => ensureSession(c, ctx, "send"));
      } catch (e) {
        console.error(`cgc-host: 无法开始对话：${message(e)}`);
        c.turn = null;
        checkIdle();
        return fail("chat_unavailable");
      }
      const { a, sessionId } = ready!;
      // KTD8：上下文块只在会话的首条消息与单元切换时附带
      const prompt: ContentBlock[] = [{ type: "text", text }];
      if (context !== c.lastContext) prompt.unshift({ type: "text", text: `<cgc-page-context>${context}</cgc-page-context>` });
      c.lastContext = context;
      c.transcript.push({ kind: "user", text });
      reply("turn.delta", { kind: "user", text });
      if (turn.stopping) return finish(c, turn, { stopReason: "cancelled" }); // 拉起会话期间学员已点停止
      turn.sessionId = sessionId;
      a.rpc.request("session/prompt", { sessionId, prompt }).then(
        (res) => finish(c, turn, res),
        (e) => {
          console.error(`cgc-host: 本轮对话失败：${message(e)}`);
          finish(c, turn, null);
        },
      );
    } else if (method === "chat.stop") {
      stop(c);
    } else if (method === "chat.new") {
      if (c.turn) return fail("busy");
      try {
        await serial(c, () => ensureSession(c, ctx, "new"));
      } catch (e) {
        console.error(`cgc-host: 新开对话失败：${message(e)}`);
        return fail("chat_unavailable");
      }
      reply("history", { running: false, events: [] });
    } else if (method === "card.answer") {
      if (!c.cards.answer(params, ctx.id)) return fail("bad_request");
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
