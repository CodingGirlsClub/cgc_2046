// server.ts — 页面 ↔ Host 的本机入口（KTD4）：只绑 127.0.0.1；每个 HTTP 请求与 WS 升级先过 Host / Origin 关口；
// 只有 GET /health 与根路径的 WS 升级。WS 上一个文本帧一个 JSON 信封，方法按 protocol.json 的 pageToHost 白名单分发。
import type { ServerWebSocket } from "bun";
import { hostname } from "node:os";
import protocol from "../protocol.json";
import { InstallError } from "./agents/install";
import { type AgentKind, type AgentStatus, isAgentKind } from "./agents/registry";
import { HOST_VERSION, SITE_ORIGIN } from "./config";
import { createPairing, type DialogRunner, hashBrowserKey, revokeToken, verifyToken } from "./pairing";
import { isAllowedRequest, isObject, isUuid, sanitizeDeviceName } from "./security";
import { type HostState, loadState, type Pairing, saveState, type SessionPointers } from "./state";

/** 两个方向共用的帧信封（cgc-host/AGENTS.md）；回复带上请求的 id */
export type Message = { method: string; id?: string; params?: Record<string, unknown> };

export type ChatMethod = "chat.attach" | "chat.send" | "chat.stop" | "chat.new" | "chat.sessions" | "chat.open" | "chat.set_setting" | "chat.authenticate" | "card.answer";

export interface ChatContext {
  /** Host 向平台核实过的账号与学习凭证（KTD6：工作目录与下发给 agent 的 mcpServers 用它们） */
  userId: string;
  token: string;
  /** KTD6：每门课每个 agent 的会话指针（Host 状态文件里与配对记录同一份）；改完调 save() 落盘 */
  sessions: SessionPointers;
  /** 每门课上次显式选过的 agent（只用于 history 回包给页面做初选）；对话层的路由缺省恒为 DEFAULT_AGENT，不看它 */
  agents: Record<string, AgentKind>;
  save(): void;
  /** 只回原连接；原配对代次失效或连接断开后丢弃，不随课程接管迁移 */
  reply(message: Message): void;
  /** 当前配对代次内，推给这门课已授权的当前持有者；重新配对后须由新 attach 更新绑定 */
  push(message: Message): void;
}

/** 对话处理器（U6 实现）：courseId 已校验为 UUID，发起连接已授权且持有这门课；其余参数由处理器自己校验 */
export type ChatHandler = (
  method: ChatMethod,
  params: Record<string, unknown> & { courseId: string },
  ctx: ChatContext,
) => unknown;

export interface ServerOptions {
  port: number;
  home: string;
  /** 平台 API 地址：main.ts 只传 config.ts 的 API_BASE，测试传假平台 */
  apiBase: string;
  runDialog: DialogRunner;
  /** 弹窗按哪个系统挑（默认 process.platform）；测试注入固定值 */
  platform?: NodeJS.Platform;
  /** 本机各 agent 的状态（注册表读缓存，同步）：status.agents 与 /health 都从这里取 */
  agents: () => AgentStatus[];
  /** 本机支持的能力（页面据此决定给不给安装入口）；缺省没有 */
  capabilities?: readonly string[];
  /** 安装某个 agent（缺省不支持）：进度经参数回调，失败抛错（InstallError 的 code 会回给页面） */
  install?(kind: AgentKind, progress: (phase: "installing") => void): Promise<{ version: string }>;
  /** 可安装的 kind（缺省只有 codex）；其余的 kind 回 unsupported，而不是含糊的 install_failed */
  installable?: readonly AgentKind[];
  /** 装完刷新定位器（否则页面要等缓存过期才看到新 agent） */
  refresh?(kind: AgentKind): Promise<void>;
  chat: ChatHandler;
  /** KTD13 的收尾依据：连接数变化时告诉对话处理器；断开时附上因此失去持有者的课程 */
  onConnections?: (count: number, released: string[]) => void;
  /** 每次弹窗关闭后的冷却，pair.request 的限流；默认 3 秒 */
  cooldownMs?: number;
}

