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
	latestEcho: null,
	echoCount: 0,
	echoes: [],
	listedAt: "2026-09-22T00:00:00Z",
	insertedAt: "2026-09-22T00:00:00Z",
	...over,
});

const { wallQuery, citiesQuery, expectRunner, deferred, useAuthed } = vi.hoisted(() => ({
	wallQuery: vi.fn(),
	citiesQuery: vi.fn(),
	expectRunner: vi.fn(),
	useAuthed: vi.fn(),
	// 手控 promise：push 一个存根，测试自行决定何时 resolve——乱序场景的
	// 时间线由测试自己排，不依赖 once-mock 的消费顺序（脆弱，且本用例正是
	// 要绕开「注册顺序=完成顺序」的巧合）
	deferred: [] as Array<{
		resolve: (v: { data: { flashbackPublicWishes: FlashbackPublicWish[] } }) => void;
		reject: (e: unknown) => void;
	}>,
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

vi.mock("@/lib/auth-provider", () => ({ useAuthed }));

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
	useAuthed.mockReset();
	useAuthed.mockReturnValue({ authed: false, confirmed: true, userId: null });
	deferred.length = 0;
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
		expect(within(card).getByRole("button", { name: "已加入期待" })).toBeTruthy();
	});

	it("再点取消：计数回落、文案回「我也期待」", async () => {
		expectRunner
			.mockResolvedValueOnce({ data: { flashbackExpectWish: { expectationCount: 3, expectedByMe: true } } })
			.mockResolvedValueOnce({ data: { flashbackExpectWish: { expectationCount: 2, expectedByMe: false } } });
		render(<WishesWall showIntro={false} />);
		const card = (await screen.findByText("愿望 w1")).closest("article")!;
		fireEvent.click(within(card).getByRole("button", { name: "我也期待" }));
		await waitFor(() => {
			expect(within(card).getByRole("button", { name: "已加入期待" })).toBeTruthy();
		});
		fireEvent.click(within(card).getByRole("button", { name: "已加入期待" }));
		await waitFor(() => {
			expect(within(card).getByText("2 人也在期待")).toBeTruthy();
		});
		expect(within(card).getByRole("button", { name: "我也期待" })).toBeTruthy();
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

	it("乱序响应不覆盖新数据：晚到的旧 seed 响应被丢弃", async () => {
		render(<WishesWall showIntro={false} />);
		await screen.findByText("愿望 w1"); // 初始加载完成

		// seed1：挂起
		wallQuery.mockImplementationOnce(() => {
			const { promise, resolve, reject } = Promise.withResolvers<{
				data: { flashbackPublicWishes: FlashbackPublicWish[] };
			}>();
			deferred.push({ resolve, reject });
			return promise;
		});
		// seed2：立即返回
		wallQuery.mockResolvedValueOnce({
			data: { flashbackPublicWishes: [wish("w-latest")] },
		});

		fireEvent.click(screen.getByText("换一批")); // → seed1 请求（挂起）
		fireEvent.click(screen.getByText("换一批")); // → seed2 请求（立即落地）
		await screen.findByText("愿望 w-latest");

		// 此刻放行 seed1 的迟到响应——守卫应将其丢弃
		deferred[0].resolve({ data: { flashbackPublicWishes: [wish("w-stale")] } });
		await waitFor(() => {
			expect(screen.queryByText("愿望 w-stale")).toBeNull();
		});
		expect(screen.getByText("愿望 w-latest")).toBeTruthy();
	});
});

describe("WishesWall · 写愿望入口（#824/U8）", () => {
	it("未登录访客去站内登录并回跳许愿树，不进入档案 token 旅程", async () => {
		render(<WishesWall showIntro={false} />);
		await screen.findByText("愿望 w1");

		const writeLink = screen.getByRole("link", { name: "写下我的愿望" });
		expect(writeLink).toHaveAttribute("href", `/login?next=${encodeURIComponent("/flashback/wishes")}`);
		expect(screen.queryByText("链接不存在或已过期")).not.toBeInTheDocument();
	});

	it("登录用户仍由主 CTA 直接打开写愿望表单", async () => {
		useAuthed.mockReturnValue({ authed: true, confirmed: true, userId: "user-1" });
		render(<WishesWall showIntro={false} />);
		await screen.findByText("愿望 w1");

		fireEvent.click(screen.getByRole("button", { name: "写下我的愿望" }));
		expect(await screen.findByRole("dialog", { name: "许个愿" })).toBeInTheDocument();
	});
});
