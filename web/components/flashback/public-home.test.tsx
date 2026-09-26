import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import PublicHome, { isOnlyFogPlaceholder } from "./public-home";
import ProfileView from "./profile-view";
import RecoverForm from "./recover-form";
import {
	FLASHBACK_LIKE_QUOTE,
	FLASHBACK_PUBLIC_PROFILE,
	FLASHBACK_RANDOM_QUOTES,
	FLASHBACK_PUBLIC_STATS,
	FLASHBACK_RECOVER,
	FLASHBACK_RECOVER_VERIFY,
	type FlashbackPublicProfile,
	type FlashbackPublicQuote,
	type FlashbackPublicStats,
} from "@/lib/graphql/flashback";

/**
 * U6 公开层测试：统计/金句墙渲染与空态叙事、找回流程（同形文案/多卡选择/
 * 错码映射）、实名页 404 态带回首页出口、导航入口。
 */

const pushMock = vi.fn();

vi.mock("@/i18n/navigation", () => ({
	Link: ({ href, children, ...rest }: { href: string; children: React.ReactNode } & Record<string, unknown>) => (
		<a href={href} {...rest}>
			{children}
		</a>
	),
	usePathname: () => "/flashback",
	useRouter: () => ({ push: pushMock, replace: vi.fn() }),
}));

const statsQuery = vi.fn();
const quotesQuery = vi.fn();
const profileQuery = vi.fn();

vi.mock("@/lib/apollo-client", () => ({
	client: {
		query: (options: { query: unknown }) => {
			if (options.query === FLASHBACK_PUBLIC_STATS) return statsQuery(options);
			if (options.query === FLASHBACK_RANDOM_QUOTES) return quotesQuery(options);
			if (options.query === FLASHBACK_PUBLIC_PROFILE) return profileQuery(options);
			throw new Error("unexpected query");
		},
	},
}));

const { recoverRunner, verifyRunner, likeRunner } = vi.hoisted(() => ({
	recoverRunner: vi.fn(),
	verifyRunner: vi.fn(),
	likeRunner: vi.fn(),
}));

vi.mock("@apollo/client/react", async (importOriginal) => {
	const actual = await importOriginal<typeof import("@apollo/client/react")>();
	return {
		...actual,
		useMutation: (doc: unknown) => {
			if (doc === FLASHBACK_RECOVER) return [recoverRunner, { loading: false }];
			if (doc === FLASHBACK_RECOVER_VERIFY) return [verifyRunner, { loading: false }];
			if (doc === FLASHBACK_LIKE_QUOTE) return [likeRunner, { loading: false }];
			return [vi.fn(), { loading: false }];
		},
	};
});

const statsWith: Partial<FlashbackPublicStats> = {
	archives: [
		{
			key: "2014-01-11-bj",
			name: "Rails Girls 北京",
			city: "北京",
			occurredOn: "2014-01-11",
			appliedCount: 344,
			attendedCount: 102,
		},
	],
	returnedCount: 12,
	sentCount: 3,
};

const quoteList: FlashbackPublicQuote[] = [
	{
		text: "我想亲眼看看是",
		attribution: "王** · 2014 · 北京",
		level: "anonymous",
		publicSlug: null,
		quoteId: "q-alice",
		likeCount: 3,
		likedByViewer: false,
	},
	{
		text: "想亲眼看看是不是",
		attribution: "李** · 2015 · 广州",
		level: "credited",
		publicSlug: "li-yinuo",
		quoteId: "q-bob",
		likeCount: 0,
		likedByViewer: true,
	},
];

beforeEach(() => {
	statsQuery.mockReset();
	quotesQuery.mockReset();
	profileQuery.mockReset();
	recoverRunner.mockReset();
	verifyRunner.mockReset();
	likeRunner.mockReset();
	window.localStorage.clear();
	pushMock.mockReset();
});

afterEach(() => {
	cleanup();
	vi.restoreAllMocks();
});

describe("isOnlyFogPlaceholder", () => {
	it("只识别雾占位符与空白，不误判普通文本", () => {
		expect(isOnlyFogPlaceholder(" \n▓▓\t▓▓\r\n")).toBe(true);
		expect(isOnlyFogPlaceholder("")).toBe(false);
		expect(isOnlyFogPlaceholder("   ")).toBe(false);
		expect(isOnlyFogPlaceholder("▓")).toBe(false);
		expect(isOnlyFogPlaceholder("▓▓还有可见原文")).toBe(false);
		expect(isOnlyFogPlaceholder("可见原文▓▓")).toBe(false);
	});
});

