import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import AccountConnectionsPage from "./page";

/**
 * U5 用户级「连接与授权」页（KTD3）：无工作台成员资格也可达的凭证管理面
 * （U4 同意页「可随时在 CGC 账号设置中撤销此授权」的落点）。
 *
 * 数据流与组件与工作台 MCP 页同源（useMcpCredentials + 两个列表组件），
 * 本测试只覆盖本页特有行为：登录门、两列表渲染、空态、撤销与错误态。
 */

const { router } = vi.hoisted(() => ({
	router: { push: vi.fn(), replace: vi.fn() },
}));
const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));
const { fetchMyMcpTokens } = vi.hoisted(() => ({ fetchMyMcpTokens: vi.fn() }));
const { fetchMyOauthAuthorizations } = vi.hoisted(() => ({
	fetchMyOauthAuthorizations: vi.fn(),
}));
const { revokeMcpToken } = vi.hoisted(() => ({ revokeMcpToken: vi.fn() }));
const { revokeOauthAuthorization } = vi.hoisted(() => ({
	revokeOauthAuthorization: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useRouter: () => router,
	usePathname: () => "/settings/account/connections",
}));

vi.mock("@/lib/use-authed", () => ({ useAuthed }));

vi.mock("@/lib/mcp", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return {
		...mod,
		fetchMyMcpTokens,
		fetchMyOauthAuthorizations,
		revokeMcpToken,
		revokeOauthAuthorization,
	};
});

const TOKENS = [
	{
		id: "tok_1",
		name: "我的 Mac",
		lastUsedAt: "2026-08-08T10:00:00Z",
		revokedAt: null,
		insertedAt: "2026-08-01T09:00:00Z",
		status: "active" as const,
	},
];

const AUTHORIZATIONS = [
	{
		clientId: "cli_opencode",
		clientName: "CGC 学习空间",
		scope: "mcp",
		grantedAt: "2026-09-15T10:00:00Z",
		lastUsedAt: null,
		status: "active" as const,
	},
];

beforeEach(() => {
	vi.clearAllMocks();
	useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "u_1" });
	fetchMyMcpTokens.mockResolvedValue(TOKENS);
	fetchMyOauthAuthorizations.mockResolvedValue(AUTHORIZATIONS);
	revokeMcpToken.mockResolvedValue({
		...TOKENS[0],
		revokedAt: "2026-09-15T12:00:00Z",
		status: "revoked" as const,
	});
	revokeOauthAuthorization.mockResolvedValue({
		...AUTHORIZATIONS[0],
		status: "revoked" as const,
	});
});

afterEach(cleanup);

describe("/settings/account/connections 用户级连接与授权页", () => {
	it("渲染两类凭证：连接令牌列表与已授权应用列表（KTD3 同界面）", async () => {
		render(<AccountConnectionsPage />);

		const tokens = await screen.findByTestId("mcp-token-list");
		expect(within(tokens).getByText("我的 Mac")).toBeInTheDocument();

		const apps = screen.getByTestId("authorized-apps");
		expect(within(apps).getByText("CGC 学习空间")).toBeInTheDocument();
		expect(within(apps).getByText("有效")).toBeInTheDocument();
	});

	it("撤销授权：两步确认 → revokeOauthAuthorization(clientId) → 行移出列表", async () => {
		render(<AccountConnectionsPage />);

		const apps = await screen.findByTestId("authorized-apps");
		fireEvent.click(within(apps).getByRole("button", { name: "撤销" }));
		// 未确认前不调用
		expect(revokeOauthAuthorization).not.toHaveBeenCalled();

		fireEvent.click(within(apps).getByRole("button", { name: "确认撤销" }));

		await waitFor(() => {
			expect(revokeOauthAuthorization).toHaveBeenCalledWith("cli_opencode");
		});
		await waitFor(() => {
			expect(screen.queryByText("CGC 学习空间")).not.toBeInTheDocument();
		});
	});

	it("撤销连接令牌：两步确认 → revokeMcpToken(id) → 行变为已撤销", async () => {
		render(<AccountConnectionsPage />);

		const tokens = await screen.findByTestId("mcp-token-list");
		fireEvent.click(within(tokens).getByRole("button", { name: "撤销" }));
		fireEvent.click(within(tokens).getByRole("button", { name: "确认撤销" }));

		await waitFor(() => {
			expect(revokeMcpToken).toHaveBeenCalledWith("tok_1");
		});
		expect(await within(tokens).findByText("已撤销")).toBeInTheDocument();
	});

	it("空态：两类凭证都为空时各显空提示", async () => {
		fetchMyMcpTokens.mockResolvedValue([]);
		fetchMyOauthAuthorizations.mockResolvedValue([]);
		render(<AccountConnectionsPage />);

		expect(await screen.findByText("还没有连接 token")).toBeInTheDocument();
		expect(screen.getByTestId("authorized-apps-empty")).toHaveTextContent(
			"还没有已授权应用",
		);
	});

	it("错误路径：撤销失败内联报错且保留该行（不静默吞）", async () => {
		revokeOauthAuthorization.mockRejectedValue(
			new Error("errors.revokeOauthAuthorizationFailed"),
		);
		render(<AccountConnectionsPage />);

		const apps = await screen.findByTestId("authorized-apps");
		fireEvent.click(within(apps).getByRole("button", { name: "撤销" }));
		fireEvent.click(within(apps).getByRole("button", { name: "确认撤销" }));

		expect(await screen.findByRole("alert")).toHaveTextContent(
			"撤销失败，请重试。",
		);
		expect(screen.getByText("CGC 学习空间")).toBeInTheDocument();
	});

	it("加载失败：内联报错 + 重试重拉两源", async () => {
		fetchMyOauthAuthorizations.mockRejectedValueOnce(new Error("network down"));
		render(<AccountConnectionsPage />);

		expect(await screen.findByRole("alert")).toBeInTheDocument();
		expect(screen.queryByTestId("authorized-apps")).not.toBeInTheDocument();

		fireEvent.click(screen.getByRole("button", { name: "重试" }));
		expect(await screen.findByTestId("authorized-apps")).toBeInTheDocument();
	});

	it("未确认登录态：不拉取数据（首帧不误踢，等 useAuthed confirm）", async () => {
		useAuthed.mockReturnValue({ authed: false, confirmed: false, userId: null });
		render(<AccountConnectionsPage />);

		expect(screen.queryByTestId("mcp-token-list")).not.toBeInTheDocument();
		expect(fetchMyMcpTokens).not.toHaveBeenCalled();
		expect(fetchMyOauthAuthorizations).not.toHaveBeenCalled();
		expect(router.replace).not.toHaveBeenCalled();
	});

	it("已确认未登录：跳登录页并带回跳参数", async () => {
		useAuthed.mockReturnValue({ authed: false, confirmed: true, userId: null });
		render(<AccountConnectionsPage />);

		await waitFor(() => {
			expect(router.replace).toHaveBeenCalledWith(
				`/login?next=${encodeURIComponent("/settings/account/connections")}`,
			);
		});
		expect(fetchMyMcpTokens).not.toHaveBeenCalled();
	});
});
