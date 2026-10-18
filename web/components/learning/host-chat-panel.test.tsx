import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";
import { MockedProvider } from "@apollo/client/testing/react";
import { render } from "@/test-utils";
import { COURSE_CONTENT } from "@/lib/graphql/course-content";
import {
	COURSE_LEARNING_DETAIL,
	type CourseLearningDetail,
	type LearningObjectiveState,
} from "@/lib/graphql/participations";
import type { HostConnection } from "@/lib/host-connection";
import type { HostStatus } from "@/lib/host-socket";
import CourseLearningPage from "@/app/[locale]/learning/courses/[id]/page";
import HostChatPanel from "./host-chat-panel";
import { POLL_MS } from "./use-host-chat";

/**
 * U10 对话栏（R7–R9、R12、R19、R20、R26、R27、R29；AE1、AE3、AE6、AE9–AE12）。
 *
 * 本机检测与 lib/mcp mock 掉；host-socket、配对与对话的 hook 都是真的，跑在假 WebSocket 上：
 * 测试替 Host 推帧，断言页面发出的帧与渲染结果。最后一组渲染整个学员课程页，学习详情经 MockedProvider 提供。
 */

const { checkHost, requestHostAccess, issueMcpToken, revokeMcpToken, fetchMyMcpTokens, useParams, useAuthed } =
	vi.hoisted(() => ({
		checkHost: vi.fn(),
		requestHostAccess: vi.fn(),
		issueMcpToken: vi.fn(),
		revokeMcpToken: vi.fn(),
		fetchMyMcpTokens: vi.fn(),
		useParams: vi.fn(),
		useAuthed: vi.fn(),
	}));
vi.mock("@/lib/host-connection", async (importOriginal) => ({
	...(await importOriginal<typeof import("@/lib/host-connection")>()),
	checkHost,
	requestHostAccess,
}));
vi.mock("@/lib/mcp", () => ({ issueMcpToken, revokeMcpToken, fetchMyMcpTokens }));
vi.mock("next/navigation", async (importOriginal) => ({
	...(await importOriginal<typeof import("next/navigation")>()),
	useParams,
}));
vi.mock("@/lib/auth-provider", () => ({ useAuthed }));
vi.mock("@/components/site-page", () => ({ default: ({ children }: { children: React.ReactNode }) => <>{children}</> }));

/** 同 use-host-chat.test.tsx 的假连接（测试文件之间不互相 import） */
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
		act(() => this.onmessage?.({ data: JSON.stringify(message) }));
	}
	reply(method: string, replyMethod: string, params: object) {
		const request = this.sent.findLast((frame) => frame.method === method);
		return act(async () => this.onmessage?.({ data: JSON.stringify({ method: replyMethod, id: request?.id, params }) }));
	}
	pushEvent(params: object) {
		this.push({ method: "turn.delta", params: { courseId: COURSE, ...params } });
	}
}

const COURSE = "11111111-1111-4111-8111-111111111111";
const WORKSPACE = "33333333-3333-4333-8333-333333333333";
const USER = "user-a";
const INSTALL = "curl -fsSL https://api.codingirlsclub.com/ext/cgc-host/install.sh | bash";
const DETECTED: HostConnection = { state: "detected", agents: [{ kind: "omp", present: true }], paired: true, capabilities: [] };
const keyOf = (userId: string) => `cgc:host-browser-key:${userId}`;

const OMP_ONLY = [{ kind: "omp", present: true }];
const status = (
	state: HostStatus["state"],
	agents: { kind: string; present: boolean; sources?: { source: string; version: string | null }[] }[] = OMP_ONLY,
): HostStatus => ({
	state,
	pairedUserId: state === "unpaired" ? null : USER,
	pairedDisplayName: state === "unpaired" ? null : "学员甲",
	deviceName: "Ada 的 MacBook",
	tokenId: state === "unpaired" ? null : "tok_this",
	agents,
	ompPresent: true,
	version: "0.2.0",
	protocolVersion: 1,
});

function renderPanel(locale: "zh-CN" | "en" = "zh-CN", extra: Partial<Parameters<typeof HostChatPanel>[0]> = {}) {
	return render(
		<MockedProvider mocks={[]}>
			<HostChatPanel courseId={COURSE} userId={USER} locale={locale} workspaceId={WORKSPACE} courseVersion={3} unitId={null} {...extra} />
		</MockedProvider>,
		{ locale },
	);
}

const socketCount = () => FakeWebSocket.all.length;

/** 已存浏览器密钥：连接 → hello → ready → chat.attach → history；返回这条连接 */
async function attach(
	events: object[] = [],
	running = false,
	settings?: object[],
	agents: { kind: string; present: boolean; sources?: { source: string; version: string | null }[] }[] = OMP_ONLY,
) {
	await waitFor(() => expect(socketCount()).toBeGreaterThan(0));
	const ws = FakeWebSocket.all.at(-1)!;
	ws.push({ method: "status", params: status("paired", agents) });
	await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("hello"));
	await ws.reply("hello", "status", status("ready", agents));
	await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.attach"));
	await ws.reply("chat.attach", "history", { courseId: COURSE, running, events, ...(settings ? { settings } : {}) });
	return ws;
}

async function readyPanel(events: object[] = [], running = false, settings?: object[]) {
	renderPanel();
	const ws = await attach(events, running, settings);
	await screen.findByRole("textbox", { name: "发给 agent 的消息" });
	return ws;
}

const input = () => screen.getByRole("textbox", { name: "发给 agent 的消息" });

async function sendMessage(ws: FakeWebSocket, text: string) {
	fireEvent.change(input(), { target: { value: text } });
	fireEvent.click(screen.getByRole("button", { name: "发送" }));
	await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.send"));
	await ws.reply("chat.send", "turn.delta", { courseId: COURSE, kind: "user", text });
}

beforeEach(() => {
	vi.stubGlobal("WebSocket", FakeWebSocket);
	FakeWebSocket.all = [];
	localStorage.clear();
	localStorage.setItem(keyOf(USER), "bk-a");
	checkHost.mockResolvedValue(DETECTED);
	fetchMyMcpTokens.mockResolvedValue([]);
	revokeMcpToken.mockResolvedValue({});
	issueMcpToken.mockResolvedValue({ token: { id: "tok_new" }, plainToken: "cgch_plain" });
});

afterEach(() => {
	cleanup();
	vi.clearAllMocks();
	vi.unstubAllGlobals();
	vi.useRealTimers();
});

