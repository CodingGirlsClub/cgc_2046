import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cleanup, fireEvent, screen, waitFor, within } from "@testing-library/react";
import { render } from "@/test-utils";
import VoicesWall from "./voices-wall";
import VoicesPage from "./voices-page";
import styles from "./voices.module.css";
import {
	FLASHBACK_LIKE_QUOTE,
	FLASHBACK_PUBLIC_QUOTE,
	FLASHBACK_PUBLIC_QUOTES,
	FLASHBACK_RANDOM_QUOTES,
	FLASHBACK_VOICE_CITIES,
	type FlashbackPublicQuote,
} from "@/lib/graphql/flashback";

/**
 * 金句墙生产页测试（U3/U4/U6/U8）：
 *
 * - 加载/失败/空态三分支（计划 U3 验收底线）；
 * - `?item=` 直达：有效 → 定位该句不播开场；失效 → 失效视图 + 看全墙入口（U4）；
 * - 点赞乐观更新 + 失败回滚（R11）；
 * - R27 首赞轻提示：每会话一次、可关闭、不遮挡赞/分享按钮（结构断言）；
 * - R28：credited 署名为链接（href 正确）、匿名无链接（U8）；
 * - 长句排版：overflow-wrap 生效（结构断言，R23）；
 * - 减少动态效果/白昼：直接白昼（R24）。
 */

// 样式单源（结构断言用）：CSS module 规则不进 happy-dom computed style，
// 直接读文件钉声明（变异验证：改坏声明断言必红）。import.meta.url 在 vitest
// 下是 file 路径（可能带查询串）——fileURLToPath 前先剥查询。
const stylesSource = readFileSync(
	fileURLToPath(new URL("./voices.module.css", import.meta.url.split("?")[0])),
	"utf8",
);

const quote = (over: Partial<FlashbackPublicQuote> = {}): FlashbackPublicQuote => ({
	text: "我想成为一个，敢说「我不会，但我可以学」的人。",
	attribution: "王** · 2014 · 北京",
	level: "anonymous",
	publicSlug: null,
	quoteId: "q-1",
	city: "北京",
	year: 2014,
	likeCount: 32,
	likedByViewer: false,
	...over,
});

const quotesList: FlashbackPublicQuote[] = [
	quote(),
	quote({
		quoteId: "q-2",
		text: "原来我也可以，是改变的开始。",
		attribution: "林晓 · 2016 · 上海",
		city: "上海",
		year: 2016,
		likeCount: 46,
	}),
	quote({
		quoteId: "q-3",
		text: "希望十年后的我，还保留着今天的好奇心。这是一句更长的金句，用来验证三行排版不会把布局撑破、不会出现横向溢出。",
		attribution: "张** · 2012 · 杭州",
		level: "credited",
		publicSlug: "zhang-ming",
		city: "杭州",
		year: 2012,
		likeCount: 39,
	}),
];

const wallQuery = vi.fn();
const randomQuery = vi.fn();
const singleQuery = vi.fn();
const voiceCitiesQuery = vi.fn();

vi.mock("@/lib/apollo-client", () => ({
	client: {
		query: (options: { query: unknown }) => {
			if (options.query === FLASHBACK_PUBLIC_QUOTES) return wallQuery(options);
			if (options.query === FLASHBACK_RANDOM_QUOTES) return randomQuery(options);
			if (options.query === FLASHBACK_PUBLIC_QUOTE) return singleQuery(options);
			if (options.query === FLASHBACK_VOICE_CITIES) return voiceCitiesQuery(options);
			throw new Error("unexpected query");
		},
	},
}));

const { likeRunner } = vi.hoisted(() => ({ likeRunner: vi.fn() }));

vi.mock("@apollo/client/react", async (importOriginal) => {
	const actual = await importOriginal<typeof import("@apollo/client/react")>();
	return {
		...actual,
		useMutation: (doc: unknown) => {
			if (doc === FLASHBACK_LIKE_QUOTE) return [likeRunner, { loading: false }];
			return [vi.fn(), { loading: false }];
		},
	};
});

