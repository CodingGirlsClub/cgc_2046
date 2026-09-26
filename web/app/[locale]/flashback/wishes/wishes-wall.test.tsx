import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import WishesWall from "./wishes-wall";
import {
	FLASHBACK_CITIES,
	FLASHBACK_WISH_CITIES,
	FLASHBACK_EXPECT_WISH,
	FLASHBACK_MY_WISHES,
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

const { wallQuery, citiesQuery, nationalCitiesQuery, myWishesQuery, expectRunner, deferred, useAuthed } = vi.hoisted(() => ({
	wallQuery: vi.fn(),
	citiesQuery: vi.fn(),
	nationalCitiesQuery: vi.fn(),
	myWishesQuery: vi.fn(),
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
			if (options.query === FLASHBACK_WISH_CITIES) return citiesQuery(options);
			if (options.query === FLASHBACK_CITIES) return nationalCitiesQuery(options);
			if (options.query === FLASHBACK_MY_WISHES) return myWishesQuery(options);
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
	nationalCitiesQuery.mockReset();
	nationalCitiesQuery.mockResolvedValue({ data: { flashbackCities: [{ name: "北京" }, { name: "上海" }, { name: "广州" }] } });
	myWishesQuery.mockReset();
	myWishesQuery.mockResolvedValue({ data: { flashbackMyWishes: { quotaRemaining: 3, wishes: [] } } });
	expectRunner.mockReset();
	useAuthed.mockReset();
	useAuthed.mockReturnValue({ authed: false, confirmed: true, userId: null });
	deferred.length = 0;
	wallQuery.mockResolvedValue({ data: { flashbackPublicWishes: [wish("w1"), wish("w2", { city: "成都" })] } });
	citiesQuery.mockResolvedValue({
		data: {
			flashbackWishCities: [
				{ name: "北京", fullName: "北京市", pinyin: "beijing", lngLat: [116.4, 39.9] },
				{ name: "成都", fullName: "成都市", pinyin: "chengdu", lngLat: [104.07, 30.57] },
				{ name: "宁波", fullName: "宁波市", pinyin: "ningbo", lngLat: [121.55, 29.87] },
			],
		},
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

// M8+L7：「已有回响」改服务端 withEchoes 筛选；每页 24 条 + 「加载更多」翻页。
describe("回响筛选与分页", () => {
 it("初始请求每页 24 条", async () => {
  render(<WishesWall showIntro={false} />);
  await screen.findByText("愿望 w1");
  expect(wallQuery.mock.calls[0][0].variables.limit).toBe(24);
  expect(wallQuery.mock.calls[0][0].variables.withEchoes).toBeFalsy();
 });

 it("「已有回响」chips 改服务端筛选：withEchoes=true 重拉", async () => {
  render(<WishesWall showIntro={false} />);
  await screen.findByText("愿望 w1");
  fireEvent.click(screen.getByRole("button", { name: "已有回响" }));
  await waitFor(() => expect(wallQuery).toHaveBeenCalledTimes(2));
  const vars = wallQuery.mock.calls[1][0].variables;
  expect(vars.withEchoes).toBe(true);
  expect(vars.limit).toBe(24);
  expect(screen.getByRole("button", { name: "已有回响" })).toHaveAttribute("aria-pressed", "true");
 });

 it("加载更多：按 offset 追加下一页；不足一页时按钮消失", async () => {
  const page1 = Array.from({ length: 24 }, (_, i) => wish(`w-${i}`));
  wallQuery.mockResolvedValueOnce({ data: { flashbackPublicWishes: page1 } });
  render(<WishesWall showIntro={false} />);
  await screen.findByText("愿望 w-0");
  expect(screen.getByRole("button", { name: "加载更多" })).toBeInTheDocument();

  wallQuery.mockResolvedValueOnce({ data: { flashbackPublicWishes: [wish("w-24")] } });
  fireEvent.click(screen.getByRole("button", { name: "加载更多" }));
  await screen.findByText("愿望 w-24");
  expect(wallQuery.mock.calls[1][0].variables.offset).toBe(24);
  expect(screen.queryByRole("button", { name: "加载更多" })).toBeNull();
 });
});

// L1：未登录写愿望的登录回跳保留城市与单条直达上下文
// PR #960 评审 3：城市钉数据源 = flashbackWishCities（全集），
// 收成每页 24 条之后城市栏不随已加载页变残
describe("城市钉真源", () => {
 it("城市钉来自 flashbackWishCities，不在已加载页里的城市也在列", async () => {
  render(<WishesWall showIntro={false} />);
  await screen.findByText("愿望 w1");
  // MapScene 城市钉按钮：aria-label = 城市名
  expect(screen.getByRole("button", { name: "宁波" })).toBeInTheDocument();
 });
});

describe("写愿望登录回跳", () => {
 it("next 带当前城市与 ?item= 单条", async () => {
  render(<WishesWall showIntro={false} initialItem={wish("w-item")} initialCity="北京" />);
  const link = await screen.findByRole("link", { name: /写下我的愿望/ });
  expect(link.getAttribute("href")).toContain("next=%2Fflashback%2Fwishes%3Fcity%3D");
  expect(link.getAttribute("href")).toContain("item%3Dw-item");
 });
});

// N10/M2：承诺不存在的「新进展提醒」文案已删——组件不得再引用，文案不得回流。
describe("文案守卫", () => {
 it("不再承诺可选择接收提醒", () => {
  const source = readFileSync(fileURLToPath(new URL("./wishes-wall.tsx", import.meta.url.split("?")[0])), "utf8");
  expect(source).not.toContain("remindHint");
  const zh = JSON.parse(readFileSync(fileURLToPath(new URL("../../../../messages/zh-CN.json", import.meta.url.split("?")[0])), "utf8"));
  expect(JSON.stringify(zh)).not.toContain("可选择接收提醒");
 });
});