describe("连接状态（R26）", () => {
	it("Covers AE1：未检测到 Host 显示安装命令与登录项提示；装好后无需刷新显示「连接」，点击即发起配对", async () => {
		vi.useFakeTimers({ shouldAdvanceTime: true });
		localStorage.clear();
		checkHost.mockResolvedValueOnce({ state: "noHost" });
		renderPanel();
		expect(await screen.findByText(INSTALL)).toBeInTheDocument();
		expect(screen.getByText(/系统设置 → 通用 → 登录项/)).toBeInTheDocument();

		await act(() => vi.advanceTimersByTimeAsync(POLL_MS));
		await waitFor(() => expect(socketCount()).toBe(1));
		FakeWebSocket.all[0].push({ method: "status", params: status("unpaired") });
		fireEvent.click(await screen.findByRole("button", { name: "连接" }));

		await waitFor(() => expect(FakeWebSocket.all[0].sent.at(-1)?.method).toBe("pair.request"));
		expect(issueMcpToken).toHaveBeenCalledWith("Ada 的 MacBook", "LEARNING_HOST");
		expect(screen.getByText("请在电脑弹出的确认框里确认这次授权（配对）。")).toBeInTheDocument();
	});

	it.each<[string, HostConnection, RegExp | string]>([
		["Covers AE12：Host 需要更新", { state: "staleHost" }, INSTALL],
		["浏览器阻止访问本机", { state: "blocked" }, "浏览器阻止了本页访问本机。"],
		["不受支持的浏览器", { state: "unsupported", reason: "browser" }, "对话栏支持 macOS、Windows 与 Ubuntu 桌面上的 Chrome，以及桌面版 Firefox。"],
		["本机没有可用的 agent", { state: "detected", agents: [{ kind: "omp", present: false }], paired: false, capabilities: [] }, "还差一个搭子引擎"],
	])("%s：给出说明与下一步", async (_, probe, text) => {
		checkHost.mockResolvedValue(probe);
		renderPanel();
		expect(await screen.findByText(text)).toBeInTheDocument();
	});

	it("不受支持的访问地址：给出规范地址的链接", async () => {
		checkHost.mockResolvedValue({ state: "unsupported", reason: "address", canonicalUrl: "https://codingirlsclub.com/learning/courses/x" });
		renderPanel();
		expect(await screen.findByRole("link", { name: "在正式地址打开" })).toHaveAttribute(
			"href",
			"https://codingirlsclub.com/learning/courses/x",
		);
	});

	it("需要允许本机访问：按钮从点击处发起本机请求", async () => {
		checkHost.mockResolvedValue({ state: "needsPermission" });
		requestHostAccess.mockResolvedValue({ state: "noHost" });
		renderPanel();
		fireEvent.click(await screen.findByRole("button", { name: "允许访问本机" }));
		expect(requestHostAccess).toHaveBeenCalledOnce();
		expect(await screen.findByText("没有检测到 CGC Host。")).toBeInTheDocument();
		expect(screen.getByText(INSTALL)).toBeInTheDocument();
	});

	it.each(["zh-CN", "en"] as const)("首次权限 prompt：提供安装入口但不主动请求本机（%s）", async (locale) => {
		checkHost.mockResolvedValue({ state: "needsPermission" });
		renderPanel(locale);
		expect(await screen.findByText(locale === "zh-CN" ? "尚未安装？" : "Not installed yet?")).toBeInTheDocument();
		expect(screen.getByText(INSTALL)).toBeInTheDocument();
		expect(screen.getByRole("button", { name: locale === "zh-CN" ? "复制命令" : "Copy command" })).toBeInTheDocument();
		expect(requestHostAccess).not.toHaveBeenCalled();
		expect(socketCount()).toBe(0);
	});

	it("点击后仍 prompt：给出失败反馈，轮询保留反馈；安装后再次点击成功进入连接状态", async () => {
		vi.useFakeTimers({ shouldAdvanceTime: true });
		localStorage.clear();
		checkHost.mockResolvedValue({ state: "needsPermission" });
		requestHostAccess.mockResolvedValueOnce({ state: "needsPermission", probeFailed: true });
		renderPanel();
		fireEvent.click(await screen.findByRole("button", { name: "允许访问本机" }));
		expect(await screen.findByRole("status")).toHaveTextContent("尚不能确认本机访问权限");
		expect(screen.getByRole("status")).toHaveTextContent("安装并启动");
		expect(screen.getByText(INSTALL)).toBeInTheDocument();
		expect(screen.queryByText("浏览器阻止了本页访问本机。")).not.toBeInTheDocument();
		expect(screen.queryByText("没有检测到 CGC Host。")).not.toBeInTheDocument();
		await act(() => vi.advanceTimersByTimeAsync(POLL_MS));
		expect(screen.getByRole("status")).toHaveTextContent("尚不能确认本机访问权限");
		expect(requestHostAccess).toHaveBeenCalledOnce();
		expect(socketCount()).toBe(0);

		requestHostAccess.mockResolvedValueOnce(DETECTED);
		fireEvent.click(screen.getByRole("button", { name: "允许访问本机" }));
		await waitFor(() => expect(socketCount()).toBe(1));
		FakeWebSocket.all[0].push({ method: "status", params: status("unpaired") });
		expect(await screen.findByRole("button", { name: "连接" })).toBeInTheDocument();
		expect(screen.queryByText(INSTALL)).not.toBeInTheDocument();
		expect(screen.queryByText(/尚不能确认本机访问权限/)).not.toBeInTheDocument();
	});

	it("点击后权限明确 denied：显示网站设置指引，不把拒绝说成未安装", async () => {
		checkHost.mockResolvedValue({ state: "needsPermission" });
		requestHostAccess.mockResolvedValue({ state: "blocked" });
		renderPanel();
		fireEvent.click(await screen.findByRole("button", { name: "允许访问本机" }));
		expect(await screen.findByText("浏览器阻止了本页访问本机。")).toBeInTheDocument();
		expect(screen.getByText(/网站设置里允许本站访问本地网络/)).toBeInTheDocument();
		expect(screen.queryByText(INSTALL)).not.toBeInTheDocument();
		expect(socketCount()).toBe(0);
	});

	it("等待本机确认可以取消；被拒绝后显示「配对被拒绝」并可重新连接", async () => {
		localStorage.clear();
		renderPanel();
		await waitFor(() => expect(socketCount()).toBe(1));
		const ws = FakeWebSocket.all[0];
		ws.push({ method: "status", params: status("unpaired") });
		fireEvent.click(await screen.findByRole("button", { name: "连接" }));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("pair.request"));

		await ws.reply("pair.request", "pair.result", { allowed: false });
		expect(await screen.findByText("你在电脑上拒绝了配对。")).toBeInTheDocument();
		fireEvent.click(screen.getByRole("button", { name: "重新连接" }));
		await waitFor(() => expect(ws.sent.filter((f) => f.method === "pair.request")).toHaveLength(2));

		fireEvent.click(screen.getByRole("button", { name: "取消" }));
		expect(ws.sent.at(-1)).toEqual({ method: "pair.cancel" });
	});

	it("连接中断：显示「连接中断」，Host 恢复后自动接上原对话", async () => {
		vi.useFakeTimers({ shouldAdvanceTime: true });
		const ws = await readyPanel([{ kind: "user", text: "上次的问题" }]);
		act(() => ws.close());
		expect(screen.getByText("与本机 Host 的连接中断了，Host 恢复后会自动重连。")).toBeInTheDocument();

		await act(() => vi.advanceTimersByTimeAsync(POLL_MS));
		await attach([{ kind: "user", text: "上次的问题" }]);
		expect(await screen.findByText("上次的问题")).toBeInTheDocument();
	});
});

it("Covers AE10：在「已配对的电脑」里撤销本机这台 → pair.forget，Host 推送未配对后回到「连接」", async () => {
	fetchMyMcpTokens.mockResolvedValue([
		{ id: "tok_this", name: "Ada 的 MacBook", kind: "LEARNING_HOST", lastUsedAt: null, revokedAt: null, insertedAt: "2026-10-01T00:00:00Z", status: "active" },
	]);
	const ws = await readyPanel();
	fireEvent.click(screen.getByRole("button", { name: "更多" }));
	fireEvent.click(screen.getByRole("menuitem", { name: "已配对的电脑" }));
	fireEvent.click(await screen.findByRole("button", { name: "撤销「Ada 的 MacBook」" }));
	fireEvent.click(screen.getByRole("button", { name: "确认撤销「Ada 的 MacBook」" }));
	await waitFor(() => expect(ws.sent.at(-1)).toEqual({ method: "pair.forget" }));

	ws.push({ method: "status", params: status("unpaired") });
	expect(await screen.findByRole("button", { name: "连接" })).toBeInTheDocument();
	expect(screen.queryByRole("textbox", { name: "发给 agent 的消息" })).not.toBeInTheDocument();
});

it("头部图标悬停显示 Tooltip（标题栏常驻图标）", async () => {
	renderPanel("zh-CN", { onTogglePin: () => {} });
	await attach();
	await screen.findByRole("textbox", { name: "发给 agent 的消息" });
	const newChat = screen.getByRole("button", { name: "新开对话" });
	fireEvent.mouseEnter(newChat);
	expect(screen.getByRole("tooltip")).toHaveTextContent("新开对话");
	fireEvent.mouseLeave(newChat);
	expect(screen.queryByRole("tooltip")).toBeNull();

	const pin = screen.getByRole("button", { name: "固定到右侧" });
	fireEvent.focus(pin);
	expect(screen.getByRole("tooltip")).toHaveTextContent("固定到右侧");
	fireEvent.blur(pin);
});

