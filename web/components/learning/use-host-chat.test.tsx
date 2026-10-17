import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { MockedProvider } from "@apollo/client/testing/react";
import { useQuery } from "@apollo/client/react";
import { COURSE_LEARNING_DETAIL } from "@/lib/graphql/participations";
import type { HostStatus } from "@/lib/host-socket";
import { CHAT_TIMEOUT_MS, POLL_MS, useHostChat, type HostChat } from "./use-host-chat";
import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
const protocol = JSON.parse(readFileSync(resolve(dirname(fileURLToPath(import.meta.url)), "../../../cgc-host/protocol.json"), "utf8"));

/**
 * U10 对话栏的状态源（R26、R28；KTD8、KTD14）。
 *
 * 本机检测（lib/host-connection）mock 掉，其余都是真的：host-socket 跑在假 WebSocket 上，配对走 useHostPairing。
 * 测试替 Host 推帧、断言页面发出的帧；学习详情的重取经 MockedProvider 按 courseId 计数。
 */

const { checkHost, requestHostAccess } = vi.hoisted(() => ({
	checkHost: vi.fn(),
	requestHostAccess: vi.fn(),
}));
vi.mock("@/lib/host-connection", async (importOriginal) => ({
	...(await importOriginal<typeof import("@/lib/host-connection")>()),
	checkHost,
	requestHostAccess,
}));
vi.mock("@/lib/mcp", () => ({ issueMcpToken: vi.fn(), revokeMcpToken: vi.fn(), fetchMyMcpTokens: vi.fn() }));

/** 同 lib/host-socket.test.ts 的假连接；构造即打开，记下每一条 */
class FakeWebSocket {
	static readonly OPEN = 1;
	static readonly CLOSED = 3;
	static all: FakeWebSocket[] = [];
	readyState = FakeWebSocket.OPEN;
	sent: Array<{ method: string; id?: string; params?: Record<string, unknown> }> = [];
	onmessage: ((event: { data: string }) => void) | null = null;
	onclose: (() => void) | null = null;
	constructor(readonly url: string) {
		FakeWebSocket.all.push(this);
	}
	send(data: string) {
		this.sent.push(JSON.parse(data));
	}
	close() {
		if (this.readyState === FakeWebSocket.CLOSED) return;
		this.readyState = FakeWebSocket.CLOSED;
		this.onclose?.();
	}
	push(message: object) {
		this.onmessage?.({ data: JSON.stringify(message) });
	}
	/** Host 回复页面最近发出的、方法为 method 的那一帧；等页面处理完回复（浏览器里它先于下一帧处理） */
	reply(method: string, replyMethod: string, params: object) {
		const request = this.sent.findLast((frame) => frame.method === method);
		return act(async () => this.push({ method: replyMethod, id: request?.id, params }));
	}
}

const COURSE = "11111111-1111-4111-8111-111111111111";
const OTHER_COURSE = "22222222-2222-4222-8222-222222222222";
const WORKSPACE = "33333333-3333-4333-8333-333333333333";
const USER = "user-a";
const DETECTED = { state: "detected", agents: [{ kind: "omp", present: true }], paired: true } as const;

const status = (state: HostStatus["state"]): HostStatus => ({
	state,
	pairedUserId: USER,
	pairedDisplayName: "学员甲",
	deviceName: "Ada 的 MacBook",
	tokenId: "tok_this",
	agents: [{ kind: "omp", present: true }],
	ompPresent: true,
	version: "0.1.0",
	protocolVersion: 1,
});

/** 每门课 COURSE_LEARNING_DETAIL 的请求次数（首取 + 重取） */
let fetches: Record<string, number>;
const detailMock = (courseId: string) => ({
	request: { query: COURSE_LEARNING_DETAIL, variables: { courseId } },
	maxUsageCount: Number.POSITIVE_INFINITY,
	result: () => {
		fetches[courseId] += 1;
		return { data: { courseLearningDetail: null } };
	},
});

let hook: { current: HostChat };

function mount(unitId: string | null = null) {
	const view = renderHook(
		({ unitId }: { unitId: string | null }) => {
			// 页面上本课程与另一门课的学习详情都在观察：重取只该落到本课程
			useQuery(COURSE_LEARNING_DETAIL, { variables: { courseId: COURSE } });
			useQuery(COURSE_LEARNING_DETAIL, { variables: { courseId: OTHER_COURSE } });
			return useHostChat({ courseId: COURSE, userId: USER, locale: "zh-CN", workspaceId: WORKSPACE, courseVersion: 3, unitId });
		},
		{
			initialProps: { unitId },
			wrapper: ({ children }) => (
				<MockedProvider mocks={[detailMock(COURSE), detailMock(OTHER_COURSE)]}>{children}</MockedProvider>
			),
		},
	);
	hook = view.result;
	return { rerender: (id: string | null) => view.rerender({ unitId: id }) };
}

