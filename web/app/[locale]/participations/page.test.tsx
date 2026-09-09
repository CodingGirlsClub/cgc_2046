import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import ParticipationsPage, { splitEnrollments } from "./page";
import {
	MY_ENROLLMENTS,
	MY_SPONSORSHIPS,
	type ParticipationEnrollment,
} from "@/lib/graphql/participations";

const { router } = vi.hoisted(() => ({
	router: { push: vi.fn(), replace: vi.fn() },
}));
const { useQuery } = vi.hoisted(() => ({ useQuery: vi.fn() }));
const { mutate } = vi.hoisted(() => ({ mutate: vi.fn() }));

const { useAuthed } = vi.hoisted(() => ({ useAuthed: vi.fn() }));
const tabState: { tab: string | null } = vi.hoisted(() => ({ tab: null }));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useRouter: () => router,
	usePathname: () => "/participations",
	// P2b 后 tab 只剩 报名(默认)/赞助;?tab=learning 旧链接重定向 /learning
	useSearchParams: () => new URLSearchParams(tabState.tab ? `tab=${tabState.tab}` : ""),
}));
vi.mock("@/lib/use-authed", () => ({ useAuthed }));
vi.mock("@apollo/client/react", () => ({ useQuery }));
vi.mock("@/lib/apollo-client", () => ({ client: { mutate } }));

const ENROLLMENT: ParticipationEnrollment = {
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
	startsAt: null,
	venue: null,
};

const CANCELLED_ENROLLMENT = {
	...ENROLLMENT,
	id: "enr-old",
	status: "cancelled" as const,
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

function mockQuery({
	enrollments = [ENROLLMENT, CANCELLED_ENROLLMENT],
	sponsorships = [SPONSORSHIP],
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
	};

	useQuery.mockImplementation((query: unknown) => {
		if (query === MY_ENROLLMENTS) return states.enrollments;
		if (query === MY_SPONSORSHIPS) return states.sponsorships;
		throw new Error("unexpected query");
	});

	return states;
}

beforeEach(() => {
	vi.clearAllMocks();
	useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "user-1" });
	tabState.tab = null;
});

afterEach(cleanup);