it("头部「更多」菜单：收纳已配对的电脑/重新检测等控制项；点外部或选项后收起", async () => {
	await readyPanel();
	const trigger = screen.getByRole("button", { name: "更多" });
	fireEvent.click(trigger);
	expect(screen.getByRole("menuitem", { name: "已配对的电脑" })).toBeInTheDocument();
	expect(screen.getByRole("menuitem", { name: "重新检测" })).toBeInTheDocument();
	expect(screen.queryByRole("menu")).not.toBeNull();

	fireEvent.mouseDown(document.body);
	expect(screen.queryByRole("menu")).toBeNull();

	fireEvent.click(trigger);
	fireEvent.click(screen.getByRole("menuitem", { name: "已配对的电脑" }));
	expect(screen.queryByRole("menu")).toBeNull();
});

it("KTD9：进入可对话状态不自动发消息；R15：显示这门课的工作目录", async () => {
	const ws = await readyPanel();
	expect(ws.sent.map((f) => f.method)).toEqual(["hello", "chat.attach"]);
	expect(screen.getByText(`~/cgc2046_workspace/courses/${USER}/${COURSE}`, { exact: false })).toBeInTheDocument();
	expect(screen.getByText(/我是你的学习搭子/)).toBeInTheDocument();
	// 总览（unitId=null）给规划类情境入口；点一下把提示词填进输入框，不自动发送
	fireEvent.click(screen.getByRole("button", { name: "帮我规划学习路径" }));
	expect(screen.getByRole("textbox", { name: "发给 agent 的消息" })).toHaveValue("帮我规划学习路径");
	expect(ws.sent.map((f) => f.method)).toEqual(["hello", "chat.attach"]);
});

describe("卡片（R19、R20）", () => {
	const PERMISSION = {
		courseId: COURSE,
		cardId: "card-p",
		kind: "permission",
		toolCallId: "t1",
		title: "echo cgc-probe",
		toolKind: "execute",
		input: '{"command":"echo cgc-probe"}',
		options: [
			{ optionId: "allow_once", name: "Allow once", kind: "allow_once" },
			{ optionId: "allow_always", name: "Always allow", kind: "allow_always" },
			{ optionId: "reject_once", name: "Reject", kind: "reject_once" },
			{ optionId: "reject_always", name: "Always reject", kind: "reject_always" },
		],
	};

	it("Covers AE6：审批卡片原样显示四个选项，「始终允许」附说明；按所选选项回填，Host 收起后卡片消失", async () => {
		const ws = await readyPanel();
		await sendMessage(ws, "运行一下");
		ws.push({ method: "turn.card", params: PERMISSION });

		const card = screen.getByRole("group", { name: "需要你的确认" });
		expect(within(card).getAllByRole("button").map((b) => b.textContent)).toEqual([
			"Allow once",
			"Always allow",
			"Reject",
			"Always reject",
		]);
		expect(within(card).getByRole("button", { name: "Always allow" })).toHaveAccessibleDescription(
			"「Always allow」：本次对话中不再询问此类操作（重启后需重新确认）",
		);

		fireEvent.click(within(card).getByRole("button", { name: "Reject" }));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("card.answer"));
		expect(ws.sent.at(-1)?.params).toEqual({ agent: "omp", courseId: COURSE, cardId: "card-p", optionId: "reject_once" });
		await ws.reply("card.answer", "turn.card.closed", { courseId: COURSE, cardId: "card-p", reason: "answered" });
		expect(screen.queryByRole("group", { name: "需要你的确认" })).not.toBeInTheDocument();
	});

	it("提问卡片：选项与自由输入都能作答，作答按 schema 的字段回填；也可以跳过", async () => {
		const ws = await readyPanel();
		await sendMessage(ws, "考考我");
		ws.push({
			method: "turn.card",
			params: {
				courseId: COURSE,
				cardId: "card-q",
				kind: "question",
				message: "请选择 甲 或 乙。",
				schema: {
					type: "object",
					properties: {
						q0: { type: "string", title: "请选择 甲 或 乙。", oneOf: [{ const: "甲", title: "甲" }, { const: "乙", title: "乙" }] },
						q0__other: { type: "string", title: "Other (type your own)" },
					},
				},
			},
		});
		const card = screen.getByRole("group", { name: "agent 在问你" });
		fireEvent.click(within(card).getByRole("radio", { name: "乙" }));
		fireEvent.change(within(card).getByRole("textbox", { name: "Other (type your own)" }), { target: { value: "补充" } });
		fireEvent.click(within(card).getByRole("button", { name: "提交" }));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("card.answer"));
		expect(ws.sent.at(-1)?.params).toEqual({
			agent: "omp",
			courseId: COURSE,
			cardId: "card-q",
			action: "accept",
			content: { q0: "乙", q0__other: "补充" },
		});

		await ws.reply("card.answer", "error", { code: "bad_request" });
		fireEvent.click(within(card).getByRole("button", { name: "跳过" }));
		await waitFor(() => expect(ws.sent.at(-1)?.params).toEqual({ agent: "omp", courseId: COURSE, cardId: "card-q", action: "decline" }));
	});

	it("Covers AE11：停止 → 发 chat.stop，等待回答的卡片立刻收起；Host 结束本轮后工具标为已停止，输入恢复可用", async () => {
		const ws = await readyPanel();
		await sendMessage(ws, "跑个长任务");
		ws.pushEvent({ kind: "tool", toolCallId: "t1", title: "npm test", toolKind: "execute", status: "in_progress" });
		ws.push({ method: "turn.card", params: PERMISSION });

		fireEvent.click(screen.getByRole("button", { name: "停止" }));
		expect(ws.sent.at(-1)).toEqual({ method: "chat.stop", params: { courseId: COURSE } });
		expect(screen.queryByRole("group", { name: "需要你的确认" })).not.toBeInTheDocument();

		ws.push({ method: "turn.card.closed", params: { courseId: COURSE, cardId: "card-p", reason: "cancelled" } });
		ws.pushEvent({ kind: "tool", toolCallId: "t1", title: "npm test", toolKind: "execute", status: "stopped" });
		ws.push({ method: "turn.end", params: { courseId: COURSE, stopReason: "cancelled" } });
		expect(screen.getByText("已停止")).toBeInTheDocument();
		expect(screen.getByText("已停止这一轮。")).toBeInTheDocument();
		fireEvent.change(input(), { target: { value: "下一条" } });
		expect(screen.getByRole("button", { name: "发送" })).toBeEnabled();
	});
});

describe("Covers AE9 / R27：模型错误", () => {
	it.each([
		["auth", "模型认证失败"],
		["quota", "模型额度用尽或被限流"],
	])("%s：显示面向学员的说明与处理办法，原文折叠在说明里，不当成 agent 的回复", async (modelError, title) => {
		const ws = await readyPanel();
		await sendMessage(ws, "你好");
		ws.pushEvent({ kind: "message", text: "Error: 401 invalid x-api-key" });
		ws.push({ method: "turn.end", params: { courseId: COURSE, stopReason: "end_turn", modelError } });

		const alert = screen.getByRole("alert");
		expect(alert).toHaveTextContent(title);
		expect(alert).toHaveTextContent("OMP");
		const raw = within(alert).getByText("Error: 401 invalid x-api-key");
		expect(raw.closest("details")).not.toHaveAttribute("open");
		expect(screen.getAllByText("Error: 401 invalid x-api-key")).toHaveLength(1);
	});

	it("unknown：照常显示原文，附一句「可能是模型配置问题」", async () => {
		const ws = await readyPanel();
		await sendMessage(ws, "/help");
		ws.pushEvent({ kind: "message", text: "Unexpected failure" });
		ws.push({ method: "turn.end", params: { courseId: COURSE, stopReason: "end_turn", modelError: "unknown" } });
		expect(screen.getByText("Unexpected failure").closest("details")).toBeNull();
		expect(screen.getByText(/可能是模型配置问题/)).toBeInTheDocument();
	});
});

