import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import type { FlashbackCapsuleArchive } from "@/lib/graphql/flashback";
import { FLASHBACK_ARCHIVES, FLASHBACK_CAPSULE } from "@/lib/graphql/flashback";
import EventDetail from "./event-detail";

/**
 * 场次页（E 的 event 步）：统计行 + 「这一场的人」3 列拍立得网格 + 找回 CTA。
 * 三级视角②的落点：参加过没回来的人从这里认领自己那张（雾卡 → 找回出口）。
 * #933：相册对所有已登录用户开放——未登录 → 登录页；已登录无档案 → 相册读面。
 */

const capsuleQuery = vi.fn();
const { replaceMock } = vi.hoisted(() => ({ replaceMock: vi.fn() }));

vi.mock("@/lib/apollo-client", () => ({
	client: {
		query: (options: { query: unknown; variables?: unknown }) => capsuleQuery(options),
	},
}));

vi.mock("@/i18n/navigation", () => ({
	Link: ({ href, children, ...rest }: { href: string; children: React.ReactNode } & Record<string, unknown>) => (
		<a href={href} {...rest}>
			{children}
		</a>
	),
	usePathname: () => "/flashback/event/2014-01-11-bj",
	useRouter: () => ({ push: vi.fn(), replace: replaceMock }),
}));

const archive: FlashbackCapsuleArchive = {
	key: "2014-01-11-bj",
	name: "Rails Girls 北京",
	city: "北京",
	occurredOn: "2014-01-11",
	appliedCount: 344,
	attendedCount: 3,
	isMine: false,
	piles: [],
	roster: [
		{
			id: "p1",
			surnameMasked: "王**",
			participation: "attended",
			fullName: null,
			city: "北京",
			occupationThen: "学生",
			appliedAt: "2013-12-06T05:06:00Z",
			sentToWallAt: null,
			answers: [],
			today: null,
		},
		{
			id: "p2",
			surnameMasked: "李*",
			participation: "attended",
			fullName: "李雷",
			city: "北京",
			occupationThen: "学生",
			appliedAt: "2013-12-07T05:06:00Z",
			sentToWallAt: "2026-09-10T00:00:00Z",
			answers: [],
			today: { nowStatus: "在做开发", want: null, say: null },
		},
		{
			id: "p3",
			surnameMasked: "周**",
			participation: "attended",
			fullName: null,
			city: "上海",
			occupationThen: "研究生",
			appliedAt: "2013-12-08T05:06:00Z",
			sentToWallAt: null,
			answers: [],
			today: null,
		},
		{
			// 圆梦线·未寄出（雾卡）：当年报了名未入选——徽标两态之一
			id: "p4",
			surnameMasked: "赵**",
			participation: "not_selected",
			fullName: null,
			city: "北京",
			occupationThen: "学生",
			appliedAt: "2013-12-05T05:06:00Z",
			sentToWallAt: null,
			answers: [],
			today: null,
		},
		{
			// 圆梦线·已寄出（点亮卡）：徽标两态之二
			id: "p5",
			surnameMasked: "钱*",
			participation: "not_selected",
			fullName: "钱进",
			city: "北京",
			occupationThen: "学生",
			appliedAt: "2013-12-09T05:06:00Z",
			sentToWallAt: "2026-09-11T00:00:00Z",
			answers: [{ questionKey: "self_intro", segments: [{ text: "一句当年答案。", fog: false, len: 0 }] }],
			today: { nowStatus: "还在写东西", want: null, say: null },
		},
	],
};

function withCapsule(archives: FlashbackCapsuleArchive[]) {
	capsuleQuery.mockResolvedValue({
		data: { flashbackCapsule: { me: {}, archives, futureEvents: [], publicWishes: [], myPrivateWishes: [], cities: [] } },
	});
}

beforeEach(() => {
	capsuleQuery.mockReset();
	replaceMock.mockReset();
	window.sessionStorage.clear();
});

afterEach(() => {
	cleanup();
	vi.restoreAllMocks();
});

