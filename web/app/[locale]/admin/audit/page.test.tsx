import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent, within } from "@testing-library/react";
import { render } from "@/test-utils";
import AdminAuditPage from "./page";

const {
	fetchToolCallLogs,
	fetchPendingOperations,
	fetchSignalLogs,
	fetchAdminActionLogs,
	fetchWorkflowRuns,
} = vi.hoisted(() => ({
	fetchToolCallLogs: vi.fn(),
	fetchPendingOperations: vi.fn(),
	fetchSignalLogs: vi.fn(),
	fetchAdminActionLogs: vi.fn(),
	fetchWorkflowRuns: vi.fn(),
}));

vi.mock("@/lib/admin", () => ({
	fetchToolCallLogs,
	fetchPendingOperations,
	fetchSignalLogs,
	fetchAdminActionLogs,
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

const adminActionLogs = [
	{
		id: "act1",
		actorId: "admin-1",
		action: "workspace_create",
		targetType: "workspace",
		targetId: "ws-abcdef123456",
		result: "success",
		insertedAt: "2026-08-03T00:00:00Z",
		// #607：未收录的 action → 读面 null（无默认透传）
		metadata: null,
		offeringChange: null,
	},
];

/** U1 offering 治理写变更投影行（闭集标量；未变更列不落键 → 只渲染变了的列） */
const offeringChangeLogs = [
	{
		id: "offering-update",
		actorId: "admin-1",
		action: "admin_event_update",
		targetType: "event",
		targetId: "evt-abcdef123456",
		result: "success",
		insertedAt: "2026-08-04T00:00:00Z",
		metadata: null,
		offeringChange: {
			titleBefore: null,
			titleAfter: null,
			visibilityBefore: "public",
			visibilityAfter: "workspace",
			capacityBefore: 10,
			capacityAfter: 20,
			pricingEnabledBefore: null,
			pricingEnabledAfter: null,
			depositEnabledBefore: null,
			depositEnabledAfter: null,
		},
	},
	{
		id: "offering-launch",
		actorId: "admin-1",
		action: "admin_event_launch",
		targetType: "event",
		targetId: "evt-launch123456",
		result: "success",
		insertedAt: "2026-08-04T00:00:01Z",
		metadata: null,
		// launch 未收录 → 投影 null
		offeringChange: null,
	},
];

/** #607 治理 metadata 白名单投影行的三种形态（改值 / 新建 / 含省略） */
const ruleChangeLogs = [
	{
		id: "rule-update",
		actorId: "admin-1",
		action: "initiative_rule_update",
		targetType: "initiative",
		targetId: "init-update-1234",
		result: "success",
		insertedAt: "2026-08-04T00:00:00Z",
		metadata: {
			ruleKey: "deposit",
			locked: true,
			lockedBefore: false,
			valueBeforeJson: '{"enabled":true,"amount_cents":6900}',
			valueAfterJson: '{"enabled":true,"amount_cents":9900}',
			valueBeforeOmitted: false,
			valueAfterOmitted: false,
		},
	},
	{
		id: "rule-create",
		actorId: "admin-1",
		action: "initiative_rule_update",
		targetType: "initiative",
		targetId: "init-create-5678",
		result: "success",
		insertedAt: "2026-08-05T00:00:00Z",
		metadata: {
			ruleKey: "min_participants",
			locked: false,
			lockedBefore: null,
			valueBeforeJson: null,
			valueAfterJson: '{"count":8}',
			valueBeforeOmitted: false,
			valueAfterOmitted: false,
		},
	},
	{
		id: "rule-omitted",
		actorId: "admin-1",
		action: "initiative_rule_update",
		targetType: "initiative",
		targetId: "init-omit-9012",
		result: "success",
		insertedAt: "2026-08-06T00:00:00Z",
		metadata: {
			ruleKey: "weird_key",
			locked: false,
			lockedBefore: false,
			valueBeforeJson: '{"hours_before_start":72}',
			valueAfterJson: '{"hours_before_start":48}',
			valueBeforeOmitted: true,
			valueAfterOmitted: true,
		},
	},
];

const workflowRuns = [
	{
		id: "run1",
		status: "succeeded",
		definitionType: "lesson_plan",
		startedAt: "2026-08-02T00:00:00Z",
		finishedAt: "2026-08-02T00:05:00Z",
		errorSummary: null,
	},
	{
		id: "run2",
		status: "failed",
		definitionType: "event_ops",
		startedAt: "2026-08-02T01:00:00Z",
		finishedAt: "2026-08-02T01:05:00Z",
		errorSummary: "workflow_failed",
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
		// #117 状态下拉也含 "ok" option——断言精确到表格 cell，避多重匹配
		expect(screen.getByRole("cell", { name: "ok" })).toBeInTheDocument();
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

		// #117：workflow tab 可带 workspace 过滤（也支持免 workspace 全量，见下测试）
		fireEvent.change(screen.getByPlaceholderText(/workspace/), {
			target: { value: "ws1" },
		});
		fireEvent.click(screen.getByRole("button", { name: /工作流运行/ }));

		expect(await screen.findByText("lesson_plan")).toBeInTheDocument();
		// #117 状态下拉也含 "succeeded" option——断言精确到表格 cell
		expect(screen.getByRole("cell", { name: "succeeded" })).toBeInTheDocument();
		// startedAt（2026-08-02T00:00:00Z）必须渲染为真实日期；字段擦除时代码取
		// row.insertedAt（WorkflowRun 无此字段）→ 时间列空/Invalid Date，此处断言年份出现。
		expect(screen.getAllByText(/2026/).length).toBeGreaterThan(0);
		expect(screen.queryByText("Invalid Date")).not.toBeInTheDocument();
		// L4:失败 run 的脱敏错误摘要经 summary 副行渲染
		expect(screen.getByText("workflow_failed")).toBeInTheDocument();
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
			expect(fetchSignalLogs).toHaveBeenLastCalledWith("ws1", {}, { first: 50 }),
		);
	});

	it("WorkflowRun tab：免 workspace 过滤全量列出（#117）", async () => {
		fetchToolCallLogs.mockResolvedValue(toolLogs);
		fetchWorkflowRuns.mockResolvedValue(workflowRuns);

		render(<AdminAuditPage />);
		await screen.findByText("get_workspace_context");

		// 不输入 workspace，直接切 tab → 全量加载
		fireEvent.click(screen.getByRole("button", { name: /工作流运行/ }));

		expect(await screen.findByText("lesson_plan")).toBeInTheDocument();
		await vi.waitFor(() =>
			expect(fetchWorkflowRuns).toHaveBeenCalledWith(undefined, {
				first: 50,
				filters: {},
			}),
		);
	});

	it("治理操作 tab：渲染中文 action 名与 result，忽略 workspace 过滤", async () => {
		fetchToolCallLogs.mockResolvedValue(toolLogs);
		fetchAdminActionLogs.mockResolvedValue(adminActionLogs);

		render(<AdminAuditPage />);
		await screen.findByText("get_workspace_context");

		fireEvent.click(screen.getByRole("button", { name: /治理操作/ }));

		// action 枚举映射为中文名；summary 为 targetId 短 ID
		expect(await screen.findByText("创建工作台")).toBeInTheDocument();
		expect(screen.getByText("ws-abcde")).toBeInTheDocument();
		expect(screen.getByText("success")).toBeInTheDocument();
		await vi.waitFor(() =>
			expect(fetchAdminActionLogs).toHaveBeenCalledWith(undefined, {}, {
				first: 50,
			}),
		);
	});

	it("#607 治理操作 tab：变更列渲染规则前后态，非规则行渲染 —", async () => {
		fetchToolCallLogs.mockResolvedValue(toolLogs);
		fetchAdminActionLogs.mockResolvedValue([...ruleChangeLogs, ...adminActionLogs]);

		render(<AdminAuditPage />);
		await screen.findByText("get_workspace_context");

		fireEvent.click(screen.getByRole("button", { name: /治理操作/ }));
		await screen.findAllByText("规则变更");

		// 变更列 = locked + 值键（键序 = 后端白名单序，前端不抄清单）
		const before = screen.getAllByTestId("audit-change-before");
		const after = screen.getAllByTestId("audit-change-after");
		// 仅 3 行有白名单投影；第 4 行（workspace_create）metadata 为 null → 整格 "—"
		expect(before).toHaveLength(3);
		expect(after).toHaveLength(3);

		// [0] 改值 + 翻锁
		expect(before[0]).toHaveTextContent("locked=false, enabled=true, amount_cents=6900");
		expect(after[0]).toHaveTextContent("locked=true, enabled=true, amount_cents=9900");
		// 副标识 = 规则中文名 + 目标短 ID
		expect(screen.getByText("押金规则 · init-upd")).toBeInTheDocument();

		// [1] :create → before 渲染「新建」（不是 —，也不是空）
		expect(before[1]).toHaveTextContent("新建");
		expect(after[1]).toHaveTextContent("locked=false, count=8");
		expect(screen.getByText("成班阈值 · init-cre")).toBeInTheDocument();

		// [2] 未知规则键 → 副标识回退原串（不静默丢信息）
		expect(screen.getByText("weird_key · init-omi")).toBeInTheDocument();

		// 非白名单 action（metadata null）→ 变更列 "—"（与「新建」区分）
		const nonRuleRow = screen.getByText("创建工作台").closest("tr");
		expect(nonRuleRow).not.toBeNull();
		expect(within(nonRuleRow as HTMLElement).getByText("—")).toBeInTheDocument();
	});

	it("U1 offering 变更投影（admin_event_update）：渲染闭集标量前后值；未收录 action 仍 —", async () => {
		fetchToolCallLogs.mockResolvedValue(toolLogs);
		fetchAdminActionLogs.mockResolvedValue(offeringChangeLogs);

		render(<AdminAuditPage />);
		await screen.findByText("get_workspace_context");

		fireEvent.click(screen.getByRole("button", { name: /治理操作/ }));
		await screen.findAllByText("evt-abcd");

		const row = screen.getByText("evt-abcd").closest("tr");
		expect(row).not.toBeNull();
		// 动作列经 ACTION_LABEL 词表本地化：缺表时渲染 missing-message 回退串（admin.admin_event_update）
		expect(within(row as HTMLElement).getByText("编辑活动")).toBeInTheDocument();

		const before = within(row as HTMLElement).getByTestId("audit-change-before");
		const after = within(row as HTMLElement).getByTestId("audit-change-after");
		// 键序 = 后端闭集次序；未变更列不渲染（不是 0/false 假值）
		expect(before).toHaveTextContent("visibility=public, capacity=10");
		expect(after).toHaveTextContent("visibility=workspace, capacity=20");
		expect(before).not.toHaveTextContent("title=");
		expect(before).not.toHaveTextContent("pricing_enabled=");

		// launch（未收录 action）→ 变更列 —
		const launchRow = screen.getByText("evt-laun").closest("tr");
		expect(within(launchRow as HTMLElement).getByText("—")).toBeInTheDocument();
	});

	it("#607 省略标记：白名单外字段以 … 标出并带可读说明", async () => {
		fetchToolCallLogs.mockResolvedValue(toolLogs);
		// 只留「含省略」行，避免多行同名标记干扰
		fetchAdminActionLogs.mockResolvedValue([ruleChangeLogs[2]]);

		render(<AdminAuditPage />);
		await screen.findByText("get_workspace_context");

		fireEvent.click(screen.getByRole("button", { name: /治理操作/ }));
		await screen.findAllByText("规则变更");

		const after = screen.getByTestId("audit-change-after");
		expect(after).toHaveTextContent("locked=false, hours_before_start=48 …");

		const marks = within(after).getAllByLabelText("白名单外字段未展示");
		expect(marks).toHaveLength(1);
		expect(marks[0]).toHaveAttribute("title", "白名单外字段未展示");
	});

	it("#607 变更列仅治理操作 tab 渲染（其它 tab 列数不变）", async () => {
		fetchToolCallLogs.mockResolvedValue(toolLogs);
		fetchAdminActionLogs.mockResolvedValue(ruleChangeLogs);

		render(<AdminAuditPage />);
		await screen.findByText("get_workspace_context");

		// 默认 tool tab：时间 / 标识 / 状态
		expect(screen.getAllByRole("columnheader")).toHaveLength(3);

		fireEvent.click(screen.getByRole("button", { name: /治理操作/ }));
		await screen.findAllByText("规则变更");

		// 治理操作 tab：时间 / 标识 / 变更 / 状态
		const headers = screen.getAllByRole("columnheader");
		expect(headers).toHaveLength(4);
		expect(headers.map((h) => h.textContent)).toEqual(["时间", "标识", "变更", "状态"]);
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
			expect(fetchToolCallLogs).toHaveBeenLastCalledWith("ws9", {}, { first: 50 }),
		);
	});
});