describe("PublicHome · 统计层与金句墙（R32）", () => {
	it("统计与金句渲染；credited 金句链实名页、匿名金句无链接", async () => {
		statsQuery.mockResolvedValue({ data: { flashbackPublicStats: statsWith } });
		quotesQuery.mockResolvedValue({ data: { flashbackRandomQuotes: quoteList } });
		render(<PublicHome />);

		expect(await screen.findByText(/报名 344 人 \/ 走进教室 102 人/)).toBeInTheDocument();
		expect(screen.getByText("已经回来 12 人，其中 3 人寄出了自己的照片。")).toBeInTheDocument();

		const anonymous = screen.getByText("“我想亲眼看看是”");
		expect(anonymous).toBeInTheDocument();
		const creditedLink = screen.getByRole("link", { name: "李** · 2015 · 广州" });
		expect(creditedLink).toHaveAttribute("href", "/flashback/li-yinuo");
	});

	it("#933 那些年的相册：每一场都能点进场次页（登录判断只在场次页一处）", async () => {
		statsQuery.mockResolvedValue({ data: { flashbackPublicStats: statsWith } });
		quotesQuery.mockResolvedValue({ data: { flashbackRandomQuotes: [] } });
		render(<PublicHome />);

		const album = await screen.findByRole("link", { name: /2014\.01\.11 · Rails Girls 北京/ });
		expect(album).toHaveAttribute("href", "/flashback/event/2014-01-11-bj");
	});

	it("全雾化金句显示本地化遮蔽说明；部分雾化金句保持原样", async () => {
		statsQuery.mockResolvedValue({ data: { flashbackPublicStats: statsWith } });
		quotesQuery.mockResolvedValue({
			data: {
				flashbackRandomQuotes: [
					{ ...quoteList[0], text: " \n▓▓\t " },
					{ ...quoteList[1], text: "可见的前半句▓▓可见的后半句" },
				],
			},
		});

		const zh = render(<PublicHome />);
		const zhFogged = await screen.findByRole("blockquote", {
			name: "这一段被呵了气——内容被本人雾面保护",
		});
		expect(zhFogged).toHaveClass("fb-quote-text--fogged");
		expect(zhFogged).toHaveTextContent("这一段被呵了气——内容被本人雾面保护");
		expect(zhFogged).toHaveAttribute("title", "这一段被呵了气——内容被本人雾面保护");
		expect(zhFogged).not.toHaveTextContent("▓▓");
		expect(screen.getByText("“可见的前半句▓▓可见的后半句”")).toBeInTheDocument();
		zh.unmount();

		render(<PublicHome />, { locale: "en" });
		const enFogged = await screen.findByRole("blockquote", {
			name: "This passage is fogged — protected by her choice",
		});
		expect(enFogged).toHaveClass("fb-quote-text--fogged");
		expect(enFogged).toHaveTextContent("This passage is fogged — protected by her choice");
		expect(enFogged).toHaveAttribute("title", "This passage is fogged — protected by her choice");
		expect(enFogged).not.toHaveTextContent("▓▓");
		expect(screen.getByText("“可见的前半句▓▓可见的后半句”")).toBeInTheDocument();
	});

	it("U5/R26：金句段带「看全墙 →」导流（链接直 /flashback/voices）", async () => {
		statsQuery.mockResolvedValue({ data: { flashbackPublicStats: statsWith } });
		quotesQuery.mockResolvedValue({ data: { flashbackRandomQuotes: quoteList } });
		render(<PublicHome />);

		const wallCta = await screen.findByTestId("fb-quotes-wall-cta");
		expect(wallCta).toHaveAttribute("href", "/flashback/voices");
		// 随机查询：limit=3（非精选、非全量）
		expect(quotesQuery).toHaveBeenCalledWith(
			expect.objectContaining({
				variables: expect.objectContaining({ limit: 3 }),
			}),
		);
	});

	it("空态：「正在发生」进度叙事代替空数字（U6 空态设计）", async () => {
		statsQuery.mockResolvedValue({ data: { flashbackPublicStats: { archives: [], returnedCount: 0, sentCount: 0 } } });
		quotesQuery.mockResolvedValue({ data: { flashbackRandomQuotes: [] } });
		render(<PublicHome />);

		// 数据到达后（非初始 null 态）仍走空态叙事——flush 查询 promise
		await act(async () => {});
		expect(screen.getByTestId("fb-stats-empty")).toHaveTextContent("第一封信还没寄出");
		expect(screen.getByTestId("fb-quotes-empty")).toHaveTextContent("金句墙还空着");
	});

	it("数据加载失败也落空态叙事（公开页不裸奔错误）", async () => {
		statsQuery.mockRejectedValue(new Error("network"));
		quotesQuery.mockRejectedValue(new Error("network"));
		render(<PublicHome />);

		expect(await screen.findByTestId("fb-stats-empty")).toBeInTheDocument();
		expect(screen.getByTestId("fb-quotes-empty")).toBeInTheDocument();
	});
});