type Conn = { keyHash: string | null; verified: boolean };
type WS = ServerWebSocket<Conn>;
type Frame = Message & { params: Record<string, unknown> };

interface Host {
  opts: ServerOptions;
  state: HostState;
  conns: Set<WS>;
  /** courseId → 持有这门课的连接：最后一个 chat.attach 的连接（R12） */
  holders: Map<string, WS>;
  pairing: ReturnType<typeof createPairing>;
  deviceName: string;
  /** 同一时刻只允许一个安装（第二次点会拿 busy） */
  installing: boolean;
  setPairing(pairing: Pairing | null): void;
}

const send = (ws: WS, message: Message) => ws.send(JSON.stringify(message));
/** 安装进度与结果：发起安装的连接一定要收到（全新机器上它还没配对过），其余已授权的连接一并收到 */
const broadcast = (host: Host, requester: WS, method: string, params: Record<string, unknown>) => {
  send(requester, { method, params });
  for (const ws of host.conns) if (ws !== requester && authorized(host, ws)) send(ws, { method, params });
};
const error = (id: string | undefined, code: string): Message => ({ method: "error", id, params: { code } });

/** 出示过当前浏览器密钥的连接。密钥一换（重新配对、换发、清掉），已 hello 的旧连接随之失效 */
const authorized = (host: Host, ws: WS) => ws.data.keyHash !== null && ws.data.keyHash === host.state.pairing?.browserKeyHash;

// 配对记录每次换发都会替换对象：引用身份就是本次配对代次，即使同一 socket 又 hello 成功也不能复活旧回复。
const canReply = (host: Host, ws: WS, pairing: Pairing | null) =>
  host.state.pairing === pairing && host.conns.has(ws) && authorized(host, ws);

function status(host: Host, ws: WS, id?: string): Message {
  const p = host.state.pairing;
  const agents = host.opts.agents();
  const omp = agents.find((agent) => agent.kind === "omp");
  return {
    method: "status",
    id,
    params: {
      state: !p ? "unpaired" : authorized(host, ws) ? "ready" : "paired",
      pairedUserId: p?.userId ?? null,
      pairedDisplayName: p?.displayName ?? null,
      deviceName: host.deviceName,
      tokenId: p?.tokenId ?? null,
      // 回滚桥：只认 ompPresent 的旧页面靠它继续工作；移除条件是下一个 Host 大版本
      ompPresent: omp?.present ?? false,
      ...(omp?.envError && { ompEnvError: omp.envError }),
      agents,
      capabilities: [...(host.opts.capabilities ?? [])],
      version: HOST_VERSION,
      protocolVersion: protocol.protocolVersion,
    },
  };
}

async function chat(host: Host, ws: WS, { method, id, params }: Frame) {
  const { courseId, agent } = params;
  if (!isUuid(courseId)) return send(ws, error(id, "bad_request"));
  // 页面指定的 agent 必须在本机支持的 kind 里；不带就由对话层按「这门课上次用的」取值
  if (agent !== undefined && !isAgentKind(agent)) return send(ws, error(id, "bad_request"));
  if (method === "chat.attach") {
    const previous = host.holders.get(courseId);
    host.holders.set(courseId, ws);
    if (previous && previous !== ws) send(previous, { method: "chat.evicted", params: { courseId } });
  } else if (host.holders.get(courseId) !== ws) {
    return send(ws, error(id, "not_holder"));
  }
  const pairing = host.state.pairing!; // 已授权必然已配对
  const { userId, token } = pairing;
  await host.opts.chat(method as ChatMethod, { ...params, courseId }, {
    userId,
    token,
    sessions: host.state.sessions,
    agents: host.state.agents,
    save: () => saveState(host.opts.home, host.state),
    reply(message) {
      if (canReply(host, ws, pairing)) send(ws, { ...message, id });
    },
    push(message) {
      const holder = host.holders.get(courseId);
      if (holder && canReply(host, holder, pairing)) send(holder, { ...message, id: undefined });
    },
  });
}