it("agent 回复按安全 Markdown 渲染：粗体、表格、行内与块级公式", async () => {
	const ws = await readyPanel();
	await sendMessage(ws, "讲讲三边关系");
	ws.pushEvent({ kind: "message", text: "**快捷判据**：$a+b>c$。\n\n| 三边 | 能否 |\n|---|---|\n| 3,4,8 | 否 |\n\n$$\n|a-b|<x<a+b\n$$" });

	const log = screen.getByRole("log");
	expect(within(log).getByText("快捷判据").tagName).toBe("STRONG");
	expect(log.querySelector("table")).not.toBeNull();
	expect(log.querySelectorAll(".katex")).toHaveLength(2);
	expect(log.querySelector(".katex-display")).not.toBeNull();
	expect(log.textContent).not.toMatch(/\*\*|\$|\|---/);
});

it("agent 回复是不可信内容：原始 HTML 转成文本、危险链接与公式里的 \\href 不产生链接；学员消息、工具输出仍是纯文本", async () => {
	const ws = await readyPanel();
	await sendMessage(ws, "<b>我的问题</b>");
	ws.pushEvent({
		kind: "message",
		text: '<img src=x onerror="window.__xss=1"> [点我](javascript:alert(1)) <a href="javascript:alert(1)">链接</a> $\\href{javascript:alert(1)}{公式链接}$',
	});
	ws.pushEvent({ kind: "tool", toolCallId: "t1", title: "<img src=x onerror=alert(1)>", toolKind: "read", status: "completed", output: "<script>alert(1)</script>" });

	const log = screen.getByRole("log");
	expect(within(log).getByText("<b>我的问题</b>")).toBeInTheDocument();
	expect(log.textContent).toContain('<img src=x onerror="window.__xss=1">');
	expect(log.querySelector("img, script, a, b")).toBeNull();
	expect(log.querySelector("[href], [src], [onerror]")).toBeNull();
	expect(log.querySelector(".katex")).not.toBeNull();
	expect((window as { __xss?: number }).__xss).toBeUndefined();
});

it("R9：思考默认折叠、可以展开；同一工具调用的多条更新合并为一段步骤摘要", async () => {
	const ws = await readyPanel();
	await sendMessage(ws, "解释一下");
	ws.pushEvent({ kind: "thought", text: "先回忆", messageId: "m1" });
	ws.pushEvent({ kind: "thought", text: "再组织", messageId: "m1" });
	ws.pushEvent({ kind: "tool", toolCallId: "t1", title: "读取 README", toolKind: "read", status: "pending" });
	ws.pushEvent({ kind: "tool", toolCallId: "t1", title: "读取 README", toolKind: "read", status: "completed", input: '{"path":"README.md"}', output: "# 标题" });

	const thought = screen.getByText("先回忆再组织").closest("details")!;
	expect(thought).not.toHaveAttribute("open");
	fireEvent.click(within(thought).getByText("思考过程"));
	expect(thought).toHaveAttribute("open");

	const steps = screen.getAllByText("读取 README");
	expect(steps).toHaveLength(1);
	const step = steps[0].closest("details")!;
	expect(step).not.toHaveAttribute("open");
	expect(step).toHaveTextContent("完成");
	expect(step).toHaveTextContent('{"path":"README.md"}');
	expect(step).toHaveTextContent("# 标题");
});

it("Covers R12：被另一个标签页接管 → 显示「已在别处打开」，不能发送；「在这里继续」重新接上", async () => {
	const ws = await readyPanel();
	ws.push({ method: "chat.evicted", params: { courseId: COURSE } });
	expect(screen.getByText("这门课的对话已在别处（另一个标签页）打开。")).toBeInTheDocument();

	fireEvent.change(input(), { target: { value: "还能发吗" } });
	expect(screen.getByRole("button", { name: "发送" })).toBeDisabled();
	fireEvent.keyDown(input(), { key: "Enter" });
	expect(ws.sent.map((f) => f.method)).not.toContain("chat.send");

	fireEvent.click(screen.getByRole("button", { name: "在这里继续" }));
	await ws.reply("chat.attach", "history", { courseId: COURSE, running: false, events: [] });
	expect(screen.getByRole("button", { name: "发送" })).toBeEnabled();
});

it("R14：「新开对话」发 chat.new，Host 回空历史后对话清空", async () => {
	const ws = await readyPanel([{ kind: "user", text: "旧问题" }, { kind: "message", text: "旧回答" }, { kind: "end", stopReason: "end_turn" }]);
	expect(screen.getByText("旧回答")).toBeInTheDocument();
	fireEvent.click(screen.getByRole("button", { name: "新开对话" }));
	expect(ws.sent.at(-1)).toMatchObject({ method: "chat.new", params: { courseId: COURSE } });
	await ws.reply("chat.new", "history", { courseId: COURSE, running: false, events: [] });
	expect(screen.queryByText("旧回答")).not.toBeInTheDocument();
});

describe("i18n", () => {
	const HERE = dirname(fileURLToPath(import.meta.url));
	const messages = (locale: string) =>
		JSON.parse(readFileSync(resolve(HERE, `../../messages/${locale}.json`), "utf8")).hostChat as Record<string, unknown>;
	const keys = (obj: Record<string, unknown>, prefix = ""): string[] =>
		Object.entries(obj).flatMap(([k, v]) =>
			v && typeof v === "object" ? keys(v as Record<string, unknown>, `${prefix}${k}.`) : [`${prefix}${k}`],
		);

	it("学习搭子头部：传入 onTogglePin 才出现固定/关闭菜单项；pinned 决定文案", () => {
	const toggle = vi.fn();
	const first = renderPanel("zh-CN", { pinned: false, onTogglePin: toggle });
	fireEvent.click(screen.getByRole("button", { name: "更多" }));
	const pin = screen.getByRole("menuitem", { name: "固定到右侧" });
	expect(pin).toBeInTheDocument();
	expect(screen.queryByRole("button", { name: "关闭学习搭子" })).toBeNull();
	fireEvent.click(pin);
	expect(toggle).toHaveBeenCalledTimes(1);
	first.unmount();

	renderPanel("zh-CN", { pinned: true, onTogglePin: toggle, onClose: () => {} });
	fireEvent.click(screen.getByRole("button", { name: "更多" }));
	expect(screen.getByRole("menuitem", { name: "取消固定" })).toBeInTheDocument();
	expect(screen.getByRole("button", { name: "关闭学习搭子" })).toBeInTheDocument();
});

it("hostChat 命名空间 zh-CN 与 en 的键集合一致", () => {
		expect(keys(messages("en")).sort()).toEqual(keys(messages("zh-CN")).sort());
	});

	it("en 下没有硬编码的中文文案（未检测到 Host、可对话两种状态）", async () => {
		checkHost.mockResolvedValueOnce({ state: "noHost" });
		const { container, unmount } = renderPanel("en");
		await screen.findByText(INSTALL);
		expect(container.textContent).not.toMatch(/[一-鿿]/);
		unmount();

		renderPanel("en");
		await attach();
		await screen.findByRole("textbox", { name: "Message to your agent" });
		expect(document.body.textContent).not.toMatch(/[一-鿿]/);
	});
});

