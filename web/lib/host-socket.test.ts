import { afterEach, beforeEach, expect, it, vi } from "vitest";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { HOST_WS_URL } from "./host-connection";
import { HOST_TO_PAGE, PAGE_TO_HOST, openHostSocket } from "./host-socket";

/**
 * U9 页面 ↔ Host 的 WebSocket 客户端（帧信封见 cgc-host/AGENTS.md）。
 *
 * 浏览器的 WebSocket 换成假连接：测试替 Host 推帧（push），断言页面发出的帧（sent）。
 * 方法名契约同 host-connection.test.ts 的端口契约，跨目录直接读 `cgc-host/protocol.json`。
 */

const HERE = dirname(fileURLToPath(import.meta.url));
const PROTOCOL_PATH = resolve(HERE, "../../cgc-host/protocol.json");

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

function connect() {
	const socket = openHostSocket();
	const ws = FakeWebSocket.last;
	ws.readyState = FakeWebSocket.OPEN;
	return { socket, ws };
}

beforeEach(() => {
	vi.stubGlobal("WebSocket", FakeWebSocket);
});

afterEach(() => {
	vi.unstubAllGlobals();
	vi.useRealTimers();
});

it("web 侧用到的方法名都在 cgc-host/protocol.json 对应方向的白名单里", () => {
	const { methods } = JSON.parse(readFileSync(PROTOCOL_PATH, "utf8")) as {
		methods: { pageToHost: string[]; hostToPage: string[] };
	};

	expect(PAGE_TO_HOST.filter((m) => !methods.pageToHost.includes(m))).toEqual([]);
	expect(HOST_TO_PAGE.filter((m) => !methods.hostToPage.includes(m))).toEqual([]);
});

it("连到 HOST_WS_URL；request 带 id 发出信封，按 id 取回各自的回复（回复可以是 error）", async () => {
	const { socket, ws } = connect();
	expect(ws.url).toBe(HOST_WS_URL);

	const pairing = socket.request("pair.request", { locale: "zh-CN" }, { timeoutMs: 1000 });
	const hello = socket.request("hello", { userId: "u1", browserKey: "k1" }, { timeoutMs: 1000 });
	const [first, second] = ws.sent;
	expect(first).toEqual({ method: "pair.request", id: expect.any(String), params: { locale: "zh-CN" } });
	expect(second.id).not.toBe(first.id);

	ws.push({ method: "error", id: second.id, params: { code: "unauthorized" } });
	ws.push({ method: "pair.result", id: first.id, params: { allowed: false } });

	await expect(hello).resolves.toEqual({
		method: "error",
		id: second.id,
		params: { code: "unauthorized" },
	});
	await expect(pairing).resolves.toEqual({
		method: "pair.result",
		id: first.id,
		params: { allowed: false },
	});
});

it("拿不到回复：超时以 timeout 拒绝；连接断开时在途请求以 disconnected 拒绝，之后的请求立即拒绝、send 不再发出", async () => {
	vi.useFakeTimers();
	const { socket, ws } = connect();

	const timedOut = socket.request("pair.request", {}, { timeoutMs: 1000 });
	vi.advanceTimersByTime(1000);
	await expect(timedOut).rejects.toThrow("timeout");

	const inFlight = socket.request("pair.request", {}, { timeoutMs: 1000 });
	const onClose = vi.fn();
	socket.onClose(onClose);
	ws.close();
	await expect(inFlight).rejects.toThrow("disconnected");
	expect(onClose).toHaveBeenCalledOnce();

	await expect(socket.request("hello", {}, { timeoutMs: 1000 })).rejects.toThrow("disconnected");
	socket.send("pair.cancel");
	expect(ws.sent.map((frame) => frame.method)).toEqual(["pair.request", "pair.request"]);
});

it("推送按方法分发，status 记作最新值；带 id 的回复不进订阅，hello 回复的 status 例外", async () => {
	const { socket, ws } = connect();
	const onStatus = vi.fn();
	const onError = vi.fn();
	socket.on("status", onStatus);
	socket.on("error", onError);
	expect(socket.status).toBeNull();

	ws.push({ method: "status", params: { state: "paired" } });
	expect(socket.status).toEqual({ state: "paired" });
	expect(onStatus).toHaveBeenLastCalledWith({ state: "paired" });

	const hello = socket.request("hello", { userId: "u1", browserKey: "k1" }, { timeoutMs: 1000 });
	ws.push({ method: "status", id: ws.sent[0].id, params: { state: "ready" } });
	await hello;
	expect(socket.status).toEqual({ state: "ready" });
	expect(onStatus).toHaveBeenLastCalledWith({ state: "ready" });

	const pairing = socket.request("pair.request", {}, { timeoutMs: 1000 });
	ws.push({ method: "error", id: ws.sent[1].id, params: { code: "busy" } });
	await pairing;
	expect(onError).not.toHaveBeenCalled();
});