/** 已存浏览器密钥：连接 → hello → ready → chat.attach → history */
async function attach(ws: FakeWebSocket, events: object[] = []) {
	act(() => ws.push({ method: "status", params: status("paired") }));
	await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("hello"));
	await ws.reply("hello", "status", status("ready"));
	await waitFor(() => expect(ws.sent.at(-1)).toMatchObject({ method: "chat.attach", params: { courseId: COURSE } }));
	await ws.reply("chat.attach", "history", { courseId: COURSE, running: false, events });
	await waitFor(() => expect(hook.current.attached).toBe(true));
}

async function readyChat(unitId: string | null = null) {
	const mounted = mount(unitId);
	await waitFor(() => expect(FakeWebSocket.all).toHaveLength(1));
	const ws = FakeWebSocket.all[0];
	await attach(ws);
	return { ws, ...mounted };
}

beforeEach(() => {
	vi.stubGlobal("WebSocket", FakeWebSocket);
	FakeWebSocket.all = [];
	fetches = { [COURSE]: 0, [OTHER_COURSE]: 0 };
	localStorage.clear();
	localStorage.setItem(`cgc:host-browser-key:${USER}`, "bk-a");
	checkHost.mockResolvedValue(DETECTED);
});

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
	vi.unstubAllGlobals();
	vi.useRealTimers();
});

const BOTH_AGENTS = {
	state: "detected",
	agents: [
		{ kind: "omp", present: true },
		{ kind: "codex", present: true },
	],
	paired: true,
} as const;

/** 指定这门课上次用的 agent（模拟这台浏览器记得的选择） */
const rememberAgent = (kind: string) => window.localStorage.setItem(`cgc-host-agent:${COURSE}`, kind);

describe("多 agent（#1148：选择、登录、重新检测）", () => {
	it("history 带回的 agent 成为这段对话的驱动者，之后的对话方法都带上它", async () => {
		checkHost.mockResolvedValue(BOTH_AGENTS);
		mount();
		await waitFor(() => expect(FakeWebSocket.all).toHaveLength(1));
		const ws = FakeWebSocket.all[0];
		act(() => ws.push({ method: "status", params: status("paired") }));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("hello"));
		await ws.reply("hello", "status", status("ready"));
		await ws.reply("chat.attach", "history", { courseId: COURSE, running: false, events: [], agent: "codex" });
		await waitFor(() => expect(hook.current.agent).toBe("codex"));

		act(() => void hook.current.send("你好"));
		await waitFor(() => expect(ws.sent.at(-1)).toMatchObject({ method: "chat.send", params: { courseId: COURSE, agent: "codex" } }));
	});

	it("auth_required：出登录卡（带登录方式）；authenticate 成功后清掉并重新 attach", async () => {
		rememberAgent("codex");
		checkHost.mockResolvedValue(BOTH_AGENTS);
		mount();
		await waitFor(() => expect(FakeWebSocket.all).toHaveLength(1));
		const ws = FakeWebSocket.all[0];
		act(() => ws.push({ method: "status", params: status("paired") }));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("hello"));
		await ws.reply("hello", "status", status("ready"));
		await waitFor(() => expect(ws.sent.at(-1)).toMatchObject({ method: "chat.attach", params: { agent: "codex" } }));
		await ws.reply("chat.attach", "history", { courseId: COURSE, running: false, events: [], agent: "codex" });

		act(() => void hook.current.send("在吗"));
		await ws.reply("chat.send", "error", {
			code: "auth_required",
			methods: [
				{ id: "api-key", name: "API Key" },
				{ id: "chat-gpt", name: "ChatGPT" },
			],
		});
		await waitFor(() => expect(hook.current.login).toEqual([
			{ id: "api-key", name: "API Key" },
			{ id: "chat-gpt", name: "ChatGPT" },
		]));

		let result: { ok: boolean } | undefined;
		await act(async () => {
			result = await (async () => {
				const pending = hook.current.authenticate("chat-gpt");
				await ws.reply("chat.authenticate", "chat.authenticated", { courseId: COURSE, agent: "codex" });
				return pending;
			})();
		});
		expect(result).toEqual({ ok: true });
		expect(hook.current.login).toBeNull();
		await waitFor(() => expect(ws.sent.at(-1)).toMatchObject({ method: "chat.attach", params: { agent: "codex" } }));
	});

	it("chooseAgent：写本浏览器的记忆、清空这段缓冲，并用新 agent 重新 attach", async () => {
		checkHost.mockResolvedValue(BOTH_AGENTS);
		const { ws } = await readyChat();

		await act(async () => hook.current.chooseAgent("codex"));
		expect(window.localStorage.getItem(`cgc-host-agent:${COURSE}`)).toBe("codex");
		await waitFor(() => expect(ws.sent.at(-1)).toMatchObject({ method: "chat.attach", params: { courseId: COURSE, agent: "codex" } }));
		expect(hook.current.events).toEqual([]);
	});

	it("只装了 Codex 的机器也连得上：可用性判据是「有没有可用的 agent」，不是「有没有 OMP」", async () => {
		checkHost.mockResolvedValue({
			state: "detected",
			agents: [
				{ kind: "omp", present: false },
				{ kind: "codex", present: true },
			],
			paired: true,
		});
		mount();
		await waitFor(() => expect(FakeWebSocket.all).toHaveLength(1));
		expect(hook.current.agents).toEqual([
			{ kind: "omp", present: false },
			{ kind: "codex", present: true },
		]);
	});

	it("refreshAgents：重新探测 /health 后，新装好的 agent 进入可选列表", async () => {
		await readyChat();
		expect(hook.current.agents.map((a) => a.kind)).toEqual(["omp"]);

		checkHost.mockResolvedValueOnce({ state: "detected", agents: [{ kind: "omp", present: true }, { kind: "codex", present: true }], paired: true });
		await act(async () => {
			await hook.current.refreshAgents();
		});
		expect(hook.current.agents.map((a) => a.kind)).toEqual(["omp", "codex"]);
	});
});

