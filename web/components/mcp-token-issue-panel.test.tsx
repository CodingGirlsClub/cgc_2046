/**
 * McpTokenIssuePanel 复制生命周期覆盖（code-review finding #5）：
 * - 「已复制」2s 复位定时器（mcp-token-issue-panel.tsx:104），连续复制重置计时；
 * - 卸载时 clearTimeout 清理（:49-53，向导完成换树卸载本组件）；
 * - copyText 失败的 copyFreshFailed role=alert 分支（:124）。
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { act, cleanup, fireEvent, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import McpTokenIssuePanel from "./mcp-token-issue-panel";

// vi.mock 工厂会被提升（hoist），mock 函数必须用 vi.hoisted 定义
const { copyText } = vi.hoisted(() => ({ copyText: vi.fn() }));
const { issueMcpToken } = vi.hoisted(() => ({ issueMcpToken: vi.fn() }));

vi.mock("@/lib/clipboard", () => ({ copyText }));
vi.mock("@/lib/mcp", () => ({ issueMcpToken }));

const ISSUED = {
	token: {
		id: "tok_new",
		name: "我的 Mac",
		lastUsedAt: null,
		revokedAt: null,
		insertedAt: "2026-08-22T00:00:00.000Z",
		status: "active",
	},
	plainToken: "cgc-mcp-plain-token-once",
};

beforeEach(() => {
	vi.clearAllMocks();
	copyText.mockResolvedValue(true);
	issueMcpToken.mockResolvedValue(ISSUED);
});

afterEach(cleanup);

/** 走通签发表单，直到一次性明文横幅出现（含「复制」按钮） */
async function issueToken() {
	const utils = render(<McpTokenIssuePanel />);
	fireEvent.click(screen.getByRole("button", { name: "签发新 token" }));
	fireEvent.change(screen.getByPlaceholderText("如：我的 Mac"), {
		target: { value: "我的 Mac" },
	});
	fireEvent.click(screen.getByRole("button", { name: "签发" }));
	await screen.findByRole("button", { name: "复制" });
	return utils;
}

/** copyText resolve 是微任务，fake timer 不阻塞——flush 即可 */
const flushMicrotasks = () =>
	act(async () => {
		await Promise.resolve();
	});

describe("McpTokenIssuePanel 明文复制", () => {
	it("签发后点「复制」：copyText 收到明文，按钮变「已复制」", async () => {
		await issueToken();

		fireEvent.click(screen.getByRole("button", { name: "复制" }));

		expect(copyText).toHaveBeenCalledWith("cgc-mcp-plain-token-once");
		expect(
			await screen.findByRole("button", { name: "已复制" }),
		).toBeInTheDocument();
	});

	it("「已复制」2s 后自动复位为「复制」", async () => {
		await issueToken();
		vi.useFakeTimers();
		try {
			fireEvent.click(screen.getByRole("button", { name: "复制" }));
			await flushMicrotasks();
			expect(
				screen.getByRole("button", { name: "已复制" }),
			).toBeInTheDocument();

			act(() => {
				vi.advanceTimersByTime(2000);
			});
			expect(
				screen.getByRole("button", { name: "复制" }),
			).toBeInTheDocument();
		} finally {
			vi.useRealTimers();
		}
	});

	it("2s 窗口内再次复制：重置计时（只保留一个 pending timer）", async () => {
		await issueToken();
		vi.useFakeTimers();
		try {
			fireEvent.click(screen.getByRole("button", { name: "复制" }));
			await flushMicrotasks();
			act(() => {
				vi.advanceTimersByTime(1500);
			});

			fireEvent.click(screen.getByRole("button", { name: "已复制" }));
			await flushMicrotasks();
			expect(copyText).toHaveBeenCalledTimes(2);

			// 距第二次点击 1999ms：若计时未重置，首个定时器已于累计 2000ms 处复位
			act(() => {
				vi.advanceTimersByTime(1999);
			});
			expect(
				screen.getByRole("button", { name: "已复制" }),
			).toBeInTheDocument();

			// 距第二次点击满 2000ms → 复位
			act(() => {
				vi.advanceTimersByTime(1);
			});
			expect(
				screen.getByRole("button", { name: "复制" }),
			).toBeInTheDocument();
		} finally {
			vi.useRealTimers();
		}
	});

	it("2s 窗口内卸载：clearTimeout 清理 pending 定时器，无 setState-after-unmount 警告", async () => {
		const { unmount } = await issueToken();
		vi.useFakeTimers();
		const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});
		try {
			const baseline = vi.getTimerCount();
			fireEvent.click(screen.getByRole("button", { name: "复制" }));
			await flushMicrotasks();
			expect(
				screen.getByRole("button", { name: "已复制" }),
			).toBeInTheDocument();
			expect(vi.getTimerCount()).toBe(baseline + 1);

			// 向导完成态换树卸载本组件：清理 effect 应摘掉 pending 定时器
			unmount();
			expect(vi.getTimerCount()).toBe(baseline);
			act(() => {
				vi.advanceTimersByTime(5000);
			});

			const unmountWarnings = errorSpy.mock.calls.filter((args) =>
				args.some(
					(arg) =>
						typeof arg === "string" && /unmounted|state update/.test(arg),
				),
			);
			expect(unmountWarnings).toEqual([]);
		} finally {
			errorSpy.mockRestore();
			vi.useRealTimers();
		}
	});

	it("复制失败（copyText resolve false）：内联 role=alert「复制失败」，不进「已复制」态", async () => {
		copyText.mockResolvedValue(false);
		await issueToken();

		fireEvent.click(screen.getByRole("button", { name: "复制" }));

		const alert = await screen.findByRole("alert");
		expect(alert).toHaveTextContent("复制失败，请手动选择上方 token 文本复制。");
		expect(
			screen.getByRole("button", { name: "复制" }),
		).toBeInTheDocument();
	});
});
