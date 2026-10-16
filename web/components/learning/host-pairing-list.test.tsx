import { afterEach, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import { formatDateTime } from "@/lib/format";
import type { McpTokenItem } from "@/lib/mcp";
import HostPairingList from "./host-pairing-list";

/**
 * U9「已配对的电脑」（R5、R30）。lib/mcp 整体 mock；撤销本机这台之后的 pair.forget 与回到未配对
 * 由 use-host-pairing.test.tsx 的 AE10 连同真实 hook 一起覆盖。
 */

const { fetchMyMcpTokens, revokeMcpToken } = vi.hoisted(() => ({
	fetchMyMcpTokens: vi.fn(),
	revokeMcpToken: vi.fn(),
}));
vi.mock("@/lib/mcp", () => ({ fetchMyMcpTokens, revokeMcpToken }));

function token(over: Partial<McpTokenItem>): McpTokenItem {
	return {
		id: "tok_this",
		name: "Ada 的 MacBook",
		kind: "LEARNING_HOST",
		lastUsedAt: "2026-10-14T08:00:00Z",
		revokedAt: null,
		insertedAt: "2026-10-01T00:00:00Z",
		status: "active",
		...over,
	};
}

const THIS = token({});
const OTHER = token({ id: "tok_other", name: "办公室 iMac", lastUsedAt: "2026-10-10T02:30:00Z" });

afterEach(() => {
	cleanup();
	vi.resetAllMocks();
});

it("只列有效的学习凭证（终端 token、已撤销与闲置过期的不出现），标出本机这台并显示最近使用时间", async () => {
	fetchMyMcpTokens.mockResolvedValue([
		THIS,
		OTHER,
		token({ id: "tok_terminal", name: "终端里的 OMP", kind: "TERMINAL" }),
		token({ id: "tok_revoked", name: "旧笔记本", status: "revoked", revokedAt: "2026-10-02T00:00:00Z" }),
		token({ id: "tok_idle", name: "寒假前的电脑", status: "idle_expired" }),
	]);
	render(<HostPairingList currentTokenId="tok_this" onRevokeCurrent={vi.fn()} />);

	const [first, second, ...rest] = await screen.findAllByRole("listitem");
	expect(rest).toEqual([]);
	expect(within(first).getByText("Ada 的 MacBook")).toBeInTheDocument();
	expect(within(first).getByText("本机这台")).toBeInTheDocument();
	expect(within(first).getByText(`最近使用：${formatDateTime(THIS.lastUsedAt)}`)).toBeInTheDocument();
	expect(within(second).getByText("办公室 iMac")).toBeInTheDocument();
	expect(within(second).queryByText("本机这台")).toBeNull();
	expect(within(second).getByText(`最近使用：${formatDateTime(OTHER.lastUsedAt)}`)).toBeInTheDocument();
});

it("撤销需二次确认：确认按钮获得焦点（键盘可完成）；取消不撤销；确认后撤销、移出列表并提示；不是本机这台不调 onRevokeCurrent", async () => {
	fetchMyMcpTokens.mockResolvedValue([THIS, OTHER]);
	revokeMcpToken.mockResolvedValue({ ...OTHER, status: "revoked" });
	const onRevokeCurrent = vi.fn();
	render(<HostPairingList currentTokenId="tok_this" onRevokeCurrent={onRevokeCurrent} />);

	fireEvent.click(await screen.findByRole("button", { name: "撤销「办公室 iMac」" }));
	expect(screen.getByRole("button", { name: "确认撤销「办公室 iMac」" })).toHaveFocus();
	fireEvent.click(screen.getByRole("button", { name: "取消" }));
	expect(revokeMcpToken).not.toHaveBeenCalled();

	fireEvent.click(screen.getByRole("button", { name: "撤销「办公室 iMac」" }));
	fireEvent.click(screen.getByRole("button", { name: "确认撤销「办公室 iMac」" }));
	await waitFor(() => expect(screen.getByRole("status")).toHaveTextContent("已撤销「办公室 iMac」"));
	expect(revokeMcpToken).toHaveBeenCalledWith("tok_other");
	expect(screen.queryByText("办公室 iMac")).toBeNull();
	expect(onRevokeCurrent).not.toHaveBeenCalled();
});

it("撤销失败 → 提示失败，列表保持不变", async () => {
	fetchMyMcpTokens.mockResolvedValue([OTHER]);
	revokeMcpToken.mockRejectedValue(new Error("network"));
	render(<HostPairingList currentTokenId={null} onRevokeCurrent={vi.fn()} />);

	fireEvent.click(await screen.findByRole("button", { name: "撤销「办公室 iMac」" }));
	fireEvent.click(screen.getByRole("button", { name: "确认撤销「办公室 iMac」" }));
	await waitFor(() => expect(screen.getByRole("status")).toHaveTextContent("撤销失败，请稍后重试"));
	expect(screen.getByText("办公室 iMac")).toBeInTheDocument();
});

it("加载中 → 加载失败可重试 → 重试后没有学习凭证显示空状态", async () => {
	fetchMyMcpTokens
		.mockRejectedValueOnce(new Error("network"))
		.mockResolvedValueOnce([token({ kind: "TERMINAL" })]);
	render(<HostPairingList currentTokenId={null} onRevokeCurrent={vi.fn()} />);
	expect(screen.getByText("正在加载已配对的电脑…")).toBeInTheDocument();

	expect(await screen.findByRole("alert")).toHaveTextContent("已配对的电脑加载失败");
	fireEvent.click(screen.getByRole("button", { name: "重试" }));
	expect(await screen.findByText("还没有已配对的电脑")).toBeInTheDocument();
	expect(fetchMyMcpTokens).toHaveBeenCalledTimes(2);
});

it("本机的配对变了（新配对完成）→ 重拉列表，新签发的那枚标为本机这台", async () => {
	fetchMyMcpTokens.mockResolvedValueOnce([OTHER]).mockResolvedValueOnce([THIS, OTHER]);
	const { rerender } = render(<HostPairingList currentTokenId={null} onRevokeCurrent={vi.fn()} />);
	await screen.findByText("办公室 iMac");

	rerender(<HostPairingList currentTokenId="tok_this" onRevokeCurrent={vi.fn()} />);
	await waitFor(() => expect(screen.getAllByRole("listitem")).toHaveLength(2));
	const [first] = screen.getAllByRole("listitem");
	expect(within(first).getByText("Ada 的 MacBook")).toBeInTheDocument();
	expect(within(first).getByText("本机这台")).toBeInTheDocument();
});