describe("连接状态（R26）", () => {
	it("检测完成前为 checking；本机访问未授权时不开连接，点击后经 requestHostAccess 发起第一次本机请求", async () => {
		checkHost.mockResolvedValue({ state: "needsPermission" });
		requestHostAccess.mockResolvedValue(DETECTED);
		mount();
		expect(hook.current.view).toEqual({ state: "checking" });
		await waitFor(() => expect(hook.current.view).toEqual({ state: "needsPermission" }));
		expect(FakeWebSocket.all).toEqual([]);

		act(() => hook.current.requestAccess());
		expect(requestHostAccess).toHaveBeenCalledOnce();
		await waitFor(() => expect(FakeWebSocket.all).toHaveLength(1));
	});

	it("Covers AE1：未检测到 Host 时每 POLL_MS 重新检测，装好 Host 后无需刷新即开连接；电脑上没有可用的 agent 时停在 noAgent", async () => {
		vi.useFakeTimers({ shouldAdvanceTime: true });
		checkHost.mockResolvedValueOnce({ state: "noHost" });
		checkHost.mockResolvedValueOnce({ state: "detected", agents: [{ kind: "omp", present: false }], paired: false });
		mount();
		await waitFor(() => expect(hook.current.view).toEqual({ state: "noHost" }));

		await act(() => vi.advanceTimersByTimeAsync(POLL_MS));
		expect(hook.current.view).toEqual({ state: "noAgent" });
		expect(FakeWebSocket.all).toEqual([]);

		await act(() => vi.advanceTimersByTimeAsync(POLL_MS));
		expect(FakeWebSocket.all).toHaveLength(1);
		expect(checkHost).toHaveBeenCalledTimes(3);
		expect(checkHost).toHaveBeenLastCalledWith({ previouslyReachedHost: true });
	});

	it("不受支持的浏览器或地址：给出状态后不再轮询", async () => {
		vi.useFakeTimers({ shouldAdvanceTime: true });
		checkHost.mockResolvedValue({ state: "unsupported", reason: "browser" });
		mount();
		await waitFor(() => expect(hook.current.view).toEqual({ state: "unsupported", reason: "browser" }));
		await act(() => vi.advanceTimersByTimeAsync(POLL_MS * 3));
		expect(checkHost).toHaveBeenCalledOnce();
	});

	it("Covers R28：连接中断 → disconnected；Host 恢复后自动重连，用已存的密钥 hello、重新 chat.attach，接上原对话", async () => {
		vi.useFakeTimers({ shouldAdvanceTime: true });
		const { ws } = await readyChat();
		expect(hook.current.view).toEqual({ state: "ready" });

		checkHost.mockResolvedValueOnce({ state: "noHost" });
		act(() => ws.close());
		expect(hook.current.view).toEqual({ state: "disconnected" });
		expect(hook.current.attached).toBe(false);
		await act(() => vi.advanceTimersByTimeAsync(POLL_MS));
		expect(hook.current.view).toEqual({ state: "disconnected" });
		expect(FakeWebSocket.all).toHaveLength(1);

		await act(() => vi.advanceTimersByTimeAsync(POLL_MS));
		expect(FakeWebSocket.all).toHaveLength(2);
		expect(checkHost).toHaveBeenLastCalledWith({ previouslyReachedHost: true });
		const again = FakeWebSocket.all[1];
		await attach(again, [{ kind: "user", text: "上次的问题" }]);
		expect(hook.current.view).toEqual({ state: "ready" });
		expect(hook.current.events).toEqual([{ kind: "user", text: "上次的问题" }]);
	});
});

