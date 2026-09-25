import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import CapsuleView from "./capsule-view";
import { FLASHBACK_RETRACT, type FlashbackCapsule } from "@/lib/graphql/flashback";

/**
 * U5 时间胶囊测试：分层墙（结构化满员/虚线内容位/雾化显影）、两形态布局
 * 类名、行动板四态与附议交互、摘要卡缺省版式、撤回后三处呈现、回访直达。
 */

const pushMock = vi.fn();

vi.mock("@/i18n/navigation", () => ({
	Link: ({ href, children, ...rest }: { href: string; children: React.ReactNode } & Record<string, unknown>) => (
		<a href={href} {...rest}>
			{children}
		</a>
	),
	usePathname: () => "/flashback/capsule",
	useRouter: () => ({ push: pushMock, replace: vi.fn() }),
}));

const capsuleQuery = vi.fn();
const capsuleMutate = vi.fn();

vi.mock("@/lib/apollo-client", () => ({
	client: {
		query: (...args: unknown[]) => capsuleQuery(...(args as [{ variables: { token?: string } }])),
		mutate: (...args: unknown[]) => capsuleMutate(...args),
	},
}));

const { useMutationMock } = vi.hoisted(() => ({
	useMutationMock: vi.fn(() => [vi.fn(), { loading: false }]),
}));

vi.mock("@apollo/client/react", async (importOriginal) => {
	const actual = await importOriginal<typeof import("@apollo/client/react")>();
	return { ...actual, useMutation: useMutationMock };
});


const rosterEntry = (overrides: Partial<FlashbackCapsule["archives"][number]["roster"][number]>) => ({
	id: "entry-1",
	surnameMasked: "王**",
	participation: "attended",
	city: "北京",
	occupationThen: "学生",
	sentToWallAt: null,
	today: null,
	answers: [],
	...overrides,
});

const baseCapsule: FlashbackCapsule = {
	me: {
		id: "me-1",
		fullName: "王晓雨",
		surname: "王",
		city: "上海",
		occupationThen: "校对",
		participation: "attended",
		appliedAt: "2012-02-20T11:03:00Z",
		today: { nowStatus: "还在写东西", want: "想学 AI", say: null, sentToWallAt: "2026-09-17T00:00:00Z" },
		quote: "我想亲眼看看是不是。",
		answers: [{ id: "me-a1", questionKey: "self_intro", rawText: "一个文科生。在出版社。", text: "一个文科生。▓▓。" }],
	},
	// 单城：钉条隐藏（<2 城不渲染），不影响既有断言
		futureEvents: [],
	publicWishes: [],
	myPrivateWishes: [],
	myWishQuotaRemaining: 3,
cities: ["北京"],
	archives: [
		{
			key: "2014-01-11-bj",
			name: "Rails Girls 北京",
			city: "北京",
			occurredOn: "2014-01-11",
			appliedCount: 344,
			attendedCount: 102,
			isMine: false,
			// #933 城市堆由服务端聚合（计入未寄出者）
			piles: [{ city: "北京", count: 2, returned: 1 }],
			roster: [
				rosterEntry({ id: "sent-1", surnameMasked: "李*", fullName: "李雷", appliedAt: "2014-01-05T05:06:00Z", sentToWallAt: "2026-09-10T00:00:00Z", today: { nowStatus: null, want: "想参加骑行", say: null }, answers: [{ questionKey: "self_intro", segments: [{ text: "", fog: true, len: 3 }, { text: "。喜欢周末骑行。", fog: false, len: 0 }] }] }),
				rosterEntry({ id: "quiet-1", surnameMasked: "王**" }),
			],
		},
	],
};

async function renderCapsule(capsule: FlashbackCapsule = baseCapsule, token = "tok-1") {
	window.history.replaceState({}, "", `/flashback/capsule?token=${token}`);
	window.sessionStorage.clear();
	capsuleQuery.mockReset();
	capsuleQuery.mockResolvedValue({ data: { flashbackCapsule: capsule } });
	render(<CapsuleView />);
	await screen.findByText("闪念间 · 时间长廊");
}

