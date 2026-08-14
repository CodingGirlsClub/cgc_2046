import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent } from "@testing-library/react";
import { render } from "@/test-utils";
import AdminReconciliationPage from "./page";

const fetchReconciliationFindings = vi.hoisted(() => vi.fn());

vi.mock("@/lib/admin", () => ({
	fetchReconciliationFindings,
}));

const findings = [
	{
		id: "f1",
		rule: "confirmed_enrollment_without_run",
		entityType: "enrollment",
		entityId: "enroll-abcdef123456",
		workspaceId: "ws1",
		firstSeenAt: "2026-08-01T00:00:00Z",
		lastSeenAt: "2026-08-01T00:10:00Z",
		insertedAt: "2026-08-01T00:00:00Z",
	},
];

beforeEach(() => {
	vi.clearAllMocks();
});

afterEach(cleanup);

describe("/admin/reconciliation 对账页", () => {
	it("默认加载：中文规则/实体标签 + ID + 时间列渲染", async () => {
		fetchReconciliationFindings.mockResolvedValue(findings);

		render(<AdminReconciliationPage />);

		// 用唯一 entityId 定位行，再断言该行内的中文标签与时间（避 select option 同名文本）
		expect(await screen.findByText("enroll-abcdef123456")).toBeInTheDocument();
		const row = screen.getByText("enroll-abcdef123456").closest("tr");
		expect(row).not.toBeNull();
		expect(row).toHaveTextContent("报名无学习 run");
		expect(row).toHaveTextContent("报名");
		expect(row).toHaveTextContent("ws1");
		// 时间列渲染为真实日期，非 Invalid Date
		expect(row).toHaveTextContent("2026");
		expect(screen.queryByText("Invalid Date")).not.toBeInTheDocument();
	});

	it("空报告 → 渲染空态", async () => {
		fetchReconciliationFindings.mockResolvedValue([]);

		render(<AdminReconciliationPage />);

		expect(await screen.findByText("暂无孤儿发现。")).toBeInTheDocument();
	});

	it("规则下拉过滤传 rule 参数（枚举串）", async () => {
		fetchReconciliationFindings.mockResolvedValue(findings);

		render(<AdminReconciliationPage />);
		await screen.findByText("enroll-abcdef123456");

		fireEvent.change(screen.getByLabelText("规则过滤"), {
			target: { value: "dead_letter_job" },
		});

		await vi.waitFor(() =>
			expect(fetchReconciliationFindings).toHaveBeenLastCalledWith(
				{ rule: "dead_letter_job", workspaceId: undefined },
				{ first: 50 },
			),
		);
	});

	it("workspace 过滤传 workspaceId", async () => {
		fetchReconciliationFindings.mockResolvedValue(findings);

		render(<AdminReconciliationPage />);
		await screen.findByText("enroll-abcdef123456");

		fireEvent.change(screen.getByPlaceholderText(/workspace/), {
			target: { value: "ws9" },
		});
		fireEvent.click(screen.getByRole("button", { name: /过滤/ }));

		await vi.waitFor(() =>
			expect(fetchReconciliationFindings).toHaveBeenLastCalledWith(
				{ rule: undefined, workspaceId: "ws9" },
				{ first: 50 },
			),
		);
	});
});
