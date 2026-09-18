import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import CapsuleView from "./capsule-view";
import type { FlashbackCapsule } from "@/lib/graphql/flashback";

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

vi.mock("@/lib/apollo-client", () => ({
	client: { query: (...args: unknown[]) => capsuleQuery(...(args as [{ variables: { token?: string } }])) },
}));

const { endorseRunner, useMutationMock } = vi.hoisted(() => {
	const endorseRunner = vi.fn();
	return {
		endorseRunner,
		useMutationMock: vi.fn(() => [endorseRunner, { loading: false }]),
	};
});

vi.mock("@apollo/client/react", async (importOriginal) => {
	const actual = await importOriginal<typeof import("@apollo/client/react")>();
	return { ...actual, useMutation: useMutationMock };
});

const rosterEntry = (overrides: Partial<FlashbackCapsule["archives"][number]["roster"][number]>) => ({
	id: "entry-1",
	surnameMasked: "王**",
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
		answers: [{ questionKey: "self_intro", text: "一个文科生。▓▓。" }],
	},
	// 单城：钉条隐藏（<2 城不渲染），不影响既有断言
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
			roster: [
				rosterEntry({ id: "sent-1", surnameMasked: "李**", sentToWallAt: "2026-09-10T00:00:00Z", today: { nowStatus: null, want: "想参加骑行", say: null }, answers: [{ questionKey: "self_intro", text: "▓▓。喜欢周末骑行。" }] }),
				rosterEntry({ id: "quiet-1", surnameMasked: "王**" }),
			],
		},
	],
	actionCards: [],
};

