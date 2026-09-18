import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import type { FlashbackCapsuleArchive } from "@/lib/graphql/flashback";
import { FLASHBACK_CAPSULE } from "@/lib/graphql/flashback";
import EventDetail from "./event-detail";

/**
 * 场次页（E 的 event 步）：统计行 + 「这一场的人」3 列拍立得网格 + 找回 CTA。
 * 三级视角②的落点：参加过没回来的人从这里认领自己那张（雾卡 → 找回出口）。
 */

const capsuleQuery = vi.fn();

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
	useRouter: () => ({ push: vi.fn(), replace: vi.fn() }),
}));

const archive: FlashbackCapsuleArchive = {
	key: "2014-01-11-bj",
	name: "Rails Girls 北京",
	city: "北京",
	occurredOn: "2014-01-11",
	appliedCount: 344,
	attendedCount: 3,
	isMine: false,
	roster: [
		{
			id: "p1",
			surnameMasked: "王**",
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
			fullName: null,
			city: "上海",
			occupationThen: "研究生",
			appliedAt: "2013-12-08T05:06:00Z",
			sentToWallAt: null,
			answers: [],
			today: null,
		},
	],
};

function withCapsule(archives: FlashbackCapsuleArchive[]) {
	capsuleQuery.mockResolvedValue({
		data: { flashbackCapsule: { me: {}, archives, actionCards: [], cities: [] } },
	});
}

beforeEach(() => {
	capsuleQuery.mockReset();
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
		expect(await screen.findByText("报名 344 位")).toBeInTheDocument();
		expect(screen.getByText("走进教室 3 位")).toBeInTheDocument();
		expect(screen.getByText("1 位已回来")).toBeInTheDocument();

		// 名册 = 单形态 3 列网格（长廊只留城市堆，名册不再有错落 masonry 形态）
		const grid = screen.getByTestId("fb-roster-grid");
		expect(grid.className).toBe("fb-roster-grid");
		expect(grid.dataset.total).toBe("3");

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

	it("复用 capsule 投影（不新增读面）：一次查询带 eventKey 过滤在客户端完成", async () => {
		withCapsule([archive]);
		render(<EventDetail eventKey="2014-01-11-bj" />);
		await screen.findByText("报名 344 位");

		expect(capsuleQuery).toHaveBeenCalledTimes(1);
		expect(capsuleQuery.mock.calls[0][0].query).toBe(FLASHBACK_CAPSULE);
	});
});
