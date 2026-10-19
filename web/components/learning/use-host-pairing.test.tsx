import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, renderHook, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import { openHostSocket, type HostSocket, type HostStatus } from "@/lib/host-socket";
import type { McpTokenItem } from "@/lib/mcp";
import HostPairingList from "./host-pairing-list";
import { PAIR_TIMEOUT_MS, useHostPairing } from "./use-host-pairing";

/**
 * U9 课程页侧的配对（KTD3；AE1、AE2、AE10）。
 *
 * 真的 host-socket 跑在假 WebSocket 上：测试替 Host 推帧，断言页面发出的帧；lib/mcp 整体 mock，
 * 断言签发与撤销调用。浏览器密钥落在 localStorage（vitest.setup 有内存兜底）。
 */

const { issueMcpToken, revokeMcpToken, fetchMyMcpTokens } = vi.hoisted(() => ({
	issueMcpToken: vi.fn(),
	revokeMcpToken: vi.fn(),
	fetchMyMcpTokens: vi.fn(),
}));
vi.mock("@/lib/mcp", () => ({ issueMcpToken, revokeMcpToken, fetchMyMcpTokens }));

/** 同 lib/host-socket.test.ts 的假连接（测试文件之间不互相 import） */
class FakeWebSocket {
	static readonly OPEN = 1;
	static readonly CLOSED = 3;
	static last: FakeWebSocket;
	readyState = 0;
	sent: Array<{ method: string; id?: string; params?: unknown }> = [];
	onmessage: ((event: { data: string }) => void) | null = null;
	onclose: (() => void) | null = null;
	constructor(readonly url: string) {
		FakeWebSocket.last = this;
	}
	send(data: string) {
		this.sent.push(JSON.parse(data));
	}
	close() {
		this.readyState = FakeWebSocket.CLOSED;
		this.onclose?.();
	}
	push(message: object) {
		this.onmessage?.({ data: JSON.stringify(message) });
	}
}

const USER_A = "user-a";
const USER_B = "user-b";
const PLAIN = "cgch_plain_shown_once";
const keyOf = (userId: string) => `cgc:host-browser-key:${userId}`;

const UNPAIRED: HostStatus = {
	state: "unpaired",
	pairedUserId: null,
	deviceName: "Ada 的 MacBook",
	tokenId: null,
	agents: [{ kind: "omp", present: true }],
	ompPresent: true,
	version: "0.1.0",
	protocolVersion: 1,
};
const paired = (userId: string, tokenId: string): HostStatus => ({
	...UNPAIRED,
	state: "paired",
	pairedUserId: userId,
	tokenId,
});
const ready = (userId: string, tokenId: string): HostStatus => ({
	...paired(userId, tokenId),
	state: "ready",
});

function computer(id: string, name: string): McpTokenItem {
	return {
		id,
		name,
		kind: "LEARNING_HOST",
		lastUsedAt: "2026-10-14T08:00:00Z",
		revokedAt: null,
		insertedAt: "2026-10-01T00:00:00Z",
		status: "active",
	};
}

/** 建好连接，Host 推送首个 status（真实 Host 在连接建立时即推送） */
function connectHost(status: HostStatus) {
	const socket = openHostSocket();
	const ws = FakeWebSocket.last;
	ws.readyState = FakeWebSocket.OPEN;
	ws.push({ method: "status", params: status });
	return { socket, ws };
}

/** Host 回复页面最近发出的那一帧 */
function reply(ws: FakeWebSocket, method: string, params: object) {
	act(() => ws.push({ method, id: ws.sent.at(-1)?.id, params }));
}

function storedValues() {
	return [localStorage, sessionStorage].flatMap((storage) =>
		Array.from({ length: storage.length }, (_, i) => storage.getItem(storage.key(i)!)),
	);
}

function renderPairing(socket: HostSocket, userId = USER_A, locale = "zh-CN") {
	return renderHook(() => useHostPairing({ socket, userId, locale }));
}