describe("学员课程页（page.tsx）", () => {
	const CONTENT = {
		chapters: [{ id: "ch1", title: "第一章" }],
		issues: [
			{ id: "issue-a", title: "单元 A", chapter_id: "ch1", objectives: [{ id: "obj-a", title: "能运行程序" }] },
			{ id: "issue-b", title: "单元 B", chapter_id: "ch1", objectives: [{ id: "obj-b", title: "能讲懂变量" }] },
		],
	};
	const objective = (id: string, mastery: LearningObjectiveState["mastery"]): LearningObjectiveState => ({
		id,
		title: id,
		required: true,
		issueId: null,
		prereqIds: [],
		mastery,
		everMastered: mastery === "mastered",
		locked: false,
		missingPrereqIds: [],
		attemptCount: 1,
		lastAttemptAt: null,
	});
	let evaluated = false;
	/** COURSE_LEARNING_DETAIL 的请求次数：同一查询的两个观察者（页面、阅读组件）由 Apollo 合并为一次 */
	let detailCalls = 0;
	const detail = (): CourseLearningDetail => ({
		courseId: COURSE,
		workspaceId: WORKSPACE,
		title: "Python 入门",
		slug: null,
		run: null,
		revisionNumber: 3,
		staleRevision: false,
		objectives: [objective("obj-a", evaluated ? "mastered" : "developing"), objective("obj-b", "unassessed")],
		nextAction: null,
		progress: { masteredRequired: evaluated ? 1 : 0, totalRequired: 2, complete: false },
	});
	const mocks = [
		{
			request: { query: COURSE_CONTENT, variables: { courseId: COURSE } },
			maxUsageCount: Number.POSITIVE_INFINITY,
			result: {
				data: {
					courseContent: {
						courseId: COURSE,
						title: "Python 入门",
						description: null,
						revisionNumber: 3,
						publishedAt: null,
						content: JSON.stringify(CONTENT),
					},
				},
			},
		},
		{
			request: { query: COURSE_LEARNING_DETAIL, variables: { courseId: COURSE } },
			maxUsageCount: Number.POSITIVE_INFINITY,
			result: () => {
				detailCalls += 1;
				return { data: { courseLearningDetail: detail() } };
			},
		},
	];

	function wide(matches: boolean) {
		vi.spyOn(window, "matchMedia").mockReturnValue({
			matches,
			addEventListener: vi.fn(),
			removeEventListener: vi.fn(),
		} as unknown as MediaQueryList);
	}

	const renderPage = () =>
		render(
			// 不加模拟延迟：每次请求的结果在发出时就定下，「评价后才重取」才测得出来
			<MockedProvider mocks={mocks} mockLinkDefaultOptions={{ delay: 0 }}>
				<CourseLearningPage />
			</MockedProvider>,
		);

	beforeEach(() => {
		evaluated = false;
		detailCalls = 0;
		useParams.mockReturnValue({ id: COURSE });
		useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: USER });
	});

	it("Covers AE3：agent 完成评价后 turn.end 触发重取，目标徽章与掌握数不刷新页面即更新；对话带上正在看的单元", async () => {
		wide(true);
		renderPage();
		const viewer = await screen.findByTestId("course-content-viewer");
		expect(viewer).not.toHaveClass("learning-reader--compact");
		// 恢复后的交互：默认收起，点「问学习搭子」才挂载面板、连本机
		fireEvent.click(await screen.findByRole("button", { name: "问学习搭子" }));
		const ws = await attach();

		fireEvent.click(within(viewer).getByRole("button", { name: /单元 A/ }));
		expect(within(within(viewer).getByTestId("course-content-objective")).getByText("学习中")).toBeInTheDocument();
		await sendMessage(ws, "我写好了，帮我评价");
		expect(ws.sent.findLast((f) => f.method === "chat.send")?.params?.context).toEqual({
			workspaceId: WORKSPACE,
			courseVersion: 3,
			unitId: "issue-a",
			locale: "zh-CN",
		});

		await waitFor(() => expect(detailCalls).toBe(2)); // 首取 + 进入可对话（history）
		evaluated = true; // agent 经学习凭证提交了一次评价
		ws.push({ method: "turn.end", params: { courseId: COURSE, stopReason: "end_turn" } });
		const objectiveA = within(viewer).getByTestId("course-content-objective");
		await waitFor(() => expect(within(objectiveA).getByText("已掌握")).toBeInTheDocument());
		expect(within(screen.getByRole("complementary", { name: "学习进度" })).getByText("1")).toBeInTheDocument();
		expect(detailCalls).toBe(3);
	});

	it("同一标签页换账号：关掉旧连接、开新连接，用新账号重新 hello", async () => {
		wide(true);
		localStorage.setItem(keyOf("user-b"), "bk-b");
		const view = renderPage();
		fireEvent.click(await screen.findByRole("button", { name: "问学习搭子" }));
		const first = await attach();
		useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "user-b" });
		view.rerender(
			<MockedProvider mocks={mocks} mockLinkDefaultOptions={{ delay: 0 }}>
				<CourseLearningPage />
			</MockedProvider>,
		);
		// 换账号后抽屉重新挂载为收起态：再点一次入口才会建新连接
		fireEvent.click(await screen.findByRole("button", { name: "问学习搭子" }));
		await waitFor(() => expect(socketCount()).toBe(2));
		expect(first.readyState).toBe(FakeWebSocket.CLOSED);
		const second = FakeWebSocket.all[1];
		second.push({ method: "status", params: status("paired") });
		await waitFor(() => expect(second.sent.at(-1)).toMatchObject({ method: "hello", params: { userId: "user-b", browserKey: "bk-b" } }));
	});

	it("默认收起：窄视口也有「问学习搭子」入口、不探测 Host；打开后才挂载面板并连本机", async () => {
		wide(false); // 页面不再按视口挂载面板；保留 matchMedia 以证明窄视口也能用
		renderPage();
		const viewer = await screen.findByTestId("course-content-viewer");
		expect(viewer).not.toHaveClass("learning-reader--compact");
		const launcher = await screen.findByRole("button", { name: "问学习搭子" });
		expect(checkHost).not.toHaveBeenCalled();
		expect(screen.queryByRole("complementary", { name: "学习搭子" })).not.toBeInTheDocument();

		fireEvent.click(launcher);
		await waitFor(() => expect(checkHost).toHaveBeenCalled());
		expect(await screen.findByRole("dialog", { name: "学习搭子" })).toBeInTheDocument();
	});
});


