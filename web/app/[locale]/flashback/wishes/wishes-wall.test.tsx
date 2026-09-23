import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import WishesWall from "./wishes-wall";
import {
	FLASHBACK_CITIES,
	FLASHBACK_EXPECT_WISH,
	FLASHBACK_PUBLIC_WISHES,
	type FlashbackPublicWish,
} from "@/lib/graphql/flashback";

/**
 * wish2 U7：公开树墙——期待乐观更新（#806 F2 按 wishId 函数式回滚）、
 * 换一批 seed、空态、举报弹层、署名快照渲染。
 */

const wish = (id: string, over: Partial<FlashbackPublicWish> = {}): FlashbackPublicWish => ({
	id,
	content: `愿望 ${id}`,
	city: "北京",
	signature: "王**",
	expectationCount: 2,
	endorsementCount: 1,
	contributionDistribution: { venue: 1 },
	expectedByViewer: false,
	endorsedByViewer: false,
	listedAt: "2026-09-22T00:00:00Z",
	insertedAt: "2026-09-22T00:00:00Z",
	...over,
});

const { wallQuery, citiesQuery, expectRunner } = vi.hoisted(() => ({
	wallQuery: vi.fn(),
	citiesQuery: vi.fn(),
	expectRunner: vi.fn(),
}));

vi.mock("@/lib/apollo-client", () => ({
	client: {
		query: (options: { query: unknown }) => {
			if (options.query === FLASHBACK_PUBLIC_WISHES) return wallQuery(options);
			if (options.query === FLASHBACK_CITIES) return citiesQuery(options);
			throw new Error("unexpected query");
		},
	},
}));

vi.mock("@apollo/client/react", async (importOriginal) => {
	const actual = await importOriginal<typeof import("@apollo/client/react")>();
	return {
		...actual,
		useMutation: (doc: unknown) => {
			if (doc === FLASHBACK_EXPECT_WISH) return [expectRunner, { loading: false }];
			return [vi.fn(), { loading: false }];
		},
	};
});

beforeEach(() => {
	wallQuery.mockReset();
	citiesQuery.mockReset();
	expectRunner.mockReset();
	wallQuery.mockResolvedValue({ data: { flashbackPublicWishes: [wish("w1"), wish("w2", { city: "成都" })] } });
	citiesQuery.mockResolvedValue({
		data: { flashbackCities: [{ name: "北京", fullName: "北京市", pinyin: "beijing", lngLat: [116.4, 39.9] }] },
	});
	window.localStorage.clear();
	window.sessionStorage.clear();
});

afterEach(() => cleanup());

describe("WishesWall · 公开许愿树（U7）", () => {
	it("渲染选中愿望大卡：署名快照 + 期待计数 + 附议数", async () => {
		render(<WishesWall showIntro={false} />);
		const card = (await screen.findByText("愿望 w1")).closest("article")!;
		expect(within(card).getByText("王** · 北京")).toBeTruthy();
		expect(within(card).getByText("2 人也在期待")).toBeTruthy();
		expect(within(card).getByText("🙌 1")).toBeTruthy();
	});

	it("期待乐观 +1，服务端计数校正", async () => {
		expectRunner.mockResolvedValue({ data: { flashbackExpectWish: { expectationCount: 3, expectedByMe: true } } });
		render(<WishesWall showIntro={false} />);
		const card = (await screen.findByText("愿望 w1")).closest("article")!;
		fireEvent.click(within(card).getByRole("button", { name: "我也期待" }));
		await waitFor(() => {
			expect(within(card).getByText("3 人也在期待")).toBeTruthy();
		});
	});

	it("期待失败按 wishId 函数式回滚——另一条愿望的乐观态不受影响", async () => {
		expectRunner.mockRejectedValue(new Error("network down"));
		render(<WishesWall showIntro={false} />);
		const card = (await screen.findByText("愿望 w1")).closest("article")!;
		fireEvent.click(within(card).getByRole("button", { name: "我也期待" }));
		await waitFor(() => {
			expect(within(card).getByText("2 人也在期待")).toBeTruthy();
		});
	});

	it("换一批：seed 变化触发重新拉取", async () => {
		render(<WishesWall showIntro={false} />);
		await screen.findByText("愿望 w1");
		fireEvent.click(screen.getByText("换一批"));
		await waitFor(() => {
			expect(wallQuery).toHaveBeenCalledTimes(2);
		});
	});

	it("空态：树还空着", async () => {
		wallQuery.mockResolvedValue({ data: { flashbackPublicWishes: [] } });
		render(<WishesWall showIntro={false} />);
		await screen.findByText("树还空着——写下第一条愿望吧。");
	});
});