it("Covers AE3 / KTD14：history、turn.card、turn.end 各重取一次本课程的学习详情；另一门课不受影响，turn.delta 不重取", async () => {
	const { ws } = await readyChat();
	await waitFor(() => expect(fetches[COURSE]).toBe(2)); // 首取 + 进入可对话（history）
	expect(fetches[OTHER_COURSE]).toBe(1);

	act(() => ws.push({ method: "turn.delta", params: { courseId: COURSE, kind: "message", text: "好的" } }));
	act(() =>
		ws.push({
			method: "turn.card",
			params: { courseId: COURSE, cardId: "card-1", kind: "question", message: "选一个", schema: { type: "object", properties: {} } },
		}),
	);
	await waitFor(() => expect(fetches[COURSE]).toBe(3));
	act(() => ws.push({ method: "turn.end", params: { courseId: COURSE, stopReason: "end_turn" } }));
	await waitFor(() => expect(fetches[COURSE]).toBe(4));
	expect(fetches[OTHER_COURSE]).toBe(1);
});

describe("KTD8：每条 chat.send 带页面上下文", () => {
	it("单元从 A 切到 B 后发送，上下文是 B；连续切换多次不发任何帧，发送时只附带一次", async () => {
		const { ws, rerender } = await readyChat("issue-a");
		const before = ws.sent.length;
		rerender("issue-b");
		rerender("issue-c");
		rerender("issue-b");
		expect(ws.sent).toHaveLength(before);

		act(() => void hook.current.send("这一单元讲什么？"));
		expect(ws.sent.slice(before)).toEqual([
			{
				method: "chat.send",
				id: expect.any(String),
				params: {
					courseId: COURSE,
					agent: "omp", // 页面现在显式点名它正在用的 agent（展示与路由同一个值）
					text: "这一单元讲什么？",
					context: { workspaceId: WORKSPACE, courseVersion: 3, unitId: "issue-b", locale: "zh-CN" },
				},
			},
		]);
	});

	it("总览时 unitId 为 null", async () => {
		const { ws } = await readyChat(null);
		act(() => void hook.current.send("从哪开始？"));
		expect(ws.sent.at(-1)?.params?.context).toMatchObject({ unitId: null });
	});
});

it("事件归约同 Host：文字按 kind + messageId 拼接，工具按 toolCallId 合并为一段；别的课的推送不进来", async () => {
	const { ws } = await readyChat();
	act(() => void hook.current.send("你好"));
	await ws.reply("chat.send", "turn.delta", { courseId: COURSE, kind: "user", text: "你好" });
	const push = (params: object) => act(() => ws.push({ method: "turn.delta", params: { courseId: COURSE, ...params } }));
	push({ kind: "thought", text: "想一", messageId: "m1" });
	push({ kind: "thought", text: "想二", messageId: "m1" });
	push({ kind: "tool", toolCallId: "t1", title: "读文件", toolKind: "read", status: "pending" });
	push({ kind: "tool", toolCallId: "t1", title: "读文件", toolKind: "read", status: "completed", output: "内容" });
	push({ kind: "message", text: "你", messageId: "m2" });
	push({ kind: "message", text: "好", messageId: "m2" });
	push({ kind: "usage", used: 10, size: 100 });
	act(() => ws.push({ method: "turn.delta", params: { courseId: OTHER_COURSE, kind: "message", text: "串台" } }));

	expect(hook.current.events).toEqual([
		{ kind: "user", text: "你好" },
		{ kind: "thought", text: "想一想二", messageId: "m1" },
		{ kind: "tool", toolCallId: "t1", title: "读文件", toolKind: "read", status: "completed", output: "内容" },
		{ kind: "message", text: "你好", messageId: "m2" },
	]);
	expect(hook.current.running).toBe(true);
});