describe("历史对话（Session History）", () => {
	const v2 = (state: HostStatus["state"]): HostStatus => ({ ...status(state), protocolVersion: 2 });

	async function readyV2() {
		renderPanel();
		await waitFor(() => expect(socketCount()).toBeGreaterThan(0));
		const ws = FakeWebSocket.all.at(-1)!;
		ws.push({ method: "status", params: v2("paired") });
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("hello"));
		await ws.reply("hello", "status", v2("ready"));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.attach"));
		await ws.reply("chat.attach", "history", { courseId: COURSE, running: false, events: [] });
		await screen.findByRole("textbox", { name: "发给 agent 的消息" });
		return ws;
	}

	it("旧 Host（协议 v1）：不显示「历史对话」入口", async () => {
		await readyPanel();
		expect(screen.queryByRole("button", { name: "历史对话" })).toBeNull();
	});

	it("打开下拉列出历史会话（时间·条数、当前标注且不可点）；点选切换后下拉关闭、对话换新", async () => {
		const ws = await readyV2();
		fireEvent.click(screen.getByRole("button", { name: "历史对话" }));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.sessions"));
		await ws.reply("chat.sessions", "sessions", {
			courseId: COURSE,
			sessions: [
				{ sessionId: "session-1", updatedAt: "2026-10-15T02:00:00Z", messageCount: 4 },
				{ sessionId: "session-2", updatedAt: "2026-10-16T02:00:00Z", messageCount: 2 },
			],
			current: "session-2",
			nextCursor: null,
		});
		const items = await screen.findAllByRole("button", { name: /条消息/ });
		expect(items).toHaveLength(2);
		expect(items[0]).toHaveTextContent("4 条消息");
		expect(items[1]).toHaveTextContent("当前");
		expect(items[1]).toBeDisabled();
		fireEvent.click(items[0]);
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.open"));
		await ws.reply("chat.open", "history", { courseId: COURSE, running: false, events: [{ kind: "user", text: "旧会话的消息" }] });
		await waitFor(() => expect(screen.queryByRole("button", { name: /条消息/ })).toBeNull());
		expect(screen.getByText("旧会话的消息")).toBeInTheDocument();
	});

	it("切换失败（session_unavailable）：下拉内就地提示，对话不变", async () => {
		const ws = await readyV2();
		fireEvent.click(screen.getByRole("button", { name: "历史对话" }));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.sessions"));
		await ws.reply("chat.sessions", "sessions", {
			courseId: COURSE,
			sessions: [{ sessionId: "session-1", updatedAt: null, messageCount: null }],
			current: "session-2",
			nextCursor: null,
		});
		fireEvent.click((await screen.findAllByRole("button", { name: /条消息/ }))[0]);
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.open"));
		await ws.reply("chat.open", "error", { code: "session_unavailable" });
		await screen.findByText(/暂时无法打开/);
		expect(screen.getByRole("textbox", { name: "发给 agent 的消息" })).toBeInTheDocument();
	});

	it("分页：加载更多带游标续页拼接；回合进行中历史行不可点", async () => {
		const ws = await readyV2();
		await sendMessage(ws, "先聊一句");
		fireEvent.click(screen.getByRole("button", { name: "历史对话" }));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.sessions"));
		expect(ws.sent.at(-1)?.params).toEqual({ agent: "omp", courseId: COURSE });
		await ws.reply("chat.sessions", "sessions", {
			courseId: COURSE,
			sessions: [{ sessionId: "session-9", updatedAt: null, messageCount: 3 }],
			current: null,
			nextCursor: "1",
		});
		const first = await screen.findByRole("button", { name: /3 条消息/ });
		expect(first).toBeDisabled();
		fireEvent.click(screen.getByRole("button", { name: "加载更多" }));
		await waitFor(() => expect(ws.sent.at(-1)).toMatchObject({ method: "chat.sessions", params: { courseId: COURSE, cursor: "1" } }));
		await ws.reply("chat.sessions", "sessions", {
			courseId: COURSE,
			sessions: [{ sessionId: "session-8", updatedAt: null, messageCount: 1 }],
			current: null,
			nextCursor: null,
		});
		await screen.findByRole("button", { name: /1 条消息/ });
		expect(screen.getAllByRole("button", { name: /条消息/ })).toHaveLength(2);
	});

	it("点面板与按钮以外的地方关闭；点面板内不关；重新打开重新拉列表", async () => {
		const ws = await readyV2();
		fireEvent.click(screen.getByRole("button", { name: "历史对话" }));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.sessions"));
		await ws.reply("chat.sessions", "sessions", {
			courseId: COURSE,
			sessions: [{ sessionId: "session-1", updatedAt: null, messageCount: 2 }],
			current: null,
			nextCursor: null,
		});
		const row = await screen.findByRole("button", { name: /2 条消息/ });
		// 面板内按下（点行、滚动）：不关闭
		fireEvent.mouseDown(row);
		expect(screen.getByRole("button", { name: /2 条消息/ })).toBeInTheDocument();
		// 面板外按下（例如「新开对话」）：关闭；再打开时重新拉一次列表
		fireEvent.mouseDown(document.body);
		expect(screen.queryByRole("button", { name: /2 条消息/ })).toBeNull();
		fireEvent.click(screen.getByRole("button", { name: "历史对话" }));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.sessions"));
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

	it("history 带 settings 时渲染两个下拉：模型按 provider 分组、思考等级平铺；没有 settings（旧版 Host）时整块不渲染", async () => {
		const bare = renderPanel();
		await attach();
		await screen.findByRole("textbox", { name: "发给 agent 的消息" });
		expect(bare.container.querySelector(".learning-chat__settings")).toBeNull();
		cleanup();
		FakeWebSocket.all = [];

		const view = renderPanel();
		await attach([], false, SETTINGS);
		await screen.findByRole("textbox", { name: "发给 agent 的消息" });
		expect(view.container.querySelector(".learning-chat__settings")).not.toBeNull();
		const model = screen.getByRole("combobox", { name: "模型" }) as HTMLSelectElement;
		const thinking = screen.getByRole("combobox", { name: "思考等级" }) as HTMLSelectElement;
		expect(model.value).toBe("alpha/one");
		expect(thinking.value).toBe("auto");
		expect(within(model).getByRole("group", { name: "alpha" })).toBeInTheDocument();
		expect(within(model).getByRole("group", { name: "beta" })).toBeInTheDocument();
		expect(within(thinking).queryByRole("group")).toBeNull();
	});

	it("改模型：发 chat.set_setting，chat.settings 的回复把两个下拉一起刷新", async () => {
		const ws = await readyPanel([], false, SETTINGS);
		fireEvent.change(screen.getByRole("combobox", { name: "模型" }), { target: { value: "beta/two" } });
		await waitFor(() =>
			expect(ws.sent.at(-1)).toMatchObject({ method: "chat.set_setting", params: { courseId: COURSE, configId: "model", value: "beta/two" } }),
		);
		// OMP 的连带调整：切模型后思考等级回退、可选值收窄 —— 一起到位
		await ws.reply("chat.set_setting", "chat.settings", {
			courseId: COURSE,
			settings: [
				{ ...SETTINGS[0], currentValue: "beta/two" },
				{ ...SETTINGS[1], currentValue: "off", options: [{ value: "off", name: "Off" }] },
			],
		});
		await waitFor(() => expect((screen.getByRole("combobox", { name: "模型" }) as HTMLSelectElement).value).toBe("beta/two"));
		expect((screen.getByRole("combobox", { name: "思考等级" }) as HTMLSelectElement).value).toBe("off");
	});

	it("改设置失败：busy 就地提示（不打扰对话）；旧版 Host 的 unknown_method 提示更新 Host", async () => {
		const ws = await readyPanel([], false, SETTINGS);
		fireEvent.change(screen.getByRole("combobox", { name: "思考等级" }), { target: { value: "off" } });
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.set_setting"));
		await ws.reply("chat.set_setting", "error", { code: "busy" });
		expect(await screen.findByRole("alert")).toHaveTextContent("有一轮回复正在进行，先等它结束再改。");

		fireEvent.change(screen.getByRole("combobox", { name: "思考等级" }), { target: { value: "auto" } });
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.set_setting"));
		await ws.reply("chat.set_setting", "error", { code: "unknown_method" });
		await waitFor(() => expect(screen.getByRole("alert")).toHaveTextContent("这台电脑上的 CGC Host 版本过旧"));
		// 值没被改走：仍是 Host 给的当前值
		expect((screen.getByRole("combobox", { name: "思考等级" }) as HTMLSelectElement).value).toBe("auto");
	});
});

describe("多 agent（#1148）", () => {
	it("装好 ≥2 个 agent：标题行出现选择器，切到另一个 agent 会用新 agent 重新 attach", async () => {
		checkHost.mockResolvedValue({
			state: "detected",
			agents: [
				{ kind: "omp", present: true },
				{ kind: "codex", present: true },
			],
			paired: true,
			capabilities: [],
		});
		renderPanel();
		const ws = await attach([], false, undefined, [
			{ kind: "omp", present: true },
			{ kind: "codex", present: true },
		]);
		await screen.findByRole("textbox", { name: "发给 agent 的消息" });

		fireEvent.click(screen.getByRole("button", { name: /由 OMP 驱动/ }));
		fireEvent.click(screen.getByRole("menuitemradio", { name: "Codex" }));
		await waitFor(() => expect(ws.sent.at(-1)).toMatchObject({ method: "chat.attach", params: { courseId: COURSE, agent: "codex" } }));
	});

	it("只装好 1 个 agent：静态标签 +「添加 agent」，没有选择器", async () => {
		renderPanel();
		await attach();
		await screen.findByRole("textbox", { name: "发给 agent 的消息" });

		expect(screen.getByText("OMP", { selector: ".learning-chat__agent-label" })).toBeInTheDocument();
		expect(screen.queryByRole("menuitemradio")).toBeNull();
		expect(screen.getByRole("button", { name: "添加 agent" })).toBeInTheDocument();
	});

	it("Covers R6：需要登录时只给 ChatGPT 登录（api-key 要密钥收集契约，首期不做）；成功后登录卡消失", async () => {
		window.localStorage.setItem(`cgc-host-agent:${COURSE}`, "codex");
		const agents = [
			{ kind: "omp", present: true },
			{ kind: "codex", present: true },
		];
		checkHost.mockResolvedValue({ state: "detected", agents, paired: true, capabilities: [] });
		renderPanel();
		// attach 就撞上「要求先登录」：Host 回 auth_required（带它播报的登录方式）
		await waitFor(() => expect(socketCount()).toBeGreaterThan(0));
		const ws = FakeWebSocket.all.at(-1)!;
		ws.push({ method: "status", params: status("paired", agents) });
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("hello"));
		await ws.reply("hello", "status", status("ready", agents));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.attach"));
		await ws.reply("chat.attach", "error", {
			code: "auth_required",
			methods: [
				{ id: "api-key", name: "API Key" },
				{ id: "chat-gpt", name: "ChatGPT" },
			],
		});

		const chatgpt = await screen.findByRole("button", { name: "用 ChatGPT 登录" });
		expect(screen.queryByRole("button", { name: "API Key" })).toBeNull();

		fireEvent.click(chatgpt);
		await waitFor(() => expect(ws.sent.at(-1)).toMatchObject({ method: "chat.authenticate", params: { courseId: COURSE, methodId: "chat-gpt" } }));
		await ws.reply("chat.authenticate", "chat.authenticated", { courseId: COURSE, agent: "codex" });
		await waitFor(() => expect(screen.queryByRole("button", { name: "用 ChatGPT 登录" })).toBeNull());
	});

	it("#1155：已装 ChatGPT App 时登录卡优先引导在 App 里登录，网页登录只兜底", async () => {
		window.localStorage.setItem(`cgc-host-agent:${COURSE}`, "codex");
		const agentsWithApp = [
			{ kind: "omp", present: true },
			{ kind: "codex", present: true, sources: [{ source: "chatgpt-app", version: "0.163.0" }] },
		];
		checkHost.mockResolvedValue({ state: "detected", agents: agentsWithApp, paired: true, capabilities: [] });
		renderPanel();
		await waitFor(() => expect(socketCount()).toBeGreaterThan(0));
		const ws = FakeWebSocket.all.at(-1)!;
		ws.push({ method: "status", params: status("paired", agentsWithApp) });
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("hello"));
		await ws.reply("hello", "status", status("ready", agentsWithApp));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.attach"));
		await ws.reply("chat.attach", "error", { code: "auth_required", methods: [{ id: "chat-gpt", name: "ChatGPT" }] });

		expect(await screen.findByText(/在 ChatGPT App 里登录后回到这里/)).toBeInTheDocument();
		const retry = screen.getByRole("button", { name: "我已登录，重试" });
		expect(screen.getByRole("button", { name: "改用浏览器登录" })).toBeInTheDocument();
		expect(screen.queryByRole("button", { name: "用 ChatGPT 登录" })).toBeNull();

		fireEvent.click(retry);
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.attach"));
	});
});

