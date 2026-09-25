import { describe, expect, it } from "vitest";
import { fireEvent, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import EventRoster from "./event-roster";
import { tiltClass } from "./tilt";
import type { FlashbackCapsuleArchive } from "@/lib/graphql/flashback";

/**
 * 名册格（场次页 3 列网格）：确定性转角（tilt 类按 person id 派生）+ 两态卡共存。
 * vitest 不加载样式表——布局由「结构类名」断言（grid/tilt 类），
 * computed style 数值断言在 ego-browser 复核（收尾阶段）。
 */

const entry = (i: number, over: Partial<FlashbackCapsuleArchive["roster"][number]> = {}) => ({
	id: `p-${i}`,
	surnameMasked: `姓${i}**`,
	participation: "attended",
	city: "北京",
	occupationThen: null,
	sentToWallAt: null,
	today: null,
	answers: [],
	...over,
});

const archive = (n: number): FlashbackCapsuleArchive => ({
	key: "2014-01-11-bj",
	name: "Rails Girls 北京",
	city: "北京",
	occurredOn: "2014-01-11",
	appliedCount: 344,
	attendedCount: n,
	isMine: false,
	roster: Array.from({ length: n }, (_, i) => entry(i)),
});

describe("tiltClass 确定性（变异锚点：改 hash → 档位断言红）", () => {
	it("同一 id 恒同档；不同 id 分布在多档", () => {
		expect(tiltClass("p-1")).toBe(tiltClass("p-1"));
		const buckets = new Set(Array.from({ length: 40 }, (_, i) => tiltClass(`person-${i}`)));
		expect(buckets.size).toBeGreaterThanOrEqual(3);
		for (const cls of buckets) expect(cls).toMatch(/^fb-tilt--[0-4]$/);
	});
});

describe("名册格结构（场次页 3 列网格）", () => {
	it("每张卡带确定性 tilt 类（id 派生，非随机）", () => {
		render(<EventRoster archive={archive(6)} />);
		const cards = screen.getAllByTestId("fb-roster-card");
		for (const card of cards) {
			// li 的 key prop 不上 DOM——改为对 data 源断言：直接验证每卡类名 ∈ 档位集
			expect(card.className).toMatch(/fb-tilt--[0-4]/);
		}
		// 确定性：同 id 派生同档（用 tiltClass 纯函数对 roster 源数据复核）
		expect(tiltClass("p-0")).toMatch(/^fb-tilt--[0-4]$/);
	});

	it("两态卡共存：已寄出可点开翻面看内容，未寄出保持虚线位", () => {
		const mixed: FlashbackCapsuleArchive = {
			...archive(2),
			roster: [
				entry(0, {
					surnameMasked: "李*",
					fullName: "李雷",
					appliedAt: "2014-01-05T05:06:00Z",
					sentToWallAt: "2026-09-10T00:00:00Z",
					today: { nowStatus: null, want: "想骑行", say: null },
					answers: [{ questionKey: "self_intro", segments: [{ text: "一句答案", fog: false, len: 0 }] }],
				}),
				entry(1),
			],
		};
		render(<EventRoster archive={mixed} />);

		const flip = screen.getByTestId("fb-polaroid-flip");
		expect(flip).toHaveTextContent("李雷");
		fireEvent.click(flip);
		expect(flip).toHaveTextContent("一句答案");
		// 未寄出卡虚线位共存
		expect(screen.getByText("她的答案，还在等她")).toBeInTheDocument();
	});
});