it("Covers R12：被另一个标签页接管 → evicted，不能发送；「在这里继续」重新 chat.attach 后恢复", async () => {
	const { ws } = await readyChat();
	act(() => ws.push({ method: "chat.evicted", params: { courseId: COURSE } }));
	expect(hook.current.view).toEqual({ state: "evicted" });
	expect(hook.current.canSend).toBe(false);

	const before = ws.sent.length;
	act(() => void hook.current.send("还能发吗"));
	expect(ws.sent).toHaveLength(before);

	act(() => hook.current.reclaim());
	await ws.reply("chat.attach", "history", { courseId: COURSE, running: false, events: [] });
	await waitFor(() => expect(hook.current.view).toEqual({ state: "ready" }));
	expect(hook.current.canSend).toBe(true);
});

/** 暂不回答 history，模拟 session/load 或 session/new/进程启动尚未结束。 */
async function pendingHistory(method: "chat.attach" | "chat.new") {
	if (method === "chat.new") {
		const { ws } = await readyChat();
		act(() => hook.current.newChat());
		return { ws, id: ws.sent.at(-1)!.id };
	}
	mount();
	await waitFor(() => expect(FakeWebSocket.all).toHaveLength(1));
	const ws = FakeWebSocket.all[0];
	act(() => ws.push({ method: "status", params: status("paired") }));
	await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("hello"));
	await ws.reply("hello", "status", status("ready"));
	await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.attach"));
	return { ws, id: ws.sent.at(-1)!.id };
}

