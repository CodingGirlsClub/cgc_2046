"use client";

/**
 * 课程页对话栏的状态源（U10；R8、R12、R13、R14、R17、R26–R29；KTD8、KTD9、KTD14；ADR-0022）。
 * 载荷契约见 cgc-host/AGENTS.md「对话的载荷契约」。只产出状态，不带文案。
 *
 * - 连接（R28）：没有连接时每 POLL_MS 跑一次 checkHost（本机访问未授权时它不发请求）；探到可用的 Host 就开连接，
 *   连接关闭后回到轮询，Host 恢复即重连。第一次本机请求只能由点击发起：requestAccess 只从按钮调用。
 * - 配对交给 useHostPairing（它用已存的浏览器密钥自动 hello）；进入 ready 即 chat.attach，取回历史、接上原对话。
 * - 事件归约同 Host：文字与上一条同 kind、同 messageId 就拼接，工具按 toolCallId 整段替换；usage 不显示，丢弃。
 * - KTD14：history、turn.card、turn.end 时按本课程重取学习详情，不轮询。
 * - KTD9：页面不自动发消息，首条由学员发起。
 * 换账号、换课程由调用方用 key 重新挂载：连接与对话从头来过。
 */

import { useCallback, useEffect, useReducer, useRef, useState } from "react";
import { useApolloClient } from "@apollo/client/react";
import { COURSE_LEARNING_DETAIL } from "@/lib/graphql/participations";
import { checkHost, requestHostAccess, type HostAgentStatus, type HostConnection } from "@/lib/host-connection";
import { openHostSocket, type HostMessage, type HostSocket } from "@/lib/host-socket";
import { useHostPairing, type HostPairing, type PairingErrorReason } from "./use-host-pairing";

/** 没有连接时重新检测的间隔：装好 Host、装好 OMP、Host 恢复，都在这个时间内被发现 */
export const POLL_MS = 3_000;
/** chat.attach / chat.send / chat.new 可能要先拉起 agent 并加载会话 */
export const CHAT_TIMEOUT_MS = 60_000;
/** 登录可能在浏览器里停留很久（ChatGPT 登录跳转 + 学员操作） */
export const AUTH_TIMEOUT_MS = 120_000;
const CARD_TIMEOUT_MS = 15_000;

export type ToolStatus = "pending" | "in_progress" | "completed" | "failed" | "stopped";
export type ModelError = "auth" | "quota" | "unknown";

/** turn.delta 的载荷与 history 的条目（usage 除外）；end 是一轮的结束，live 时由 turn.end 补进来 */
export type ChatEvent =
	| { kind: "user" | "message" | "thought"; text: string; messageId?: string }
	| {
			kind: "tool";
			toolCallId: string;
			title: string;
			toolKind: string;
			status: ToolStatus;
			input?: string;
			output?: string;
	  }
	| { kind: "end"; stopReason: string; modelError?: ModelError };

export interface EnumOption {
	const: string;
	title: string;
}
/** 提问卡片的 JSON Schema 属性（ACP elicitation 的 form 模式）；未知 type 不渲染 */
export interface QuestionProperty {
	type: string;
	title?: string | null;
	description?: string | null;
	enum?: string[] | null;
	oneOf?: EnumOption[] | null;
	items?: { enum?: string[] | null; anyOf?: EnumOption[] | null };
}

export type ChatCard =
	| {
			cardId: string;
			kind: "permission";
			toolCallId: string;
			title: string;
			toolKind: string | null;
			input?: string;
			/** 原样来自学员的 OMP：与终端里一致（R19） */
			options: { optionId: string; name: string; kind: string }[];
	  }
	| {
			cardId: string;
			kind: "question";
			message: string;
			schema: { properties?: Record<string, QuestionProperty> };
	  };

export type AnswerValue = string | number | boolean | string[];
export type CardAnswer =
	| { optionId: string }
	| { action: "accept"; content: Record<string, AnswerValue> }
	| { action: "decline" };

/** Host 的 error.params.code（含义见 cgc-host/AGENTS.md），或拿不到回复（timeout / disconnected） */
export type ChatErrorCode = string;

