import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent } from "@testing-library/react";
import { render } from "@/test-utils";
import AdminAuditPage from "./page";

const {
	fetchToolCallLogs,
	fetchPendingOperations,
	fetchSignalLogs,
	fetchWorkflowRuns,
} = vi.hoisted(() => ({
	fetchToolCallLogs: vi.fn(),
	fetchPendingOperations: vi.fn(),
	fetchSignalLogs: vi.fn(),
	fetchWorkflowRuns: vi.fn(),
}));

vi.mock("@/lib/admin", () => ({
	fetchToolCallLogs,
	fetchPendingOperations,
	fetchSignalLogs,
}));

vi.mock("@/lib/workflows", () => ({
	fetchWorkflowRuns,
}));

const toolLogs = [
	{
		id: "log1",
		userId: "u1",
		tool: "get_workspace_context",
		resultStatus: "ok",
		errorMessage: null,
		latencyMs: 12,
		insertedAt: "2026-08-01T00:00:00Z",
	},
];

const pendingOps = [
	{
		id: "op1",
		userId: "u1",
		tool: "create_invitation",
		summary: "创建邀请",
		status: "pending",
		insertedAt: "2026-08-01T00:00:00Z",
	},
];

const signalLogs = [
	{
		id: "sig1",
		workspaceId: "ws1",
		signalType: "workflow.approval",
		insertedAt: "2026-08-01T00:00:00Z",
	},
];

const workflowRuns = [
	{
		id: "run1",
		status: "succeeded",
		definitionId: "def_lesson_plan",
		facts: {},
		startedAt: "2026-08-02T00:00:00Z",
		finishedAt: "2026-08-02T00:05:00Z",
	},
];

beforeEach(() => {
	vi.clearAllMocks();
});

afterEach(cleanup);

describe("/admin/audit 审计仪表盘", () => {
	it("默认展示 ToolCallLog tab，列表渲染", async () => {
		fetchToolCallLogs.mockResolvedValue(toolLogs);

		render(<AdminAuditPage />);

		expect(await screen.findByText("get_workspace_context")).toBeInTheDocument();
		expect(screen.getByText("ok")).toBeInTheDocument();
	});

	it("切换 tab 加载对应资源", async () => {
		fetchToolCallLogs.mockResolvedValue(toolLogs);
		fetchPendingOperations.mockResolvedValue(pendingOps);

		render(<AdminAuditPage />);
		await screen.findByText("get_workspace_context");

		fireEvent.click(screen.getByRole("button", { name: /待确认操作/ }));
		expect(await screen.findByText("创建邀请")).toBeInTheDocument();
		await vi.waitFor(() => expect(fetchPendingOperations).toHaveBeenCalled());
	});

	it("WorkflowRun tab：时间列取 startedAt，非 Invalid Date（typed adapter 修复）", async () => {
		fetchToolCallLogs.mockResolvedValue(toolLogs);
		fetchWorkflowRuns.mockResolvedValue(workflowRuns);

		render(<AdminAuditPage />);
		await screen.findByText("get_workspace_context");

		// workflow 分支要求 workspace 过滤
		fireEvent.change(screen.getByPlaceholderText(/workspace/), {
			target: { value: "ws1" },
		});
		fireEvent.click(screen.getByRole("button", { name: /工作流运行/ }));

		expect(await screen.findByText("def_lesson_plan")).toBeInTheDocument();
		expect(screen.getByText("succeeded")).toBeInTheDocument();
		// startedAt（2026-08-02T00:00:00Z）必须渲染为真实日期；字段擦除时代码取
		// row.insertedAt（WorkflowRun 无此字段）→ 时间列空/Invalid Date，此处断言年份出现。
		expect(screen.getByText(/2026/)).toBeInTheDocument();
		expect(screen.queryByText("Invalid Date")).not.toBeInTheDocument();
	});

	it("SignalLog tab：workspace 过滤传 workspaceId", async () => {
		fetchToolCallLogs.mockResolvedValue(toolLogs);
		fetchSignalLogs.mockResolvedValue(signalLogs);

		render(<AdminAuditPage />);
		await screen.findByText("get_workspace_context");

		fireEvent.click(screen.getByRole("button", { name: /信号日志/ }));
		await screen.findByText("workflow.approval");

		// 输入 workspace id 过滤
		fireEvent.change(screen.getByPlaceholderText(/workspace/), {
			target: { value: "ws1" },
		});
		fireEvent.click(screen.getByRole("button", { name: /过滤/ }));

		await vi.waitFor(() =>
			expect(fetchSignalLogs).toHaveBeenLastCalledWith("ws1", { first: 50 }),
		);
	});

	it("ToolCallLog workspace 过滤也传 workspaceId（D5 JSONB）", async () => {
		fetchToolCallLogs.mockResolvedValue(toolLogs);

		render(<AdminAuditPage />);
		await screen.findByText("get_workspace_context");

		fireEvent.change(screen.getByPlaceholderText(/workspace/), {
			target: { value: "ws9" },
		});
		fireEvent.click(screen.getByRole("button", { name: /过滤/ }));

		await vi.waitFor(() =>
			expect(fetchToolCallLogs).toHaveBeenLastCalledWith("ws9", { first: 50 }),
		);
	});
});