const handlers: Record<string, (host: Host, ws: WS, frame: Frame) => unknown> = {
  async hello(host, ws, { id, params }) {
    const p = host.state.pairing;
    if (typeof params.userId !== "string" || typeof params.browserKey !== "string") return send(ws, error(id, "bad_request"));
    if (!p || params.userId !== p.userId || hashBrowserKey(params.browserKey) !== p.browserKeyHash) {
      return send(ws, error(id, "unauthorized"));
    }
    if (!ws.data.verified) {
      // KTD16：每个连接只在 hello 时核实一次，不定时探测——每次核实都刷新 last_used_at，定时探测会让闲置过期永不触发
      ws.data.verified = true;
      if ((await verifyToken(host.opts.apiBase, p.token)) === "invalid" && host.state.pairing === p) {
        console.error("cgc-host: 平台不再认本机凭证，已清掉本机配对");
        host.setPairing(null);
      }
    }
    if (host.state.pairing === p) ws.data.keyHash = p.browserKeyHash; // 核实期间配对没被换掉才授权
    send(ws, status(host, ws, id));
  },
  async "pair.request"(host, ws, { id, params }) {
    const outcome = await host.pairing.request(ws, params);
    send(ws, "error" in outcome ? error(id, outcome.error) : { method: "pair.result", id, params: outcome });
  },
  "pair.cancel": (host, ws) => host.pairing.cancel(ws),
  async "pair.forget"(host) {
    const { token } = host.state.pairing!;
    host.setPairing(null);
    await revokeToken(host.opts.apiBase, token);
  },
  "chat.attach": chat,
  "chat.send": chat,
  "chat.stop": chat,
  "chat.new": chat,
  "chat.sessions": chat,
  "chat.open": chat,
  "chat.set_setting": chat,
  "chat.authenticate": chat,
  "card.answer": chat,
  async "agent.install"(host, ws, { id, params }) {
    if (!isAgentKind(params.kind)) return send(ws, error(id, "bad_request"));
    // 未配对的全新机器必须能装（这正是解开「没有 agent → 无法配对」的那一步）；这台机器一旦有配对记录，
    // 安装只给已 hello 的页面——不再让任意本机进程或站点来源页借未授权连接写盘、占住安装位。
    if (host.state.pairing && !authorized(host, ws)) return send(ws, error(id, "unauthorized"));
    if (!host.opts.install || !(host.opts.installable ?? ["codex"]).includes(params.kind)) return send(ws, error(id, "unsupported"));
    if (host.installing) return send(ws, error(id, "busy"));
    const kind = params.kind;
    host.installing = true;
    send(ws, { method: "agent.install.started", id, params: { started: true } });
    try {
      const { version } = await host.opts.install(kind, (phase) => broadcast(host, ws, "agent.install.progress", { kind, phase }));
      await host.opts.refresh?.(kind);
      broadcast(host, ws, "agent.done", { kind, ok: true, version });
    } catch (e) {
      const code = e instanceof InstallError ? e.code : "install_failed";
      console.error(`cgc-host: 安装 ${kind} 失败（${code}）`); // 只记错误码：安装输出里有本地路径
      broadcast(host, ws, "agent.done", { kind, ok: false, code });
    } finally {
      host.installing = false;
      for (const conn of host.conns) if (conn === ws || authorized(host, conn)) send(conn, status(host, conn));
    }
  },
};

/** 白名单即 handlers 的键，测试断言它与 protocol.json 的 pageToHost 完全一致 */
export const PAGE_METHODS = Object.keys(handlers);
/**
 * KTD4：未授权的连接只能调用这几个；status 不是页面可调的方法，由 Host 在连接时与状态变化时推送。
 * 安装也要先配对（与 chat.* 同一道授权）：否则任意能连上本机 Host 的站点来源页都能静默触发 337MB 的安装，
 * 幂等短路只挡重复、挡不住第一次；页面在配对前先给「连接这台电脑」。
 */
const OPEN_METHODS = new Set(["hello", "pair.request", "pair.cancel"]);

function parse(raw: string | Buffer): Frame | null {
  let m: unknown;
  try {
    m = typeof raw === "string" ? JSON.parse(raw) : null;
  } catch {
    return null;
  }
  if (!isObject(m)) return null;
  const { method, id, params = {} } = m;
  if (typeof method !== "string" || (id !== undefined && typeof id !== "string") || !isObject(params)) return null;
  return { method, id, params };
}