/** chat.sessions 的返回：本课程的历史对话（updatedAt / messageCount 缺省为 null，OMP 版本差异） */
export interface SessionsPage {
	sessions: { sessionId: string; updatedAt: string | null; messageCount: number | null }[];
	current: string | null;
	nextCursor: string | null;
}

/** history 的 settings 与 chat.settings 的载荷：Host 收窄后的会话设置（模型、OMP 的思考等级 / Codex 的推理强度） */
export interface HostChatSetting {
	id: string;
	name: string;
	category: string;
	currentValue: string;
	options: { value: string; name: string; description?: string }[];
}

/** R26 的状态：一处状态源。ready / evicted 时对话可见 */
export type ChatView =
	| Exclude<HostConnection, { state: "detected" }>
	| { state: "checking" | "noAgent" | "disconnected" | "unpaired" | "confirming" | "denied" | "ready" | "evicted" }
	| { state: "pairingFailed"; reason: PairingErrorReason };

interface ChatState {
	/** 收到本连接的 history：这条连接持有这门课，可以发送 */
	attached: boolean;
	events: ChatEvent[];
	cards: ChatCard[];
	/** 本机 agent 的会话设置（模型、OMP 的思考等级 / Codex 的推理强度）；空数组表示不渲染入口（旧版 Host 或 agent 不给） */
	settings: HostChatSetting[];
	running: boolean;
	sending: boolean;
	stopping: boolean;
	evicted: boolean;
	error: ChatErrorCode | null;
}

const INITIAL: ChatState = {
	attached: false,
	events: [],
	cards: [],
	settings: [],
	running: false,
	sending: false,
	stopping: false,
	evicted: false,
	error: null,
};

type Action =
	| { type: "reset" }
	| { type: "history"; running: boolean; events: ChatEvent[]; settings: HostChatSetting[] }
	| { type: "settings"; settings: HostChatSetting[] }
	| { type: "delta"; event: ChatEvent }
	| { type: "card"; card: ChatCard }
	| { type: "cardClosed"; cardId: string }
	| { type: "end"; stopReason: string; modelError?: ModelError }
	| { type: "evicted" }
	| { type: "sending" }
	| { type: "stop" }
	| { type: "error"; code: ChatErrorCode };

function append(events: ChatEvent[], event: ChatEvent): ChatEvent[] {
	if (event.kind === "tool") {
		const at = events.findIndex((e) => e.kind === "tool" && e.toolCallId === event.toolCallId);
		return at >= 0 ? events.with(at, event) : [...events, event];
	}
	const last = events.at(-1);
	if (event.kind !== "end" && last?.kind === event.kind && last.messageId === event.messageId) {
		return [...events.slice(0, -1), { ...last, text: last.text + event.text }];
	}
	return [...events, event];
}

function reduce(state: ChatState, action: Action): ChatState {
	switch (action.type) {
		case "reset":
			return INITIAL;
		case "history":
			// 未答的卡片随后由 Host 逐张重发
			return {
				...INITIAL,
				attached: true,
				running: action.running,
				events: action.events.reduce(append, []),
				settings: action.settings,
			};
		case "settings":
			// 设置不进对话记录，只刷新入口的当前值与可选值
			return { ...state, settings: action.settings };
		case "delta":
			// kind: user 是 chat.send 的回复：Host 接下了这一轮
			return action.event.kind === "user"
				? { ...state, sending: false, running: true, events: append(state.events, action.event) }
				: { ...state, events: append(state.events, action.event) };
		case "card":
			return state.cards.some((c) => c.cardId === action.card.cardId) ? state : { ...state, cards: [...state.cards, action.card] };
		case "cardClosed":
			// 收起的可能是本页没显示过的卡片（别的标签页答的、回合结束统一收起的）：没有就原样返回，不触发重渲染
			return state.cards.some((c) => c.cardId === action.cardId)
				? { ...state, cards: state.cards.filter((c) => c.cardId !== action.cardId) }
				: state;
		case "end":
			return {
				...state,
				running: false,
				stopping: false,
				cards: [],
				events: append(state.events, { kind: "end", stopReason: action.stopReason, modelError: action.modelError }),
			};
		case "evicted":
			return { ...state, evicted: true, cards: [] };
		case "sending":
			return { ...state, sending: true, error: null };
		case "stop":
			// R29：等待回答的卡片立刻收起；输入在 turn.end 到达时恢复
			return { ...state, stopping: true, cards: [] };
		case "error":
			return action.code === "not_holder"
				? { ...state, sending: false, evicted: true, cards: [] }
				: { ...state, sending: false, error: action.code };
	}
}

