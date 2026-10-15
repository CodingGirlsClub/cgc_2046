import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, renderHook, waitFor } from "@testing-library/react";
import { MockedProvider } from "@apollo/client/testing/react";
import { useQuery } from "@apollo/client/react";
import { COURSE_LEARNING_DETAIL } from "@/lib/graphql/participations";
import type { HostStatus } from "@/lib/host-socket";
import { POLL_MS, useHostChat, type HostChat } from "./use-host-chat";

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
const DETECTED = { state: "detected", ompPresent: true, paired: true } as const;

const status = (state: HostStatus["state"]): HostStatus => ({
	state,
	pairedUserId: USER,
	pairedDisplayName: "学员甲",
	deviceName: "Ada 的 MacBook",
	tokenId: "tok_this",
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

	it("Covers AE1：未检测到 Host 时每 POLL_MS 重新检测，装好 Host 后无需刷新即开连接；电脑上没有 OMP 时停在 noOmp", async () => {
		vi.useFakeTimers({ shouldAdvanceTime: true });
		checkHost.mockResolvedValueOnce({ state: "noHost" });
		checkHost.mockResolvedValueOnce({ state: "detected", ompPresent: false, paired: false });
		mount();
		await waitFor(() => expect(hook.current.view).toEqual({ state: "noHost" }));

		await act(() => vi.advanceTimersByTimeAsync(POLL_MS));
		expect(hook.current.view).toEqual({ state: "noOmp" });
		expect(FakeWebSocket.all).toEqual([]);

		await act(() => vi.advanceTimersByTimeAsync(POLL_MS));
		expect(FakeWebSocket.all).toHaveLength(1);
		expect(checkHost).toHaveBeenCalledTimes(3);
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