beforeEach(() => {
	vi.stubGlobal("WebSocket", FakeWebSocket);
	localStorage.clear();
	sessionStorage.clear();
	issueMcpToken.mockResolvedValue({
		token: computer("tok_new", "Ada 的 MacBook"),
		plainToken: PLAIN,
	});
	revokeMcpToken.mockResolvedValue({});
});

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
	vi.unstubAllGlobals();
	vi.useRealTimers();
});

it("Covers AE1：未配对 → 签发学习凭证（备注取设备名）→ pair.request 带明文 → 允许 → 按账号存浏览器密钥、hello、进入 ready", async () => {
	const { socket, ws } = connectHost(UNPAIRED);
	const { result } = renderPairing(socket, USER_A, "en");
	expect(result.current.phase).toBe("unpaired");

	act(() => void result.current.connect());
	expect(result.current.phase).toBe("confirming");
	await waitFor(() => expect(ws.sent).toHaveLength(1));
	expect(issueMcpToken).toHaveBeenCalledWith("Ada 的 MacBook", "LEARNING_HOST");
	expect(ws.sent[0]).toMatchObject({ method: "pair.request", params: { token: PLAIN, locale: "en" } });

	reply(ws, "pair.result", { allowed: true, browserKey: "bk-new" });
	await waitFor(() => expect(ws.sent).toHaveLength(2));
	expect(ws.sent[1]).toMatchObject({ method: "hello", params: { userId: USER_A, browserKey: "bk-new" } });
	expect(localStorage.getItem(keyOf(USER_A))).toBe("bk-new");

	reply(ws, "status", ready(USER_A, "tok_new"));
	await waitFor(() => expect(result.current.phase).toBe("ready"));
	expect(revokeMcpToken).not.toHaveBeenCalled();
	// 明文只在那一次请求的闭包里：不进 storage，也不在交给对话栏的值里
	expect(storedValues().join()).not.toContain(PLAIN);
	expect(JSON.stringify(result.current)).not.toContain(PLAIN);
});

it("Covers AE2：本机确认被拒 → denied，不存任何密钥，用登录态补撤销刚签发的那一枚；可以重新发起", async () => {
	const { socket, ws } = connectHost(UNPAIRED);
	const { result } = renderPairing(socket);
	act(() => void result.current.connect());
	await waitFor(() => expect(ws.sent).toHaveLength(1));

	reply(ws, "pair.result", { allowed: false });
	await waitFor(() => expect(result.current.phase).toBe("denied"));
	expect(storedValues()).toEqual([]);
	expect(revokeMcpToken).toHaveBeenCalledWith("tok_new");

	act(() => void result.current.connect());
	expect(result.current.phase).toBe("confirming");
	await waitFor(() => expect(ws.sent).toHaveLength(2));
	expect(issueMcpToken).toHaveBeenCalledTimes(2);
	reply(ws, "pair.result", { allowed: false });
	await waitFor(() => expect(result.current.phase).toBe("denied"));
});

describe("Covers AE2：拿不到「允许」的结果 → 用登录态撤销刚签发的那一枚", () => {
	it.each([
		["Host 回 error（没走到弹窗就结束）", "platform_unavailable"],
		["页面等待超时", "timeout"],
		["连接中断", "disconnected"],
	])("%s → error(%s)，不存密钥；连接还开着就发 pair.cancel", async (_, reason) => {
		if (reason === "timeout") vi.useFakeTimers({ shouldAdvanceTime: true });
		const { socket, ws } = connectHost(UNPAIRED);
		const { result } = renderPairing(socket);
		act(() => void result.current.connect());
		await waitFor(() => expect(ws.sent).toHaveLength(1));

		if (reason === "platform_unavailable") reply(ws, "error", { code: "platform_unavailable" });
		if (reason === "timeout") act(() => vi.advanceTimersByTime(PAIR_TIMEOUT_MS));
		if (reason === "disconnected") act(() => ws.close());

		await waitFor(() => expect(result.current.phase).toBe("error"));
		expect(result.current.reason).toBe(reason);
		expect(revokeMcpToken).toHaveBeenCalledWith("tok_new");
		expect(storedValues()).toEqual([]);
		expect(ws.sent.map((frame) => frame.method)).toEqual(
			reason === "disconnected" ? ["pair.request"] : ["pair.request", "pair.cancel"],
		);
	});
});