/** 推送、回复的 params 与 history 的条目去掉 courseId 即事件本身；usage 不显示 */
function eventOf(params: Record<string, unknown>): ChatEvent | null {
	const event = { ...params };
	delete event.courseId;
	return event.kind === "usage" ? null : (event as unknown as ChatEvent);
}

/** settings 载荷只应来自 Host：形状不合就按空处理（旧版 Host 不带这个字段，页面据此不渲染入口） */
function settingsOf(params: Record<string, unknown>): HostChatSetting[] {
	if (!Array.isArray(params.settings)) return [];
	return params.settings.flatMap((item) => {
		if (typeof item !== "object" || item === null) return [];
		const option = item as Record<string, unknown>;
		if (typeof option.id !== "string" || typeof option.currentValue !== "string" || !Array.isArray(option.options)) return [];
		return [
			{
				id: option.id,
				name: typeof option.name === "string" ? option.name : option.id,
				category: typeof option.category === "string" ? option.category : option.id,
				currentValue: option.currentValue,
				options: option.options.flatMap((raw) => {
					if (typeof raw !== "object" || raw === null) return [];
					const value = raw as Record<string, unknown>;
					if (typeof value.value !== "string" || typeof value.name !== "string") return [];
					return [{ value: value.value, name: value.name, ...(typeof value.description === "string" ? { description: value.description } : {}) }];
				}),
			},
		];
	});
}

/** 本机至少有一个装好的 agent（R1：一个都没有时给安装指引，而不是只提 OMP） */
const hasAgent = (agents: readonly HostAgentStatus[]) => agents.some((agent) => agent.present);

/** 要不要开连接：有 agent 就要（对话/配对）；一个都没有但 Host 能装，也要——安装请求得走这条连接 */
const needsSocket = (probe: HostConnection) =>
	probe.state === "detected" && (hasAgent(probe.agents) || (probe.capabilities ?? []).includes("agent.install"));

function viewOf(
	probe: HostConnection | null,
	socket: HostSocket | null,
	lost: boolean,
	pairing: HostPairing,
	evicted: boolean,
	agents: readonly HostAgentStatus[],
): ChatView {
	if (!socket) {
		// 探到有可用的 agent 到连接打开之间、连接刚断还没重新检测，都只是过渡
		if (!probe || needsSocket(probe)) return { state: lost ? "disconnected" : "checking" };
		if (lost && probe.state === "noHost") return { state: "disconnected" };
		if (probe.state === "detected") return { state: "noAgent" };
		return probe;
	}
	if (pairing.phase === "ready") {
		// 配对之后还没有可用的 agent：停在「没有可用的 agent」，安装入口在这里（用活的 agents，装完由 status 推送刷新）
		const liveAgents = agents.length > 0 ? agents : probe?.state === "detected" ? probe.agents : [];
		return hasAgent(liveAgents) ? (evicted ? { state: "evicted" } : { state: "ready" }) : { state: "noAgent" };
	}
	if (pairing.phase === "error") return { state: "pairingFailed", reason: pairing.reason ?? "failed" };
	return { state: pairing.phase };
}

