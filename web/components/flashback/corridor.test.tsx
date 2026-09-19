import { afterEach, describe, expect, it, vi } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import type { FlashbackCapsule, FlashbackCapsuleArchive } from "@/lib/graphql/flashback";
import Corridor, { cityPiles } from "./corridor";

/**
 * 长廊收口（定稿 D + 收尾）：一帧只留城市照片堆（堆可点）；叙事标签 flabel。
 * 堆 = 名册聚合的 {city,count}（city 空值不计；count 降序 → 城市码位序；最多 8 堆）；
 * 显影照原型 --d 手法：加载即播、全局时间线（摞间 +0.3s、摞内 +0.2s），forwards 停雾态。
 */

const { useMutationMock } = vi.hoisted(() => ({
	useMutationMock: vi.fn(() => [vi.fn(), { loading: false }]),
}));

vi.mock("@apollo/client/react", async (importOriginal) => {
	const actual = await importOriginal<typeof import("@apollo/client/react")>();
	return { ...actual, useMutation: useMutationMock };
});

vi.mock("@/i18n/navigation", () => ({
	Link: ({ href, children, ...rest }: { href: string; children: React.ReactNode } & Record<string, unknown>) => (
		<a href={href} {...rest}>
			{children}
		</a>
	),
	usePathname: () => "/flashback/capsule",
	useRouter: () => ({ push: vi.fn(), replace: vi.fn() }),
}));

const entry = (id: string, city: string | null): FlashbackCapsuleArchive["roster"][number] => ({
	id,
	surnameMasked: "姓**",
	city,
	occupationThen: null,
	sentToWallAt: null,
	today: null,
	answers: [],
});

const archive = (
	key: string,
	roster: FlashbackCapsuleArchive["roster"],
	label?: string | null,
): FlashbackCapsuleArchive => ({
	key,
	name: `场次 ${key}`,
	city: "北京",
	occurredOn: "2014-01-11",
	appliedCount: 344,
	attendedCount: roster.length,
	label: label ?? null,
	isMine: false,
	roster,
});

/** 帧一：9 城（第 9 城「西安」按码位序被 8 堆上限截断）+ 3 条空城市名不计，带叙事标签；帧二：单城无 label（回落场次名） */
const multiCity = archive(
	"2014-01-11-bj",
	[
	entry("1", "北京"),
	entry("2", "北京"),
	entry("3", "北京"),
	entry("4", "上海"),
	entry("5", "上海"),
	entry("6", "广州"),
	entry("7", "杭州"),
	entry("8", "深圳"),
	entry("9", "南京"),
	entry("9a", "武汉"),
	entry("9b", "西安"),
	entry("9c", "成都"),
	entry("10", null),
	entry("11", ""),
	entry("12", "   "),
], "六城同日");
const singleCity = archive("2016-05-21-sh", [entry("12", "上海")]);

const capsule: FlashbackCapsule = {
	me: {
		id: "me-1",
		fullName: "王晓雨",
		city: "上海",
		occupationThen: "校对",
		participation: "attended",
		appliedAt: "2012-02-20T11:03:00Z",
		today: null,
		quote: null,
		answers: [],
	},
	futureEvents: [],
	publicWishes: [],
	myPrivateWishes: [],
	cities: ["上海", "北京"],
	archives: [multiCity, singleCity],
};

afterEach(() => {
	cleanup();
	vi.restoreAllMocks();
});

describe("cityPiles（城市堆聚合判据）", () => {
	it("city 空值/空白不计；count 降序 → 城市码位序；最多 8 堆", () => {
		expect(cityPiles(multiCity)).toEqual([
			{ city: "北京", count: 3 },
			{ city: "上海", count: 2 },
			{ city: "南京", count: 1 },
			{ city: "广州", count: 1 },
			{ city: "成都", count: 1 },
			{ city: "杭州", count: 1 },
			{ city: "武汉", count: 1 },
			{ city: "深圳", count: 1 },
		]);
		// 确定性：同输入恒同输出（无 Math.random）
		expect(cityPiles(multiCity)).toEqual(cityPiles(multiCity));
	});

	it("无名册 → 无堆", () => {
		expect(cityPiles(archive("empty", []))).toEqual([]);
	});
});

