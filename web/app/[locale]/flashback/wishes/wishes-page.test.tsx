import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import WishesPage from "./wishes-page";
import {
	FLASHBACK_CITIES,
	FLASHBACK_EXPECT_WISH,
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
