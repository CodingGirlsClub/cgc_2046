import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import ParticipationsPage from "./page";
import { MY_ENROLLMENTS, MY_LEARNING_RUNS, MY_SPONSORSHIPS } from "@/lib/graphql/participations";

const { router } = vi.hoisted(() => ({
	router: { push: vi.fn(), replace: vi.fn() },
}));
const { useQuery } = vi.hoisted(() => ({ useQuery: vi.fn() }));
const { mutate } = vi.hoisted(() => ({ mutate: vi.fn() }));

const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));
const tabState: { tab: string | null } = vi.hoisted(() => ({ tab: null }));

vi.mock("next/navigation", () => ({
	useRouter: () => router,
	usePathname: () => "/participations",
	// U8 tab 状态由 URL ?tab= 承载;用例按需切 tab(默认学习 tab)
	useSearchParams: () => new URLSearchParams(tabState.tab ? `tab=${tabState.tab}` : ""),
}));
vi.mock("@/lib/use-authed", () => ({ useAuthed }));
vi.mock("@apollo/client/react", () => ({ useQuery }));
vi.mock("@/lib/apollo-client", () => ({ client: { mutate } }));

const ENROLLMENT = {
	id: "enr-1",
	status: "pending",
	targetTitle: "教研分享会",
	eventId: "event-1",
	courseId: null,
	approvedAt: null,
	rejectionReason: null,
	approvalDeadline: "2026-08-20T00:00:00Z",
	expiredAt: null,
	cancelledAt: null,
	insertedAt: "2026-08-10T00:00:00Z",
};

const CANCELLED_ENROLLMENT = {
	...ENROLLMENT,
	id: "enr-old",
	status: "cancelled",
	cancelledAt: "2026-08-11T00:00:00Z",
};

const SPONSORSHIP = {
	id: "sponsor-1",
	level: "event",
	status: "active",
	tierName: "冠名",
	amount: 20000,
	targetTitle: "教研分享会",
	approvedAt: "2026-08-09T00:00:00Z",
	rejectionReason: null,
	endedAt: null,
	deliveries: [
		{ benefit: "主会场 Logo 展示", dueDate: null, fulfilledAt: "2026-08-10T00:00:00Z" },
		{ benefit: "公众号推文", dueDate: "2026-08-30T00:00:00Z", fulfilledAt: null },
	],
};

const LEARNING_RUN = {
	runId: "run-1",
	enrollmentId: "enr-1",
	targetTitle: "教研分享会",
	status: "waiting",
	doneIssues: 1,
	totalIssues: 3,
	currentIssueId: "py-02",
	currentIssueTitle: "变量与数据",
	currentIssueKey: "PYTH-02",
	courseId: "course-1",
};

function mockQuery({
	enrollments = [ENROLLMENT, CANCELLED_ENROLLMENT],
	sponsorships = [SPONSORSHIP],
	learningRuns = [LEARNING_RUN],
	enrollmentPage = {},
	sponsorshipPage = {},
} = {}) {
	const states = {
		enrollments: {
			data: {
				myEnrollments: {
					count: enrollments.length,
					results: enrollments,
					startKeyset: null,
					endKeyset: null,
					...enrollmentPage,
				},
			},
			loading: false,
			error: undefined,
			refetch: vi.fn().mockResolvedValue(undefined),
			fetchMore: vi.fn().mockResolvedValue(undefined),
		},
		sponsorships: {
			data: {
				mySponsorships: {
					count: sponsorships.length,
					results: sponsorships,
					startKeyset: null,
					endKeyset: null,
					...sponsorshipPage,
				},
			},
			loading: false,
			error: undefined,
			refetch: vi.fn().mockResolvedValue(undefined),
			fetchMore: vi.fn().mockResolvedValue(undefined),
		},
		learning: {
			data: { myLearningRuns: learningRuns },
			loading: false,
			error: undefined,
		},
	};

	useQuery.mockImplementation((query: unknown) => {
		if (query === MY_ENROLLMENTS) return states.enrollments;
		if (query === MY_SPONSORSHIPS) return states.sponsorships;
		if (query === MY_LEARNING_RUNS) return states.learning;
		throw new Error("unexpected query");
	});

	return states;
}

beforeEach(() => {
	vi.clearAllMocks();
	useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "user-1" });
});

afterEach(cleanup);