describe("多 agent 的评审修复（M1 / M2 / M4）", () => {
	const both = {
		state: "detected",
		agents: [
			{ kind: "omp", present: true },
			{ kind: "codex", present: true },
		],
		paired: true,
	} as const;

	it("M1：noAgent 并列给出两个 agent 的安装指引（R1），不是只提 Codex", async () => {
		checkHost.mockResolvedValue({
			state: "detected",
			agents: [
				{ kind: "omp", present: false },
				{ kind: "codex", present: false },
			],
			paired: false,
		});
		renderPanel();

		await screen.findByText("还差一个搭子引擎");
		// OMP 卡（默认推荐）与 Codex 卡并列；旧 Host 不支持页面安装时给手动命令
		expect(screen.getByText("OMP")).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "我已装好 OMP，重新检测" })).toBeInTheDocument();
		expect(screen.getByText(/这个 Host 不支持在页面里安装/)).toBeInTheDocument();
		expect(screen.getByText("bun add -g @agentclientprotocol/codex-acp")).toBeInTheDocument();
	});

	it("M2：回合进行中不提供切换（选择器项不可点，与历史 chips 同一规则）", async () => {
		checkHost.mockResolvedValue(both);
		renderPanel();
		await attach([], true, undefined, [
			{ kind: "omp", present: true },
			{ kind: "codex", present: true },
		]); // running = true → canSend 为 false
		await screen.findByRole("textbox", { name: "发给 agent 的消息" });

		fireEvent.click(screen.getByRole("button", { name: /由 OMP 驱动/ }));
		expect(screen.getByRole("menuitemradio", { name: "Codex" })).toBeDisabled();
	});

	it("#1155：OMP 需要登录时给终端登录说明与重试，不出现 ChatGPT 登录按钮", async () => {
		renderPanel(); // DETECTED：只有 OMP 可用，默认就是 OMP
		await waitFor(() => expect(socketCount()).toBeGreaterThan(0));
		const ws = FakeWebSocket.all.at(-1)!;
		ws.push({ method: "status", params: status("paired") });
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("hello"));
		await ws.reply("hello", "status", status("ready"));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.attach"));
		await ws.reply("chat.attach", "error", { code: "auth_required", methods: [{ id: "api-key", name: "API Key" }] });

		expect(await screen.findByText(/OMP 只提供页面外登录/)).toBeInTheDocument();
		expect(screen.queryByRole("button", { name: "用 ChatGPT 登录" })).toBeNull();
		fireEvent.click(screen.getByRole("button", { name: "重试" }));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.attach"));
	});

	it("M4：没有可点的登录方式时给页面外登录说明与重试，不留死卡", async () => {
		window.localStorage.setItem(`cgc-host-agent:${COURSE}`, "codex");
		checkHost.mockResolvedValue(both);
		renderPanel();
		await waitFor(() => expect(socketCount()).toBeGreaterThan(0));
		const ws = FakeWebSocket.all.at(-1)!;
		ws.push({ method: "status", params: status("paired") });
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("hello"));
		await ws.reply("hello", "status", status("ready"));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.attach"));
		await ws.reply("chat.attach", "error", { code: "auth_required", methods: [{ id: "api-key", name: "API Key" }] });

		expect(await screen.findByText(/OMP 只提供页面外登录/)).toBeInTheDocument();
		expect(screen.queryByRole("button", { name: "用 ChatGPT 登录" })).toBeNull();

		fireEvent.click(screen.getByRole("button", { name: "重试" }));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.attach"));
	});
});

