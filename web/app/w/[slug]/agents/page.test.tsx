import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, waitFor } from "@testing-library/react";
import { fireEvent } from "@testing-library/react";
import { render } from "@/test-utils";
import AgentsPage from "./page";
import type { WorkflowRunItem } from "@/lib/workflows";

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
const { copyText } = vi.hoisted(() => ({ copyText: vi.fn() }));
const { params } = vi.hoisted(() => ({
	params: { value: { slug: "cgc-academy" } },
}));
const { fetchCurrentProfile } = vi.hoisted(() => ({
	fetchCurrentProfile: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	useRouter: () => router,
	useParams: () => params.value,
	usePathname: () => `/w/${params.value.slug}/agents`,
}));

vi.mock("@/lib/auth", () => ({
	isAuthenticated,
	clearAuthToken,
	clearSession,
}));

vi.mock("@/lib/use-authed", () => ({ useAuthed }));

vi.mock("@/lib/profile", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchCurrentProfile };
});

vi.mock("@/lib/workspaces", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchMyWorkspaces };
});

vi.mock("@/lib/workflows", () => ({ fetchWorkflowRuns }));

vi.mock("@/lib/mcp", () => ({ fetchMyMcpTokens }));

vi.mock("@/lib/agents", () => ({ fetchMyWorkspaceToolCalls }));

vi.mock("@/lib/clipboard", () => ({ copyText }));

const TEST_WORKSPACES = [
	{
		id: "ws_02",
		slug: "cgc-academy",
		name: "CGC 线上学院",
		joinPolicy: "request" as const,
		sponsorshipEnabled: true,
		myRoleNames: ["admin"],
		roles: ["admin"],
		myAbilities: ["view_workspace", "access_invite_only"],
		membershipStatus: "active" as const,
	},
];

const LEARNING_RUN: WorkflowRunItem = {
	id: "run_learn_1",
	status: "running",
	definitionId: "def_learn",
	definitionType: "learning",
	facts: {},
	steps: [
		{ stepKey: "module_reading", title: "阅读模块", type: "manual", outputSchema: null },
		{ stepKey: "final_reflection", title: "结课反思", type: "manual", outputSchema: null },
	],
	startedAt: "2026-08-06T10:00:00Z",
	finishedAt: null,
};

const RESEARCH_RUN: WorkflowRunItem = {
	id: "run_res_1",
	status: "succeeded",
	definitionId: "def_res",
	definitionType: "research",
	facts: { uppercase: { text: "HI" } },
	steps: [],
	startedAt: "2026-08-06T10:00:00Z",
	finishedAt: "2026-08-06T10:00:05Z",
};

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
	fetchWorkflowRuns.mockResolvedValue([LEARNING_RUN, RESEARCH_RUN]);
	fetchMyWorkspaceToolCalls.mockResolvedValue(ACTIVITY);
	fetchMyMcpTokens.mockResolvedValue([]);
	copyText.mockResolvedValue(true);
});

afterEach(cleanup);

