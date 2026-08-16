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
		definitionType: "research",
		facts: { uppercase: { text: "HI" } },
		steps: [
			{ stepKey: "uppercase", title: "大写", type: "auto", outputSchema: null },
		],
		startedAt: "2026-08-06T10:00:00Z",
		finishedAt: "2026-08-06T10:00:05Z",
	},
	{
		id: "run_0002",
		status: "pending",
		definitionId: "def_1",
		definitionType: "research",
		facts: {},
		steps: [],
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

		// plan 020 U4：步骤产物按步骤渲染——步骤标题（大写，步骤条 + 产物标题各一处）+ schema 缺失回退 FactsTree（text: HI）
		expect(screen.getAllByText("大写").length).toBeGreaterThan(0);
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

	describe("plan 020 U3：步骤条 + CTA 条件（waiting·learning only）", () => {
		it("learning + running + 待办 manual 步骤 → 步骤条（完成/待办）+ CTA 出现，交接文本含 workspace/run/step", async () => {
			const learningRun: WorkflowRunItem = {
				id: "run_learn_1",
				status: "running",
				definitionId: "def_learn",
				definitionType: "learning",
				facts: { module_reading: { text: "读完了" } },
				steps: [
					{ stepKey: "module_reading", title: "阅读模块", type: "manual", outputSchema: null },
					{ stepKey: "final_reflection", title: "结课反思", type: "manual", outputSchema: null },
				],
				startedAt: "2026-08-06T10:00:00Z",
				finishedAt: null,
			};
			fetchWorkflowRuns.mockResolvedValue([learningRun]);
			render(<WorkflowsPage />);

			const stepsBar = await screen.findByTestId("workflow-run-steps");
			expect(stepsBar).toBeInTheDocument();
			// 完成集推导：module_reading 已完成（facts 有值），final_reflection 待办
			expect(screen.getByTestId("workflow-step-done")).toHaveTextContent("阅读模块");
			const pendingChip = screen.getByTestId("workflow-step-pending");
			expect(pendingChip).toHaveTextContent("结课反思");
			expect(pendingChip).toHaveTextContent("待办");

			// CTA：主动作复制按钮 + 交接文本内容（含 workspace id/run id/step key）
			const cta = await screen.findByTestId("workflow-run-cta");
			expect(cta).toBeInTheDocument();
			const copyButton = cta.querySelector('[data-testid="step-handoff-copy"]');
			const handoff = copyButton?.getAttribute("data-handoff") ?? "";
			expect(handoff).toContain("workspace: cgc-academy(ws_02)");
			expect(handoff).toContain("run: run_learn_1");
			expect(handoff).toContain("step: final_reflection");
			expect(handoff).toContain("save_step_output");

			// 多宿主文案 + 副链接
			expect(screen.getByText(/OpenClacky \/ opencode \/ omp/)).toBeInTheDocument();
			const agentsLink = screen.getByRole("link", { name: "去 Agents 页" });
			expect(agentsLink).toHaveAttribute("href", "/w/cgc-academy/agents");
			const connectLink = screen.getByRole("link", { name: "连接设置" });
			expect(connectLink).toHaveAttribute("href", "/w/cgc-academy/settings/integrations/agents/mcp");
		});

		it("learning + 终态（succeeded）→ 无 CTA；research + running → 无 CTA", async () => {
			const succeededLearning: WorkflowRunItem = {
				id: "run_learn_2",
				status: "succeeded",
				definitionId: "def_learn",
				definitionType: "learning",
				facts: { final_reflection: { text: "反思" } },
				steps: [
					{ stepKey: "final_reflection", title: "结课反思", type: "manual", outputSchema: null },
				],
				startedAt: "2026-08-06T10:00:00Z",
				finishedAt: "2026-08-06T10:00:05Z",
			};
			const runningResearch: WorkflowRunItem = {
				id: "run_res_1",
				status: "running",
				definitionId: "def_res",
				definitionType: "research",
				facts: {},
				steps: [
					{ stepKey: "collect", title: "收集", type: "manual", outputSchema: null },
				],
				startedAt: "2026-08-06T10:00:00Z",
				finishedAt: null,
			};
			fetchWorkflowRuns.mockResolvedValue([succeededLearning, runningResearch]);
			render(<WorkflowsPage />);

			await screen.findAllByTestId("workflow-run");
			expect(screen.queryByTestId("workflow-run-cta")).not.toBeInTheDocument();
			// CTA 只属 learning：research run 无复制交接按钮（步骤条待办高亮对所有 run 生效）
			expect(screen.queryAllByTestId("step-handoff-copy")).toHaveLength(0);
		});

		it("steps 无 output_schema → SchemaOutputList 回退 FactsTree（schema 缺失回退矩阵之页级）", async () => {
			// run_0001（research，steps 带 outputSchema: null）→ 步骤产物走 FactsTree
			render(<WorkflowsPage />);
			await screen.findAllByTestId("workflow-run");
			expect(screen.getAllByText("大写").length).toBeGreaterThan(0);
			expect(screen.getByText("HI")).toBeInTheDocument();
			expect(screen.queryByTestId("schema-output-field")).not.toBeInTheDocument();
		});

		it("learning + running + steps 带 output_schema → schema 驱动渲染（label 有序 + optional 缺失隐藏）", async () => {
			const learningRun: WorkflowRunItem = {
				id: "run_learn_3",
				status: "running",
				definitionId: "def_learn",
				definitionType: "learning",
				facts: {
					reading: { text: "读书笔记", reflection: "心得" },
				},
				steps: [
					{
						stepKey: "reading",
						title: "阅读产出",
						type: "manual",
						outputSchema: [
							{ name: "text", type: "string", label: "笔记内容", optional: false },
							{ name: "reflection", type: "string", label: "心得体会", optional: false },
							{ name: "extra", type: "string", label: "补充（可选）", optional: true },
						],
					},
				],
				startedAt: "2026-08-06T10:00:00Z",
				finishedAt: null,
			};
			fetchWorkflowRuns.mockResolvedValue([learningRun]);
			render(<WorkflowsPage />);

			await screen.findAllByTestId("schema-output-field");
			// 顺序 + 中文标签
			const labels = screen.getAllByText(/笔记内容|心得体会|补充（可选）/);
			expect(labels.length).toBeGreaterThan(0);
			expect(screen.getByText("读书笔记")).toBeInTheDocument();
			expect(screen.getByText("心得")).toBeInTheDocument();
			// optional 缺失隐藏：extra 字段值缺失 → 不渲染
			expect(screen.queryByText("补充（可选）")).not.toBeInTheDocument();
		});
	});
});
