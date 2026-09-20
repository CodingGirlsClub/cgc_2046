import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, fireEvent, screen } from "@testing-library/react";
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
	// 参与条件（#627）默认：免费 + 无年龄门槛（逐用例覆写）
	paymentMode: "free",
	deposit: { enabled: false, amountCents: null, refundableOnCheckIn: null },
	minAge: null,
	priceRangeMinCents: null,
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
	it("渲染四项计数、城市筛选 chips 与后端派生徽章矩阵", async () => {
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

		// 城市名从分组 h2 移到筛选 chip（button）
		expect(screen.getByRole("button", { name: /长沙市/ })).toBeInTheDocument();
		expect(screen.getByRole("button", { name: /深圳市/ })).toBeInTheDocument();

		// 平铺后四场同屏（不再按城市分 section）
		expect(screen.getByRole("link", { name: /上海站/ })).toBeInTheDocument();
		expect(screen.getByRole("link", { name: /北京站/ })).toBeInTheDocument();
		expect(screen.getByRole("link", { name: /深圳站/ })).toBeInTheDocument();

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

	it("平铺 + 城市筛选：chip 过滤场次，「全部城市」恢复", async () => {
		fetchPublicInitiative.mockResolvedValue(PAYLOAD);

		render(<InitiativeDetail slug="hackerstart1024" />);
		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		// 平铺：四场同屏
		expect(screen.getByRole("link", { name: /长沙站/ })).toBeInTheDocument();
		expect(screen.getByRole("link", { name: /上海站/ })).toBeInTheDocument();
		expect(screen.getByRole("link", { name: /北京站/ })).toBeInTheDocument();
		expect(screen.getByRole("link", { name: /深圳站/ })).toBeInTheDocument();

		// 筛选「长沙市」：深圳站离场，长沙组三场仍在
		fireEvent.click(screen.getByRole("button", { name: /长沙市/ }));
		expect(screen.queryByRole("link", { name: /深圳站/ })).toBeNull();
		expect(screen.getByRole("link", { name: /长沙站/ })).toBeInTheDocument();
		expect(screen.getByRole("link", { name: /上海站/ })).toBeInTheDocument();
		expect(screen.getByRole("link", { name: /北京站/ })).toBeInTheDocument();

		// 「全部城市」恢复四场
		fireEvent.click(screen.getByRole("button", { name: "全部城市" }));
		expect(screen.getByRole("link", { name: /深圳站/ })).toBeInTheDocument();
	});

	it("单城市不渲染筛选条", async () => {
		fetchPublicInitiative.mockResolvedValue({
			...PAYLOAD,
			cityCount: 1,
			eventCount: 1,
			cities: [{ city: "长沙市", events: [PAYLOAD.cities[0].events[0]] }],
		});

		render(<InitiativeDetail slug="hackerstart1024" />);
		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		expect(document.querySelector(".initiative-filter")).toBeNull();
		expect(screen.getByRole("link", { name: /长沙站/ })).toBeInTheDocument();
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

/**
 * #627 参与条件披露：押金（必须，交易前提）/ 年龄门槛存在性 / 成班进度复用徽章。
 * 单槽三态——绝不出现「免费」与「押金 ¥69」并列（R10/KTD10）。
 */
describe("参与条件披露（#627）", () => {
	/** 单场 payload：把 BASE_EVENT 覆写成待测形态 */
	function singleEvent(partial: Record<string, unknown>) {
		return {
			...PAYLOAD,
			cityCount: 1,
			eventCount: 1,
			confirmedCount: 0,
			qualifiedEventCount: 0,
			cities: [{ city: "长沙市", events: [event(partial)] }],
		};
	}

	function conditionBadge() {
		return document.querySelector(".initiative-badge--condition")!.textContent;
	}

	it("押金态：金额 + 到场退 + 年龄门槛存在性（不投校验策略）", async () => {
		fetchPublicInitiative.mockResolvedValue(
			singleEvent({
				paymentMode: "deposit",
				deposit: { enabled: true, amountCents: 6900, refundableOnCheckIn: true },
				minAge: 18,
			}),
		);

		render(<InitiativeDetail slug="hackerstart1024" />);
		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		expect(conditionBadge()).toBe("押金 ¥69（到场退） · 限 18+");
	});

	it("押金金额缺失：退化为不表态形态，绝不显示 ¥0（#586 守卫）", async () => {
		fetchPublicInitiative.mockResolvedValue(
			singleEvent({
				paymentMode: "deposit",
				deposit: { enabled: true, amountCents: null, refundableOnCheckIn: true },
			}),
		);

		render(<InitiativeDetail slug="hackerstart1024" />);
		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		expect(conditionBadge()).toBe("押金（金额待定）");
		expect(document.querySelector(".initiative-page")!.textContent).not.toContain("¥0");
		expect(document.querySelector(".initiative-page")!.textContent).not.toContain("免费");
	});

	it("收费态：金额锚出「起」；金额锚缺失走降级文案", async () => {
		fetchPublicInitiative.mockResolvedValue(
			singleEvent({ paymentMode: "pricing", priceRangeMinCents: 9900, minAge: 21 }),
		);

		render(<InitiativeDetail slug="hackerstart1024" />);
		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		expect(conditionBadge()).toBe("收费 ¥99 起 · 限 21+");

		cleanup();
		fetchPublicInitiative.mockResolvedValue(
			singleEvent({ paymentMode: "pricing", priceRangeMinCents: null }),
		);

		render(<InitiativeDetail slug="hackerstart1024" />);
		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		// D2：宁可多说一句，也不给一张光秃秃的卡片
		expect(conditionBadge()).toBe("收费（档位以活动页为准）");
	});

	it("免费态：单槽只出「免费」，无年龄门槛时不带「限」；成班进度仍只在徽章", async () => {
		fetchPublicInitiative.mockResolvedValue(
			singleEvent({ paymentMode: "free", minParticipants: 8, qualificationBadge: "short_by", shortBy: 8 }),
		);

		render(<InitiativeDetail slug="hackerstart1024" />);
		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		expect(conditionBadge()).toBe("免费");
		expect(conditionBadge()).not.toContain("限");
		// 成班进度复用既有徽章（#593）：条件行不出现第二个进度数字
		expect(conditionBadge()).not.toContain("人成班");
		expect(screen.getByText("还差 8 人成班")).toBeInTheDocument();
	});

	it("已取消留档场照常披露参与条件", async () => {
		fetchPublicInitiative.mockResolvedValue(
			singleEvent({
				status: "cancelled",
				archived: true,
				qualificationBadge: "cancelled",
				shortBy: null,
				paymentMode: "deposit",
				deposit: { enabled: true, amountCents: 6900, refundableOnCheckIn: true },
				minAge: 18,
			}),
		);

		render(<InitiativeDetail slug="hackerstart1024" />);
		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		expect(conditionBadge()).toBe("押金 ¥69（到场退） · 限 18+");
		expect(document.querySelector(".initiative-badge--cancelled")!.textContent).toBe("已取消");
	});

	it("en 逐字：Deposit / Paid from / Free / Age", async () => {
		fetchPublicInitiative.mockResolvedValue(
			singleEvent({
				paymentMode: "deposit",
				deposit: { enabled: true, amountCents: 6900, refundableOnCheckIn: true },
				minAge: 18,
			}),
		);

		render(<InitiativeDetail slug="hackerstart1024" />, { locale: "en" });
		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		expect(conditionBadge()).toBe("Deposit ¥69 (refunded on attendance) · Age 18+");

		cleanup();
		fetchPublicInitiative.mockResolvedValue(
			singleEvent({ paymentMode: "pricing", priceRangeMinCents: 9900 }),
		);

		render(<InitiativeDetail slug="hackerstart1024" />, { locale: "en" });
		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		expect(conditionBadge()).toBe("Paid from ¥99");

		cleanup();
		fetchPublicInitiative.mockResolvedValue(singleEvent({ paymentMode: "free" }));

		render(<InitiativeDetail slug="hackerstart1024" />, { locale: "en" });
		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		expect(conditionBadge()).toBe("Free");
		expect(conditionBadge()).not.toContain("Deposit");
	});
});

/**
 * F4：未知/缺失缴费态**不得 fail-open 成「免费」**——用默认值冒充事实正是 #586
 * 的病根（把押金场说成免费）；F1：条件徽章必须独占一行，否则 360px 视口下
 * `__head`（nowrap flex）会把标题挤到 0px（浏览器实测值见报告）。
 */
describe("F1 布局结构 + F4 未知缴费态（#627）", () => {
	function single(partial: Record<string, unknown>) {
		return {
			...PAYLOAD,
			cityCount: 1,
			eventCount: 1,
			confirmedCount: 0,
			qualifiedEventCount: 0,
			cities: [{ city: "长沙市", events: [event(partial)] }],
		};
	}

	it("F1：条件徽章不在 __head 内（独占一行），成班徽章仍与标题同排", async () => {
		fetchPublicInitiative.mockResolvedValue(
			single({ qualificationBadge: "short_by", shortBy: 8 }),
		);

		render(<InitiativeDetail slug="hackerstart1024" />);
		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		const card = document.querySelector(".public-catalog-card")!;
		const head = card.querySelector(".public-catalog-card__head")!;
		const condition = card.querySelector(".initiative-badge--condition")!;

		// 结构判据：条件徽章是卡片（column flex）的直接子元素 → 独占一行
		expect(head.contains(condition)).toBe(false);
		expect(condition.parentElement).toBe(card);
		// 成班徽章仍在 head 内（与标题同排），未被本次布局修复动到
		expect(head.querySelector(".initiative-badge")).not.toBeNull();
		expect(head.textContent).toContain("还差 8 人成班");
	});

	it("F4：未知/缺失 paymentMode 落「缴费信息待定」，不再冒充满费", async () => {
		fetchPublicInitiative.mockResolvedValue(
			single({ paymentMode: undefined, minAge: 18 }),
		);

		render(<InitiativeDetail slug="hackerstart1024" />);
		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		const badge = document.querySelector(".initiative-badge--condition")!.textContent;
		expect(badge).toBe("缴费信息待定 · 限 18+");
		expect(badge).not.toContain("免费");

		cleanup();
		fetchPublicInitiative.mockResolvedValue(single({ paymentMode: "free" }));

		render(<InitiativeDetail slug="hackerstart1024" />);
		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		// 显式 free 仍出「免费」（中性态不误伤真免费场）
		expect(document.querySelector(".initiative-badge--condition")!.textContent).toBe("免费");
	});

	it("F5 客户端同纪律：minAge 非正不渲染门槛（陈旧 payload）", async () => {
		for (const dirty of [0, -3]) {
			fetchPublicInitiative.mockResolvedValue(single({ paymentMode: "free", minAge: dirty }));

			render(<InitiativeDetail slug="hackerstart1024" />);
			await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

			const badge = document.querySelector(".initiative-badge--condition")!.textContent;
			expect(badge).toBe("免费");
			expect(badge).not.toContain("限");
			cleanup();
		}
	});

	it("F4/F9 en：Payment info TBD / Deposit (amount TBD) / 降级句为陈述式", async () => {
		fetchPublicInitiative.mockResolvedValue(single({ paymentMode: undefined }));

		render(<InitiativeDetail slug="hackerstart1024" />, { locale: "en" });
		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		expect(document.querySelector(".initiative-badge--condition")!.textContent).toBe(
			"Payment info TBD",
		);

		cleanup();
		fetchPublicInitiative.mockResolvedValue(
			single({
				paymentMode: "deposit",
				deposit: { enabled: true, amountCents: null, refundableOnCheckIn: true },
			}),
		);

		render(<InitiativeDetail slug="hackerstart1024" />, { locale: "en" });
		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		expect(document.querySelector(".initiative-badge--condition")!.textContent).toBe(
			"Deposit (amount TBD)",
		);

		cleanup();
		fetchPublicInitiative.mockResolvedValue(
			single({ paymentMode: "pricing", priceRangeMinCents: null }),
		);

		render(<InitiativeDetail slug="hackerstart1024" />, { locale: "en" });
		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		expect(document.querySelector(".initiative-badge--condition")!.textContent).toBe(
			"Paid (tiers are listed on the event page)",
		);
	});
});

/**
 * 描述按 \n\n 分段渲染（plan 001）：单 <p> + white-space:normal 会把多段描述
 * 塌成一堵文字墙；空段（连续空行）必须丢弃，否则段距随空行数漂移。
 */
describe("hero 描述分段渲染", () => {
	it("多段描述渲染为恰好 3 个 <p>，空段被丢弃", async () => {
		fetchPublicInitiative.mockResolvedValue({
			...PAYLOAD,
			description: "\n\n第一段。\n\n第二段。\n\n\n\n第三段。\n\n",
		});

		render(<InitiativeDetail slug="hackerstart1024" />);
		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		const desc = document.querySelector(".initiative-hero__desc")!;
		const paragraphs = desc.querySelectorAll("p");
		expect(paragraphs).toHaveLength(3);
		expect(paragraphs[0].textContent).toBe("第一段。");
		expect(paragraphs[1].textContent).toBe("第二段。");
		expect(paragraphs[2].textContent).toBe("第三段。");
	});

	it("描述为 null 时不渲染 .initiative-hero__desc", async () => {
		fetchPublicInitiative.mockResolvedValue({ ...PAYLOAD, description: null });

		render(<InitiativeDetail slug="hackerstart1024" />);
		await screen.findByRole("heading", { name: "Hackerstart 1024 全国黑客松" });

		expect(document.querySelector(".initiative-hero__desc")).toBeNull();
	});
});