it("连接中断后对话栏换上新连接（R28 的重连）：上一条连接上的 error(disconnected) 不再停留，按新连接的 status 推导", async () => {
	const first = connectHost(UNPAIRED);
	const { result, rerender } = renderHook(({ socket }) => useHostPairing({ socket, userId: USER_A, locale: "zh-CN" }), {
		initialProps: { socket: first.socket },
	});
	act(() => void result.current.connect());
	await waitFor(() => expect(first.ws.sent).toHaveLength(1));
	act(() => first.ws.close());
	await waitFor(() => expect(result.current.reason).toBe("disconnected"));

	const second = connectHost(UNPAIRED);
	rerender({ socket: second.socket });
	expect(result.current.phase).toBe("unpaired");
	expect(result.current.reason).toBeNull();
});

it("等待本机确认时取消 → 发 pair.cancel；Host 按拒绝结束后回到未配对（不是「已拒绝」），刚签发的那一枚照样补撤销", async () => {
	const { socket, ws } = connectHost(UNPAIRED);
	const { result } = renderPairing(socket);
	act(() => void result.current.connect());
	await waitFor(() => expect(ws.sent).toHaveLength(1));

	act(() => result.current.cancel());
	expect(ws.sent[1]).toEqual({ method: "pair.cancel" });
	act(() => ws.push({ method: "pair.result", id: ws.sent[0].id, params: { allowed: false } }));

	await waitFor(() => expect(result.current.phase).toBe("unpaired"));
	expect(revokeMcpToken).toHaveBeenCalledWith("tok_new");
	expect(storedValues()).toEqual([]);
});

it("Host 已为本账号配对（本浏览器没有密钥，如换了浏览器）→ 不签发，pair.request 不带凭证；允许后换发浏览器密钥", async () => {
	const { socket, ws } = connectHost(paired(USER_A, "tok_a"));
	const { result } = renderPairing(socket);
	expect(result.current.phase).toBe("unpaired");

	act(() => void result.current.connect());
	await waitFor(() => expect(ws.sent).toHaveLength(1));
	expect(ws.sent[0]).toEqual({ method: "pair.request", id: expect.any(String), params: { locale: "zh-CN" } });
	expect(issueMcpToken).not.toHaveBeenCalled();

	reply(ws, "pair.result", { allowed: true, browserKey: "bk-reissued" });
	await waitFor(() => expect(ws.sent).toHaveLength(2));
	expect(localStorage.getItem(keyOf(USER_A))).toBe("bk-reissued");
	reply(ws, "status", ready(USER_A, "tok_a"));
	await waitFor(() => expect(result.current.phase).toBe("ready"));
});

describe("收到 status 时用本账号存的浏览器密钥 hello", () => {
	it("Host 核实期间为 checking，回 ready 即可对话", async () => {
		localStorage.setItem(keyOf(USER_A), "bk-a");
		const { socket, ws } = connectHost(paired(USER_A, "tok_a"));
		const { result } = renderPairing(socket);
		expect(result.current.phase).toBe("checking");
		await waitFor(() => expect(ws.sent).toHaveLength(1));
		expect(ws.sent[0]).toMatchObject({ method: "hello", params: { userId: USER_A, browserKey: "bk-a" } });

		reply(ws, "status", ready(USER_A, "tok_a"));
		expect(result.current.phase).toBe("ready");
	});

	it("Host 回 unauthorized → 本机密钥已失效，清掉并显示未配对", async () => {
		localStorage.setItem(keyOf(USER_A), "bk-stale");
		const { socket, ws } = connectHost(paired(USER_A, "tok_a"));
		const { result } = renderPairing(socket);
		await waitFor(() => expect(ws.sent).toHaveLength(1));

		reply(ws, "error", { code: "unauthorized" });
		await waitFor(() => expect(result.current.phase).toBe("unpaired"));
		expect(localStorage.getItem(keyOf(USER_A))).toBeNull();
	});
});

