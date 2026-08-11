import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, fireEvent } from "@testing-library/react";
import { render } from "@/test-utils";
import AdminApplicationsPage from "./page";

const { fetchApplications, approveApplication, rejectApplication } = vi.hoisted(() => ({
	fetchApplications: vi.fn(),
	approveApplication: vi.fn(),
	rejectApplication: vi.fn(),
}));

vi.mock("@/lib/admin", () => ({ fetchApplications, approveApplication, rejectApplication }));

const pendingApps = [
	{
		id: "app1",
		applicantId: "u1",
		name: "研究协作空间",
		slug: "research-collab",
		purpose: "团队研究协作",
		status: "pending",
		rejectionReason: null,
		insertedAt: "2026-08-01T00:00:00Z",
	},
];

beforeEach(() => {
	vi.clearAllMocks();
});

afterEach(cleanup);

describe("/admin/applications 申请审批", () => {
	it("渲染 pending 申请列表（name/slug/purpose）", async () => {
		fetchApplications.mockResolvedValue(pendingApps);

		render(<AdminApplicationsPage />);

		expect(await screen.findByText("研究协作空间")).toBeInTheDocument();
		expect(screen.getByText("research-collab")).toBeInTheDocument();
		expect(screen.getByText("团队研究协作")).toBeInTheDocument();
	});

	it("approve 后列表按当前 filter 重新加载（P3：新状态无手动刷新）", async () => {
		// 首次加载：pending 列表有 app1；approve 后重新加载：pending 过滤下 app1 消失
		fetchApplications.mockResolvedValueOnce(pendingApps).mockResolvedValueOnce([]);
		approveApplication.mockResolvedValue({
			result: { id: "app1", status: "approved" },
			errors: [],
		});

		render(<AdminApplicationsPage />);
		await screen.findByText("研究协作空间");

		fireEvent.click(screen.getByRole("button", { name: /通过/ }));

		// approve 后 fetchApplications 再次被调用，且仍按当前 filter（pending）加载
		await vi.waitFor(() => {
			expect(fetchApplications).toHaveBeenCalledTimes(2);
			expect(fetchApplications).toHaveBeenLastCalledWith("pending", { first: 50 });
		});
		// 列表刷新：app1 不再显示
		await vi.waitFor(() => {
			expect(screen.queryByText("研究协作空间")).not.toBeInTheDocument();
		});
	});

	it("reject 输入原因后调用 rejectApplication 带 rejectionReason", async () => {
		fetchApplications.mockResolvedValue(pendingApps);
		rejectApplication.mockResolvedValue({
			result: { id: "app1", status: "rejected", rejectionReason: "slug 冲突" },
			errors: [],
		});

		render(<AdminApplicationsPage />);
		await screen.findByText("研究协作空间");

		fireEvent.click(screen.getByRole("button", { name: /拒绝/ }));
		fireEvent.change(screen.getByPlaceholderText(/拒绝原因/), {
			target: { value: "slug 冲突" },
		});
		fireEvent.click(screen.getByRole("button", { name: /确认拒绝/ }));

		await vi.waitFor(() =>
			expect(rejectApplication).toHaveBeenCalledWith("app1", "slug 冲突"),
		);
	});

	it("approve 失败时展示错误消息", async () => {
		fetchApplications.mockResolvedValue(pendingApps);
		approveApplication.mockResolvedValue({
			result: null,
			errors: [{ message: "该申请已被处理", code: "invalid_attribute" }],
		});

		render(<AdminApplicationsPage />);
		await screen.findByText("研究协作空间");

		fireEvent.click(screen.getByRole("button", { name: /通过/ }));
		expect(await screen.findByText(/该申请已被处理/)).toBeInTheDocument();
	});

	it("已处理申请（approved/rejected）也可见，rejectionReason 展示", async () => {
		const processed = [
			{
				id: "app2",
				applicantId: "u2",
				name: "已拒绝空间",
				slug: "rejected-space",
				purpose: "测试",
				status: "rejected",
				rejectionReason: "不符合要求",
				insertedAt: "2026-08-02T00:00:00Z",
			},
		];
		// 初始（pending 过滤）返回空；切"全部"后返回已处理
		fetchApplications.mockImplementation(async (statusFilter?: string) =>
			statusFilter === "pending" ? [] : processed,
		);

		render(<AdminApplicationsPage />);

		// 等初始加载完成（pending 空态或加载结束）
		await vi.waitFor(() => {
			expect(fetchApplications).toHaveBeenCalledWith("pending", { first: 50 });
		});

		fireEvent.click(screen.getByRole("button", { name: "全部" }));
		expect(await screen.findByText("已拒绝空间")).toBeInTheDocument();
		expect(screen.getByText(/原因：不符合要求/)).toBeInTheDocument();
	});
});
