import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import RequestsPage from "./page";

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
const { fetchJoinRequests } = vi.hoisted(() => ({
	fetchJoinRequests: vi.fn(),
}));
const { approveJoinRequest } = vi.hoisted(() => ({
	approveJoinRequest: vi.fn(),
}));
const { rejectJoinRequest } = vi.hoisted(() => ({
	rejectJoinRequest: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	useRouter: () => router,
	useParams: () => params.value,
	usePathname: () => `/w/${params.value.slug}/settings/requests`,
}));

vi.mock("@/lib/use-authed", () => ({ useAuthed }));

vi.mock("@/lib/workspaces", async (importOriginal) => {
	const mod = (await importOriginal()) as Record<string, unknown>;
	return { ...mod, fetchMyWorkspaces };
});

vi.mock("@/lib/requests", () => ({
	fetchJoinRequests,
	approveJoinRequest,
	rejectJoinRequest,
}));

const ADMIN_WORKSPACES = [
	{
		id: "ws_02",
		slug: "cgc-academy",
		name: "CGC 线上学院",
		joinPolicy: "request" as const,
		sponsorshipEnabled: true,
		myRoleNames: ["admin"],
		roles: ["admin"],
		myAbilities: [
			"view_workspace",
			"access_invite_only",
			"list_members",
			"manage_members",
			"assign_roles",
		],
		membershipStatus: "active" as const,
	},
];

const MEMBER_WORKSPACES = [
	{
		id: "ws_01",
		slug: "cgc-shanghai",
		name: "CGC 上海分社",
		joinPolicy: "open" as const,
		sponsorshipEnabled: true,
		myRoleNames: [],
		roles: [],
		myAbilities: ["view_workspace", "access_invite_only"],
		membershipStatus: "active" as const,
	},
];

const PENDING_REQUESTS = [
	{
		id: "jr_1",
		workspaceId: "ws_02",
		userId: "u_new1",
		status: "pending" as const,
		message: "我想加入学习编程",
		approvalDeadline: "2026-08-20T03:00:00Z",
	},
	{
		id: "jr_2",
		workspaceId: "ws_02",
		userId: "u_new2",
		status: "pending" as const,
		message: null,
		approvalDeadline: "2026-08-10T03:00:00Z",
	},
];

beforeEach(() => {
	vi.clearAllMocks();
	useAuthed.mockReturnValue({
		authed: true,
		confirmed: true,
		userId: "admin_1",
	});
	params.value = { slug: "cgc-academy" };
	fetchMyWorkspaces.mockResolvedValue(ADMIN_WORKSPACES);
	fetchJoinRequests.mockResolvedValue({
		items: PENDING_REQUESTS,
		endKeyset: null,
		count: 2,
	});
	approveJoinRequest.mockResolvedValue({ id: "jr_1", status: "approved" });
	rejectJoinRequest.mockResolvedValue({ id: "jr_2", status: "rejected" });
});

afterEach(cleanup);

describe("/w/[slug]/settings/requests 审批页", () => {
	it("能力门控：无 manage_members 时显示提示不加载", async () => {
		params.value = { slug: "cgc-shanghai" };
		fetchMyWorkspaces.mockResolvedValue(MEMBER_WORKSPACES);
		render(<RequestsPage />);

		expect(
			await screen.findByText("仅具备管理成员能力的用户可查看加入审批。"),
		).toBeInTheDocument();
		expect(fetchJoinRequests).not.toHaveBeenCalled();
	});

	it("管理员可见 pending 列表", async () => {
		render(<RequestsPage />);

		expect(await screen.findByText("u_new1")).toBeInTheDocument();
		expect(screen.getByText("u_new2")).toBeInTheDocument();
		expect(screen.getByText("我想加入学习编程")).toBeInTheDocument();
	});

	it("每个申请有通过/拒绝按钮", async () => {
		render(<RequestsPage />);

		const approveButtons = await screen.findAllByRole("button", {
			name: "通过",
		});
		expect(approveButtons).toHaveLength(2);
		const rejectButtons = await screen.findAllByRole("button", {
			name: "拒绝",
		});
		expect(rejectButtons).toHaveLength(2);
	});

	it("点击通过打开弹窗，默认无标签后确认", async () => {
		render(<RequestsPage />);

		const approveButtons = await screen.findAllByRole("button", {
			name: "通过",
		});
		fireEvent.click(approveButtons[0]);

		// 弹窗出现
		expect(
			await screen.findByRole("heading", { name: "审批通过" }),
		).toBeInTheDocument();
		expect(screen.queryByRole("checkbox", { name: "member" })).not.toBeInTheDocument();
		for (const role of ["tutor", "volunteer", "learner"]) {
			expect(screen.getByRole("checkbox", { name: role })).not.toBeChecked();
		}

		// 确认通过（默认无标签）
		fireEvent.click(screen.getByRole("button", { name: "确认通过" }));
		await waitFor(() => {
			expect(approveJoinRequest).toHaveBeenCalledWith("jr_1", []);
		});
	});

	it("点击拒绝打开弹窗，填原因后确认", async () => {
		render(<RequestsPage />);

		const rejectButtons = await screen.findAllByRole("button", {
			name: "拒绝",
		});
		fireEvent.click(rejectButtons[1]);

		// 弹窗出现
		expect(
			await screen.findByRole("heading", { name: "拒绝申请" }),
		).toBeInTheDocument();
		// 填写原因
		const textarea = screen.getByPlaceholderText("填写拒绝原因…");
		fireEvent.change(textarea, { target: { value: "名额已满" } });

		fireEvent.click(screen.getByRole("button", { name: "确认拒绝" }));
		await waitFor(() => {
			expect(rejectJoinRequest).toHaveBeenCalledWith("jr_2", "名额已满");
		});
	});

	it("ApprovalChip 显示倒计时", async () => {
		render(<RequestsPage />);

		// 两个申请都有 approvalDeadline，应显示倒计时 chip
		const chips = await screen.findAllByText(/剩余 \d+/);
		expect(chips.length).toBeGreaterThanOrEqual(1);
	});

	it("无 pending 申请时显示空态", async () => {
		fetchJoinRequests.mockResolvedValue({
			items: [],
			endKeyset: null,
			count: 0,
		});
		render(<RequestsPage />);

		expect(await screen.findByText("暂无待处理的加入申请")).toBeInTheDocument();
	});
});