describe("/participations 我的参与", () => {
	it("渲染报名、赞助交付与学习进度三段数据（U8 三 tab 分面）", () => {
		mockQuery();

		// 报名 tab
		tabState.tab = "enrollments";
		render(<ParticipationsPage />);
		expect(screen.getByRole("heading", { name: "我的参与" })).toBeInTheDocument();
		expect(screen.getByRole("heading", { name: "我的报名" })).toBeInTheDocument();
		expect(screen.getByText("等待审批")).toBeInTheDocument();
		expect(screen.getByText("已取消")).toBeInTheDocument();
		cleanup();

		// 赞助 tab
		tabState.tab = "sponsorships";
		render(<ParticipationsPage />);
		expect(screen.getByRole("heading", { name: "我的赞助" })).toBeInTheDocument();
		expect(screen.getByText("主会场 Logo 展示")).toBeInTheDocument();
		expect(screen.getByText("已完成")).toBeInTheDocument();
		expect(screen.getByText("公众号推文")).toBeInTheDocument();
		expect(screen.getByText(/待履约/)).toBeInTheDocument();
		cleanup();

		// 学习 tab（默认）
		tabState.tab = null;
		render(<ParticipationsPage />);
		expect(screen.getByRole("heading", { name: "我的学习" })).toBeInTheDocument();
		// 行内进度:doneIssues/totalIssues 与静态文案同 span(textContent 匹配)
		expect(
			screen.getByText((_, el) => el?.textContent === "学习进度：1/3 节"),
		).toBeInTheDocument();
		expect(screen.getByText("等待中")).toBeInTheDocument();
		expect(screen.getByText("PYTH-02")).toBeInTheDocument();
		expect(screen.getByText("变量与数据")).toBeInTheDocument();
	});

	it("未登录跳转登录页", () => {
		useAuthed.mockReturnValue({ authed: false, confirmed: true, userId: null });
		mockQuery({ enrollments: [], sponsorships: [], learningRuns: [] });
		{
		// 用例主体是报名/赞助面 → 报名 tab(学习为默认 tab)
		tabState.tab = "enrollments";
		render(<ParticipationsPage />);
	}

		expect(router.replace).toHaveBeenCalledWith("/login?next=%2Fparticipations");
	});

	it("取消报名先二次确认，成功后 mutation 并刷新报名列表", async () => {
		const states = mockQuery({ enrollments: [ENROLLMENT] });
		mutate.mockResolvedValue({
			data: {
				cancelEnrollment: {
					result: { id: ENROLLMENT.id, status: "cancelled", cancelledAt: "2026-08-12T00:00:00Z" },
					errors: [],
				},
			},
		});
		{
		// 用例主体是报名/赞助面 → 报名 tab(学习为默认 tab)
		tabState.tab = "enrollments";
		render(<ParticipationsPage />);
	}

		fireEvent.click(screen.getByRole("button", { name: "取消报名" }));
		expect(screen.getByRole("group", { name: "确认取消报名" })).toHaveTextContent(
			"名额将即时释放",
		);
		expect(screen.getByRole("group", { name: "确认取消报名" })).toHaveTextContent("不可恢复");
		fireEvent.click(screen.getByRole("button", { name: "确认取消报名" }));

		await waitFor(() =>
			expect(mutate).toHaveBeenCalledWith(
				expect.objectContaining({ variables: { id: ENROLLMENT.id } }),
			),
		);
		await waitFor(() => expect(states.enrollments.refetch).toHaveBeenCalledOnce());
	});

	it("already_processed 取消结果也刷新，不显示错误", async () => {
		const states = mockQuery({ enrollments: [ENROLLMENT] });
		mutate.mockResolvedValue({
			data: {
				cancelEnrollment: {
					result: null,
					errors: [
						{ code: "enrollment_already_processed", message: "already processed" },
					],
				},
			},
		});
		{
		// 用例主体是报名/赞助面 → 报名 tab(学习为默认 tab)
		tabState.tab = "enrollments";
		render(<ParticipationsPage />);
	}

		fireEvent.click(screen.getByRole("button", { name: "取消报名" }));
		fireEvent.click(screen.getByRole("button", { name: "确认取消报名" }));

		await waitFor(() => expect(states.enrollments.refetch).toHaveBeenCalledOnce());
		expect(screen.queryByRole("alert")).not.toBeInTheDocument();
	});

	it("无更多数据时隐藏加载更多，存在下一页时按 keyset 请求", async () => {
		const states = mockQuery({
			enrollments: [ENROLLMENT],
			enrollmentPage: { count: 2, endKeyset: "enrollment-next" },
			sponsorshipPage: { count: 2, endKeyset: "sponsorship-next" },
		});
		{
		// 用例主体是报名/赞助面 → 报名 tab(学习为默认 tab)
		tabState.tab = "enrollments";
		render(<ParticipationsPage />);
	}

		// U8 tab 制:报名与赞助分屏,各屏一个「加载更多」
		const moreButtons = screen.getAllByRole("button", { name: "加载更多" });
		expect(moreButtons).toHaveLength(1);
		fireEvent.click(moreButtons[0]);
		await waitFor(() => expect(states.enrollments.fetchMore).toHaveBeenCalledOnce());
		expect(states.enrollments.fetchMore).toHaveBeenCalledWith(
			expect.objectContaining({ variables: { first: 20, after: "enrollment-next" } }),
		);
		cleanup();

		// 赞助 tab 同语义(keyset 透传)
		tabState.tab = "sponsorships";
		render(<ParticipationsPage />);
		const sponsorshipMore = screen.getAllByRole("button", { name: "加载更多" });
		expect(sponsorshipMore).toHaveLength(1);
		fireEvent.click(sponsorshipMore[0]);
		await waitFor(() => expect(states.sponsorships.fetchMore).toHaveBeenCalledOnce());
		expect(states.sponsorships.fetchMore).toHaveBeenCalledWith(
			expect.objectContaining({ variables: { first: 20, after: "sponsorship-next" } }),
		);
	});
});