beforeEach(() => {
	wallQuery.mockReset();
	randomQuery.mockReset();
	singleQuery.mockReset();
	likeRunner.mockReset();
	voiceCitiesQuery.mockReset();
	// M10：城市真源 = flashbackVoiceCities（有金句的城市全集，不受热门限量）；
	// 宁波不在旧 45 城静态表内
	voiceCitiesQuery.mockResolvedValue({
		data: {
			flashbackVoiceCities: [
				{ name: "北京", pinyin: "beijing", lngLat: [116.4, 39.9] },
				{ name: "上海", pinyin: "shanghai", lngLat: [121.47, 31.23] },
				{ name: "杭州", pinyin: "hangzhou", lngLat: [120.15, 30.27] },
				{ name: "宁波", pinyin: "ningbo", lngLat: [121.55, 29.87] },
			],
		},
	});
	// 服务端语义：city 筛选先于热门限量
	wallQuery.mockImplementation(({ variables } = {}) => {
		const city = (variables as { city?: string } | undefined)?.city;
		const list = city ? quotesList.filter((q) => q.city === city) : quotesList;
		return Promise.resolve({ data: { flashbackPublicQuotes: list } });
	});
	randomQuery.mockResolvedValue({ data: { flashbackRandomQuotes: [] } });
	likeRunner.mockResolvedValue({ data: { flashbackLikeQuote: { likeCount: 33 } } });
	window.localStorage.clear();
	window.sessionStorage.clear();
});

afterEach(() => {
	cleanup();
	vi.restoreAllMocks();
});

describe("VoicesWall · 数据面（U3）", () => {
	it("加载成功渲染金句/署名/计数；credited 署名链档案页（U8）、匿名无链接", async () => {
		render(<VoicesWall showIntro={false} />);

		// 首句（涌现序第一条）
		expect(await screen.findByTestId("selected-text")).toHaveTextContent(
			"我想成为一个，敢说「我不会，但我可以学」的人。",
		);
		expect(screen.getByTestId("quote-like")).toHaveTextContent("32");

		// 切到 credited 句：署名为链接（U8）
		fireEvent.click(screen.getByRole("button", { name: /下一句/ }));
		fireEvent.click(screen.getByRole("button", { name: /下一句/ }));
		const link = await screen.findByTestId("quote-attribution-link");
		expect(link).toHaveAttribute("href", "/flashback/zhang-ming");

		// 回匿名句：无链接（R28 匿名档无任何身份入口）
		fireEvent.click(screen.getByRole("button", { name: /上一句/ }));
		fireEvent.click(screen.getByRole("button", { name: /上一句/ }));
		await waitFor(() =>
			expect(screen.queryByTestId("quote-attribution-link")).not.toBeInTheDocument(),
		);
	});

	it("失败态：加载失败渲染重试分支；点重试重新拉取", async () => {
		wallQuery.mockRejectedValueOnce(new Error("network"));
		render(<VoicesWall showIntro={false} />);

		expect(await screen.findByRole("button", { name: "重试" })).toBeInTheDocument();

		wallQuery.mockResolvedValue({ data: { flashbackPublicQuotes: quotesList } });
		fireEvent.click(screen.getByRole("button", { name: "重试" }));
		expect(await screen.findByTestId("selected-text")).toBeInTheDocument();
	});

	it("空态：无授权句时显示空墙文案而非报错", async () => {
		wallQuery.mockResolvedValue({ data: { flashbackPublicQuotes: [] } });
		render(<VoicesWall showIntro={false} />);

		expect(await screen.findByTestId("voices-empty")).toHaveTextContent(
			"金句墙还空着——第一句会来自某位校友的授权。",
		);
	});

	it("长句排版：overflow-wrap 防横向溢出（结构断言，R23）", async () => {
		// CSS module 规则不进 happy-dom 的 computed style——直接钉样式单源
		// （.quote 的 overflow-wrap 声明）；变异验证：删掉该声明断言必红。
		expect(styles.quote).toBeTruthy();
		expect(stylesSource).toMatch(/\.quote\{[^}]*overflow-wrap:anywhere/);

		render(<VoicesWall showIntro={false} />);
		fireEvent.click(await screen.findByRole("button", { name: /下一句/ }));
		fireEvent.click(screen.getByRole("button", { name: /下一句/ }));

		const blockquote = await screen.findByTestId("selected-text");
		expect(blockquote.className).toContain(styles.quote);
	});
});

