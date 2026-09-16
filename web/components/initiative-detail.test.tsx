import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import InitiativeDetail from "./initiative-detail";

const { fetchPublicInitiative } = vi.hoisted(() => ({
	fetchPublicInitiative: vi.fn(),
}));

vi.mock("@/lib/graphql/initiatives", () => ({ fetchPublicInitiative }));

vi.mock("next/navigation", () => ({
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
	useRouter: () => ({ push: vi.fn(), replace: vi.fn(), back: vi.fn() }),
	usePathname: () => "/initiatives/hackerstart1024",
}));

const BASE_EVENT = {
	id: "e1",
	slug: "evt-1",
	visibility: "public",
	startsAt: "2026-10-13T15:22:30Z",
	endsAt: null,
	registrationDeadline: null,
	venue: null,
	minParticipants: 8,
	archived: false,
};

function event(partial: Record<string, unknown>) {
	return { ...BASE_EVENT, ...partial };
}

const PAYLOAD = {
	id: "i1",
	name: "Hackerstart 1024 全国黑客松",
	slug: "hackerstart1024",
	hashtag: "#hackerstart1024",
	description: "1024 程序员节全国巡回黑客松。",
	status: "open",
	windowStartsAt: "2026-10-01T02:00:00Z",
	windowEndsAt: "2026-10-31T02:00:00Z",
	cityCount: 2,
	eventCount: 4,
	confirmedCount: 14,
	qualifiedEventCount: 1,
	cities: [
		{
			city: "长沙市",
			events: [
				event({
					id: "e1",
					slug: "1024-changsha-01",
					title: "长沙站",
					status: "open",
					confirmedCount: 4,
					qualificationStatus: "pending",
					qualificationBadge: "short_by",
					shortBy: 4,
				}),
				event({
					id: "e2",
					slug: "1024-shanghai-01",
					title: "上海站",
					status: "open",
					confirmedCount: 8,
					qualificationStatus: "confirmed",
					qualificationBadge: "confirmed",
					shortBy: null,
				}),
				event({
					id: "e3",
					slug: "1024-beijing-01",
					title: "北京站",
					status: "cancelled",
					confirmedCount: 2,
					qualificationStatus: "underfilled",
					qualificationBadge: "cancelled",
					shortBy: null,
					archived: true,
				}),
			],
		},
		{
			city: "深圳市",
			events: [
				event({
					id: "e4",
					slug: "1024-shenzhen-01",
					title: "深圳站",
					status: "closed",
					confirmedCount: 0,
					qualificationStatus: "pending",
					qualificationBadge: "closed",
					shortBy: null,
					archived: true,
				}),
			],
		},
	],
};

/** 取指定场次卡片的三条 fact（时间/地点/报名人数），dt 与 dd 同序对应 */
function cardFacts(name: RegExp) {
	const card = screen.getByRole("link", { name });
	const facts = card.querySelector(".public-catalog-card__facts")!;
	return {
		dts: Array.from(facts.querySelectorAll("dt")).map((n) => n.textContent ?? ""),
		dds: Array.from(facts.querySelectorAll("dd")).map((n) => n.textContent ?? ""),
	};
}

/**
 * 「报名人数」fact 的值；标签缺失即失败（#593：旧 seats 标签 + x / y 比值口径的回归守卫）。
 * 用 indexOf 定位而非固定下标——卡片与 hero 可能同名 label，且 fact 顺序不应被测试绑死。
 */
function participantsCount(name: RegExp, label = "报名人数") {
	const { dts, dds } = cardFacts(name);
	const i = dts.indexOf(label);
	expect(i).toBeGreaterThanOrEqual(0);
	return dds[i] ?? "";
}

beforeEach(() => {
	vi.clearAllMocks();
});

afterEach(cleanup);