describe("Corridor · 城市堆与入口（定稿 D）", () => {
	it("每帧：一城一摞（4 张层叠拍立得）+ 计数，堆可点 + 叙事标签；长廊零名册元素", () => {
		render(<Corridor capsule={capsule} />);

		const piles = screen.getAllByTestId("fb-corridor-pile");
		expect(piles).toHaveLength(9); // 帧一 8 堆 + 帧二 1 堆
		expect(piles.map((pile) => pile.dataset.city)).toEqual([
			"北京", "上海", "南京", "广州", "成都", "杭州", "武汉", "深圳", "上海",
		]);
		expect(piles.map((pile) => pile.dataset.count)).toEqual(["3", "2", "1", "1", "1", "1", "1", "1", "1"]);
		expect(piles[0]).toHaveTextContent("北京 · 3 位");
		expect(piles[7]).toHaveTextContent("深圳 · 1 位");
		expect(piles[8]).toHaveTextContent("上海 · 1 位");

		// 一城一摞（原型错落感）：堆容器 + 同卡 4 张层叠；纸白卡 + grain + 窗内城市名
		const stack = piles[0].querySelector(".fb-corridor-stack") as HTMLElement;
		expect(stack).not.toBeNull();
		const cards = stack.querySelectorAll(".fb-corridor-polaroid");
		expect(cards).toHaveLength(4);
		expect(cards[0]).toHaveClass("fb-polaroid", "fb-grain");
		expect(cards[0].querySelector(".fb-corridor-photo")).toHaveTextContent("北京");
		// 每张都印窗下小字（原型 caption）
		expect(cards[3].querySelector(".fb-corridor-caption")).toHaveTextContent("3 位 · 她们的档案");

		// 文字链接已下线（堆可点后多此一举）：长廊内无「进入这一场 →」
		expect(screen.queryAllByRole("link", { name: "进入这一场 →" })).toHaveLength(0);
		// 叙事标签（原型 D ia-frame-label）：label 优先，缺失回落场次名
		const whens = screen.getAllByTestId("fb-corridor-when");
		expect(whens[0]).toHaveTextContent("六城同日");
		expect(whens[1]).toHaveTextContent("场次 2016-05-21-sh");

		// 堆可点（用户定稿收尾）：每个堆整体是链接，与帧头入口并存、同目标
		const pileLinks = piles.map((pile) => pile.querySelector("a"));
		expect(pileLinks.every((link) => link !== null)).toBe(true);
		expect(pileLinks[0]!.getAttribute("href")).toBe("/flashback/event/2014-01-11-bj");
		expect(pileLinks[7]!.getAttribute("href")).toBe("/flashback/event/2014-01-11-bj");
		expect(pileLinks[8]!.getAttribute("href")).toBe("/flashback/event/2016-05-21-sh");

		// 名册已整体归场次页：长廊内零 .fb-roster-*
		expect(document.querySelector(".fb-roster-card, .fb-roster-grid, .fb-roster-meta")).toBeNull();
	});

	it("城市钉筛选且该城无名册：空态提示 + 「今天」格仍在", () => {
		render(<Corridor capsule={{ ...capsule, archives: [] }} cityFiltered />);

		expect(screen.getByText("这座城市还没有名册照片。")).toBeInTheDocument();
		expect(screen.getByTestId("fb-today-slot")).toBeInTheDocument();
		expect(screen.queryAllByTestId("fb-corridor-pile")).toHaveLength(0);
	});
});

describe("Corridor · 城市堆显影（原型 --d 全局时间线）", () => {
	it("每张卡常驻显影动画；--fb-d = (count%5)*0.3 + i*0.2（人数取模打散，群星闪耀）", () => {
		render(<Corridor capsule={capsule} />);

		const cards = [...document.querySelectorAll(".fb-corridor-polaroid")] as HTMLElement[];
		expect(cards.every((card) => card.classList.contains("fb-develop-soft"))).toBe(true);
		// 帧一前 3 摞：北京3 → 0.9 起；上海2 → 0.6 起；南京1 → 0.3 起（摞内 +0.2 步进）
		const delays = cards.slice(0, 12).map((card) => card.style.getPropertyValue("--fb-d"));
		expect(delays).toEqual([
			"0.9s", "1.1s", "1.3s", "1.5s",
			"0.6s", "0.8s", "1.0s", "1.2s",
			"0.3s", "0.5s", "0.7s", "0.9s",
		]);
		// 帧二上海 1 位 → 0.3 起（与帧一的 1 位城同刻——跨帧同时闪耀）
		const secondFrameCards = [...document.querySelectorAll(".fb-corridor-frame")[1].querySelectorAll(".fb-corridor-polaroid")] as HTMLElement[];
		expect(secondFrameCards.map((card) => card.style.getPropertyValue("--fb-d"))).toEqual([
			"0.3s", "0.5s", "0.7s", "0.9s",
		]);
	});
});
