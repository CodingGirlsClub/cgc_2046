import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import ApprovalsPage from "./page";

const { router } = vi.hoisted(() => ({
	router: { push: vi.fn(), replace: vi.fn() },
}));
const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));
const { useQuery } = vi.hoisted(() => ({ useQuery: vi.fn() }));
const { mutate } = vi.hoisted(() => ({ mutate: vi.fn() }));
const { approveJoinRequest } = vi.hoisted(() => ({
	approveJoinRequest: vi.fn(),
}));
const { rejectJoinRequest } = vi.hoisted(() => ({
	rejectJoinRequest: vi.fn(),
}));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useRouter: () => router,
	usePathname: () => "/approvals",
	useSearchParams: () => new URLSearchParams(),
}));
vi.mock("@/lib/use-authed", () => ({ useAuthed }));
vi.mock("@apollo/client/react", () => ({ useQuery }));
vi.mock("@/lib/apollo-client", () => ({ client: { mutate } }));
vi.mock("@/lib/requests", () => ({ approveJoinRequest, rejectJoinRequest }));

const PENDING_ENROLLMENT = {
	id: "enr-1",
	kind: "enrollment",
	workspaceId: "ws-1",
	userId: "u-1",
	eventId: "ev-1",
	courseId: null,
	status: "pending",
	approvalDeadline: new Date(Date.now() + 24 * 3600 * 1000).toISOString(),
	expiredAt: null,
	requesterName: "申请者甲",
	workspaceName: "CGC 学院",
	contextTitle: "教研分享会",
};

const PENDING_JOIN = {
	id: "jr-1",
	kind: "join_request",
	workspaceId: "ws-1",
	userId: "u-2",
	eventId: null,
	courseId: null,
	status: "pending",
	approvalDeadline: new Date(Date.now() + 72 * 3600 * 1000).toISOString(),
	expiredAt: null,
	requesterName: "申请者乙",
	workspaceName: "CGC 学院",
	contextTitle: "CGC 学院",
};

const EXPIRED_ROW = {
	...PENDING_ENROLLMENT,
	id: "enr-old",
	status: "expired",
	expiredAt: new Date(Date.now() - 3600 * 1000).toISOString(),
};

function mockQuery(rows: unknown[]) {
	useQuery.mockReturnValue({
		data: { myPendingApprovals: rows },
		loading: false,
		error: undefined,
		refetch: vi.fn(),
	});
}

beforeEach(() => {
	vi.clearAllMocks();
	useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "owner-1" });
});

afterEach(cleanup);