describe("PublicHome · 自助找回（R21/KTD7）", () => {
	it("提交前 trim：聊天复制的首尾空白不进 identifier（实测 bug 1 前半段）", async () => {
		statsQuery.mockResolvedValue({ data: { flashbackPublicStats: { archives: [], returnedCount: 0, sentCount: 0 } } });
		quotesQuery.mockResolvedValue({ data: { flashbackRandomQuotes: [] } });
		recoverRunner.mockResolvedValue({ data: { flashbackRecover: { dispatched: true } } });
		render(<PublicHome />);

		fireEvent.change(screen.getByLabelText("当年报名用的邮箱"), {
			target: { value: "  lipan2000girl@163.com\n" },
		});
		await act(async () => {
			fireEvent.click(screen.getByRole("button", { name: "找回我的档案" }));
		});

		await waitFor(() =>
			expect(recoverRunner).toHaveBeenCalledWith({
				variables: { identifier: "lipan2000girl@163.com" },
			}),
		);
	});

	it("邮箱发起后提示查收邮件、不出验证码框；文案不区分命中与否（同形）", async () => {
		statsQuery.mockResolvedValue({ data: { flashbackPublicStats: { archives: [], returnedCount: 0, sentCount: 0 } } });
		quotesQuery.mockResolvedValue({ data: { flashbackRandomQuotes: [] } });
		recoverRunner.mockResolvedValue({ data: { flashbackRecover: { dispatched: true } } });
		render(<PublicHome />);

		fireEvent.change(screen.getByLabelText("当年报名用的邮箱"), { target: { value: "old@example.com" } });
		fireEvent.click(screen.getByRole("button", { name: "找回我的档案" }));

		expect(await screen.findByText(/入口链接已经发出——请查收邮箱/)).toBeInTheDocument();
		expect(screen.queryByLabelText("验证码")).not.toBeInTheDocument();
		expect(recoverRunner).toHaveBeenCalledWith({ variables: { identifier: "old@example.com" } });
	});

	it("手机号找回暂停：输入手机号就地提示填邮箱，不发起找回（不发短信）", async () => {
		statsQuery.mockResolvedValue({ data: { flashbackPublicStats: { archives: [], returnedCount: 0, sentCount: 0 } } });
		quotesQuery.mockResolvedValue({ data: { flashbackRandomQuotes: [] } });
		render(<PublicHome />);

		expect(screen.queryByText(/手机/)).not.toBeInTheDocument();
		fireEvent.change(screen.getByLabelText("当年报名用的邮箱"), { target: { value: "13900000001" } });
		fireEvent.click(screen.getByRole("button", { name: "找回我的档案" }));

		expect(await screen.findByRole("alert")).toHaveTextContent("请填写当年报名用的邮箱。");
		expect(recoverRunner).not.toHaveBeenCalled();
	});

	// 以下两例走保留的手机通道（phoneEnabled）：重新开放时这段 UI 仍有回归保护
	it("手机通道（保留）·多档案命中：verify 后展示「你的 N 张卡」选择列表并进胶囊", async () => {
		statsQuery.mockResolvedValue({ data: { flashbackPublicStats: { archives: [], returnedCount: 0, sentCount: 0 } } });
		quotesQuery.mockResolvedValue({ data: { flashbackRandomQuotes: [] } });
		recoverRunner.mockResolvedValue({ data: { flashbackRecover: { dispatched: true } } });
		verifyRunner.mockResolvedValue({
			data: {
				flashbackRecoverVerify: {
					bound: true,
					cards: [
						{ personId: "p1", surnameMasked: "王**", eventName: "Rails Girls 北京", city: "北京" },
						{ personId: "p2", surnameMasked: "李*", eventName: "Rails Girls 广州", city: "广州" },
					],
				},
			},
		});
		render(<RecoverForm phoneEnabled />);

		fireEvent.change(screen.getByLabelText("当年报名用的邮箱"), { target: { value: "13900000001" } });
		fireEvent.click(screen.getByRole("button", { name: "找回我的档案" }));
		expect(await screen.findByText(/验证码已经发出/)).toBeInTheDocument();
		fireEvent.change(await screen.findByLabelText("验证码"), { target: { value: "123456" } });
		fireEvent.click(screen.getByRole("button", { name: "验证并进入" }));

		expect(await screen.findByText("找到了你的 2 张卡——它们都归你了")).toBeInTheDocument();
		expect(screen.getByText("王** · Rails Girls 北京 · 北京")).toBeInTheDocument();

		fireEvent.click(screen.getByRole("button", { name: "进入时间长廊 →" }));
		await waitFor(() => expect(pushMock).toHaveBeenCalledWith("/flashback/capsule"));
	});

	it("手机通道（保留）·错码映射 code 文案", async () => {
		statsQuery.mockResolvedValue({ data: { flashbackPublicStats: { archives: [], returnedCount: 0, sentCount: 0 } } });
		quotesQuery.mockResolvedValue({ data: { flashbackRandomQuotes: [] } });
		recoverRunner.mockResolvedValue({ data: { flashbackRecover: { dispatched: true } } });
		verifyRunner.mockRejectedValue({
			errors: [{ message: "x", extensions: { code: "invalid_or_expired_code" } }],
		});
		render(<RecoverForm phoneEnabled />);

		fireEvent.change(screen.getByLabelText("当年报名用的邮箱"), { target: { value: "13900000001" } });
		fireEvent.click(screen.getByRole("button", { name: "找回我的档案" }));
		fireEvent.change(await screen.findByLabelText("验证码"), { target: { value: "000000" } });
		fireEvent.click(screen.getByRole("button", { name: "验证并进入" }));

		await waitFor(() => expect(verifyRunner).toHaveBeenCalled());
		expect(await screen.findByRole("alert", {}, { timeout: 3000 })).toHaveTextContent("验证码不对或已过期");
	});

	it("限流 code 映射（flashback_recover_rate_limited）", async () => {
		statsQuery.mockResolvedValue({ data: { flashbackPublicStats: { archives: [], returnedCount: 0, sentCount: 0 } } });
		quotesQuery.mockResolvedValue({ data: { flashbackRandomQuotes: [] } });
		recoverRunner.mockRejectedValue({
			errors: [{ message: "x", extensions: { code: "flashback_recover_rate_limited" } }],
		});
		render(<PublicHome />);

		fireEvent.change(screen.getByLabelText("当年报名用的邮箱"), { target: { value: "old@example.com" } });
		await act(async () => {
			fireEvent.click(screen.getByRole("button", { name: "找回我的档案" }));
		});

		expect(await screen.findByRole("alert")).toHaveTextContent("找回尝试过于频繁");
	});
});

