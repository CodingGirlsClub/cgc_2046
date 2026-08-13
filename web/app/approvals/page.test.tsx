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
		expect(screen.getByText(/申请者可重新提交/)).toBeInTheDocument();
		expect(screen.queryByRole("button", { name: "通过" })).not.toBeInTheDocument();
		expect(screen.getByText("暂无待审批项。")).toBeInTheDocument();
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
