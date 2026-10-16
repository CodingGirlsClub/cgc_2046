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
import { checkHost, requestHostAccess, type HostConnection } from "@/lib/host-connection";
import { openHostSocket, type HostMessage, type HostSocket } from "@/lib/host-socket";
import { useHostPairing, type HostPairing, type PairingErrorReason } from "./use-host-pairing";

/** 没有连接时重新检测的间隔：装好 Host、装好 OMP、Host 恢复，都在这个时间内被发现 */
export const POLL_MS = 3_000;
/** chat.attach / chat.send / chat.new 可能要先拉起 OMP 并加载会话 */
export const CHAT_TIMEOUT_MS = 60_000;
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

/** R26 的状态：一处状态源。ready / evicted 时对话可见 */
export type ChatView =
	| Exclude<HostConnection, { state: "detected" }>
	| { state: "checking" | "noOmp" | "disconnected" | "unpaired" | "confirming" | "denied" | "ready" | "evicted" }
	| { state: "pairingFailed"; reason: PairingErrorReason };

interface ChatState {
	/** 收到本连接的 history：这条连接持有这门课，可以发送 */
	attached: boolean;
	events: ChatEvent[];
	cards: ChatCard[];
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
	running: false,
	sending: false,
	stopping: false,
	evicted: false,
	error: null,
};

type Action =
	| { type: "reset" }
	| { type: "history"; running: boolean; events: ChatEvent[] }
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
			};
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

function viewOf(
	probe: HostConnection | null,
	socket: HostSocket | null,
	lost: boolean,
	pairing: HostPairing,
	evicted: boolean,
): ChatView {
	if (!socket) {
		// 探到可用的 Host 到连接打开之间、连接刚断还没重新检测，都只是过渡
		if (!probe || (probe.state === "detected" && probe.ompPresent)) return { state: lost ? "disconnected" : "checking" };
		if (lost && probe.state === "noHost") return { state: "disconnected" };
		if (probe.state === "detected") return { state: "noOmp" };
		return probe;
	}
	if (pairing.phase === "ready") return { state: evicted ? "evicted" : "ready" };
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

	useEffect(() => {
		let cancelled = false;
		let current: HostSocket | null = null;
		let timer: ReturnType<typeof setTimeout> | undefined;
		let previouslyReachedHost = false;
		const check = () => void checkHost({ previouslyReachedHost }).then(apply);
		function apply(result: HostConnection) {
			if (cancelled || current) return;
			clearTimeout(timer);
			if (result.state === "detected") previouslyReachedHost = true;
			// 没连上时每 3 秒检测一次，结果多半没变：内容相同就沿用旧对象，对话栏不随轮询重渲染
			setProbe((prev) => {
				// 被动权限查询没有新探测结果，不能抹掉上次点击失败后的下一步指引。
				if (result.state === "needsPermission" && prev?.state === "needsPermission" && prev.probeFailed) return prev;
				return prev && JSON.stringify(prev) === JSON.stringify(result) ? prev : result;
			});
			if (result.state === "detected" && result.ompPresent) {
				const opened = openHostSocket();
				current = opened;
				opened.onClose(() => {
					if (cancelled) return;
					ownership.current += 1;
					current = null;
					setSocket(null);
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
			if (reply.method === "error") return dispatch({ type: "error", code: String(params.code) });
			if (reply.method === "history") {
				const events = ((params.events as Record<string, unknown>[]) ?? []).flatMap((e) => eventOf(e) ?? []);
				dispatch({ type: "history", running: params.running === true, events });
				return refetch();
			}
			if (reply.method === "turn.card.closed") return dispatch({ type: "cardClosed", cardId: String(params.cardId) });
			const event = reply.method === "turn.delta" ? eventOf(params) : null;
			if (event) dispatch({ type: "delta", event });
		},
		[refetch],
	);
	// Host 回复仍回原 socket；接管、断线或重新 attach 后，旧请求不能再改本页状态。
	const requestChat = useCallback(
		async (method: "chat.attach" | "chat.new" | "chat.send" | "card.answer", params: Record<string, unknown>, timeoutMs = CHAT_TIMEOUT_MS) => {
			if (!socket) return null;
			const generation = ownership.current;
			const reply = await socket.request(method, params, { timeoutMs })
				.catch((e: Error): HostMessage => ({ method: "error", params: { code: e.message } }));
			if (generation !== ownership.current) return null;
			if (reply.method === "error" && reply.params?.code === "not_holder") ownership.current += 1;
			onReply(reply);
			return reply;
		},
		[socket, onReply],
	);

	const ready = pairing.phase === "ready";
	const attach = useCallback(() => {
		ownership.current += 1;
		void requestChat("chat.attach", { courseId });
	}, [requestChat, courseId]);
	useEffect(() => {
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
		];
		return () => offs.forEach((off) => off());
	}, [socket, courseId, refetch]);

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
		socket?.send("chat.stop", { courseId });
		dispatch({ type: "stop" });
	}, [socket, courseId]);

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

	const { evicted, ...rest } = chat;
	return {
		...rest,
		view: viewOf(probe, socket, lost, pairing, evicted),
		pairing,
		canSend,
		requestAccess,
		send,
		stop,
		newChat,
		answer,
		reclaim: attach,
	};
}
