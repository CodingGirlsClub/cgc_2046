import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import AgentsMcpPage from "./page";

const { router } = vi.hoisted(() => ({
	router: { push: vi.fn(), replace: vi.fn() },
}));
const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));
const { params } = vi.hoisted(() => ({
	params: { value: { slug: "cgc-academy" } },
}));
const { fetchMyWorkspaces } = vi.hoisted(() => ({
	fetchMyWorkspaces: vi.fn(),
}));
const { fetchMyMcpTokens } = vi.hoisted(() => ({ fetchMyMcpTokens: vi.fn() }));
const { issueMcpToken } = vi.hoisted(() => ({ issueMcpToken: vi.fn() }));
const { revokeMcpToken } = vi.hoisted(() => ({ revokeMcpToken: vi.fn() }));

vi.mock("next/navigation", () => ({
	useRouter: () => router,
	useParams: () => params.value,
	usePathname: () =>
		`/w/${params.value.slug}/settings/integrations/agents/mcp`,
}));

vi.mock("@/lib/use-authed", () => ({ useAuthed }));

vi.mock("@/lib/workspaces", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchMyWorkspaces };
});

vi.mock("@/lib/mcp", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchMyMcpTokens, issueMcpToken, revokeMcpToken };
});

const WORKSPACES = [
	{
		id: "ws_02",
		slug: "cgc-academy",
		name: "CGC 线上学院",
		joinPolicy: "request" as const,
		sponsorshipEnabled: true,
		myRoleNames: [],
		roles: [],
		myAbilities: ["view_workspace", "access_invite_only"],
		membershipStatus: "active" as const,
	},
];

const TEST_TOKENS = [
	{
		id: "tok_1",
		name: "我的 Mac",
		lastUsedAt: "2026-08-08T10:00:00Z",
		revokedAt: null,
		insertedAt: "2026-08-01T09:00:00Z",
		status: "active" as const,
	},
	{
		id: "tok_2",
		name: "公司服务器",
		lastUsedAt: null,
		revokedAt: "2026-08-05T12:00:00Z",
		insertedAt: "2026-07-20T09:00:00Z",
		status: "revoked" as const,
	},
];

beforeEach(() => {
	vi.clearAllMocks();
	useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "u_1" });
	params.value = { slug: "cgc-academy" };
	fetchMyWorkspaces.mockResolvedValue(WORKSPACES);
	fetchMyMcpTokens.mockResolvedValue(TEST_TOKENS);
	issueMcpToken.mockResolvedValue({
		token: {
			id: "tok_new",
			name: "新设备",
			lastUsedAt: null,
			revokedAt: null,
			insertedAt: "2026-08-08T18:00:00Z",
			status: "active" as const,
		},
		plainToken: "cgc_test_plain_token_value",
	});
	revokeMcpToken.mockResolvedValue({
		...TEST_TOKENS[0],
		revokedAt: "2026-08-08T18:30:00Z",
		status: "revoked" as const,
	});
});

afterEach(cleanup);

describe("/w/[slug]/settings/integrations/agents/mcp 集成 MCP 页", () => {
	it("渲染 token 列表：名称 + 状态（有效/已撤销）", async () => {
		render(<AgentsMcpPage />);

		expect(await screen.findByText("我的 Mac")).toBeInTheDocument();
		expect(screen.getByText("公司服务器")).toBeInTheDocument();
		expect(screen.getByText("有效")).toBeInTheDocument();
		expect(screen.getByText("已撤销")).toBeInTheDocument();
	});

	it("空态：无 token 时显示轻提示 + 查看接入指引链接（指向 guides 页）", async () => {
		fetchMyMcpTokens.mockResolvedValue([]);
		render(<AgentsMcpPage />);

		expect(await screen.findByText("还没有连接 token")).toBeInTheDocument();
		const link = screen.getByRole("link", { name: /查看接入指引/ });
		expect(link).toHaveAttribute(
			"href",
			"/w/cgc-academy/settings/integrations/agents/openclacky",
		);
	});

	it("页内 Tab：MCP 选中，其余三 tab 链接存在", async () => {
		render(<AgentsMcpPage />);

		const tabs = await screen.findByRole("navigation", {
			name: "工作区设置页签",
		});
		for (const label of ["MCP", "OpenClacky", "opencode", "OMP"]) {
			expect(within(tabs).getByRole("link", { name: label }))
				.toBeInTheDocument();
		}
		expect(within(tabs).getByRole("link", { name: "MCP" })).toHaveAttribute(
			"href",
			"/w/cgc-academy/settings/integrations/agents/mcp",
		);
	});

	it("签发：表单提交后展示一次性明文（含只显示一次警告）并更新列表", async () => {
		render(<AgentsMcpPage />);

		fireEvent.click(
			await screen.findByRole("button", { name: /签发新 token/ }),
		);
		fireEvent.change(screen.getByPlaceholderText("如：我的 Mac"), {
			target: { value: "新设备" },
		});
		fireEvent.click(screen.getByRole("button", { name: "签发" }));

		await waitFor(() => {
			expect(issueMcpToken).toHaveBeenCalledWith("新设备");
		});
		// 明文一次性展示区
		expect(
			await screen.findByText("cgc_test_plain_token_value"),
		).toBeInTheDocument();
		expect(screen.getByText(/只显示这一次/)).toBeInTheDocument();
		// 列表更新（明文横幅与列表卡片都含名称，收窄到列表容器断言）
		const list = await waitFor(() => {
			const el = document.querySelector(".invitations-list");
			expect(el).toHaveTextContent("新设备");
			return el;
		});
		expect(list).toHaveTextContent("我的 Mac");
	});

	it("撤销需二次确认：点击撤销 → 确认撤销 → 状态变为已撤销", async () => {
		render(<AgentsMcpPage />);

		const revokeButton = await screen.findByRole("button", { name: "撤销" });
		fireEvent.click(revokeButton);
		// 未确认前不调用
		expect(revokeMcpToken).not.toHaveBeenCalled();

		fireEvent.click(
			await screen.findByRole("button", { name: "确认撤销" }),
		);

		await waitFor(() => {
			expect(revokeMcpToken).toHaveBeenCalledWith("tok_1");
		});
		// 两个 token 都已是已撤销状态
		expect((await screen.findAllByText("已撤销")).length).toBe(2);
	});
});