describe("E-8 #123 审批控制台", () => {
	it("pending 行渲染 D7 形状：kind/requester 摘要/context 摘要/倒计时；48h 内显示紧急脉冲", () => {
		mockQuery([PENDING_ENROLLMENT, PENDING_JOIN]);
		render(<ApprovalsPage />);

		expect(screen.getByText("活动报名")).toBeInTheDocument();
		expect(screen.getByText("加入申请")).toBeInTheDocument();
		expect(screen.getByText("申请者甲")).toBeInTheDocument();
		expect(screen.getByText(/教研分享会 · CGC 学院/)).toBeInTheDocument();
		// 24h 截止 → 紧急 chip（脉冲圆点 + 剩余小时）
		expect(screen.getByText(/剩余 2[34]h/)).toBeInTheDocument();
	});

	it("enrollment 通过 → confirmEnrollment mutation；join_request 通过 → approveJoinRequest", async () => {
		const refetch = vi.fn();
		useQuery.mockReturnValue({
			data: { myPendingApprovals: [PENDING_ENROLLMENT, PENDING_JOIN] },
			loading: false,
			error: undefined,
			refetch,
		});
		mutate.mockResolvedValue({
			data: { confirmEnrollment: { result: { id: "enr-1", status: "confirmed" } } },
		});
		approveJoinRequest.mockResolvedValue({});

		render(<ApprovalsPage />);
		const approveButtons = screen.getAllByRole("button", { name: "通过" });
		fireEvent.click(approveButtons[0]);
		await waitFor(() => expect(mutate).toHaveBeenCalledOnce());
		expect(mutate.mock.calls[0][0].variables).toEqual({ id: "enr-1" });
		await waitFor(() => expect(refetch).toHaveBeenCalled());

		fireEvent.click(screen.getAllByRole("button", { name: "通过" })[1]);
		await waitFor(() => expect(approveJoinRequest).toHaveBeenCalledWith("jr-1"));
	});

	it("拒绝：展开原因输入 → rejectEnrollment 携带 rejectionReason", async () => {
		useQuery.mockReturnValue({
			data: { myPendingApprovals: [PENDING_ENROLLMENT] },
			loading: false,
			error: undefined,
			refetch: vi.fn(),
		});
		mutate.mockResolvedValue({
			data: { rejectEnrollment: { result: { id: "enr-1", status: "rejected" } } },
		});

		render(<ApprovalsPage />);
		fireEvent.click(screen.getByRole("button", { name: "拒绝" }));
		fireEvent.change(screen.getByLabelText("拒绝原因"), {
			target: { value: "名额已满" },
		});
		fireEvent.click(screen.getByRole("button", { name: "确认拒绝" }));

		await waitFor(() => expect(mutate).toHaveBeenCalledOnce());
		expect(mutate.mock.calls[0][0].variables).toEqual({
			id: "enr-1",
			input: { rejectionReason: "名额已满" },
		});
	});

	it("expired 区只读展示「已过期」+ 过期时间，无通过/拒绝按钮", () => {
		mockQuery([EXPIRED_ROW]);
		render(<ApprovalsPage />);

		expect(screen.getByText("已过期")).toBeInTheDocument();
		expect(screen.getByText(/审批超时的申请不可再通过或拒绝/)).toBeInTheDocument();
		expect(screen.queryByRole("button", { name: "通过" })).not.toBeInTheDocument();
		expect(screen.getByText("暂无待审批项。")).toBeInTheDocument();
	});

	it("E-9 deadline 时序边界：pending 行 deadline 已过 → 无通过/拒绝按钮", () => {
		mockQuery([
			{
				...PENDING_ENROLLMENT,
				approvalDeadline: new Date(Date.now() - 60 * 1000).toISOString(),
			},
		]);
		render(<ApprovalsPage />);

		// ApprovalExpiryWorker 落库前短窗口：按钮按行级 deadline 守卫不渲染
		expect(screen.queryByRole("button", { name: "通过" })).not.toBeInTheDocument();
		expect(screen.queryByRole("button", { name: "拒绝" })).not.toBeInTheDocument();
		expect(screen.getByText("审批已超时，等待系统更新状态。")).toBeInTheDocument();
		// chip 与按钮同源判定：deadline 已过 → chip 显示「已过期」
		expect(screen.getByText("已过期")).toBeInTheDocument();
	});

	it("E-9 deadline 时序边界：pending 行 deadline 未过 → 正常渲染操作按钮", () => {
		mockQuery([PENDING_ENROLLMENT]);
		render(<ApprovalsPage />);

		expect(screen.getByRole("button", { name: "通过" })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "拒绝" })).toBeInTheDocument();
	});

	it("未登录 → 跳 /login?next=/approvals", () => {
		useAuthed.mockReturnValue({ authed: false, confirmed: true, userId: null });
		mockQuery([]);
		render(<ApprovalsPage />);
		expect(router.replace).toHaveBeenCalledWith(
			`/login?next=${encodeURIComponent("/approvals")}`,
		);
	});
});

const PENDING_SPONSORSHIP = {
	id: "sp-1",
	kind: "sponsorship",
	workspaceId: "ws-1",
	userId: "u-3",
	eventId: "ev-1",
	courseId: null,
	status: "pending",
	approvalDeadline: new Date(Date.now() + 48 * 3600 * 1000).toISOString(),
	expiredAt: null,
	requesterName: "Acme 冠名",
	workspaceName: "CGC 学院",
	contextTitle: "教研分享会",
	level: "event",
	companyName: "Acme 冠名",
	contactEmail: null,
	tierName: "冠名",
	amount: 10_000,
};