async function renderCapsule(capsule: FlashbackCapsule = baseCapsule, token = "tok-1") {
	window.history.replaceState({}, "", `/flashback/capsule?token=${token}`);
	window.sessionStorage.clear();
	capsuleQuery.mockReset();
	capsuleQuery.mockResolvedValue({ data: { flashbackCapsule: capsule } });
	render(<CapsuleView />);
	await screen.findByText("闪念间 · 时间胶囊");
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

describe("CapsuleView · 分层墙（R12）", () => {
	it("结构化卡满员：姓氏隐名 + 城市 + 职业；未寄出者内容位为虚线且无文本泄露", async () => {
		await renderCapsule();

		const cards = screen.getAllByTestId("fb-roster-card");
		expect(cards).toHaveLength(2);

		const quiet = cards.find((card) => card.dataset.sent === "false");
		expect(quiet).toBeTruthy();
		expect(quiet).toHaveTextContent("王**");
		expect(quiet).toHaveTextContent("北京 · 学生");
		expect(quiet).toHaveTextContent("她的答案，还在等她");
		// 零文本泄露：未寄出者不出现任何答案内容
		expect(quiet).not.toHaveTextContent("骑行");

		const sent = cards.find((card) => card.dataset.sent === "true");
		expect(sent).toHaveTextContent("李**");
		// 寄出者：雾化文本（▓▓）与今天摘要显影
		expect(sent).toHaveTextContent("▓▓。喜欢周末骑行。");
		expect(sent).toHaveTextContent("想参加骑行");
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

describe("CapsuleView · 名册折叠（叠照，用户改进 1）", () => {
	const bigRoster = Array.from({ length: 30 }, (_, i) =>
		rosterEntry({ id: `p-${i}`, surnameMasked: `${String.fromCharCode(0x7389 + (i % 20))}${"*".repeat(1 + (i % 2))}` }),
	);

	it("大场默认折叠：首屏 12 张 + 叠层暗示 + 展开按钮带总数", async () => {
		await renderCapsule({
			...baseCapsule,
			archives: [{ ...baseCapsule.archives[0], roster: bigRoster }],
		});

		const grid = screen.getByTestId("fb-roster-grid");
		expect(grid.dataset.total).toBe("30");
		// 首屏 12 张真卡；叠层暗示卡 aria-hidden、无 testid（非数据卡）
		expect(screen.getAllByTestId("fb-roster-card").length).toBe(12);
		expect(document.querySelector(".fb-roster-card--stacked")).toBeTruthy();
		const toggle = screen.getByTestId("fb-roster-toggle");
		expect(toggle).toHaveAttribute("aria-expanded", "false");
		expect(toggle).toHaveTextContent("展开全部 30 位");
		expect(screen.getByText("还有 18 位在叠照下")).toBeInTheDocument();
	});

	it("展开 → 全量 30 张 + 收起按钮；再点收起回 12", async () => {
		await renderCapsule({
			...baseCapsule,
			archives: [{ ...baseCapsule.archives[0], roster: bigRoster }],
		});

		fireEvent.click(screen.getByTestId("fb-roster-toggle"));
		expect(await screen.findByRole("button", { name: "收起（保留前几张）" })).toBeInTheDocument();
		expect(screen.getAllByTestId("fb-roster-card").length).toBe(30);
		expect(screen.queryByText(/在叠照下/)).not.toBeInTheDocument();

		fireEvent.click(screen.getByTestId("fb-roster-toggle"));
		await waitFor(() => {
			expect(screen.getAllByTestId("fb-roster-card").length).toBe(12);
			expect(document.querySelector(".fb-roster-card--stacked")).toBeTruthy();
		});
		expect(screen.getByTestId("fb-roster-toggle")).toHaveAttribute("aria-expanded", "false");
	});

	it("小场（2 人）不折叠：无按钮无叠层卡", async () => {
		await renderCapsule();

		expect(screen.queryByTestId("fb-roster-toggle")).not.toBeInTheDocument();
		expect(screen.getAllByTestId("fb-roster-card").length).toBe(2);
	});
});

describe("CapsuleView · 两形态布局（宽屏横向/窄屏纵向）", () => {
	it("窄屏（<768px）：走廊为纵向形态（无 --wide 类）", async () => {
		await renderCapsule();

		expect(document.querySelector(".fb-corridor")).not.toHaveClass("fb-corridor--wide");
	});

	it("宽屏（≥768px）：走廊切横向形态类", async () => {
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
	});
});

describe("CapsuleView · 行动板四态（R13）", () => {
	it("空板：占位文案（空板不是错误态）", async () => {
		await renderCapsule();

		expect(screen.getByTestId("fb-action-empty")).toHaveTextContent("还没有人提议");
	});

	it("proposed/forming/scheduled/done 四态渲染；scheduled 直链报名 + web 端退回文案", async () => {
		await renderCapsule({
			...baseCapsule,
			actionCards: [
				{ id: "c1", title: "医生专场", city: "广州", status: "proposed", endorsementCount: 7, endorsedByMe: false, rolesClaimed: [], eventId: null, eventSlug: null },
				{ id: "c2", title: "潜水场", city: "上海", status: "forming", endorsementCount: 9, endorsedByMe: false, rolesClaimed: ["promoter"], eventId: null, eventSlug: null },
				{ id: "c3", title: "骑行场", city: "北京", status: "scheduled", endorsementCount: 23, endorsedByMe: true, rolesClaimed: ["organizer"], eventId: "e1", eventSlug: "1024-bj-ride" },
				{ id: "c4", title: "重聚", city: "北京", status: "done", endorsementCount: 12, endorsedByMe: true, rolesClaimed: [], eventId: "e2", eventSlug: "reunion" },
			],
		});

		const cards = screen.getAllByTestId("fb-action-card");
		expect(cards.map((card) => card.dataset.status)).toEqual(["proposed", "forming", "scheduled", "done"]);

		expect(screen.getByText("提议中 · 等同伴")).toBeInTheDocument();
		expect(screen.getByText("9 人已附议")).toBeInTheDocument();
		// 「宣传拉人」在已认领标签与附议表单 radio 各出现一次
		expect(screen.getAllByText("宣传拉人").length).toBeGreaterThanOrEqual(2);

		// scheduled：直链 Event 报名页 + web 端退回触达文案（KTD5）
		const signup = screen.getByRole("link", { name: "报名这一场 →" });
		expect(signup).toHaveAttribute("href", "/events/1024-bj-ride");
		expect(screen.getByText(/成场通知会发到你预留的手机\/邮箱/)).toBeInTheDocument();

		// done：回贴占位说明
		expect(screen.getByText(/照片与回顾会贴回这张卡/)).toBeInTheDocument();

		// 未附议的 proposed/forming 卡各有附议入口；已附议（scheduled/done）没有
		const endorseButtons = screen.getAllByRole("button", { name: "附议这张卡 +1" });
		expect(endorseButtons).toHaveLength(2);
	});

	it("附议交互：角色选择 + 提交后重拉胶囊（附议计数即时可见）", async () => {
		endorseRunner.mockReset();
		endorseRunner.mockResolvedValue({
			data: { flashbackEndorse: { cardId: "c1", status: "proposed", roleClaimed: "organizer", firstTime: true } },
		});

		await renderCapsule({
			...baseCapsule,
			actionCards: [
				{ id: "c1", title: "医生专场", city: "广州", status: "forming", endorsementCount: 7, endorsedByMe: false, rolesClaimed: [], eventId: null, eventSlug: null },
			],
		});

		fireEvent.click(screen.getByRole("radio", { name: "组织者" }));
		fireEvent.click(screen.getByRole("button", { name: "附议这张卡 +1" }));

		await waitFor(() =>
			expect(endorseRunner).toHaveBeenCalledWith({
				variables: { token: "tok-1", cardId: "c1", roleClaimed: "organizer" },
			}),
		);
		// onChanged 重拉胶囊
		await waitFor(() => expect(capsuleQuery).toHaveBeenCalledTimes(2));
	});
});

describe("CapsuleView · 摘要卡与全文卡（R14/R15）", () => {
	it("摘要卡：时间戳+城市+金句+今天；缺省版式（未选金句）用占位句", async () => {
		await renderCapsule();

		expect(screen.getByText("2012.02.20 · 上海")).toBeInTheDocument();
		expect(screen.getByText("“我想亲眼看看是不是。”")).toBeInTheDocument();
		expect(screen.getByText(/今天的我：想学 AI/)).toBeInTheDocument();
	});

	it("未选金句 + 未填今天的缺省版式（R14）", async () => {
		await renderCapsule({
			...baseCapsule,
			me: { ...baseCapsule.me, quote: null, today: null },
		});

		expect(screen.getByText("“（这里将是你选出的一句金句）”")).toBeInTheDocument();
		expect(screen.queryByText(/今天的我/)).not.toBeInTheDocument();
	});

	it("全文卡：切换 tab 后呈现雾化态答案（R15 下载同一物件）", async () => {
		await renderCapsule();

		fireEvent.click(screen.getByRole("button", { name: "全文卡" }));

		const card = screen.getByTestId("fb-export-card");
		expect(card).toHaveTextContent("请简单的介绍一下自己");
		expect(card).toHaveTextContent("一个文科生。▓▓。");
	});
});

describe("CapsuleView · 城市钉筛选（R34）", () => {
	const card = (id: string, title: string, city: string) => ({
		id,
		title,
		city,
		status: "forming" as const,
		endorsementCount: 3,
		endorsedByMe: false,
		rolesClaimed: [],
		eventId: null,
		eventSlug: null,
	});

	it("多城渲染钉条（全部 + 城市）；点城市带 city 重拉，名册与行动板呈现服务端过滤结果", async () => {
		await renderCapsule({
			...baseCapsule,
			cities: ["上海", "北京"],
			actionCards: [card("c1", "骑行场", "北京"), card("c2", "潜水场", "上海")],
		});

		expect(screen.getByRole("button", { name: "全部" })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "北京" })).toHaveAttribute("aria-pressed", "false");

		// 点「北京」→ 第二次 query 带 city: "北京"；返回北京过滤后的胶囊
		capsuleQuery.mockResolvedValue({
			data: {
				flashbackCapsule: {
					...baseCapsule,
					cities: ["上海", "北京"],
					actionCards: [card("c1", "骑行场", "北京")],
				},
			},
		});
		fireEvent.click(screen.getByRole("button", { name: "北京" }));

		await waitFor(() => expect(capsuleQuery).toHaveBeenCalledTimes(2));
		expect(capsuleQuery).toHaveBeenLastCalledWith(
			expect.objectContaining({ variables: { token: "tok-1", city: "北京" } }),
		);
		await waitFor(() => expect(screen.getAllByTestId("fb-action-card")).toHaveLength(1));
		expect(screen.getByText("骑行场")).toBeInTheDocument();
		expect(screen.queryByText("潜水场")).not.toBeInTheDocument();
		// 钉条仍渲染全量城市（不随过滤收缩），可切回
		expect(screen.getByRole("button", { name: "上海" })).toBeInTheDocument();

		// 切回「全部」→ city: null
		fireEvent.click(screen.getByRole("button", { name: "全部" }));
		await waitFor(() =>
			expect(capsuleQuery).toHaveBeenLastCalledWith(
				expect.objectContaining({ variables: { token: "tok-1", city: null } }),
			),
		);
	});

	it("单城不渲染钉条（无筛选意义）", async () => {
		await renderCapsule();
		expect(screen.queryByRole("button", { name: "全部" })).not.toBeInTheDocument();
	});

	it("筛选后空名册/空板：区分「该城暂无」空态文案", async () => {
		await renderCapsule({ ...baseCapsule, cities: ["上海", "北京"] });
		capsuleQuery.mockResolvedValue({
			data: {
				flashbackCapsule: { ...baseCapsule, cities: ["上海", "北京"], archives: [], actionCards: [] },
			},
		});
		fireEvent.click(screen.getByRole("button", { name: "上海" }));

		expect(await screen.findByText("这座城市还没有名册照片。")).toBeInTheDocument();
		expect(screen.getByTestId("fb-action-empty")).toHaveTextContent("这座城市还没有行动卡");
		// 「今天」格不随城市筛选消失
		expect(screen.getByTestId("fb-today-slot")).toBeInTheDocument();
	});
});

describe("CapsuleView · 身份与回访", () => {
	it("token 失效（claimed）走 invalid 分支", async () => {
		capsuleQuery.mockReset();
		capsuleQuery.mockRejectedValue({
			errors: [{ message: "x", extensions: { code: "flashback_token_claimed" } }],
		});
		window.history.replaceState({}, "", "/flashback/capsule?token=dead");
		window.sessionStorage.clear();
		render(<CapsuleView />);

		expect(await screen.findByText("这个档案已有主人")).toBeInTheDocument();
	});

	it("无 token 未登录（auth_required）：自助找回引导", async () => {
		capsuleQuery.mockReset();
		capsuleQuery.mockRejectedValue({
			errors: [{ message: "x", extensions: { code: "flashback_auth_required" } }],
		});
		window.sessionStorage.clear();
		render(<CapsuleView />);

		expect(await screen.findByText("进入胶囊需要你的身份")).toBeInTheDocument();
		expect(screen.getByRole("link", { name: "去自助找回" })).toHaveAttribute("href", "/flashback");
	});
});
