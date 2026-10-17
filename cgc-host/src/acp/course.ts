// course.ts — 一门课的对话记录（U6）：当前 agent、会话指针、缓冲、卡片、设置与排队；由 session.ts 读写。
import type { ChatContext, Message } from "../server";
import type { AgentKind } from "../agents/registry";
import { type Cards, createCards } from "./cards";
import { createTranscript, type Transcript } from "./events";
import type { ConfigOption } from "./settings";

/** sessionId 在 session/prompt 发出时才填：之前（含拉起会话时 session/load 的回放）收到的更新只进缓冲，不推给页面 */
export interface Turn {
  stopping: boolean;
  sessionId: string | null;
  text: string;
}

export interface Course {
  id: string;
  /** 这段对话现在由哪个 agent 驱动；换成另一个 agent 就是换一段会话（见 session.ts 的 handle 与 course） */
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
  /** agent 给的会话设置项（模型、思考等级，收窄后）：新一轮会话从它的回包里刷新 */
  settings: ConfigOption[];
  /** 上一次推给页面的设置（JSON）：内容没变就不重复推；null 表示还没同步过 */
  settingsKey: string | null;
  graceTimer: Timer | null;
  /** 同一门课的会话操作（new / load）排队执行 */
  queue: Promise<unknown>;
}

/** 新建一门课的对话记录；页面连接就是持有者（server.ts 已判定） */
export function createCourse(id: string, agent: AgentKind, ctx: ChatContext): Course {
  const course: Course = {
    id,
    agent,
    send: ctx.push,
    held: true,
    sessionId: null,
    userId: ctx.userId,
    token: ctx.token,
    transcript: createTranscript(),
    cards: createCards((method, params) => course.send({ method, params: { courseId: id, ...params } })),
    turn: null,
    lastContext: null,
    settings: [],
    settingsKey: null,
    graceTimer: null,
    queue: Promise.resolve(),
  };
  return course;
}