describe("F1：持有权失效后的异步回复", () => {
	it("页面请求使用协议等待预算，覆盖 Host 准备预算并留出余量", async () => {
		const timers = vi.spyOn(globalThis, "setTimeout");
		try {
			await pendingHistory("chat.attach");
			expect(timers).toHaveBeenCalledWith(expect.any(Function), CHAT_TIMEOUT_MS);
			expect(CHAT_TIMEOUT_MS - protocol.preparationTimeoutMs).toBeGreaterThanOrEqual(15_000);
		} finally { timers.mockRestore(); }
	});
	it.each(["chat.attach", "chat.new"] as const)("%s 的迟到 history 不能撤销 eviction，只有新 reclaim 可以恢复", async (method) => {
		const { ws, id } = await pendingHistory(method);
		act(() => ws.push({ method: "chat.evicted", params: { courseId: COURSE } }));
		expect(hook.current.view.state).toBe("evicted");
		await act(async () => ws.push({ method: "history", id, params: { courseId: COURSE, running: true, events: [{ kind: "user", text: "过期历史" }] } }));
		expect(hook.current.view.state).toBe("evicted");
		expect(hook.current.canSend).toBe(false);
		expect(hook.current.running).toBe(false);
		expect(hook.current.events).toEqual([]);
		const count = ws.sent.length;
		act(() => hook.current.newChat());
		expect(ws.sent).toHaveLength(count);
		act(() => hook.current.reclaim());
		await ws.reply("chat.attach", "history", { courseId: COURSE, running: false, events: [{ kind: "user", text: "最新历史" }] });
		expect(hook.current.view.state).toBe("ready");
		expect(hook.current.canSend).toBe(true);
		expect(hook.current.events).toEqual([{ kind: "user", text: "最新历史" }]);
	});

	it.each(["history", "error"] as const)("reclaim 已成功后，旧请求的 %s 不能覆盖新状态", async (replyMethod) => {
		const { ws, id } = await pendingHistory("chat.new");
		act(() => ws.push({ method: "chat.evicted", params: { courseId: COURSE } }));
		act(() => hook.current.reclaim());
		await ws.reply("chat.attach", "history", { courseId: COURSE, running: false, events: [{ kind: "user", text: "新持有权" }] });
		await act(async () => ws.push({ method: replyMethod, id, params: { courseId: COURSE, running: false, events: [], code: "not_holder" } }));
		expect(hook.current.view.state).toBe("ready");
		expect(hook.current.canSend).toBe(true);
		expect(hook.current.error).toBeNull();
		expect(hook.current.events).toEqual([{ kind: "user", text: "新持有权" }]);
	});

	it("reclaim 等待时再次被接管：该 reclaim 回复同样失效", async () => {
		const { ws } = await readyChat();
		act(() => ws.push({ method: "chat.evicted", params: { courseId: COURSE } }));
		act(() => hook.current.reclaim());
		act(() => ws.push({ method: "chat.evicted", params: { courseId: COURSE } }));
		await ws.reply("chat.attach", "history", { courseId: COURSE, running: false, events: [] });
		expect(hook.current.view.state).toBe("evicted");
		expect(hook.current.canSend).toBe(false);
	});

	it("被后一次 reclaim 取代的请求超时不污染已恢复的对话", async () => {
		vi.useFakeTimers({ shouldAdvanceTime: true });
		const { ws } = await pendingHistory("chat.attach");
		act(() => hook.current.reclaim());
		await ws.reply("chat.attach", "history", { courseId: COURSE, running: false, events: [] });
		await act(() => vi.advanceTimersByTimeAsync(60_000));
		expect(hook.current.view.state).toBe("ready");
		expect(hook.current.error).toBeNull();
	});

	it.each([false, true])("连接关闭使挂起请求失效（history 已排入微任务：%s），重连正常恢复", async (queued) => {
		vi.useFakeTimers({ shouldAdvanceTime: true });
		const { ws, id } = await pendingHistory("chat.attach");
		await act(async () => {
			if (queued) ws.push({ method: "history", id, params: { courseId: COURSE, running: false, events: [{ kind: "user", text: "旧连接" }] } });
			ws.close();
		});
		expect(hook.current.view.state).toBe("disconnected");
		expect(hook.current.attached).toBe(false);
		expect(hook.current.events).toEqual([]);
		expect(hook.current.error).toBeNull();
		await act(() => vi.advanceTimersByTimeAsync(POLL_MS));
		await waitFor(() => expect(FakeWebSocket.all).toHaveLength(2));
		await attach(FakeWebSocket.all[1]);
		expect(hook.current.canSend).toBe(true);
	});

	it("失去配对授权时丢弃旧 history；重新 hello 后的新 attach 可以恢复", async () => {
		const { ws, id } = await pendingHistory("chat.attach");
		act(() => ws.push({ method: "status", params: status("unpaired") }));
		await act(async () => ws.push({ method: "history", id, params: { courseId: COURSE, running: false, events: [{ kind: "user", text: "旧配对" }] } }));
		expect(hook.current.attached).toBe(false);
		expect(hook.current.events).toEqual([]);
		act(() => ws.push({ method: "status", params: status("ready") }));
		await waitFor(() => expect(ws.sent.filter((m) => m.method === "chat.attach")).toHaveLength(2));
		await ws.reply("chat.attach", "history", { courseId: COURSE, running: false, events: [] });
		expect(hook.current.canSend).toBe(true);
	});

	it("当前请求的错误仍显示，重试成功后清除", async () => {
		const { ws } = await pendingHistory("chat.attach");
		await ws.reply("chat.attach", "error", { code: "chat_unavailable" });
		expect(hook.current.error).toBe("chat_unavailable");
		act(() => hook.current.reclaim());
		await ws.reply("chat.attach", "history", { courseId: COURSE, running: false, events: [] });
		expect(hook.current.canSend).toBe(true);
		expect(hook.current.error).toBeNull();
	});

	it("被接管后迟到的发送确认不写回事件，也不报告本页发送成功", async () => {
		const { ws } = await readyChat();
		let sent!: Promise<boolean>;
		act(() => { sent = hook.current.send("旧请求"); });
		act(() => ws.push({ method: "chat.evicted", params: { courseId: COURSE } }));
		await ws.reply("chat.send", "turn.delta", { courseId: COURSE, kind: "user", text: "旧请求" });
		expect(await sent).toBe(false);
		expect(hook.current.events).toEqual([]);
		expect(hook.current.view.state).toBe("evicted");
	});

	it("当前作答被 not_holder 拒绝后，同代次的其他挂起作答不能再写入错误", async () => {
		const { ws } = await readyChat();
		act(() => { void hook.current.answer("card-1", { optionId: "reject_once" }); });
		const first = ws.sent.at(-1)!;
		act(() => { void hook.current.answer("card-2", { optionId: "reject_once" }); });
		await act(async () => ws.push({ method: "error", id: first.id, params: { code: "not_holder" } }));
		expect(hook.current.view.state).toBe("evicted");
		await ws.reply("card.answer", "error", { code: "timeout" });
		expect(hook.current.error).toBeNull();
		expect(hook.current.view.state).toBe("evicted");
	});
});


