import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import AgentsPage from "./page";

const { router } = vi.hoisted(() => ({
	router: { push: vi.fn(), replace: vi.fn() },
}));
const { isAuthenticated, clearAuthToken, clearSession } = vi.hoisted(() => ({
	isAuthenticated: vi.fn(),
	clearAuthToken: vi.fn(),
	clearSession: vi.fn(),
}));
const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));
const { fetchMyWorkspaces } = vi.hoisted(() => ({
	fetchMyWorkspaces: vi.fn(),
}));
const { fetchWorkflowRuns } = vi.hoisted(() => ({
	fetchWorkflowRuns: vi.fn(),
}));
const { fetchMyMcpTokens } = vi.hoisted(() => ({
	fetchMyMcpTokens: vi.fn(),
}));
const { fetchMyWorkspaceToolCalls } = vi.hoisted(() => ({
	fetchMyWorkspaceToolCalls: vi.fn(),
}));
const { params } = vi.hoisted(() => ({
	params: { value: { slug: "cgc-academy" } },
}));
const { fetchCurrentProfile } = vi.hoisted(() => ({
	fetchCurrentProfile: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useRouter: () => router,
	usePathname: () => "/w/cgc-academy/agents",
	useParams: () => params.value,
}));

vi.mock("@/lib/auth", () => ({
	isAuthenticated,
	clearAuthToken,
	clearSession,
}));

vi.mock("@/lib/use-authed", () => ({ useAuthed }));

vi.mock("@/lib/profile", async (importOriginal) => {
	const actual = await importOriginal<typeof import("@/lib/profile")>();
	return { ...actual, fetchCurrentProfile };
});

vi.mock("@/lib/workspaces", async (importOriginal) => {
	const actual = await importOriginal<typeof import("@/lib/workspaces")>();
	return { ...actual, fetchMyWorkspaces };
});

// 隐私切换后本页不得再触碰 workflow run 审计适配器；保留 spy 断言零调用
vi.mock("@/lib/workflows", () => ({ fetchWorkflowRuns }));

vi.mock("@/lib/mcp", () => ({ fetchMyMcpTokens }));

vi.mock("@/lib/agents", () => ({ fetchMyWorkspaceToolCalls }));

const TEST_WORKSPACES = [
	{
		id: "ws_1",
		slug: "cgc-academy",
		name: "CGC 学院",
		joinPolicy: "open",
		sponsorshipEnabled: false,
		myRoleNames: ["member"],
		myAbilities: [],
		myMembershipId: "m_1",
		memberCount: 12,
		unreadCount: 0,
	},
];

const ACTIVITY = [
	{
		id: "log_1",
		tool: "get_workspace_context",
		status: "ok",
		latencyMs: 12,
		insertedAt: "2026-08-15T10:00:00Z",
		errorMessage: null,
	},
	{
		id: "log_2",
		tool: "save_step_output",
		status: "error",
		latencyMs: 8,
		insertedAt: "2026-08-15T09:00:00Z",
		errorMessage: "boom",
	},
];

beforeEach(() => {
	vi.clearAllMocks();
	isAuthenticated.mockReturnValue(true);
	useAuthed.mockReturnValue({ authed: true, confirmed: true });
	params.value = { slug: "cgc-academy" };
	fetchMyWorkspaces.mockResolvedValue(TEST_WORKSPACES);
	fetchCurrentProfile.mockResolvedValue({
		id: "u_0202",
		email: "xiaomei@example.com",
		displayName: "小美",
		avatarUrl: null,
		isPlatformAdmin: false,
	});
	fetchMyWorkspaceToolCalls.mockResolvedValue(ACTIVITY);
	fetchMyMcpTokens.mockResolvedValue([]);
});

afterEach(cleanup);

describe("Agents 工作面 /w/[slug]/agents（plan 020 U2）", () => {
	it("两区渲染：活动流时间轴 + 无 token 连接引导；不再请求 workflow run 审计", async () => {
		render(<AgentsPage />);

		expect(await screen.findByRole("heading", { name: "Agents" })).toBeInTheDocument();

		// 隐私切换：页面不再读取 raw WorkflowRun（platformWorkflowAudit 适配器零调用），
		// 原待办交接区已退役
		expect(fetchWorkflowRuns).not.toHaveBeenCalled();
		expect(screen.queryByTestId("agents-todos")).not.toBeInTheDocument();
		expect(screen.queryByTestId("agents-todos-empty")).not.toBeInTheDocument();

		// ① 活动流：时间轴条目 + status 色点 + 耗时
		const activitySection = await screen.findByTestId("agents-activity");
		const activityItems = activitySection.querySelectorAll('[data-testid="agents-activity-item"]');
		expect(activityItems.length).toBe(2);
		expect(activitySection).toHaveTextContent("get_workspace_context");
		expect(activitySection).toHaveTextContent("12ms");
		expect(activitySection).toHaveTextContent("save_step_output");
		expect(activitySection).toHaveTextContent("boom");

		// ② 连接引导：无 active token → 展示；链 MCP tab + OpenClacky tab
		const connect = await screen.findByTestId("agents-connect");
		const tokenLink = connect.querySelector('a[href="/w/cgc-academy/settings/integrations/agents/mcp"]');
		expect(tokenLink).not.toBeNull();
		const openclackyLink = connect.querySelector('a[href="/w/cgc-academy/settings/integrations/agents/openclacky"]');
		expect(openclackyLink).not.toBeNull();
	});

	it("有 active token → 连接引导不渲染", async () => {
		fetchMyMcpTokens.mockResolvedValue([
			{ id: "tok_1", name: "我的助手", lastUsedAt: null, revokedAt: null, insertedAt: "2026-08-10T00:00:00Z", status: "active" },
		]);
		render(<AgentsPage />);

		await screen.findByTestId("agents-page");
		expect(screen.queryByTestId("agents-connect")).not.toBeInTheDocument();
	});

	it("仅剩 idle_expired token → 连接引导重新出现（#226：闲置过期不再算 active）", async () => {
		fetchMyMcpTokens.mockResolvedValue([
			{ id: "tok_idle", name: "旧设备", lastUsedAt: null, revokedAt: null, insertedAt: "2026-05-01T00:00:00Z", status: "idle_expired" },
		]);
		render(<AgentsPage />);

		expect(await screen.findByTestId("agents-connect")).toBeInTheDocument();
	});

	it("活动流空态：无调用记录时显示引导文案", async () => {
		fetchMyWorkspaceToolCalls.mockResolvedValue([]);
		render(<AgentsPage />);

		expect(await screen.findByTestId("agents-activity-empty")).toBeInTheDocument();
		expect(screen.queryByTestId("agents-activity")).not.toBeInTheDocument();
	});
});