describe("一键安装（期 2 / #1149）", () => {
	/** Host 声明了安装能力、OMP 已就绪而 Codex 缺：选择器里的「添加 agent」入口 */
	const CAN_INSTALL = {
		state: "detected",
		agents: [
			{ kind: "omp", present: true },
			{ kind: "codex", present: false },
		],
		paired: true,
		capabilities: ["agent.install"],
	} as const;
	const ompOnly = [
		{ kind: "omp", present: true },
		{ kind: "codex", present: false },
	];

	it("没装引擎但检测到 ChatGPT App：Codex 卡置顶说明约 2MB，OMP 卡并列", async () => {
		const agents = [
			{ kind: "omp", present: false },
			{ kind: "codex", present: false, sources: [{ source: "chatgpt-app", version: "0.163.0" }] },
		];
		checkHost.mockResolvedValue({ state: "detected", agents, paired: false, capabilities: ["agent.install"] });
		renderPanel();
		// 声明了安装能力：即使一个 agent 都没有也开连接，装完的 entry 要回推 status
		await waitFor(() => expect(socketCount()).toBeGreaterThan(0));
		const ws = FakeWebSocket.all.at(-1)!;
		ws.push({ method: "status", params: status("paired", agents) });
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("hello"));
		await ws.reply("hello", "status", status("ready", agents));

		await screen.findByText("还差一个搭子引擎");
		expect(screen.getByText(/检测到你已安装 ChatGPT App 0\.163\.0/)).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "安装 Codex 支持（约 2MB）" })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "我已装好 OMP，重新检测" })).toBeInTheDocument();
	});

	it("检测到可复用来源：提示约 2MB 并显示来源/版本；装完（reused）显示已复用", async () => {
		const agentsWithApp = [
			{ kind: "omp", present: true },
			{ kind: "codex", present: false, sources: [{ source: "chatgpt-app", version: "0.163.0" }] },
		];
		checkHost.mockResolvedValue({ state: "detected", agents: agentsWithApp, paired: true, capabilities: ["agent.install"] });
		renderPanel();
		const ws = await attach([], false, undefined, agentsWithApp);

		fireEvent.click(screen.getByRole("button", { name: "添加 agent" }));
		expect(await screen.findByText(/安装只需约 2MB 适配器/)).toBeInTheDocument();
		expect(screen.getByText(/已检测到：ChatGPT App 0\.163\.0/)).toBeInTheDocument();

		fireEvent.click(await screen.findByRole("button", { name: "安装 Codex 支持" }));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("agent.install"));
		await ws.reply("agent.install", "agent.install.started", { started: true });
		act(() => ws.push({ method: "agent.done", params: { kind: "codex", ok: true, version: "2.2.2", reused: true } }));
		act(() =>
			ws.push({
				method: "status",
				params: status("ready", [
					{ kind: "omp", present: true },
					{ kind: "codex", present: true, sources: [{ source: "chatgpt-app", version: "0.163.0" }] },
				]),
			}),
		);
		expect(screen.getByText(/已复用你已有的 Codex/)).toBeInTheDocument();
	});

	it("#1155：没装 ChatGPT App 时先引导安装 App（默认路径），再给全量安装兜底", async () => {
		checkHost.mockResolvedValue(CAN_INSTALL);
		renderPanel();
		await attach([], false, undefined, ompOnly);

		fireEvent.click(screen.getByRole("button", { name: "添加 agent" }));
		expect(await screen.findByText(/推荐先安装 ChatGPT App/)).toBeInTheDocument();
		const download = screen.getByRole("link", { name: "下载 ChatGPT App" });
		expect(download).toHaveAttribute("href", "https://chatgpt.com/download");
		// 全量安装入口仍在（兜底），不是唯一路径
		expect(screen.getByRole("button", { name: "安装 Codex 支持" })).toBeInTheDocument();
	});

	it("没有 agent + 声明能力：未配对先给「连接」；配对后才有安装按钮，点击发请求、装完入口消失", async () => {
		window.localStorage.clear(); // 隔离前序用例留下的浏览器密钥（有它就会先走 hello，停在 checking）
		checkHost.mockResolvedValue({
			state: "detected",
			agents: [
				{ kind: "omp", present: false },
				{ kind: "codex", present: false },
			],
			paired: false,
			capabilities: ["agent.install"],
		});
		renderPanel();
		await waitFor(() => expect(socketCount()).toBeGreaterThan(0));
		const ws = FakeWebSocket.all.at(-1)!;

		// 未配对：安装与 chat.* 同一道授权，先给「连接」
		act(() => ws.push({ method: "status", params: status("unpaired", [{ kind: "omp", present: false }, { kind: "codex", present: false }]) }));
		expect(await screen.findByRole("button", { name: "连接" })).toBeInTheDocument();
		expect(screen.queryByRole("button", { name: "安装 Codex 支持" })).toBeNull();

		// 配对完成：没有 agent → 安装入口
		act(() => ws.push({ method: "status", params: status("ready", [{ kind: "omp", present: false }, { kind: "codex", present: false }]) }));
		fireEvent.click(await screen.findByRole("button", { name: "安装完整 Codex（约 337MB）" }));
		await waitFor(() => expect(ws.sent.at(-1)).toMatchObject({ method: "agent.install", params: { kind: "codex" } }));
		await ws.reply("agent.install", "agent.install.started", { started: true });
		act(() => ws.push({ method: "agent.install.progress", params: { kind: "codex", phase: "installing" } }));
		expect(await screen.findByRole("button", { name: "正在准备搭子…" })).toBeDisabled();

		// 装完：Host 推 status（codex 已 present），入口消失
		act(() =>
			ws.push({
				method: "status",
				params: status("ready", [
					{ kind: "omp", present: false },
					{ kind: "codex", present: true },
				]),
			}),
		);
		act(() => ws.push({ method: "agent.done", params: { kind: "codex", ok: true, version: "2.2.2" } }));
		await waitFor(() => expect(screen.queryByRole("button", { name: /安装完整 Codex|正在准备搭子/ })).toBeNull());
	});

	it("安装失败：就地给出可重试的提示，按钮恢复可点", async () => {
		checkHost.mockResolvedValue(CAN_INSTALL);
		renderPanel();
		const ws = await attach([], false, undefined, ompOnly);

		fireEvent.click(screen.getByRole("button", { name: "添加 agent" }));
		fireEvent.click(await screen.findByRole("button", { name: "安装 Codex 支持" }));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("agent.install"));
		await ws.reply("agent.install", "agent.install.started", { started: true });
		act(() => ws.push({ method: "agent.done", params: { kind: "codex", ok: false, code: "install_failed" } }));

		expect(await screen.findByText("安装没有完成，检查网络后再试一次。")).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "安装 Codex 支持" })).toBeEnabled();
	});

	it.each([
		["version_mismatch", "装上的版本和预期不一致，请再试一次。"],
		["timeout", "安装超时了，检查网络后再试一次。"],
	] as const)("安装失败按 code 给下一步（%s）", async (code, text) => {
		checkHost.mockResolvedValue(CAN_INSTALL);
		renderPanel();
		const ws = await attach([], false, undefined, ompOnly);

		fireEvent.click(screen.getByRole("button", { name: "添加 agent" }));
		fireEvent.click(await screen.findByRole("button", { name: "安装 Codex 支持" }));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("agent.install"));
		await ws.reply("agent.install", "agent.install.started", { started: true });
		act(() => ws.push({ method: "agent.done", params: { kind: "codex", ok: false, code } }));

		expect(await screen.findByText(text)).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "安装 Codex 支持" })).toBeEnabled();
	});

	it.each([
		["busy", "另一个页面正在安装，稍等一下再试。"],
		["unsupported", "这个 Host 不支持在页面里安装，请用下面的手动命令。"],
	] as const)("安装请求被拒按 code 给下一步（%s）", async (code, text) => {
		checkHost.mockResolvedValue(CAN_INSTALL);
		renderPanel();
		const ws = await attach([], false, undefined, ompOnly);

		fireEvent.click(screen.getByRole("button", { name: "添加 agent" }));
		fireEvent.click(await screen.findByRole("button", { name: "安装 Codex 支持" }));
		await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("agent.install"));
		await ws.reply("agent.install", "error", { code });

		expect(await screen.findByText(text)).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "安装 Codex 支持" })).toBeEnabled();
	});

	it("旧 Host 没声明能力（0.2.0）：即使缺 Codex 也只给手动命令，不出现一键安装按钮", async () => {
		renderPanel();
		await attach([], false, undefined, ompOnly);
		fireEvent.click(screen.getByRole("button", { name: "添加 agent" }));
		expect(await screen.findByRole("button", { name: "重新检测" })).toBeInTheDocument();
		expect(screen.queryByRole("button", { name: "安装 Codex 支持" })).toBeNull();
		expect(screen.getByText("bun add -g @agentclientprotocol/codex-acp")).toBeInTheDocument();
	});
});