describe("历史对话（Session History）", () => {
	it("listSessions：发出 chat.sessions 并解析列表；游标原样带上", async () => {
		const { ws } = await readyChat();
		let promise!: Promise<unknown>;
		act(() => {
			promise = hook.current.listSessions();
		});
		await waitFor(() => expect(ws.sent.at(-1)).toMatchObject({ method: "chat.sessions", params: { courseId: COURSE } }));
		await ws.reply("chat.sessions", "sessions", {
			courseId: COURSE,
			sessions: [{ sessionId: "s1", updatedAt: "2026-10-15T02:00:00Z", messageCount: 4 }],
			current: "s1",
			nextCursor: "1",
		});
		expect(await promise).toMatchObject({ current: "s1", nextCursor: "1", sessions: [{ sessionId: "s1", messageCount: 4 }] });

		act(() => {
			promise = hook.current.listSessions("1");
		});
		await waitFor(() => expect(ws.sent.at(-1)).toMatchObject({ method: "chat.sessions", params: { courseId: COURSE, cursor: "1" } }));
		await ws.reply("chat.sessions", "sessions", { courseId: COURSE, sessions: [], current: "s1", nextCursor: null });
		expect(await promise).toMatchObject({ sessions: [] });
	});

	it("listSessions 失败：返回错误码，不进入全局错误态", async () => {
		const { ws } = await readyChat();
		let promise!: Promise<unknown>;
		act(() => {
			promise = hook.current.listSessions();
		});
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.sessions"));
		await ws.reply("chat.sessions", "error", { code: "chat_unavailable" });
		expect(await promise).toEqual({ error: "chat_unavailable" });
		expect(hook.current.canSend).toBe(true);
	});

	it("openSession 成功：history 回复接管归约，事件替换为切过去的会话", async () => {
		const { ws } = await readyChat();
		let promise!: Promise<unknown>;
		act(() => {
			promise = hook.current.openSession("session-9");
		});
		await waitFor(() => expect(ws.sent.at(-1)).toMatchObject({ method: "chat.open", params: { courseId: COURSE, sessionId: "session-9" } }));
		await ws.reply("chat.open", "history", { courseId: COURSE, running: false, events: [{ kind: "user", text: "切过去的会话" }] });
		expect(await promise).toEqual({ ok: true });
		await waitFor(() => expect(hook.current.events).toEqual([{ kind: "user", text: "切过去的会话" }]));
	});

	it("openSession 失败：返回错误码、不发全局错误态、原会话保持可发", async () => {
		const { ws } = await readyChat();
		let promise!: Promise<unknown>;
		act(() => {
			promise = hook.current.openSession("session-9");
		});
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.open"));
		await ws.reply("chat.open", "error", { code: "session_unavailable" });
		expect(await promise).toEqual({ ok: false, code: "session_unavailable" });
		expect(hook.current.error).toBeNull();
		expect(hook.current.canSend).toBe(true);
	});

	it("Covers 持有权代次：被接管后迟到的列表/切换回复不再改写本页", async () => {
		const { ws } = await readyChat();
		let list!: Promise<unknown>;
		let open!: Promise<unknown>;
		act(() => {
			list = hook.current.listSessions();
			open = hook.current.openSession("s");
		});
		await waitFor(() => expect(ws.sent.some((f) => f.method === "chat.open")).toBe(true));
		ws.push({ method: "chat.evicted", params: { courseId: COURSE } });
		await ws.reply("chat.sessions", "sessions", { courseId: COURSE, sessions: [{ sessionId: "late", updatedAt: null, messageCount: 1 }], current: "late", nextCursor: null });
		await ws.reply("chat.open", "history", { courseId: COURSE, running: false, events: [{ kind: "user", text: "不该出现" }] });
		expect(await list).toEqual({ error: "disconnected" });
		expect(await open).toEqual({ ok: false, code: "disconnected" });
		expect(hook.current.events).toEqual([]);
	});
});