describe("/participations 我的参与（P2b：报名默认 tab + 赞助）", () => {
	it("默认渲染报名 tab（含 startsAt/venue），赞助 tab 渲染交付数据", () => {
		mockQuery({
			enrollments: [
				{ ...ENROLLMENT, startsAt: "2099-01-01T00:00:00Z", venue: "上海 徐汇" },
				CANCELLED_ENROLLMENT,
			],
		});

		// 默认（无 ?tab=）→ 报名 tab
		render(<ParticipationsPage />);
		expect(screen.getByRole("heading", { name: "我的参与" })).toBeInTheDocument();
		expect(screen.getByRole("heading", { name: "我的报名" })).toBeInTheDocument();
		expect(screen.getByText("等待审批")).toBeInTheDocument();
		expect(screen.getByText("已取消")).toBeInTheDocument();
		// P2a：卡片显示开始时间与地点
		expect(screen.getByTestId("starts-at-enr-1").textContent).toContain("开始时间");
		expect(screen.getByTestId("venue-enr-1").textContent).toContain("上海 徐汇");
		cleanup();

		// 赞助 tab
		tabState.tab = "sponsorships";
		render(<ParticipationsPage />);
		expect(screen.getByRole("heading", { name: "我的赞助" })).toBeInTheDocument();
		expect(screen.getByText("主会场 Logo 展示")).toBeInTheDocument();
		expect(screen.getByText("已完成")).toBeInTheDocument();
		expect(screen.getByText("公众号推文")).toBeInTheDocument();
		expect(screen.getByText(/待履约/)).toBeInTheDocument();
	});

	it("旧 ?tab=learning 链接重定向到 /learning（P2b IA 分家）", () => {
		mockQuery();
		tabState.tab = "learning";
		render(<ParticipationsPage />);
		expect(router.replace).toHaveBeenCalledWith("/learning");
	});

	it("P2a 时间感知分组：即将开始升序置顶，时间已过的活跃报名进「已结束」小节", () => {
		const future1 = { ...ENROLLMENT, id: "enr-f1", targetTitle: "远期活动", startsAt: "2099-06-01T00:00:00Z" };
		const future2 = { ...ENROLLMENT, id: "enr-f2", targetTitle: "近期活动", startsAt: "2099-01-01T00:00:00Z" };
		const pastActive = { ...ENROLLMENT, id: "enr-past", targetTitle: "已举行活动", status: "confirmed" as const, startsAt: "2020-01-01T00:00:00Z" };
		mockQuery({ enrollments: [pastActive, future1, ENROLLMENT, future2] });

		render(<ParticipationsPage />);

		const upcoming = screen.getByTestId("upcoming-section");
		// 即将开始按 startsAt 升序：近期在前
		const order = [...upcoming.querySelectorAll("article")].map((a) =>
			a.getAttribute("data-testid"),
		);
		expect(order).toEqual(["enrollment-enr-f2", "enrollment-enr-f1"]);

		// startsAt 已过但 status 仍 confirmed → 单独「已结束」小节，不在进行中
		const past = screen.getByTestId("past-section");
		expect(past.querySelector('[data-testid="enrollment-enr-past"]')).not.toBeNull();
		const activeHead = screen.getByText("进行中").parentElement!;
		expect(activeHead.querySelector('[data-testid="enrollment-enr-past"]')).toBeNull();
	});

	it("confirmed 课程报名 → 「进入课程」直达内容页（P1-4）", () => {
		mockQuery({
			enrollments: [
				{
					...ENROLLMENT,
					id: "enr-course",
					status: "confirmed",
					targetTitle: "示例课程",
					eventId: null,
					courseId: "course-42",
				},
			],
		});

		render(<ParticipationsPage />);

		const link = screen.getByTestId("enter-course-enr-course");
		expect(link.getAttribute("href")).toContain("/learning/courses/course-42");
		expect(link.textContent).toContain("进入课程");
	});

	it("未登录跳转登录页", () => {
		useAuthed.mockReturnValue({ authed: false, confirmed: true, userId: null });
		mockQuery({ enrollments: [], sponsorships: [] });
		render(<ParticipationsPage />);

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
		render(<ParticipationsPage />);

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
		render(<ParticipationsPage />);

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
		render(<ParticipationsPage />);

		// P2b tab 制:报名与赞助分屏,各屏一个「加载更多」
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

describe("splitEnrollments（P2a 分组纯函数）", () => {
	const NOW = new Date("2026-09-09T00:00:00Z").getTime();
	const row = (over: Partial<ParticipationEnrollment>): ParticipationEnrollment => ({
		...ENROLLMENT,
		...over,
	});

	it("未来 startsAt 升序；无 startsAt 的活跃报名留在进行中；终态不受 startsAt 影响", () => {
		const rows = [
			row({ id: "b", startsAt: "2026-10-02T00:00:00Z" }),
			row({ id: "a", startsAt: "2026-10-01T00:00:00Z" }),
			row({ id: "no-time", startsAt: null }),
			row({ id: "bad-time", startsAt: "not-a-date" }),
			row({ id: "past", status: "confirmed", startsAt: "2026-01-01T00:00:00Z" }),
			row({ id: "ended", status: "cancelled", startsAt: "2099-01-01T00:00:00Z" }),
		];
		const { upcoming, active, past, ended } = splitEnrollments(rows, NOW);
		expect(upcoming.map((r) => r.id)).toEqual(["a", "b"]);
		expect(active.map((r) => r.id)).toEqual(["no-time", "bad-time"]);
		expect(past.map((r) => r.id)).toEqual(["past"]);
		expect(ended.map((r) => r.id)).toEqual(["ended"]);
	});
});