describe("VoicesWall · 点赞（R11/R29）", () => {
	it("乐观 +1 → 服务端校正；voterKey 落盘并随请求发出", async () => {
		render(<VoicesWall showIntro={false} />);
		const likeButton = await screen.findByTestId("quote-like");

		fireEvent.click(likeButton);
		// 乐观更新
		expect(screen.getByTestId("quote-like")).toHaveTextContent("33");
		expect(likeRunner).toHaveBeenCalledWith(
			expect.objectContaining({
				variables: expect.objectContaining({ quoteId: "q-1", liked: true }),
			}),
		);
		const voterKey = window.localStorage.getItem("flashback.voterKey");
		expect(voterKey).toMatch(/^a:/);
		expect(likeRunner.mock.calls[0][0].variables.voterKey).toBe(voterKey);

		// 服务端校正（同值示范）
		await waitFor(() => expect(screen.getByTestId("quote-like")).toHaveTextContent("33"));
	});

	it("失败回滚到点击前状态", async () => {
		likeRunner.mockRejectedValue(new Error("server"));
		render(<VoicesWall showIntro={false} />);
		const likeButton = await screen.findByTestId("quote-like");

		fireEvent.click(likeButton);
		expect(screen.getByTestId("quote-like")).toHaveTextContent("33");
		await waitFor(() => expect(screen.getByTestId("quote-like")).toHaveTextContent("32"));
	});
});

describe("VoicesWall · 首赞轻提示（U6/R27）", () => {
	it("首赞出现「找回」引导；再赞不重复；关闭后不再出现", async () => {
		render(<VoicesWall showIntro={false} />);
		fireEvent.click(await screen.findByTestId("quote-like"));

		const hint = await screen.findByTestId("like-hint");
		expect(hint).toHaveTextContent("这句话是当年真实的报名答案——你也写过吗？");
		// 结构断言：提示为 fixed 定位浮层（不推挤布局、不遮挡赞/分享按钮所在文档流）
		expect(hint.className).toContain("likeHint");
		// 找回链接指向落地页
		expect(hint.querySelector("a")).toHaveAttribute("href", "/flashback#recover");

		// 再赞：不重复出现（仍只有一个，不新增）
		fireEvent.click(screen.getByRole("button", { name: /下一句/ }));
		fireEvent.click(screen.getByTestId("quote-like"));
		expect(screen.getAllByTestId("like-hint")).toHaveLength(1);

		// 关闭后不再出现
		fireEvent.click(screen.getByRole("button", { name: "知道了" }));
		expect(screen.queryByTestId("like-hint")).not.toBeInTheDocument();

		fireEvent.click(screen.getByRole("button", { name: /下一句/ }));
		fireEvent.click(screen.getByTestId("quote-like"));
		expect(screen.queryByTestId("like-hint")).not.toBeInTheDocument();
	});

	it("会话已标记 → 首赞不出现提示（sessionStorage 记忆）", async () => {
		window.sessionStorage.setItem("flashback.voicesLikeHintShown", "1");
		render(<VoicesWall showIntro={false} />);
		fireEvent.click(await screen.findByTestId("quote-like"));

		await waitFor(() => expect(likeRunner).toHaveBeenCalled());
		expect(screen.queryByTestId("like-hint")).not.toBeInTheDocument();
	});
});