beforeEach(() => {
	vi.spyOn(window, "matchMedia").mockReturnValue({
		matches: false,
		media: "",
		onchange: null,
		addListener: vi.fn(),
		removeListener: vi.fn(),
		addEventListener: vi.fn(),
		removeEventListener: vi.fn(),
		dispatchEvent: vi.fn(),
	} as unknown as MediaQueryList);
});

afterEach(() => {
	cleanup();
	vi.restoreAllMocks();
	window.history.replaceState({}, "", "/flashback/capsule");
	window.sessionStorage.clear();
});

describe("CapsuleView · 长廊城市堆（定稿 D）", () => {
	it("每帧渲染城市堆：聚合计数 + 城市名 + 叙事标签（长廊不再有 .fb-roster-*，入口为堆链接）", async () => {
		await renderCapsule();

		// baseCapsule 服务端聚合 1 堆（2 人同城）→「北京 · 2 位」
		const piles = screen.getAllByTestId("fb-corridor-pile");
		expect(piles).toHaveLength(1);
		expect(piles[0].dataset.city).toBe("北京");
		expect(piles[0].dataset.count).toBe("2");
		expect(piles[0]).toHaveTextContent("北京 · 2 位");
		// 拍立得结构：纸白卡 + grain 质感 + 城市名在照片窗内
		expect(piles[0].querySelector(".fb-corridor-polaroid.fb-grain.fb-polaroid")).toBeTruthy();
		expect(piles[0].querySelector(".fb-corridor-photo")).toHaveTextContent("北京");

		// 入口保留：逐个名册归场次页 3 列网格
		expect(screen.getAllByTestId("fb-corridor-pile")[0].querySelector("a")).toHaveAttribute(
			"href",
			"/flashback/event/2014-01-11-bj",
		);
		// 长廊内零名册元素（卡/网格/统计行都只在场次页）
		expect(document.querySelector(".fb-corridor .fb-roster-card, .fb-corridor .fb-roster-grid, .fb-corridor .fb-roster-meta")).toBeNull();
		expect(screen.queryAllByTestId("fb-roster-card")).toHaveLength(0);
	});

	it("「今天」格：寄出者亮起；token 从 URL 读入后即刻清除", async () => {
		await renderCapsule();

		expect(window.location.search).toBe("");
		const today = screen.getByTestId("fb-today-slot");
		expect(today.dataset.sent).toBe("true");
		expect(today).toHaveTextContent("还在写东西");
	});

	it("未寄出者「今天」格为虚线 + 去寄出出口（撤回后三处呈现之二）", async () => {
		await renderCapsule({
			...baseCapsule,
			me: { ...baseCapsule.me, today: { nowStatus: "还在写东西", want: null, say: null, sentToWallAt: null } },
		});

		const today = screen.getByTestId("fb-today-slot");
		expect(today.dataset.sent).toBe("false");
		expect(today).toHaveTextContent("你的照片还没寄出");
		expect(screen.getByRole("link", { name: "去寄出它 →" })).toHaveAttribute("href", "/flashback/enter");
	});
});