describe("E-3 #48 sponsorship kind dispatch", () => {
	it("赞助行渲染 kind 标签 + 档位名；通过 → approveSponsorship(id)", async () => {
		const refetch = vi.fn();
		useQuery.mockReturnValue({
			data: { myPendingApprovals: [PENDING_SPONSORSHIP] },
			loading: false,
			error: undefined,
			refetch,
		});
		mutate.mockResolvedValue({
			data: { approveSponsorship: { result: { id: "sp-1", status: "active" } } },
		});

		render(<ApprovalsPage />);
		expect(screen.getByText("活动赞助")).toBeInTheDocument();
		expect(screen.getByText(/教研分享会 · CGC 学院 · 冠名/)).toBeInTheDocument();

		fireEvent.click(screen.getByRole("button", { name: "通过" }));
		await waitFor(() => expect(mutate).toHaveBeenCalledOnce());
		expect(mutate.mock.calls[0][0].variables).toEqual({ id: "sp-1" });
		await waitFor(() => expect(refetch).toHaveBeenCalled());
	});

	it("拒绝 → rejectSponsorship 携带 rejectionReason", async () => {
		useQuery.mockReturnValue({
			data: { myPendingApprovals: [PENDING_SPONSORSHIP] },
			loading: false,
			error: undefined,
			refetch: vi.fn(),
		});
		mutate.mockResolvedValue({
			data: { rejectSponsorship: { result: { id: "sp-1", status: "rejected" } } },
		});

		render(<ApprovalsPage />);
		fireEvent.click(screen.getByRole("button", { name: "拒绝" }));
		fireEvent.change(screen.getByLabelText("拒绝原因"), {
			target: { value: "物料不符合" },
		});
		fireEvent.click(screen.getByRole("button", { name: "确认拒绝" }));

		await waitFor(() => expect(mutate).toHaveBeenCalledOnce());
		expect(mutate.mock.calls[0][0].variables).toEqual({
			id: "sp-1",
			input: { rejectionReason: "物料不符合" },
		});
	});

	it("approve 失败（如 Workspace 级 Admin 越权）回显后端错误", async () => {
		useQuery.mockReturnValue({
			data: {
				myPendingApprovals: [{ ...PENDING_SPONSORSHIP, level: "workspace", eventId: null }],
			},
			loading: false,
			error: undefined,
			refetch: vi.fn(),
		});
		mutate.mockResolvedValue({
			data: {
				approveSponsorship: {
					result: null,
					errors: [{ message: "forbidden" }],
				},
			},
		});

		render(<ApprovalsPage />);
		fireEvent.click(screen.getByRole("button", { name: "通过" }));
		await waitFor(() =>
			expect(screen.getByRole("alert")).toHaveTextContent("forbidden"),
		);
	});
});

const EXPIRED_LINK_COPY = "已过期 · 申请者可重新提交";

describe("E-9 #123 expired 重提链接", () => {
	it("enrollment → /participations（014 我的报名页）", () => {
		mockQuery([EXPIRED_ROW]);
		render(<ApprovalsPage />);

		expect(screen.getByRole("link", { name: EXPIRED_LINK_COPY })).toHaveAttribute(
			"href",
			"/participations",
		);
	});

	it("join_request → /join?workspace=<slug>", () => {
		mockQuery([
			{
				...PENDING_JOIN,
				id: "jr-old",
				status: "expired",
				expiredAt: new Date(Date.now() - 3600 * 1000).toISOString(),
				workspaceSlug: "cgc-academy",
			},
		]);
		render(<ApprovalsPage />);

		expect(screen.getByRole("link", { name: EXPIRED_LINK_COPY })).toHaveAttribute(
			"href",
			"/join?workspace=cgc-academy",
		);
	});

	it("sponsorship event 级 → 目标活动公开页 /events/<slug>", () => {
		mockQuery([
			{
				...PENDING_SPONSORSHIP,
				id: "sp-old",
				status: "expired",
				expiredAt: new Date(Date.now() - 3600 * 1000).toISOString(),
				eventSlug: "meetup-2026",
			},
		]);
		render(<ApprovalsPage />);

		expect(screen.getByRole("link", { name: EXPIRED_LINK_COPY })).toHaveAttribute(
			"href",
			"/events/meetup-2026",
		);
	});

	it("sponsorship workspace 级 → /w/<slug> 并注明无公开赞助入口", () => {
		mockQuery([
			{
				...PENDING_SPONSORSHIP,
				id: "sp-ws-old",
				level: "workspace",
				eventId: null,
				status: "expired",
				expiredAt: new Date(Date.now() - 3600 * 1000).toISOString(),
				workspaceSlug: "cgc-academy",
			},
		]);
		render(<ApprovalsPage />);

		expect(screen.getByRole("link", { name: EXPIRED_LINK_COPY })).toHaveAttribute(
			"href",
			"/w/cgc-academy",
		);
		expect(screen.getByText(/该工作台无公开赞助入口/)).toBeInTheDocument();
	});

	it("slug 缺失（历史行）→ 降级纯文本不渲染链接", () => {
		mockQuery([
			{
				...PENDING_JOIN,
				id: "jr-noslug",
				status: "expired",
				expiredAt: new Date(Date.now() - 3600 * 1000).toISOString(),
				workspaceSlug: null,
			},
		]);
		render(<ApprovalsPage />);

		expect(screen.queryByRole("link", { name: EXPIRED_LINK_COPY })).not.toBeInTheDocument();
		expect(screen.getByText(EXPIRED_LINK_COPY)).toBeInTheDocument();
	});
});