describe("对话设置（模型与思考等级）", () => {
	const SETTINGS = [
		{
			id: "model",
			name: "Model",
			category: "model",
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
			currentValue: "auto",
			options: [
				{ value: "off", name: "Off" },
				{ value: "auto", name: "Auto", description: "Auto-detect per prompt" },
			],
		},
	];

	it("history 带的 settings 进入状态；没有这个字段（旧版 Host）时是空数组，页面据此不渲染入口", async () => {
		const { ws } = await readyChat();
		expect(hook.current.settings).toEqual([]);

		act(() => hook.current.reclaim());
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.attach"));
		await ws.reply("chat.attach", "history", { courseId: COURSE, running: false, events: [], settings: SETTINGS });
		await waitFor(() => expect(hook.current.settings).toEqual(SETTINGS));
	});

	it("Host 主动推 chat.settings（OMP 自己改了设置）时刷新；形状不合的载荷按空处理", async () => {
		const { ws } = await readyChat();
		act(() => ws.push({ method: "chat.settings", params: { courseId: COURSE, settings: SETTINGS } }));
		await waitFor(() => expect(hook.current.settings).toEqual(SETTINGS));

		act(() => ws.push({ method: "chat.settings", params: { courseId: COURSE, settings: [{ id: "model", currentValue: 3 }] } }));
		await waitFor(() => expect(hook.current.settings).toEqual([]));
	});

	it("setSetting 成功：发 chat.set_setting，chat.settings 的回复接管归约（整体刷新）", async () => {
		const { ws } = await readyChat();
		act(() => ws.push({ method: "chat.settings", params: { courseId: COURSE, settings: SETTINGS } }));
		let promise!: Promise<unknown>;
		act(() => {
			promise = hook.current.setSetting("model", "beta/two");
		});
		await waitFor(() =>
			expect(ws.sent.at(-1)).toMatchObject({ method: "chat.set_setting", params: { courseId: COURSE, configId: "model", value: "beta/two" } }),
		);
		await ws.reply("chat.set_setting", "chat.settings", {
			courseId: COURSE,
			settings: [{ ...SETTINGS[0], currentValue: "beta/two" }, SETTINGS[1]],
		});
		expect(await promise).toEqual({ ok: true });
		expect(hook.current.settings[0].currentValue).toBe("beta/two");
	});

	it("setSetting 失败：返回错误码、状态不变、不进全局错误态（旧版 Host 回 unknown_method）", async () => {
		const { ws } = await readyChat();
		act(() => ws.push({ method: "chat.settings", params: { courseId: COURSE, settings: SETTINGS } }));
		let promise!: Promise<unknown>;
		act(() => {
			promise = hook.current.setSetting("thinking", "off");
		});
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.set_setting"));
		await ws.reply("chat.set_setting", "error", { code: "unknown_method" });
		expect(await promise).toEqual({ ok: false, code: "unknown_method" });
		expect(hook.current.settings[1].currentValue).toBe("auto");
		expect(hook.current.error).toBeNull();
		expect(hook.current.canSend).toBe(true);
	});
});

describe("多 agent 的回落与登录态（评审修复）", () => {
	it("记住的 agent 不在本机时，回落到可用的那个：路由与历史都不再撞 chat_unavailable", async () => {
		rememberAgent("codex"); // 这台浏览器记着 codex，但本机只装了 omp（例如适配器被卸载）
		mount();
		await waitFor(() => expect(FakeWebSocket.all).toHaveLength(1));
		const ws = FakeWebSocket.all[0];
		act(() => ws.push({ method: "status", params: status("paired") }));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("hello"));
		await ws.reply("hello", "status", status("ready"));

		await waitFor(() => expect(ws.sent.at(-1)).toMatchObject({ method: "chat.attach", params: { agent: "omp" } }));
		await ws.reply("chat.attach", "history", { courseId: COURSE, running: false, events: [] });
		await waitFor(() => expect(hook.current.attached).toBe(true));

		expect(hook.current.agent).toBe("omp");
		act(() => void hook.current.send("你好"));
		await waitFor(() => expect(ws.sent.at(-1)).toMatchObject({ method: "chat.send", params: { agent: "omp" } }));
	});

	it("重新接上对话就清掉登录卡（学员可能在页面外完成了登录）", async () => {
		mount();
		await waitFor(() => expect(FakeWebSocket.all).toHaveLength(1));
		const ws = FakeWebSocket.all[0];
		act(() => ws.push({ method: "status", params: status("paired") }));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("hello"));
		await ws.reply("hello", "status", status("ready"));
		await ws.reply("chat.attach", "error", { code: "auth_required", methods: [{ id: "chat-gpt", name: "ChatGPT" }] });
		await waitFor(() => expect(hook.current.login).toEqual([{ id: "chat-gpt", name: "ChatGPT" }]));

		act(() => hook.current.reclaim());
		await ws.reply("chat.attach", "history", { courseId: COURSE, running: false, events: [] });
		await waitFor(() => expect(hook.current.login).toBeNull());
	});
});
