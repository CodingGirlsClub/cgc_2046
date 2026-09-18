import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import type { FlashbackCapsule, FlashbackCapsuleArchive } from "@/lib/graphql/flashback";
import Corridor, { cityPiles } from "./corridor";
import { tiltClass } from "./tilt";

/**
 * 长廊收口（定稿 D）：一帧只留城市照片堆 + 「进入这一场 →」入口。
 * 堆 = 名册聚合的 {city,count}（city 空值不计；count 降序 → 城市码位序；最多 4 堆）；
 * 转角确定性（tilt 类按城市名派生，禁止随机）；显影进视口才播
 * （无 IntersectionObserver / reduced-motion 直达终态）。
 */

vi.mock("@/i18n/navigation", () => ({
	Link: ({ href, children, ...rest }: { href: string; children: React.ReactNode } & Record<string, unknown>) => (
		<a href={href} {...rest}>
			{children}
		</a>
	),
	usePathname: () => "/flashback/capsule",
	useRouter: () => ({ push: vi.fn(), replace: vi.fn() }),
}));

class FakeIntersectionObserver {
	static instances: FakeIntersectionObserver[] = [];
	targets = new Set<Element>();
	constructor(private readonly callback: IntersectionObserverCallback) {
		FakeIntersectionObserver.instances.push(this);
	}
	observe(target: Element) {
		this.targets.add(target);
	}
	unobserve(target: Element) {
		this.targets.delete(target);
	}
	disconnect() {
		this.targets.clear();
	}
	/** 测试驱动：让当前观测目标全部「进入视口」 */
	enterViewport() {
		const entries = [...this.targets].map(
			(target) => ({ target, isIntersecting: true }) as IntersectionObserverEntry,
		);
		this.callback(entries, this as unknown as IntersectionObserver);
	}
}

const entry = (id: string, city: string | null): FlashbackCapsuleArchive["roster"][number] => ({
	id,
	surnameMasked: "姓**",
	city,
	occupationThen: null,
	sentToWallAt: null,
	today: null,
	answers: [],
});

const archive = (key: string, roster: FlashbackCapsuleArchive["roster"]): FlashbackCapsuleArchive => ({
	key,
	name: `场次 ${key}`,
	city: "北京",
	occurredOn: "2014-01-11",
	appliedCount: 344,
	attendedCount: roster.length,
	isMine: false,
	roster,
});

/** 帧一：4 城（第 5 城深圳被 4 堆上限截断）+ 3 条空城市名不计；帧二：单城 */
const multiCity = archive("2014-01-11-bj", [
	entry("1", "北京"),
	entry("2", "北京"),
	entry("3", "北京"),
	entry("4", "上海"),
	entry("5", "上海"),
	entry("6", "广州"),
	entry("7", "杭州"),
	entry("8", "深圳"),
	entry("9", null),
	entry("10", ""),
	entry("11", "   "),
]);
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
	cities: ["上海", "北京"],
	archives: [multiCity, singleCity],
	actionCards: [],
};

function pileClasses(): string[] {
	return [...document.querySelectorAll(".fb-corridor-polaroid")].map((node) => node.className);
}

beforeEach(() => {
	FakeIntersectionObserver.instances = [];
	vi.stubGlobal("IntersectionObserver", FakeIntersectionObserver);
});

afterEach(() => {
	cleanup();
	vi.unstubAllGlobals();
	vi.restoreAllMocks();
});

describe("cityPiles（城市堆聚合判据）", () => {
	it("city 空值/空白不计；count 降序 → 城市码位序；最多 4 堆", () => {
		expect(cityPiles(multiCity)).toEqual([
			{ city: "北京", count: 3 },
			{ city: "上海", count: 2 },
			{ city: "广州", count: 1 },
			{ city: "杭州", count: 1 },
		]);
		// 确定性：同输入恒同输出（无 Math.random）
		expect(cityPiles(multiCity)).toEqual(cityPiles(multiCity));
	});

	it("无名册 → 无堆", () => {
		expect(cityPiles(archive("empty", []))).toEqual([]);
	});
});