describe("ProfileView · 实名档案页（R31 credited 档）", () => {
	it("已授权者渲染实名内容", async () => {
		const profile: FlashbackPublicProfile = {
			fullName: "李一诺",
			city: "广州",
			eventName: "Rails Girls 广州",
			year: 2015,
			creditedNote: "在做无障碍开发",
			quote: "想亲眼看看是不是",
		};
		profileQuery.mockResolvedValue({ data: { flashbackPublicProfile: profile } });
		render(<ProfileView slug="li-yinuo" />);

		expect(await screen.findByText("李一诺")).toBeInTheDocument();
		expect(screen.getByText(/2015 · Rails Girls 广州/)).toBeInTheDocument();
		expect(screen.getByText("“想亲眼看看是不是”")).toBeInTheDocument();
		expect(screen.getByText("在做无障碍开发")).toBeInTheDocument();
		expect(screen.getByText(/实名授权公开/)).toBeInTheDocument();
	});

	it("未授权者 404 态带回首页出口", async () => {
		profileQuery.mockResolvedValue({ data: { flashbackPublicProfile: null } });
		render(<ProfileView slug="nobody" />);

		expect(await screen.findByText("这一页还没有显影")).toBeInTheDocument();
		expect(screen.getByRole("link", { name: "回到闪念间首页" })).toHaveAttribute("href", "/flashback");
	});
});