it.each([
	["Host 为 A 配对、这条连接未授权（换账号后打开的页面）", paired(USER_A, "tok_a")],
	["这条连接已为 A 授权（不刷新直接换账号）", ready(USER_A, "tok_a")],
])("同一浏览器换成 B 登录：%s → 未配对，不拿 A 的密钥 hello；B 连接时签发自己的凭证", async (_, status) => {
	localStorage.setItem(keyOf(USER_A), "bk-a");
	const { socket, ws } = connectHost(status);
	const { result } = renderPairing(socket, USER_B);
	expect(result.current.phase).toBe("unpaired");
	expect(ws.sent).toEqual([]);
	expect(localStorage.getItem(keyOf(USER_A))).toBe("bk-a");

	act(() => void result.current.connect());
	await waitFor(() => expect(ws.sent).toHaveLength(1));
	expect(issueMcpToken).toHaveBeenCalledOnce();
	expect(ws.sent[0]).toMatchObject({ method: "pair.request", params: { token: PLAIN } });
	reply(ws, "pair.result", { allowed: false });
	await waitFor(() => expect(result.current.phase).toBe("denied"));
});

/** 对话栏（U10）的接法：已配对的电脑撤销本机这台时交给 forget */
function Panel({ socket }: { socket: HostSocket }) {
	const pairing = useHostPairing({ socket, userId: USER_A, locale: "zh-CN" });
	return (
		<>
			<output data-testid="phase">{pairing.phase}</output>
			<HostPairingList
				currentTokenId={pairing.status?.tokenId ?? null}
				onRevokeCurrent={pairing.forget}
			/>
		</>
	);
}

describe("Covers AE10：在「已配对的电脑」里撤销本机这台 → 登录态撤销、清掉本机密钥，回到未配对", () => {
	it("连接已授权 → 发出 pair.forget，Host 推送未配对后显示未配对", async () => {
		localStorage.setItem(keyOf(USER_A), "bk-a");
		fetchMyMcpTokens.mockResolvedValue([
			computer("tok_this", "Ada 的 MacBook"),
			computer("tok_other", "办公室 iMac"),
		]);
		const { socket, ws } = connectHost(ready(USER_A, "tok_this"));
		render(<Panel socket={socket} />);
		expect(screen.getByTestId("phase")).toHaveTextContent("ready");

		fireEvent.click(await screen.findByRole("button", { name: "撤销「Ada 的 MacBook」" }));
		fireEvent.click(screen.getByRole("button", { name: "确认撤销「Ada 的 MacBook」" }));

		await waitFor(() => expect(ws.sent).toEqual([{ method: "pair.forget" }]));
		expect(revokeMcpToken).toHaveBeenCalledWith("tok_this");
		expect(localStorage.getItem(keyOf(USER_A))).toBeNull();

		act(() => ws.push({ method: "status", params: UNPAIRED }));
		expect(screen.getByTestId("phase")).toHaveTextContent("unpaired");
	});

	it("连接未授权（本浏览器没有密钥）→ 不发 pair.forget（Host 下次 hello 核实遇 401 自己清掉）", async () => {
		fetchMyMcpTokens.mockResolvedValue([computer("tok_this", "Ada 的 MacBook")]);
		const { socket, ws } = connectHost(paired(USER_A, "tok_this"));
		render(<Panel socket={socket} />);

		fireEvent.click(await screen.findByRole("button", { name: "撤销「Ada 的 MacBook」" }));
		fireEvent.click(screen.getByRole("button", { name: "确认撤销「Ada 的 MacBook」" }));

		await waitFor(() => expect(revokeMcpToken).toHaveBeenCalledWith("tok_this"));
		expect(ws.sent).toEqual([]);
		expect(screen.getByTestId("phase")).toHaveTextContent("unpaired");
	});
});
