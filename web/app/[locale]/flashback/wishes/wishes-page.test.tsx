import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import WishesPage from "./wishes-page";
import {
	FLASHBACK_CITIES,
	FLASHBACK_WISH_CITIES,
	FLASHBACK_EXPECT_WISH,
	FLASHBACK_PUBLIC_WISH,
	FLASHBACK_PUBLIC_WISHES,
	type FlashbackPublicWish,
} from "@/lib/graphql/flashback";

/**
 * 001 护栏：wishes 页参与 SSR 后——「mount 链路没断」与「KTD8 开场标记仍写」两条
 * 轻量客户端回归（真红绿闸门是 dev server 的一抓一剥三断言，见 plans/001 Step 3）。
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
	latestEcho: null,
	echoCount: 0,
	echoes: [],
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
		query: (options: { query: unknown; variables?: { wishId?: string } }) => {
			if (options.query === FLASHBACK_PUBLIC_WISHES) return wallQuery(options);
			if (options.query === FLASHBACK_CITIES) return citiesQuery(options);
			if (options.query === FLASHBACK_WISH_CITIES) return citiesQuery(options);
			if (options.query === FLASHBACK_PUBLIC_WISH) {
				if (options.variables?.wishId === "wb-net-fail") {
					return Promise.reject(new Error("network down"));
				}
				return Promise.resolve({ data: { flashbackPublicWish: null } });
			}
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
	wallQuery.mockResolvedValue({ data: { flashbackPublicWishes: [wish("w1")] } });
	citiesQuery.mockResolvedValue({
		data: { flashbackCities: [{ name: "北京", fullName: "北京市", pinyin: "beijing", lngLat: [116.4, 39.9] }] },
	});
	window.localStorage.clear();
	window.sessionStorage.clear();
});

afterEach(() => cleanup());

describe("WishesPage · SSR 参与后的客户端回归（001）", () => {
	it("mount 后展示墙（护栏：mount 链路没断）", async () => {
		render(<WishesPage />);
		await screen.findByText("换一批");
	});

	it("开场标记仍被写入 localStorage（KTD8 行为不回退）", async () => {
		render(<WishesPage />);
		await waitFor(() => {
			expect(window.localStorage.getItem("flashback.wishesIntroSeen")).toBe("1");
		});
	});
});

describe("WishesPage · ?item= 直达失败口径", () => {
	it("网络失败按「只是网络问题」呈现（loadError），不谎报「这个愿望目前无法查看」", async () => {
		render(<WishesPage item="wb-net-fail" />);
		// 隐藏的
		await screen.findByText("这条心愿暂时没加载出来");
		expect(screen.getByText(/多半只是网络问题/)).toBeInTheDocument();
		expect(screen.queryByText("这个愿望目前无法查看")).not.toBeInTheDocument();
	});

	it("查无此愿：仍走「这个愿望目前无法查看」（gone 口径独立分开）", async () => {
		render(<WishesPage item="wb-absent" />);
		await screen.findByText("这个愿望目前无法查看");
		expect(screen.queryByText("这条心愿暂时没加载出来")).not.toBeInTheDocument();
	});
});
