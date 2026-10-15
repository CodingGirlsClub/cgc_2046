import { HOST_WS_URL } from "./host-connection";

/**
 * 页面 ↔ 本机 Host 的 WebSocket 客户端（KTD4；ADR-0022）。帧信封、status 字段与错误码见
 * `cgc-host/AGENTS.md`「页面 ↔ Host 帧信封」。
 *
 * 每个标签页只开一条：Host 的授权按连接计（一个连接 hello 一次），配对（use-host-pairing）
 * 与对话（U10）共用这一条。这里只收发信封——请求按 id 等回复、订阅推送、关闭回调；
 * 不重连，连接的生命周期归对话栏（U10）。
 */

/** 页面会发的方法；契约测试断言它们都在 protocol.json 的 pageToHost 里 */
export const PAGE_TO_HOST = [
	"hello",
	"pair.request",
	"pair.cancel",
	"pair.forget",
	"chat.attach",
	"chat.send",
	"chat.stop",
	"chat.new",
	"card.answer",
] as const;
/** 页面会处理的 Host 消息；契约测试断言它们都在 hostToPage 里 */
export const HOST_TO_PAGE = [
	"status",
	"pair.result",
	"error",
	"history",
	"turn.delta",
	"turn.card",
	"turn.card.closed",
	"turn.end",
	"chat.evicted",
] as const;

export type PageMethod = (typeof PAGE_TO_HOST)[number];
export type HostMethod = (typeof HOST_TO_PAGE)[number];

/** 两个方向共用的帧信封；回复带上请求的 id，Host 主动推送的不带 */
export interface HostMessage {
	method: string;
	id?: string;
	params?: Record<string, unknown>;
}

/** status.params。state：ready 指这条连接已授权（hello 过、密钥与账号相符），paired 指本机已配对但这条连接未授权 */
export interface HostStatus {
	state: "unpaired" | "paired" | "ready";
	pairedUserId: string | null;
	pairedDisplayName: string | null;
	deviceName: string;
	/** 本机所持学习凭证的记录 id：「已配对的电脑」据此标出本机这台 */
	tokenId: string | null;
	ompPresent: boolean;
	version: string;
	protocolVersion: number;
}

/** request 拿不到回复时 Error.message 的取值：超时，或连接已断开（含发出时就不在打开状态） */
export type HostRequestFailure = "timeout" | "disconnected";

export interface HostSocket {
	/** 最近一次收到的 status：连接建立时 Host 立即推送一次，晚于它订阅的一方从这里取当前值 */
	readonly status: HostStatus | null;
	/** 不等回复的消息（pair.cancel、pair.forget、chat.stop）；连接不在打开状态时不发 */
	send(method: PageMethod, params?: Record<string, unknown>): void;
	/** 按 id 等回复（可能是 error）；超时或连接断开时以 Error(HostRequestFailure) 拒绝 */
	request(
		method: PageMethod,
		params: Record<string, unknown>,
		options: { timeoutMs: number },
	): Promise<HostMessage>;
	/** 订阅不带 id 的推送；status 例外，hello 回复的 status 也会送到（它同样是这条连接的最新状态）。返回退订函数 */
	on(method: HostMethod, handler: (params: Record<string, unknown>) => void): () => void;
	/** 连接关闭（含没连上）时回调，返回退订函数 */
	onClose(handler: () => void): () => void;
	close(): void;
}

export function openHostSocket(): HostSocket {
	const ws = new WebSocket(HOST_WS_URL);
	const pending = new Map<string, (reply: HostMessage | HostRequestFailure) => void>();
	const listeners = new Map<string, Set<(params: Record<string, unknown>) => void>>();
	const closeListeners = new Set<() => void>();
	let status: HostStatus | null = null;
	let lastId = 0;

	ws.onmessage = (event) => {
		const message = JSON.parse(event.data) as HostMessage;
		if (message.method === "status") status = message.params as unknown as HostStatus;
		if (message.id !== undefined) pending.get(message.id)?.(message);
		if (message.id === undefined || message.method === "status") {
			for (const handler of listeners.get(message.method) ?? []) handler(message.params ?? {});
		}
	};
	ws.onclose = () => {
		for (const settle of [...pending.values()]) settle("disconnected");
		for (const handler of closeListeners) handler();
	};

	return {
		get status() {
			return status;
		},
		send(method, params) {
			if (ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ method, params }));
		},
		request(method, params, { timeoutMs }) {
			if (ws.readyState !== WebSocket.OPEN) return Promise.reject(new Error("disconnected"));
			const id = String(++lastId);
			return new Promise((resolve, reject) => {
				const timer = setTimeout(() => settle("timeout"), timeoutMs);
				const settle = (reply: HostMessage | HostRequestFailure) => {
					clearTimeout(timer);
					pending.delete(id);
					if (typeof reply === "string") reject(new Error(reply));
					else resolve(reply);
				};
				pending.set(id, settle);
				ws.send(JSON.stringify({ method, id, params }));
			});
		},
		on(method, handler) {
			const handlers = listeners.get(method) ?? new Set();
			listeners.set(method, handlers);
			handlers.add(handler);
			return () => handlers.delete(handler);
		},
		onClose(handler) {
			closeListeners.add(handler);
			return () => closeListeners.delete(handler);
		},
		close() {
			ws.close();
		},
	};
}
