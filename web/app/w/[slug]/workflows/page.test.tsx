import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import WorkflowsPage from "./page";
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
const { params } = vi.hoisted(() => ({
	params: { value: { slug: "cgc-academy" } },
}));
const { fetchCurrentProfile } = vi.hoisted(() => ({
	fetchCurrentProfile: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	useRouter: () => router,
	useParams: () => params.value,
	usePathname: () => `/w/${params.value.slug}/workflows`,
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

const TEST_RUNS: WorkflowRunItem[] = [
	{
		id: "run_0001",
		status: "succeeded",
		definitionId: "def_1",
		facts: { uppercase: { text: "HI" } },
		startedAt: "2026-08-06T10:00:00Z",
		finishedAt: "2026-08-06T10:00:05Z",
	},
	{
		id: "run_0002",
		status: "pending",
		definitionId: "def_1",
		facts: {},
		startedAt: null,
		finishedAt: null,
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
	fetchWorkflowRuns.mockResolvedValue(TEST_RUNS);
});

afterEach(cleanup);

describe("教研产出页 /w/[slug]/workflows (#40)", () => {
	it("未登录：重定向 /login 且不请求 run", async () => {
		isAuthenticated.mockReturnValue(false);
		useAuthed.mockReturnValue({ authed: false, confirmed: true });
		render(<WorkflowsPage />);
		await waitFor(() => expect(router.replace).toHaveBeenCalledWith("/login"));
		expect(fetchWorkflowRuns).not.toHaveBeenCalled();
	});

	it("渲染 run 列表：status 中文 label + facts 递归树", async () => {
		render(<WorkflowsPage />);

		expect(
			await screen.findByRole("heading", { name: "教研产出" }),
		).toBeInTheDocument();
		expect(screen.getByText("查看该工作台的教研 workflow 执行结果")).toBeInTheDocument();

		// fetchWorkflowRuns 以 workspaceId 调用（ws_02 来自 fetchMyWorkspaces 解析）
		await waitFor(() =>
			expect(fetchWorkflowRuns).toHaveBeenCalledWith("ws_02"),
		);

		const runs = await screen.findAllByTestId("workflow-run");
		expect(runs).toHaveLength(2);

		// status label：succeeded → 已完成；pending → 待执行
		expect(screen.getAllByText("已完成").length).toBeGreaterThan(0);
		expect(screen.getAllByText("待执行").length).toBeGreaterThan(0);

		// facts 递归树：uppercase → text: HI
		expect(screen.getByText("uppercase")).toBeInTheDocument();
		expect(screen.getByText("text")).toBeInTheDocument();
		expect(screen.getByText("HI")).toBeInTheDocument();

		// 无 facts 的 run 显示空态文案
		expect(screen.getAllByText("暂无执行产物").length).toBeGreaterThan(0);
	});

	it("空态：无 run 时显示「暂无教研产出」", async () => {
		fetchWorkflowRuns.mockResolvedValue([]);
		render(<WorkflowsPage />);

		expect(
			await screen.findByTestId("workflows-empty"),
		).toBeInTheDocument();
		expect(screen.getByText("暂无教研产出")).toBeInTheDocument();
		expect(screen.queryByTestId("workflows-list")).not.toBeInTheDocument();
	});

	it("加载失败：显示错误信息且不渲染空态", async () => {
		fetchWorkflowRuns.mockRejectedValue(new Error("网络错误"));
		render(<WorkflowsPage />);

		expect(await screen.findByRole("alert")).toHaveTextContent("网络错误");
		expect(screen.queryByTestId("workflows-empty")).not.toBeInTheDocument();
	});
});
