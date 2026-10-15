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
const DETECTED: HostConnection = { state: "detected", ompPresent: true, paired: true };
const keyOf = (userId: string) => `cgc:host-browser-key:${userId}`;

const status = (state: HostStatus["state"]): HostStatus => ({
	state,
	pairedUserId: state === "unpaired" ? null : USER,
	pairedDisplayName: state === "unpaired" ? null : "学员甲",
	deviceName: "Ada 的 MacBook",
	tokenId: state === "unpaired" ? null : "tok_this",
	ompPresent: true,
	version: "0.1.0",
	protocolVersion: 1,
});

function renderPanel(locale: "zh-CN" | "en" = "zh-CN") {
	return render(
		<MockedProvider mocks={[]}>
			<HostChatPanel courseId={COURSE} userId={USER} locale={locale} workspaceId={WORKSPACE} courseVersion={3} unitId={null} />
		</MockedProvider>,
		{ locale },
	);
}

const socketCount = () => FakeWebSocket.all.length;

/** 已存浏览器密钥：连接 → hello → ready → chat.attach → history；返回这条连接 */
async function attach(events: object[] = [], running = false) {
	await waitFor(() => expect(socketCount()).toBeGreaterThan(0));
	const ws = FakeWebSocket.all.at(-1)!;
	ws.push({ method: "status", params: status("paired") });
	await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("hello"));
	await ws.reply("hello", "status", status("ready"));
	await waitFor(() => expect(ws.sent.at(-1)?.method).toBe("chat.attach"));
	await ws.reply("chat.attach", "history", { courseId: COURSE, running, events });
	return ws;
}

async function readyPanel(events: object[] = [], running = false) {
	renderPanel();
	const ws = await attach(events, running);
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
		expect(screen.getByText("请在电脑上弹出的确认框里选择允许。")).toBeInTheDocument();
	});

	it.each<[string, HostConnection, RegExp | string]>([
		["Covers AE12：Host 需要更新", { state: "staleHost" }, INSTALL],
		["浏览器阻止访问本机", { state: "blocked" }, "浏览器阻止了本页访问本机。"],
		["不受支持的浏览器", { state: "unsupported", reason: "browser" }, "对话栏目前只支持 macOS 上的 Chrome。"],
		["电脑上找不到 OMP", { state: "detected", ompPresent: false, paired: false }, "这台电脑上找不到 OMP。"],
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
		expect(await screen.findByText(INSTALL)).toBeInTheDocument();
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
	fireEvent.click(screen.getByRole("button", { name: "已配对的电脑" }));
	fireEvent.click(await screen.findByRole("button", { name: "撤销「Ada 的 MacBook」" }));
	fireEvent.click(screen.getByRole("button", { name: "确认撤销「Ada 的 MacBook」" }));
	await waitFor(() => expect(ws.sent.at(-1)).toEqual({ method: "pair.forget" }));

	ws.push({ method: "status", params: status("unpaired") });
	expect(await screen.findByRole("button", { name: "连接" })).toBeInTheDocument();
	expect(screen.queryByRole("textbox", { name: "发给 agent 的消息" })).not.toBeInTheDocument();
});

it("KTD9：进入可对话状态不自动发消息；R15：显示这门课的工作目录", async () => {
	const ws = await readyPanel();
	expect(ws.sent.map((f) => f.method)).toEqual(["hello", "chat.attach"]);
	expect(screen.getByText(`~/CGC/${USER}/${COURSE}`, { exact: false })).toBeInTheDocument();
	expect(screen.getByText("向你的 agent 提问吧。它知道你正在学这门课，以及你正在看的单元。")).toBeInTheDocument();
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
		expect(ws.sent.at(-1)?.params).toEqual({ courseId: COURSE, cardId: "card-p", optionId: "reject_once" });
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
			courseId: COURSE,
			cardId: "card-q",
			action: "accept",
			content: { q0: "乙", q0__other: "补充" },
		});

		await ws.reply("card.answer", "error", { code: "bad_request" });
		fireEvent.click(within(card).getByRole("button", { name: "跳过" }));
		await waitFor(() => expect(ws.sent.at(-1)?.params).toEqual({ courseId: COURSE, cardId: "card-q", action: "decline" }));
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
		await waitFor(() => expect(viewer).toHaveClass("learning-reader--compact"));
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
		const first = await attach();
		useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "user-b" });
		view.rerender(
			<MockedProvider mocks={mocks} mockLinkDefaultOptions={{ delay: 0 }}>
				<CourseLearningPage />
			</MockedProvider>,
		);
		await waitFor(() => expect(socketCount()).toBe(2));
		expect(first.readyState).toBe(FakeWebSocket.CLOSED);
		const second = FakeWebSocket.all[1];
		second.push({ method: "status", params: status("paired") });
		await waitFor(() => expect(second.sent.at(-1)).toMatchObject({ method: "hello", params: { userId: "user-b", browserKey: "bk-b" } }));
	});

	it("视口窄于 1280px：不挂载对话栏、不连本机，阅读组件保持默认布局", async () => {
		wide(false);
		renderPage();
		const viewer = await screen.findByTestId("course-content-viewer");
		expect(viewer).not.toHaveClass("learning-reader--compact");
		expect(checkHost).not.toHaveBeenCalled();
		expect(screen.queryByRole("complementary", { name: "本机 agent" })).not.toBeInTheDocument();
	});
});