describe("PublicHome · 金句点赞（R36）", () => {
	const renderWithQuotes = async () => {
		statsQuery.mockResolvedValue({ data: { flashbackPublicStats: statsWith } });
		quotesQuery.mockResolvedValue({ data: { flashbackRandomQuotes: quoteList } });
		render(<PublicHome />);
		await screen.findAllByTestId("fb-quote-like");
	};

	it("按 likedByViewer 渲染 ♡/♥ + 计数，请求带 localStorage 去重键", async () => {
		await renderWithQuotes();

		const buttons = screen.getAllByTestId("fb-quote-like");
		expect(buttons[0]).toHaveTextContent("♡3");
		expect(buttons[0]).toHaveAttribute("aria-pressed", "false");
		expect(buttons[1]).toHaveTextContent("♥0");
		expect(buttons[1]).toHaveAttribute("aria-pressed", "true");

		const voterKey = window.localStorage.getItem("flashback.voterKey");
		expect(voterKey).toMatch(/^a:/);
		// U5/R26：落地页 = 随机 3 句（非精选、非全量）
		expect(quotesQuery).toHaveBeenCalledWith(
			expect.objectContaining({
				variables: expect.objectContaining({ limit: 3, voterKey }),
			}),
		);
	});

	it("点击：乐观 +1 → 服务端计数校正；不就地重排", async () => {
		let resolveLike: (value: unknown) => void = () => {};
		likeRunner.mockReturnValue(new Promise((resolve) => (resolveLike = resolve)));
		await renderWithQuotes();

		const [first] = screen.getAllByTestId("fb-quote-like");
		first.click();

		// 乐观更新：立刻 +1 且变已赞
		await waitFor(() => expect(screen.getAllByTestId("fb-quote-like")[0]).toHaveTextContent("♥4"));
		expect(likeRunner).toHaveBeenCalledWith(
			expect.objectContaining({
				variables: expect.objectContaining({ quoteId: "q-alice", liked: true }),
			}),
		);

		// 服务端计数校正（真实计数可能与乐观值不同）
		resolveLike({ data: { flashbackLikeQuote: { likeCount: 9 } } });
		await waitFor(() => expect(screen.getAllByTestId("fb-quote-like")[0]).toHaveTextContent("♥9"));

		// 顺序不变（涌现排序只在下次加载生效）
		const texts = screen.getAllByTestId("fb-quote-like").map((node) => node.textContent);
		expect(texts).toHaveLength(2);
	});

	it("失败回滚到点击前状态", async () => {
		likeRunner.mockRejectedValue(new Error("rate limited"));
		await renderWithQuotes();

		screen.getAllByTestId("fb-quote-like")[0].click();

		await waitFor(() => expect(screen.getAllByTestId("fb-quote-like")[0]).toHaveTextContent("♡3"));
		expect(screen.getAllByTestId("fb-quote-like")[0]).toHaveAttribute("aria-pressed", "false");
	});

	it("存储不可用（拿不到去重键）→ 不渲染点赞按钮", async () => {
		vi.spyOn(window.localStorage, "getItem").mockReturnValue(null);
		vi.spyOn(window.localStorage, "setItem").mockImplementation(() => {
			throw new Error("storage disabled");
		});
		statsQuery.mockResolvedValue({ data: { flashbackPublicStats: statsWith } });
		quotesQuery.mockResolvedValue({ data: { flashbackRandomQuotes: quoteList } });

		render(<PublicHome />);
		await screen.findByText(/我想亲眼看看是/);

		expect(screen.queryAllByTestId("fb-quote-like")).toHaveLength(0);
		vi.restoreAllMocks();
	});
});