describe("VoicesWall · 城市与导航（R13/R35）", () => {
	it("城市栏选中切换内容与地图指向（data-city 同步）", async () => {
		render(<VoicesWall showIntro={false} />);
		await screen.findByTestId("selected-text");

		// 地图坐标钉住（R2 真实地理位置）：城市栏按钮与地图光点同名，
		// 取城市栏（aria-label 容器内）的按钮
		const cityBar = document.querySelector("[aria-label='按城市浏览']")!;
		fireEvent.click(within(cityBar as HTMLElement).getByRole("button", { name: "上海" }));
		expect(await screen.findByTestId("selected-text")).toHaveTextContent("原来我也可以，是改变的开始。");
		expect(screen.getByTestId("map")).toHaveAttribute("data-city", "上海");
	});

	it("M10：城市栏来自 flashbackVoiceCities，选城改服务端按城重拉", async () => {
		render(<VoicesWall showIntro={false} />);
		await screen.findByTestId("selected-text");

		const cityBar = document.querySelector("[aria-label='按城市浏览']")!;
		// 宁波不在旧 45 城静态表、也不在默认热样本里——真源来自服务端
		expect(within(cityBar as HTMLElement).getByRole("button", { name: "宁波" })).toBeInTheDocument();
		fireEvent.click(within(cityBar as HTMLElement).getByRole("button", { name: "宁波" }));
		await waitFor(() => expect(wallQuery).toHaveBeenCalledTimes(2));
		expect(wallQuery.mock.calls[1][0].variables.city).toBe("宁波");
	});

	it("M10：初始 ?city= 直接服务端筛选（先筛后限量）", async () => {
		wallQuery.mockClear();
		render(<VoicesWall showIntro={false} initialCity="上海" />);
		await screen.findByTestId("selected-text");
		expect(wallQuery.mock.calls[0][0].variables.city).toBe("上海");
		// 直达城市里的句子（q-2 上海）
		expect(screen.getByTestId("selected-text")).toHaveTextContent("原来我也可以");
	});

	it("随便听听：调随机查询并定位返回句（R35）", async () => {
		const fresh = quote({ quoteId: "q-9", text: "写下第一行代码时，我听见了一扇门打开。", city: "成都" });
		randomQuery.mockResolvedValue({ data: { flashbackRandomQuotes: [fresh] } });
		render(<VoicesWall showIntro={false} />);
		await screen.findByTestId("selected-text");

		fireEvent.click(screen.getByTestId("random-listen"));
		expect(randomQuery).toHaveBeenCalledWith(
			expect.objectContaining({ variables: expect.objectContaining({ limit: 3 }) }),
		);
		expect(await screen.findByTestId("selected-text")).toHaveTextContent(
			"写下第一行代码时，我听见了一扇门打开。",
		);
	});

	// #822 根因回归：后端 randomQuotes 与 publicQuotes 同池（public.ex 仅排序不同），
	// 公开句 ≤ 60 时随机结果必然 ⊆ 墙。若把墙预置进 randomSeen，此处必报 randomEmpty。
	it("随便听听：随机句已在墙上列表里，仍定位该句而非报空（R35）", async () => {
		randomQuery.mockResolvedValue({ data: { flashbackRandomQuotes: [quotesList[1]] } });
		render(<VoicesWall showIntro={false} />);
		await screen.findByTestId("selected-text");

		fireEvent.click(screen.getByTestId("random-listen"));
		expect(await screen.findByTestId("selected-text")).toHaveTextContent("原来我也可以，是改变的开始。");
		expect(screen.queryByText("暂时没有更多声音了。")).not.toBeInTheDocument();
	});
});

describe("VoicesPage · 分享直达与失效页（U4/KTD4）", () => {
	it("有效 item：直达该句、不播开场", async () => {
		singleQuery.mockResolvedValue({ data: { flashbackPublicQuote: quotesList[1] } });
		render(<VoicesPage item="q-2" />);

		expect(await screen.findByTestId("selected-text")).toHaveTextContent("原来我也可以，是改变的开始。");
		// 直达抑制开场：无分镜轨
		expect(screen.queryByText("源起")).not.toBeInTheDocument();
	});

	it("失效 item（已收回/不存在）：失效视图 + 看全墙入口（HTTP 200 软 404）", async () => {
		singleQuery.mockResolvedValue({ data: { flashbackPublicQuote: null } });
		render(<VoicesPage item="gone-id" />);

		const gone = await screen.findByTestId("voices-gone");
		expect(gone).toHaveTextContent("这句话已被作者收回");
		expect(gone.querySelector("a")).toHaveAttribute("href", "/flashback/voices");
	});
});

describe("VoicesWall · 开场（R5/R8/R24）", () => {
	it("showIntro=false：直接白昼（progress=1，无分镜轨）", async () => {
		render(<VoicesWall showIntro={false} />);
		await screen.findByTestId("selected-text");
		expect(screen.getByTestId("map")).toHaveAttribute("data-progress", "1.00");
		expect(screen.queryByText("跳过片头")).not.toBeInTheDocument();
	});
});

// N10：金句墙不再把原型阶段的说明文案带上线。
describe("文案守卫", () => {
 it("introHint 不含原型示意", () => {
  const zh = JSON.parse(readFileSync(fileURLToPath(new URL("../../../../messages/zh-CN.json", import.meta.url.split("?")[0])), "utf8"));
  expect(zh.flashback.voices.introHint).not.toContain("原型示意");
 });
});