describe("Corridor · 城市堆与入口（定稿 D）", () => {
	it("每帧：城市堆（城市名 + 计数 + 确定性 tilt）+ 进入这一场入口；长廊零名册元素", () => {
		render(<Corridor capsule={capsule} />);

		const piles = screen.getAllByTestId("fb-corridor-pile");
		expect(piles).toHaveLength(5); // 帧一 4 堆 + 帧二 1 堆
		expect(piles.map((pile) => pile.dataset.city)).toEqual(["北京", "上海", "广州", "杭州", "上海"]);
		expect(piles.map((pile) => pile.dataset.count)).toEqual(["3", "2", "1", "1", "1"]);
		expect(piles[0]).toHaveTextContent("北京 · 3 位");
		expect(piles[4]).toHaveTextContent("上海 · 1 位");

		// 拍立得结构：纸白卡（.fb-polaroid）+ grain 质感 + 照片窗内城市名
		const first = piles[0].querySelector(".fb-corridor-polaroid") as HTMLElement;
		expect(first).toHaveClass("fb-polaroid", "fb-grain");
		expect(first.querySelector(".fb-corridor-photo")).toHaveTextContent("北京");
		// 转角确定性：城市名派生档位（同城恒同档，非随机）
		expect(first.className).toContain(tiltClass("北京"));

		// 入口保留：每帧一个「进入这一场 →」，指向场次页
		const opens = screen.getAllByRole("link", { name: "进入这一场 →" });
		expect(opens.map((link) => link.getAttribute("href"))).toEqual([
			"/flashback/event/2014-01-11-bj",
			"/flashback/event/2016-05-21-sh",
		]);

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

describe("Corridor · 城市堆显影（进视口才播）", () => {
	it("初始 --pending；进视口转 --develop 且只播一次（unobserve）", async () => {
		render(<Corridor capsule={capsule} />);

		// 每帧一个观察器（帧一 4 堆，帧二 1 堆）
		await waitFor(() => expect(FakeIntersectionObserver.instances.length).toBe(2));
		const [firstFrame, secondFrame] = FakeIntersectionObserver.instances;
		expect(firstFrame.targets.size).toBe(4);
		expect(secondFrame.targets.size).toBe(1);
		for (const className of pileClasses()) {
			expect(className).toContain("fb-corridor-polaroid--pending");
			expect(className).not.toContain("fb-corridor-polaroid--develop");
		}

		firstFrame.enterViewport();

		await waitFor(() => {
			const developed = pileClasses().filter((className) => className.includes("--develop"));
			expect(developed).toHaveLength(4);
		});
		// 第二帧未进视口 → 仍前置态；已显影的堆不再被观测
		expect(pileClasses().filter((className) => className.includes("--pending"))).toHaveLength(1);
		expect(firstFrame.targets.size).toBe(0);
	});

	it("无 IntersectionObserver：直达终态（不挂显影类）", () => {
		vi.stubGlobal("IntersectionObserver", undefined);
		render(<Corridor capsule={capsule} />);

		for (const className of pileClasses()) {
			expect(className).not.toContain("fb-corridor-polaroid--pending");
			expect(className).not.toContain("fb-corridor-polaroid--develop");
		}
	});

	it("reduced-motion：直达终态（不挂显影类）", () => {
		vi.spyOn(window, "matchMedia").mockImplementation(
			(query: string) =>
				({
					matches: query.includes("reduce"),
					media: query,
					onchange: null,
					addListener: vi.fn(),
					removeListener: vi.fn(),
					addEventListener: vi.fn(),
					removeEventListener: vi.fn(),
					dispatchEvent: vi.fn(),
				}) as unknown as MediaQueryList,
		);
		render(<Corridor capsule={capsule} />);

		for (const className of pileClasses()) {
			expect(className).not.toContain("--pending");
			expect(className).not.toContain("--develop");
		}
	});
});