export interface HostChat extends Omit<ChatState, "evicted"> {
	view: ChatView;
	pairing: HostPairing;
	/** 已接上对话、未被接管、没有在跑或在发的一轮 */
	canSend: boolean;
	/** 只从点击处理器调用：第一次本机请求必须由用户手势发起 */
	requestAccess(): void;
	/** 返回 Host 是否接下了这条消息 */
	send(text: string): Promise<boolean>;
	stop(): void;
	newChat(): void;
	answer(cardId: string, answer: CardAnswer): Promise<void>;
	/** 被接管后「在这里继续」，或接上对话失败后重试 */
	reclaim(): void;
	/** 列出本课程的历史对话；Host 不认识这个方法（旧版）或读取失败时返回错误码 */
	listSessions(cursor?: string): Promise<SessionsPage | { error: ChatErrorCode }>;
	/** 切换到某个历史会话；成功即由 history 回复接管归约，失败返回错误码且不影响当前会话 */
	openSession(sessionId: string): Promise<{ ok: true } | { ok: false; code: ChatErrorCode }>;
	/** 改当前会话的设置（模型、思考/推理强度）；成功即由 chat.settings 回复接管归约，失败返回错误码 */
	setSetting(configId: string, value: string): Promise<{ ok: true } | { ok: false; code: ChatErrorCode }>;
	/** 本机各 agent 的安装状态（KTD1）：选择器与「添加 agent」都读它 */
	agents: HostAgentStatus[];
	/** 这段对话由哪个 agent 驱动（R2：这台浏览器上次选过的 → Host 记的这门课上次用过的 → 唯一可用的 → 省略、由 Host 按 omp 处理）；偏好不在本机时回落到可用的那个 */
	agent: string;
	/** 切到另一个 agent：换一段会话（KTD8），旧的在跑回合由 Host 先按取消收尾，这里随后重新 attach */
	chooseAgent(kind: string): void;
	/** 这个 agent 要求先登录时的登录方式（协商得来的清单）；null 表示当前不需要登录 */
	login: { id: string; name: string }[] | null;
	/** 发起登录（Codex 的 chat-gpt 会在学员本机开浏览器）；成功后自动重新 attach */
	authenticate(methodId: string): Promise<{ ok: true } | { ok: false; code: ChatErrorCode }>;
	/** 重新探测 /health（学员刚装好另一个 agent 时用），返回最新的安装状态 */
	refreshAgents(): Promise<HostAgentStatus[] | null>;
	/** 本机声明的能力（如 "agent.install"）：页面据此决定给不给一键安装入口 */
	capabilities: string[];
	/** 一键安装的状态：null 没在装；"installing" 进行中；{ error } 失败可重试 */
	install: "installing" | { error: string } | null;
	/** 最近一次安装的结果：reuse = 复用学员已有 Codex（只装适配器）；null 未知 */
	installOutcome: "reuse" | "full" | null;
	/** 请 Host 装 Codex 适配器（只有 capabilities 含 agent.install 时才有意义） */
	installAgent(): Promise<void>;
}