describe("/initiatives/[slug] 公开页", () => {
	it("渲染四项计数、城市分组与后端派生徽章矩阵", async () => {
		fetchPublicInitiative.mockResolvedValue(PAYLOAD);

		render(<InitiativeDetail slug="hackerstart1024" />);

		expect(
			await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" }),
		).toBeInTheDocument();

		const stats = document.querySelector(".initiative-stats")!;
		expect(stats.textContent).toContain("2");
		expect(stats.textContent).toContain("4");
		expect(stats.textContent).toContain("14");
		expect(stats.textContent).toContain("1");

		expect(screen.getByRole("heading", { name: "长沙市" })).toBeInTheDocument();
		expect(screen.getByRole("heading", { name: "深圳市" })).toBeInTheDocument();

		// hero 状态行 + 倡导窗口（与小程序 initiative-detail hero 同信息）
		const hero = document.querySelector(".initiative-hero")!;
		expect(hero.querySelector(".initiative-hero__status")!.textContent).toBe("进行中");
		expect(hero.querySelector(".initiative-hero__window")!.textContent).toContain("2026");

		expect(screen.getByText("还差 4 人成班")).toBeInTheDocument();
		expect(screen.getAllByText("已成班").length).toBeGreaterThanOrEqual(2);
		expect(screen.getByText("已取消")).toBeInTheDocument();
		expect(screen.getByText("已结束")).toBeInTheDocument();

		expect(
			screen.getByRole("link", { name: /长沙站/ }),
		).toHaveAttribute("href", "/events/1024-changsha-01");
	});

	// #628：活动级状态文案分叉（中止 vs 收尾），两者都仍可直达
	it("closed 渲染留档文案，无中止说明行", async () => {
		fetchPublicInitiative.mockResolvedValue({ ...PAYLOAD, status: "closed", cities: [], eventCount: 0 });

		render(<InitiativeDetail slug="hackerstart1024" />);

		expect(await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" })).toBeInTheDocument();
		const hero = document.querySelector(".initiative-hero")!;
		expect(hero.querySelector(".initiative-hero__status")!.textContent).toBe("已结束 · 活动留档");
		expect(hero.querySelector(".initiative-hero__cancelled")).toBeNull();
	});

	it("cancelled 渲染中止文案 + 全额退款说明行（与 closed 不同）", async () => {
		fetchPublicInitiative.mockResolvedValue({ ...PAYLOAD, status: "cancelled", cities: [], eventCount: 0 });

		render(<InitiativeDetail slug="hackerstart1024" />);

		expect(await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" })).toBeInTheDocument();
		const hero = document.querySelector(".initiative-hero")!;
		expect(hero.querySelector(".initiative-hero__status")!.textContent).toBe("已取消 · 活动中止");
		expect(hero.querySelector(".initiative-hero__cancelled")!.textContent).toContain("全额退款");
		// 分叉钉死：cancelled 与 closed 文案不得相同
		expect(hero.querySelector(".initiative-hero__status")!.textContent).not.toBe("已结束 · 活动留档");
		expect(screen.queryByRole("link", { name: /长沙站/ })).toBeNull();
	});

	it("加载失败渲染 notFound 与返回入口", async () => {
		fetchPublicInitiative.mockRejectedValue(new Error("network"));

		render(<InitiativeDetail slug="missing" />);

		expect(
			await screen.findByRole("heading", { name: "活动不存在" }),
		).toBeInTheDocument();
		expect(screen.getByRole("button", { name: "返回" })).toBeInTheDocument();
	});
});

/**
 * #593：第三个 fact 曾以 initiatives.seats（zh「报名」/ en「Seats」）渲染
 * `${confirmedCount} / ${minParticipants}`——minParticipants 是成班阈值不是名额，
 * 已成班场还会出现 20 / 8 这类不可能被正确理解的比值。
 * 现口径 = 裸报名人数（复用 hero 的 initiatives.participants），成班语义只由徽章承载。
 */
describe("场次卡片报名口径（#593）", () => {
	it("只报报名人数：无 x / y 比值、无旧「报名」标签，徽章仍承担成班语义", async () => {
		fetchPublicInitiative.mockResolvedValue(PAYLOAD);

		render(<InitiativeDetail slug="hackerstart1024" />);

		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		// 页面级回归：旧口径的 `x / y`（含空格分隔）整体消失
		// （日期经 toLocaleString 渲染为 2026/10/13，不带空格，不会误伤本断言）
		expect(document.querySelector(".initiative-page")!.textContent).not.toContain(" / ");

		// 四场各自的 fact 值 = 裸计数（8 = 上海站报名数，同时也是其阈值 → 旧口径会渲染 8 / 8）
		expect(participantsCount(/长沙站/)).toBe("4");
		expect(participantsCount(/上海站/)).toBe("8");
		expect(participantsCount(/北京站/)).toBe("2");
		expect(participantsCount(/深圳站/)).toBe("0");

		// 旧 seats 标签（zh「报名」）不再作为 fact 标签出现
		expect(cardFacts(/长沙站/).dts).not.toContain("报名");

		// 成班语义仍由徽章承载，与计数不重复、不冲突
		expect(screen.getByText("还差 4 人成班")).toBeInTheDocument();
	});

	it("已成班且报名超阈值时不出现 20 / 8（真实可达状态）", async () => {
		fetchPublicInitiative.mockResolvedValue({
			...PAYLOAD,
			cityCount: 1,
			eventCount: 1,
			confirmedCount: 20,
			qualifiedEventCount: 1,
			cities: [
				{
					city: "广州市",
					events: [
						event({
							id: "e5",
							slug: "1024-guangzhou-01",
							title: "广州站",
							status: "open",
							confirmedCount: 20,
							qualificationStatus: "confirmed",
							qualificationBadge: "confirmed",
							shortBy: null,
						}),
					],
				},
			],
		});

		render(<InitiativeDetail slug="hackerstart1024" />);

		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		expect(participantsCount(/广州站/)).toBe("20");
		expect(document.querySelector(".initiative-page")!.textContent).not.toContain("20 / 8");
		expect(
			document.querySelector(".initiative-badge--confirmed")!.textContent,
		).toBe("已成班");
	});

	it("未配阈值（badge=open）时同样只报报名人数", async () => {
		fetchPublicInitiative.mockResolvedValue({
			...PAYLOAD,
			cityCount: 1,
			eventCount: 1,
			confirmedCount: 3,
			qualifiedEventCount: 0,
			cities: [
				{
					city: "线上 / 待定",
					events: [
						event({
							id: "e6",
							slug: "1024-online-01",
							title: "线上场",
							status: "open",
							confirmedCount: 3,
							minParticipants: null,
							qualificationStatus: "pending",
							qualificationBadge: "open",
							shortBy: null,
						}),
					],
				},
			],
		});

		render(<InitiativeDetail slug="hackerstart1024" />);

		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		expect(participantsCount(/线上场/)).toBe("3");
		expect(document.querySelector(".initiative-badge--open")!.textContent).toBe("开放报名");
	});

	it("en 与 zh 同步：Participants 裸计数，无 Seats 比值", async () => {
		fetchPublicInitiative.mockResolvedValue(PAYLOAD);

		render(<InitiativeDetail slug="hackerstart1024" />, { locale: "en" });

		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		expect(participantsCount(/长沙站/, "Participants")).toBe("4");
		expect(cardFacts(/长沙站/).dts).not.toContain("Seats");
		expect(document.querySelector(".initiative-page")!.textContent).not.toContain(" / ");
		expect(screen.getByText("4 more needed to qualify")).toBeInTheDocument();
	});
});