describe("CapsuleView · 我的卡动作（G2 编辑 + G3 撤下）", () => {
	it("已寄出 + token 在场：「今天」格动作行渲染编辑与撤下", async () => {
		await renderCapsule();

		const today = screen.getByTestId("fb-today-slot");
		expect(within(today).getByRole("button", { name: "编辑今天的你" })).toBeInTheDocument();
		expect(within(today).getByRole("button", { name: "撤下" })).toBeInTheDocument();
	});

	it("已寄出 + 登录态无 token：撤下照常渲染（#931 起 retract 双入口），编辑恒在", async () => {
		window.history.replaceState({}, "", "/flashback/capsule");
		window.sessionStorage.clear();
		capsuleQuery.mockReset();
		capsuleQuery.mockResolvedValue({ data: { flashbackCapsule: baseCapsule } });
		render(<CapsuleView />);
		await screen.findByText("闪念间 · 时间长廊");

		const today = screen.getByTestId("fb-today-slot");
		expect(within(today).getByRole("button", { name: "撤下" })).toBeInTheDocument();
		expect(within(today).getByRole("button", { name: "编辑今天的你" })).toBeInTheDocument();
	});

	it("撤下完整流：确认后 retract 带 token → 重拉数据 → 今天格回虚线位 + 去寄出引导", async () => {
		window.history.replaceState({}, "", "/flashback/capsule?token=tok-1");
		window.sessionStorage.clear();
		capsuleQuery.mockReset();
		capsuleQuery
			.mockResolvedValueOnce({ data: { flashbackCapsule: baseCapsule } })
			.mockResolvedValue({
				data: {
					flashbackCapsule: {
						...baseCapsule,
						me: { ...baseCapsule.me, today: { ...baseCapsule.me.today!, sentToWallAt: null } },
					},
				},
			});
		capsuleMutate.mockReset();
		capsuleMutate.mockResolvedValue({ data: { flashbackRetract: { retracted: true } } });
		render(<CapsuleView />);
		await screen.findByText("闪念间 · 时间长廊");

		fireEvent.click(screen.getByRole("button", { name: "撤下" }));
		fireEvent.click(await screen.findByRole("button", { name: "确认撤下" }));

		await waitFor(() => expect(capsuleMutate).toHaveBeenCalledTimes(1));
		const [opts] = capsuleMutate.mock.calls.map(([call]) => call) as [
			{ mutation: unknown; variables: unknown },
		];
		expect(opts.mutation).toBe(FLASHBACK_RETRACT);
		expect(opts.variables).toEqual({ token: "tok-1" });

		// 刷新后回未寄出态（U5 就位呈现：虚线位 + 去寄出）
		await waitFor(() => expect(capsuleQuery).toHaveBeenCalledTimes(2));
		const today = screen.getByTestId("fb-today-slot");
		await waitFor(() => expect(today.dataset.sent).toBe("false"));
		expect(today).toHaveTextContent("你的照片还没寄出");
		expect(screen.getByRole("link", { name: "去寄出它 →" })).toHaveAttribute("href", "/flashback/enter");
	});
});

describe("CapsuleView · 两形态布局（宽屏横向/窄屏纵向）", () => {
	it("窄屏（<768px）：走廊为纵向形态（无 --wide 类）；提示只有钉排下一处", async () => {
		await renderCapsule();

		expect(document.querySelector(".fb-corridor")).not.toHaveClass("fb-corridor--wide");
		// 副标题已删（与 scrollHint 同句式会重复），header 内无提示行
		expect(document.querySelector(".fb-capsule-header .fb-hint")).toBeNull();
		expect(document.querySelectorAll(".fb-root > .fb-hint")).toHaveLength(1);
		expect(document.querySelector(".fb-corridor-scrollhint")?.textContent).toContain("下滑 = 时间前进");
	});

	it("宽屏（≥768px）：走廊切横向形态类；竖滑提示不渲染", async () => {
		vi.spyOn(window, "matchMedia").mockImplementation(
			(query: string) =>
				({
					matches: query === "(min-width: 768px)",
					media: query,
					onchange: null,
					addListener: vi.fn(),
					removeListener: vi.fn(),
					addEventListener: vi.fn(),
					removeEventListener: vi.fn(),
					dispatchEvent: vi.fn(),
				}) as unknown as MediaQueryList,
		);
		await renderCapsule();

		expect(document.querySelector(".fb-corridor")).toHaveClass("fb-corridor--wide");
		expect(document.querySelector(".fb-capsule-header .fb-hint")).toBeNull();
	});
});