export function useHostChat({
	courseId,
	userId,
	locale,
	workspaceId,
	courseVersion,
	unitId,
}: {
	courseId: string;
	userId: string;
	locale: string;
	workspaceId: string;
	/** 页面显示的课程版本号，未知为 null */
	courseVersion: number | null;
	/** 学员正在看的单元 id，总览为 null */
	unitId: string | null;
}): HostChat {
	const client = useApolloClient();
	const [probe, setProbe] = useState<HostConnection | null>(null);
	const [socket, setSocket] = useState<HostSocket | null>(null);
	/** 连接断过：之后连不上就显示「连接中断」而不是「未检测到 Host」 */
	const [lost, setLost] = useState(false);
	const accessRef = useRef<() => void>(() => {});
	const ownership = useRef(0);
	const pairing = useHostPairing({ socket, userId, locale });
	const [chat, dispatch] = useReducer(reduce, INITIAL);
	/** 本机各 agent 的状态：探测结果更新它；选择器与「添加 agent」都读它 */
	const [agents, setAgents] = useState<HostAgentStatus[]>([]);
	/** 一键安装的状态（期 2）：null 没在装；"installing" 进行中；{ error } 失败可重试 */
	const [install, setInstall] = useState<"installing" | { error: string } | null>(null);
	/** 最近一次安装的结果（Host 的 agent.done.reused）：复用已有 Codex 还是全量安装 */
	const [installOutcome, setInstallOutcome] = useState<"reuse" | "full" | null>(null);
	/** 这台浏览器上次选过的 agent（只是偏好）：实际路由要看它在本机是否可用，见 effectiveAgent */
	const [preferred, setPreferred] = useState(() => {
		try {
			return window.localStorage.getItem(`cgc-host-agent:${courseId}`) ?? "";
		} catch {
			return ""; // 隐私模式下不可读：少一层记忆，不影响默认（Host 会按 omp 处理）
		}
	});
	/** agent 要求先登录时的登录方式（auth_required 带回）；登录成功或重新接上对话后清掉 */
	const [login, setLogin] = useState<{ id: string; name: string }[] | null>(null);
	/** 本机当前能用的那个 agent（R2 的回落）：记忆里那个装好了就用它，否则用第一个装好的；都没有就留空（Host 按 omp 处理）。
	 *  展示与路由共用这一个值——不出现「标题写着 OMP、请求却带着另一个 agent」的分叉。 */
	const agent = agents.some((entry) => entry.present && entry.kind === preferred)
		? preferred
		: (agents.find((entry) => entry.present)?.kind ?? "");
	/** 本机能做什么（/health 的 capabilities，期 2 起有 "agent.install"）；旧 Host 不带、按空处理 */
	const capabilities = probe?.state === "detected" ? (probe.capabilities ?? []) : [];
	const anyAgent = agents.some((entry) => entry.present);

	useEffect(() => {
		let cancelled = false;
		let current: HostSocket | null = null;
		let timer: ReturnType<typeof setTimeout> | undefined;
		let previouslyReachedHost = false;
		const check = () => void checkHost({ previouslyReachedHost }).then(apply);
		function apply(result: HostConnection) {
			if (cancelled || current) return;
			clearTimeout(timer);
			// 探测到 Host 的应答（detected / 版本过旧的 staleHost）都算「本轮连上过」：请求本身已经证明
			// loopback 可达。sessionStorage 不可用时（隐私模式）只能靠它，否则下一次轮询会退回授权卡。
			if (result.state === "detected" || result.state === "staleHost") previouslyReachedHost = true;
			// 没连上时每 3 秒检测一次，结果多半没变：内容相同就沿用旧对象，对话栏不随轮询重渲染
			setProbe((prev) => {
				// 被动权限查询没有新探测结果，不能抹掉上次点击失败后的下一步指引。
				if (result.state === "needsPermission" && prev?.state === "needsPermission" && prev.probeFailed) return prev;
				return prev && JSON.stringify(prev) === JSON.stringify(result) ? prev : result;
			});
			if (result.state === "detected") setAgents(result.agents);
			if (result.state === "detected" && needsSocket(result)) {
				const opened = openHostSocket();
				current = opened;
				opened.onClose(() => {
					if (cancelled) return;
					ownership.current += 1;
					current = null;
					setSocket(null);
					setInstall(null); // 装到一半断线：别把「正在安装」永久留在按钮上
					setInstallOutcome(null);
					setLost(true);
					dispatch({ type: "reset" });
					timer = setTimeout(check, POLL_MS);
				});
				setSocket(opened);
			} else if (result.state !== "unsupported") {
				// 不受支持的浏览器或地址换不了，不再检测；其余等学员装好、授权或 Host 恢复
				timer = setTimeout(check, POLL_MS);
			}
		}
		accessRef.current = () => void requestHostAccess().then(apply);
		check();
		return () => {
			cancelled = true;
			ownership.current += 1;
			clearTimeout(timer);
			current?.close();
		};
	}, []);

	const refetch = useCallback(() => {
		client
			.refetchQueries({
				include: [COURSE_LEARNING_DETAIL],
				onQueryUpdated: (query) => query.variables?.courseId === courseId,
			})
			// 重取失败由页面上这条查询自己的错误态呈现
			.catch(() => {});
	}, [client, courseId]);

	const onReply = useCallback(
		(reply: HostMessage) => {
			const params = reply.params ?? {};
			if (reply.method === "error") {
				// agent 要求先登录：出登录卡（登录方式由它的握手协商得来），其余错误照旧
				if (params.code === "auth_required") {
					setLogin(((params.methods as { id: string; name: string }[]) ?? []).filter((m) => typeof m?.id === "string"));
					return;
				}
				return dispatch({ type: "error", code: String(params.code) });
			}
			if (reply.method === "history") {
				const events = ((params.events as Record<string, unknown>[]) ?? []).flatMap((e) => eventOf(e) ?? []);
				// R2：没选过就用 Host 记的「这门课上次用过」（这台浏览器的记忆在初始值里，已经用过就不覆盖）
				const remembered = typeof params.agent === "string" ? params.agent : "";
				if (remembered) setPreferred((current) => current || remembered);
				setLogin(null); // 会话接上了就说明现在不需要登录（学员可能刚在页面外完成）
				dispatch({ type: "history", running: params.running === true, events, settings: settingsOf(params) });
				return refetch();
			}
			if (reply.method === "chat.settings") {
				dispatch({ type: "settings", settings: settingsOf(params) });
				return;
			}
			if (reply.method === "turn.card.closed") return dispatch({ type: "cardClosed", cardId: String(params.cardId) });
			const event = reply.method === "turn.delta" ? eventOf(params) : null;
			if (event) dispatch({ type: "delta", event });
		},
		[refetch],
	);
	const withAgent = useCallback(
		(params: Record<string, unknown>) => (agent && !("agent" in params) ? { agent, ...params } : params),
		[agent],
	);
	// Host 回复仍回原 socket；接管、断线或重新 attach 后，旧请求不能再改本页状态。
	// raw：只做代次校验与 not_holder 失效，不把回复交给归约——历史列表/切换失败要在调用方就地呈现。
	const requestChatRaw = useCallback(
		async (
			method:
				| "chat.attach"
				| "chat.new"
				| "chat.send"
				| "chat.sessions"
				| "chat.open"
				| "chat.set_setting"
				| "chat.authenticate"
				| "card.answer",
			params: Record<string, unknown>,
			timeoutMs = CHAT_TIMEOUT_MS,
		) => {
			if (!socket) return null;
			const generation = ownership.current;
			const reply = await socket.request(method, withAgent(params), { timeoutMs })
				.catch((e: Error): HostMessage => ({ method: "error", params: { code: e.message } }));
			if (generation !== ownership.current) return null;
			if (reply.method === "error" && reply.params?.code === "not_holder") ownership.current += 1;
			return reply;
		},
		[socket, withAgent],
	);
	const requestChat = useCallback(
		async (
			method: "chat.attach" | "chat.new" | "chat.send" | "chat.open" | "card.answer",
			params: Record<string, unknown>,
			timeoutMs = CHAT_TIMEOUT_MS,
		) => {
			const reply = await requestChatRaw(method, params, timeoutMs);
			if (reply) onReply(reply);
			return reply;
		},
		[requestChatRaw, onReply],
	);

	const ready = pairing.phase === "ready";
	const attach = useCallback(() => {
		ownership.current += 1;
		void requestChat("chat.attach", { courseId });
	}, [requestChat, courseId]);
	useEffect(() => {
		// attach 只发起异步 I/O（等 Host 的 history 回复才改状态）；规则把「effect 里调到的函数最终会 setState」一律当成同步级联，
		// 这一处是它认不出的形状，指向的是既有的「配对就绪 → 接上对话」行为
		// eslint-disable-next-line react-hooks/set-state-in-effect
		if (ready) attach();
	}, [ready, attach]);

	useEffect(() => {
		if (!socket) return;
		const mine = (handler: (params: Record<string, unknown>) => void) => (params: Record<string, unknown>) => {
			if (params.courseId === courseId) handler(params);
		};
		const offs = [
			socket.on("status", (params) => {
				if (params.state !== "ready") ownership.current += 1;
				// 装完 agent 后 Host 会主动推一次 status：不必等下一次 /health 轮询
				if (Array.isArray(params.agents)) setAgents(params.agents as HostAgentStatus[]);
			}),
			socket.on("agent.install.progress", (params) => {
				if (params.kind === "codex") setInstall("installing");
			}),
			socket.on("agent.done", (params) => {
				if (params.kind !== "codex") return;
				if (params.ok) {
					setInstall(null);
					setInstallOutcome(params.reused === true ? "reuse" : "full");
					void checkHost({ previouslyReachedHost: true }).then((result) => {
						if (result.state === "detected") setAgents(result.agents);
					});
				} else {
					setInstallOutcome(null);
					setInstall({ error: String(params.code ?? "install_failed") });
				}
			}),
			socket.on(
				"turn.delta",
				mine((params) => {
					const event = eventOf(params);
					if (event) dispatch({ type: "delta", event });
				}),
			),
			socket.on(
				"turn.card",
				mine((params) => {
					dispatch({ type: "card", card: eventOf(params) as unknown as ChatCard });
					refetch();
				}),
			),
			socket.on("turn.card.closed", mine((params) => dispatch({ type: "cardClosed", cardId: String(params.cardId) }))),
			socket.on(
				"turn.end",
				mine((params) => {
					dispatch({ type: "end", stopReason: String(params.stopReason), modelError: params.modelError as ModelError | undefined });
					refetch();
				}),
			),
			socket.on("chat.evicted", mine(() => {
				ownership.current += 1;
				dispatch({ type: "evicted" });
			})),
			socket.on("chat.settings", mine((params) => dispatch({ type: "settings", settings: settingsOf(params) }))),
		];
		return () => offs.forEach((off) => off());
	}, [socket, courseId, refetch]);

	// 连上以后整页轮询就停了；但一个 agent 都没有时仍要每 POLL_MS 探一次 /health——学员在终端里装好 OMP 后最多 3 秒自愈
	useEffect(() => {
		if (!socket || anyAgent) return;
		const timer = setInterval(() => {
			void checkHost({ previouslyReachedHost: true }).then((result) => {
				if (result.state === "detected") setAgents(result.agents);
			});
		}, POLL_MS);
		return () => clearInterval(timer);
	}, [socket, anyAgent]);

	const canSend = ready && chat.attached && !chat.evicted && !chat.running && !chat.sending;

	const send = useCallback(
		async (text: string) => {
			if (!socket || !canSend || !text.trim()) return false;
			dispatch({ type: "sending" });
			const reply = await requestChat("chat.send", { courseId, text, context: { workspaceId, courseVersion, unitId, locale } });
			return reply?.method === "turn.delta";
		},
		[socket, canSend, courseId, workspaceId, courseVersion, unitId, locale, requestChat],
	);

	const stop = useCallback(() => {
		if (!socket) return;
		// Host 对 chat.stop 不回包：用 send（不等待回复），但必须带 agent——否则旧 Host 会把它当成「换 agent」。
		socket.send("chat.stop", withAgent({ courseId }));
		dispatch({ type: "stop" });
	}, [socket, courseId, withAgent]);

	const newChat = useCallback(() => {
		if (!canSend) return;
		ownership.current += 1;
		void requestChat("chat.new", { courseId });
	}, [canSend, courseId, requestChat]);

	const answer = useCallback(
		async (cardId: string, value: CardAnswer) => {
			await requestChat("card.answer", { courseId, cardId, ...value }, CARD_TIMEOUT_MS);
		},
		[courseId, requestChat],
	);

	const requestAccess = useCallback(() => accessRef.current(), []);

	// 历史对话：列表只读（失败不打扰对话，错误交给面板就地呈现）；切换成功由 history 归约接管。
	const listSessions = useCallback(
		async (cursor?: string): Promise<SessionsPage | { error: ChatErrorCode }> => {
			const reply = await requestChatRaw("chat.sessions", { courseId, ...(cursor ? { cursor } : {}) });
			if (!reply) return { error: "disconnected" };
			if (reply.method === "sessions") {
				const params = reply.params ?? {};
				return {
					sessions: (params.sessions as SessionsPage["sessions"]) ?? [],
					current: (params.current as string | null) ?? null,
					nextCursor: (params.nextCursor as string | null) ?? null,
				};
			}
			if (reply.method === "error" && reply.params?.code === "not_holder") onReply(reply); // 被接管：与其他方法同语义
			return { error: String(reply.params?.code ?? "unknown") };
		},
		[courseId, requestChatRaw, onReply],
	);
	const openSession = useCallback(
		async (sessionId: string): Promise<{ ok: true } | { ok: false; code: ChatErrorCode }> => {
			const reply = await requestChatRaw("chat.open", { courseId, sessionId });
			if (!reply) return { ok: false, code: "disconnected" };
			if (reply.method === "history") {
				onReply(reply);
				return { ok: true };
			}
			if (reply.method === "error" && reply.params?.code === "not_holder") onReply(reply);
			return { ok: false, code: String(reply.params?.code ?? "unknown") };
		},
		[courseId, requestChatRaw, onReply],
	);

	// 改本机 agent 的会话设置：成功由 chat.settings 回复接管归约；busy / chat_unavailable / bad_request 原样回给调用方
	const setSetting = useCallback(
		async (configId: string, value: string): Promise<{ ok: true } | { ok: false; code: ChatErrorCode }> => {
			const reply = await requestChatRaw("chat.set_setting", { courseId, configId, value });
			if (!reply) return { ok: false, code: "disconnected" };
			if (reply.method === "chat.settings") {
				onReply(reply);
				return { ok: true };
			}
			if (reply.method === "error" && reply.params?.code === "not_holder") onReply(reply);
			return { ok: false, code: String(reply.params?.code ?? "unknown") };
		},
		[courseId, requestChatRaw, onReply],
	);

	// 切 agent（R3、KTD8）：换一段会话——清空本页缓冲与登录态，再用新 agent 重新 attach；
	// 旧 agent 上有回合在跑时 Host 会先按取消收尾并回一次 busy，重试即接上新的那段。
	const chooseAgent = useCallback(
		(kind: string) => {
			if (kind === preferred) return;
			setLogin(null);
			setPreferred(kind);
			try {
				window.localStorage.setItem(`cgc-host-agent:${courseId}`, kind);
			} catch {
				// 隐私模式：只是少一层本浏览器的记忆
			}
			ownership.current += 1;
			dispatch({ type: "reset" });
			void requestChat("chat.attach", { courseId, agent: kind });
		},
		[preferred, courseId, requestChat],
	);

	// 登录（KTD4）：页面只发起，浏览器由这个 agent 的适配器自己开；成功后重新 attach 接上对话
	const authenticate = useCallback(
		async (methodId: string): Promise<{ ok: true } | { ok: false; code: ChatErrorCode }> => {
			const reply = await requestChatRaw("chat.authenticate", { courseId, methodId }, AUTH_TIMEOUT_MS);
			if (!reply) return { ok: false, code: "disconnected" };
			if (reply.method === "chat.authenticated") {
				setLogin(null);
				void requestChat("chat.attach", { courseId });
				return { ok: true };
			}
			return { ok: false, code: String(reply.params?.code ?? "unknown") };
		},
		[courseId, requestChat, requestChatRaw],
	);

	/** 请 Host 装 Codex 适配器（期 2）：安装是长任务，先回 started，进度与结果走 agent.install.progress / agent.done */
	const installAgent = useCallback(async () => {
		if (!socket) return;
		setInstallOutcome(null);
		setInstall("installing");
		const reply = await socket
			.request("agent.install", { kind: "codex" }, { timeoutMs: CARD_TIMEOUT_MS })
			.catch((e: Error): HostMessage => ({ method: "error", params: { code: e.message } }));
		if (reply.method === "error") setInstall({ error: String(reply.params?.code ?? "install_failed") });
	}, [socket]);

	/** 重新探测 /health：学员刚装好另一个 agent 时用（本页已经连上过，权限已给，不需要手势） */
	const refreshAgents = useCallback(async () => {
		const result = await checkHost({ previouslyReachedHost: true });
		if (result.state !== "detected") return null;
		setAgents(result.agents);
		return result.agents;
	}, []);

	const { evicted, ...rest } = chat;
	return {
		...rest,
		view: viewOf(probe, socket, lost, pairing, evicted, agents),
		pairing,
		canSend,
		requestAccess,
		send,
		stop,
		newChat,
		answer,
		reclaim: attach,
		listSessions,
		openSession,
		setSetting,
		agents,
		agent,
		chooseAgent,
		login,
		authenticate,
		refreshAgents,
		capabilities,
		install,
		installOutcome,
		installAgent,
	};
}
