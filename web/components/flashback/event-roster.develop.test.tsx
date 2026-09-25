import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import type { FlashbackCapsuleArchive } from "@/lib/graphql/flashback";
import EventRoster from "./event-roster";
import { developClass } from "./use-develop-on-view";

/**
 * 第 7a 件：名册显影——进视口才播（--pending → --develop，只播一次），
 * 无 IntersectionObserver 时直达终态（无显影类）；reduced-motion 不短路显影（叙事动画）。
 */

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

const archive: FlashbackCapsuleArchive = {
	key: "2014-01-11-bj",
	name: "Rails Girls 北京",
	occurredOn: "2014-01-11",
	appliedCount: 344,
	attendedCount: 3,
	isMine: false,
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
			today: null,
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
	],
};

function cardClasses(): string[] {
	return [...document.querySelectorAll("[data-testid='fb-roster-card']")].map((node) => node.className);
}

beforeEach(() => {
	FakeIntersectionObserver.instances = [];
	vi.stubGlobal("IntersectionObserver", FakeIntersectionObserver);
});

afterEach(() => {
	cleanup();
	vi.unstubAllGlobals();
});

describe("EventRoster · 视口内显影（第 7a 件）", () => {
	it("初始为前置态（--pending）；进视口后转 --develop 且只播一次（unobserve）", async () => {
		render(<EventRoster archive={archive} />);

		await waitFor(() => expect(FakeIntersectionObserver.instances.length).toBe(1));
		const observer = FakeIntersectionObserver.instances[0];
		expect(observer.targets.size).toBe(3);
		for (const className of cardClasses()) {
			expect(className).toContain("fb-roster-card--pending");
			expect(className).not.toContain("fb-roster-card--develop");
		}

		observer.enterViewport();

		await waitFor(() => {
			for (const className of cardClasses()) {
				expect(className).toContain("fb-roster-card--develop");
				expect(className).not.toContain("fb-roster-card--pending");
			}
		});
		// 只播一次：已显影的卡不再被观测
		expect(observer.targets.size).toBe(0);
	});

	it("无 IntersectionObserver：直达终态（不挂显影类）", () => {
		vi.stubGlobal("IntersectionObserver", undefined);
		render(<EventRoster archive={archive} />);

		for (const className of cardClasses()) {
			expect(className).not.toContain("fb-roster-card--pending");
			expect(className).not.toContain("fb-roster-card--develop");
		}
	});

	it("版式为拍立得结构（第 7c 件）：雾卡透明窗 + 已寄出灰窗", () => {
		render(<EventRoster archive={archive} />);

		// 未寄出：虚框雾卡——窗内姓氏隐名 + 窗下小字「她的答案，还在等她」
		const quiet = document.querySelector("[data-card-id='p1']") as HTMLElement;
		expect(quiet.querySelector(".fb-roster-photo")).toBeTruthy();
		expect(quiet.querySelector(".fb-roster-photo")?.textContent).toBe("王**");
		expect(quiet.textContent).toContain("她的答案，还在等她");

		// 已寄出：纸白卡 + 灰窗（封面窗内含全名）
		const sent = document.querySelector("[data-card-id='p2']") as HTMLElement;
		expect(sent.className).toContain("fb-roster-card--lit");
		expect(sent.querySelector(".fb-flip-cover-photo")?.textContent).toContain("李雷");
		expect(sent.querySelector(".fb-flip-cover-facts")?.textContent).toBe("2013 · 北京");
	});
});

describe("developClass（判据单源，名册与城市堆共用）", () => {
	it("active=false → 无类（终态）；未显影 → pending；已显影 → develop", () => {
		expect(developClass("fb-roster-card", false, false)).toBe("");
		expect(developClass("fb-roster-card", false, true)).toBe("");
		expect(developClass("fb-roster-card", true, false)).toBe(" fb-roster-card--pending");
		expect(developClass("fb-roster-card", true, true)).toBe(" fb-roster-card--develop");
		expect(developClass("fb-corridor-polaroid", true, false)).toBe(" fb-corridor-polaroid--pending");
	});
});