describe("EventDetail · 场次页（E 的 event 步）", () => {
	it("统计行 + 3 列网格 + 找回 CTA（三级视角②出口）", async () => {
		withCapsule([archive]);
		render(<EventDetail eventKey="2014-01-11-bj" />);

		// 统计行：报名 / 走进教室 / 已回来（教练数本场缺失，不编造）
		// 名册扩员（attended + not_selected 混合 = 5 人）不变形：
		// 走进教室取后端 attendedCount 字段，已回来按寄出人数（含圆梦线寄出者）
		expect(await screen.findByText("报名 344 位")).toBeInTheDocument();
		expect(screen.getByText("走进教室 3 位")).toBeInTheDocument();
		expect(screen.getByText("2 位已回来")).toBeInTheDocument();

		// 名册 = 单形态 3 列网格（长廊只留城市堆，名册不再有错落 masonry 形态）
		const grid = screen.getByTestId("fb-roster-grid");
		expect(grid.className).toBe("fb-roster-grid");
		expect(grid.dataset.total).toBe("5");

		// 找回 CTA → 公开首页的自助找回入口
		const cta = screen.getByRole("link", { name: /找回你的那一张/ });
		expect(cta).toHaveAttribute("href", "/flashback");

		// 返回长廊
		expect(screen.getByRole("link", { name: /时间长廊/ })).toHaveAttribute("href", "/flashback/capsule");
	});

	it("已寄出=显影卡带名字；未回来=雾卡（姓氏隐名 + 答案还在等她）", async () => {
		withCapsule([archive]);
		render(<EventDetail eventKey="2014-01-11-bj" />);

		const sent = (await screen.findByText("李雷")).closest("[data-testid='fb-roster-card']") as HTMLElement;
		expect(sent.getAttribute("data-sent")).toBe("true");
		expect(sent.className).toContain("fb-roster-card--lit");

		const quiet = document.querySelector("[data-card-id='p1']") as HTMLElement;
		expect(quiet.textContent).toContain("王**");
		expect(quiet.textContent).toContain("她的答案，还在等她");
		// 未寄出者不泄露全名（R12：姓氏隐名，内容待点亮）
		expect(quiet.textContent).not.toContain("李雷");
		// #933：未寄出卡只有「王**」+ 状态语——城市与当年职业即使在数据里也不渲染（后端已不下发，前端双保险）
		const legacy = document.querySelector("[data-card-id='p3']") as HTMLElement;
		expect(legacy.textContent).not.toContain("上海");
		expect(legacy.textContent).not.toContain("研究生");
	});

	it("圆梦线徽标只在已寄出卡上：未寄出雾卡不显示（#933 参与类型不对外）；attended 卡无徽标", async () => {
		withCapsule([archive]);
		render(<EventDetail eventKey="2014-01-11-bj" />);
		await screen.findByText("报名 344 位");

		// 雾卡态（p4 未寄出 not_selected）：即使数据里带了参与类型也不渲染徽标
		const fogCard = document.querySelector("[data-card-id='p4']") as HTMLElement;
		expect(fogCard.getAttribute("data-sent")).toBe("false");
		expect(fogCard.textContent).not.toContain("当年报了名");
		expect(fogCard.textContent).toContain("她的答案，还在等她");

		// 点亮卡态（p5 已寄出 not_selected，走 PolaroidFlip 卡面）
		const litCard = document.querySelector("[data-card-id='p5']") as HTMLElement;
		expect(litCard.getAttribute("data-sent")).toBe("true");
		expect(litCard.textContent).toContain("当年报了名");
		expect(litCard.textContent).toContain("钱进");

		// attended 两张卡（p1 未寄出 / p2 已寄出）均无徽标
		expect((document.querySelector("[data-card-id='p1']") as HTMLElement).textContent).not.toContain("当年报了名");
		expect((document.querySelector("[data-card-id='p2']") as HTMLElement).textContent).not.toContain("当年报了名");

		// 徽标计数钉死 = 已寄出的 not_selected 数（1）
		expect(screen.getAllByText("当年报了名")).toHaveLength(1);
	});

	it("attendedCount 缺失（导入未带该列）→ 不显示走进教室，不编造（#933 起未寄出者不下发参与类型，名册数不出）", async () => {
		withCapsule([{ ...archive, attendedCount: null }]);
		render(<EventDetail eventKey="2014-01-11-bj" />);

		expect(await screen.findByText("报名 344 位")).toBeInTheDocument();
		expect(screen.queryByText(/走进教室/)).not.toBeInTheDocument();
	});

	it("报名数缺失（导入未带该列）→ 不显示该格，不编造 0", async () => {
		withCapsule([{ ...archive, appliedCount: null }]);
		render(<EventDetail eventKey="2014-01-11-bj" />);

		expect(await screen.findByText("走进教室 3 位")).toBeInTheDocument();
		expect(screen.queryByText(/报名/)).not.toBeInTheDocument();
	});

	it("场次不在名册里 → 明确出口（不空转）", async () => {
		withCapsule([archive]);
		render(<EventDetail eventKey="2099-01-01-xx" />);

		expect(await screen.findByText(/不在你的名册里/)).toBeInTheDocument();
		await waitFor(() => expect(capsuleQuery).toHaveBeenCalled());
	});

	it("token 失效 → 失效落地页（自助找回出口）", async () => {
		capsuleQuery.mockRejectedValue({
			graphQLErrors: [{ message: "gone", extensions: { code: "flashback_token_revoked" } }],
		});
		render(<EventDetail eventKey="2014-01-11-bj" />);

		expect(await screen.findByText("这封信已被收回")).toBeInTheDocument();
	});

	it("#933 未登录 → 登录页，登录后回到这一场（不渲染任何名册）", async () => {
		capsuleQuery.mockRejectedValue({
			graphQLErrors: [{ message: "sign in", extensions: { code: "flashback_auth_required" } }],
		});
		const view = render(<EventDetail eventKey="2014-01-11-bj" />);

		await waitFor(() =>
			expect(replaceMock).toHaveBeenCalledWith(`/login?next=${encodeURIComponent("/flashback/event/2014-01-11-bj")}`),
		);
		// 跳转在 effect 里只发一次：父组件重渲染不再重复导航（此前在渲染期调用 router.replace）
		view.rerender(<EventDetail eventKey="2014-01-11-bj" />);
		expect(replaceMock).toHaveBeenCalledTimes(1);
		expect(screen.queryByTestId("fb-roster-grid")).not.toBeInTheDocument();
	});

	it("#933 已登录无档案 → 相册读面看完整名册；找回出口仍在；返回闪念间首页（不回胶囊）", async () => {
		capsuleQuery.mockImplementation(({ query }: { query: unknown }) =>
			query === FLASHBACK_ARCHIVES
				? Promise.resolve({ data: { flashbackArchives: { archives: [archive], cities: [] } } })
				: Promise.reject({ graphQLErrors: [{ message: "not bound", extensions: { code: "flashback_person_not_bound" } }] }),
		);
		render(<EventDetail eventKey="2014-01-11-bj" />);

		expect(await screen.findByTestId("fb-roster-grid")).toHaveAttribute("data-total", "5");
		expect(screen.getByText("2 位已回来")).toBeInTheDocument();
		expect(screen.getByRole("link", { name: /找回你的那一张/ })).toHaveAttribute("href", "/flashback");
		expect(screen.getByRole("link", { name: "‹ 闪念间" })).toHaveAttribute("href", "/flashback");
		expect(replaceMock).not.toHaveBeenCalled();
	});

	it("#933 已登录无档案且这一场不存在 → 明确出口（不空转）", async () => {
		capsuleQuery.mockImplementation(({ query }: { query: unknown }) =>
			query === FLASHBACK_ARCHIVES
				? Promise.resolve({ data: { flashbackArchives: { archives: [archive], cities: [] } } })
				: Promise.reject({ graphQLErrors: [{ message: "not bound", extensions: { code: "flashback_person_not_bound" } }] }),
		);
		render(<EventDetail eventKey="2099-01-01-xx" />);

		expect(await screen.findByText(/不在你的名册里/)).toBeInTheDocument();
	});

	it("复用 capsule 投影（不新增读面）：一次查询带 eventKey 过滤在客户端完成", async () => {
		withCapsule([archive]);
		render(<EventDetail eventKey="2014-01-11-bj" />);
		await screen.findByText("报名 344 位");

		expect(capsuleQuery).toHaveBeenCalledTimes(1);
		expect(capsuleQuery.mock.calls[0][0].query).toBe(FLASHBACK_CAPSULE);
	});
});