async function dispatch(host: Host, ws: WS, raw: string | Buffer) {
  const frame = parse(raw);
  if (!frame) return send(ws, error(undefined, "bad_request"));
  if (!Object.hasOwn(handlers, frame.method)) return send(ws, error(frame.id, "unknown_method"));
  if (!OPEN_METHODS.has(frame.method) && !authorized(host, ws)) return send(ws, error(frame.id, "unauthorized"));
  const pairing = host.state.pairing;
  try {
    await handlers[frame.method](host, ws, frame);
  } catch (e) {
    // 只记方法名与异常，不记帧内容：pair.* 与 hello 帧里有凭证与浏览器密钥（KTD16）
    console.error(`cgc-host: 处理 ${frame.method} 出错`, e);
    if (OPEN_METHODS.has(frame.method) || canReply(host, ws, pairing)) send(ws, error(frame.id, "internal"));
  }
}

/** 端口被占时 Bun.serve 抛出 code 为 EADDRINUSE 的错误，由调用方决定怎么退出 */
export function startServer(opts: ServerOptions) {
  const state = loadState(opts.home);
  const conns = new Set<WS>();
  const setPairing = (pairing: Pairing | null) => {
    const released = [...host.holders.keys()];
    host.holders.clear();
    state.pairing = pairing;
    saveState(opts.home, state);
    // 清除或换发配对会让旧连接失去授权，即使 socket 没断，也不能再算课程持有者。
    // 通知对话层启动无人作答的宽限期；新连接 hello + attach 后可恢复持有权。
    opts.onConnections?.(conns.size, released);
    for (const ws of conns) send(ws, status(host, ws));
  };
  const host: Host = {
    opts,
    state,
    conns,
    holders: new Map(),
    deviceName: sanitizeDeviceName(hostname()),
    installing: false,
    setPairing,
    pairing: createPairing({
      apiBase: opts.apiBase,
      runDialog: opts.runDialog,
      platform: opts.platform,
      cooldownMs: opts.cooldownMs ?? 3000,
      getPairing: () => state.pairing,
      setPairing,
    }),
  };
  const cors = { "access-control-allow-origin": SITE_ORIGIN, vary: "Origin" };

  return Bun.serve({
    hostname: "127.0.0.1", // Bun 默认绑 0.0.0.0，会把能驱动 agent 的接口暴露到局域网（R23）
    port: opts.port,
    fetch(req, server) {
      if (!isAllowedRequest(req, server.port!)) return new Response(null, { status: 403 });
      const { pathname } = new URL(req.url);
      if (pathname === "/health" && req.method === "GET") {
        const agents = opts.agents();
        return Response.json(
          {
            version: HOST_VERSION,
            // 回滚桥：只认 ompPresent 的旧页面靠它继续工作（与 status 同一口径）
            ompPresent: agents.some((agent) => agent.kind === "omp" && agent.present),
            paired: state.pairing !== null,
            agents,
            capabilities: [...(opts.capabilities ?? [])],
          },
          { headers: cors },
        );
      }
      if (pathname === "/health" && req.method === "OPTIONS") {
        return new Response(null, { status: 204, headers: { ...cors, "access-control-allow-methods": "GET" } });
      }
      if (pathname === "/" && server.upgrade(req, { data: { keyHash: null, verified: false } })) return;
      return new Response(null, { status: 404 });
    },
    websocket: {
      data: {} as Conn,
      open(ws) {
        conns.add(ws);
        send(ws, status(host, ws));
        opts.onConnections?.(conns.size, []);
      },
      close(ws) {
        conns.delete(ws);
        const released: string[] = [];
        for (const [courseId, holder] of host.holders) {
          if (holder !== ws) continue;
          host.holders.delete(courseId);
          released.push(courseId);
        }
        opts.onConnections?.(conns.size, released);
      },
      message(ws, raw) {
        void dispatch(host, ws, raw);
      },
    },
  });
}