describe("Agents 工作面 /w/[slug]/agents（plan 020 U2）", () => {
	it("三区渲染：待办置顶（learning running 待办 manual）+ 活动流时间轴 + 无 token 连接引导", async () => {
		render(<AgentsPage />);

		expect(await screen.findByRole("heading", { name: "Agents" })).toBeInTheDocument();

		// ① 待办交接：learning running run 的 2 个待办 manual 步骤（facts 空）
		const todoSection = await screen.findByTestId("agents-todos");
		const todoItems = todoSection.querySelectorAll('[data-testid="agents-todo-item"]');
		expect(todoItems.length).toBe(2);

		// 每项复制按钮的交接文本：含 workspace slug(id) / run / step / 工具提示
		const copyButtons = todoSection.querySelectorAll('[data-testid="step-handoff-copy"]');
		expect(copyButtons.length).toBe(2);
		const firstHandoff = copyButtons[0].getAttribute("data-handoff") ?? "";
		expect(firstHandoff).toContain("workspace: cgc-academy(ws_02)");
		expect(firstHandoff).toContain("run: run_learn_1");
		expect(firstHandoff).toMatch(/step: (module_reading|final_reflection)/);
		expect(firstHandoff).toContain("用 save_step_output 写回该 step");

		// 多宿主文案
		expect(screen.getByText(/粘贴给你的 OpenClacky \/ opencode \/ omp 助手/)).toBeInTheDocument();

		// ② 活动流：时间轴条目 + status 色点 + 耗时
		const activitySection = await screen.findByTestId("agents-activity");
		const activityItems = activitySection.querySelectorAll('[data-testid="agents-activity-item"]');
		expect(activityItems.length).toBe(2);
		expect(activitySection).toHaveTextContent("get_workspace_context");
		expect(activitySection).toHaveTextContent("12ms");
		expect(activitySection).toHaveTextContent("save_step_output");
		expect(activitySection).toHaveTextContent("boom");

		// ③ 连接引导：无 active token → 展示；链 MCP tab + OpenClacky tab
		const connect = await screen.findByTestId("agents-connect");
		const tokenLink = connect.querySelector('a[href="/w/cgc-academy/settings/integrations/agents/mcp"]');
		expect(tokenLink).not.toBeNull();
		const openclackyLink = connect.querySelector('a[href="/w/cgc-academy/settings/integrations/agents/openclacky"]');
		expect(openclackyLink).not.toBeNull();
	});

	it("交接按钮点击：copyText 收到含 workspace id 的完整交接文本", async () => {
		render(<AgentsPage />);

		const copyButton = (await screen.findAllByTestId("step-handoff-copy"))[0];
		fireEvent.click(copyButton);

		await waitFor(() => expect(copyText).toHaveBeenCalledTimes(1));
		const copied = vi.mocked(copyText).mock.calls[0][0];
		expect(copied).toContain("workspace: cgc-academy(ws_02)");
		expect(copied).toContain("run: run_learn_1");
		expect(copied).toContain("step:");
		expect(copied).toContain("save_step_output");
		// 成功后按钮进入「已复制」态
		expect(await screen.findByText("已复制")).toBeInTheDocument();
	});

	it("无待办（learning 终态 + research run）→ 待办空态；活动流仍渲染", async () => {
		const finishedLearning: WorkflowRunItem = {
			...LEARNING_RUN,
			id: "run_learn_2",
			status: "succeeded",
			facts: { final_reflection: { text: "反思" } },
		};
		fetchWorkflowRuns.mockResolvedValue([finishedLearning, RESEARCH_RUN]);
		render(<AgentsPage />);

		expect(await screen.findByTestId("agents-todos-empty")).toBeInTheDocument();
		expect(screen.queryByTestId("agents-todos")).not.toBeInTheDocument();
		expect(screen.queryAllByTestId("step-handoff-copy")).toHaveLength(0);
		expect(await screen.findByTestId("agents-activity")).toBeInTheDocument();
	});

	it("有 active token → 连接引导不渲染", async () => {
		fetchMyMcpTokens.mockResolvedValue([
			{ id: "tok_1", name: "我的助手", lastUsedAt: null, revokedAt: null, insertedAt: "2026-08-10T00:00:00Z", status: "active" },
		]);
		render(<AgentsPage />);

		await screen.findByTestId("agents-page");
		expect(screen.queryByTestId("agents-connect")).not.toBeInTheDocument();
	});

	it("活动流空态：无调用记录时显示引导文案", async () => {
		fetchMyWorkspaceToolCalls.mockResolvedValue([]);
		render(<AgentsPage />);

		expect(await screen.findByTestId("agents-activity-empty")).toBeInTheDocument();
		expect(screen.queryByTestId("agents-activity")).not.toBeInTheDocument();
	});
});
