import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { act, cleanup, fireEvent, screen, waitFor } from "@testing-library/react";
import { render } from "@/test-utils";
import PublicHome from "./public-home";
import ProfileView from "./profile-view";
import {
	FLASHBACK_PUBLIC_PROFILE,
	FLASHBACK_PUBLIC_QUOTES,
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
		query: ({ query }: { query: unknown }) => {
			if (query === FLASHBACK_PUBLIC_STATS) return statsQuery();
			if (query === FLASHBACK_PUBLIC_QUOTES) return quotesQuery();
			if (query === FLASHBACK_PUBLIC_PROFILE) return profileQuery();
			throw new Error("unexpected query");
		},
	},
}));

const { recoverRunner, verifyRunner } = vi.hoisted(() => ({
	recoverRunner: vi.fn(),
	verifyRunner: vi.fn(),
}));

vi.mock("@apollo/client/react", async (importOriginal) => {
	const actual = await importOriginal<typeof import("@apollo/client/react")>();
	return {
		...actual,
		useMutation: (doc: unknown) => {
			if (doc === FLASHBACK_RECOVER) return [recoverRunner, { loading: false }];
			if (doc === FLASHBACK_RECOVER_VERIFY) return [verifyRunner, { loading: false }];
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
	{ text: "我想亲眼看看是", attribution: "王** · 2014 · 北京", level: "anonymous", publicSlug: null },
	{ text: "想亲眼看看是不是", attribution: "李** · 2015 · 广州", level: "credited", publicSlug: "li-yinuo" },
];

beforeEach(() => {
	statsQuery.mockReset();
	quotesQuery.mockReset();
	profileQuery.mockReset();
	recoverRunner.mockReset();
	verifyRunner.mockReset();
	pushMock.mockReset();
});

afterEach(() => {
	cleanup();
	vi.restoreAllMocks();
});

describe("PublicHome · 统计层与金句墙（R32）", () => {
	it("统计与金句渲染；credited 金句链实名页、匿名金句无链接", async () => {
		statsQuery.mockResolvedValue({ data: { flashbackPublicStats: statsWith } });
		quotesQuery.mockResolvedValue({ data: { flashbackPublicQuotes: quoteList } });
		render(<PublicHome />);

		expect(await screen.findByText(/报名 344 人 \/ 走进教室 102 人/)).toBeInTheDocument();
		expect(screen.getByText("已经回来 12 人，其中 3 人寄出了自己的照片。")).toBeInTheDocument();

		const anonymous = screen.getByText("“我想亲眼看看是”");
		expect(anonymous).toBeInTheDocument();
		const creditedLink = screen.getByRole("link", { name: "李** · 2015 · 广州" });
		expect(creditedLink).toHaveAttribute("href", "/flashback/li-yinuo");
	});

	it("空态：「正在发生」进度叙事代替空数字（U6 空态设计）", async () => {
		statsQuery.mockResolvedValue({ data: { flashbackPublicStats: { archives: [], returnedCount: 0, sentCount: 0 } } });
		quotesQuery.mockResolvedValue({ data: { flashbackPublicQuotes: [] } });
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
		quotesQuery.mockResolvedValue({ data: { flashbackPublicQuotes: [] } });
		recoverRunner.mockResolvedValue({ data: { flashbackRecover: { dispatched: true } } });
		render(<PublicHome />);

		fireEvent.change(screen.getByLabelText("当年的手机号或邮箱"), {
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

	it("发起后进入验证码步，文案不区分命中与否（同形）", async () => {
		statsQuery.mockResolvedValue({ data: { flashbackPublicStats: { archives: [], returnedCount: 0, sentCount: 0 } } });
		quotesQuery.mockResolvedValue({ data: { flashbackPublicQuotes: [] } });
		recoverRunner.mockResolvedValue({ data: { flashbackRecover: { dispatched: true } } });
		render(<PublicHome />);

		fireEvent.change(screen.getByLabelText("当年的手机号或邮箱"), { target: { value: "13900000001" } });
		fireEvent.click(screen.getByRole("button", { name: "找回我的档案" }));

		expect(await screen.findByText(/验证码或入口链接已经发出/)).toBeInTheDocument();
		expect(recoverRunner).toHaveBeenCalledWith({ variables: { identifier: "13900000001" } });
	});

	it("多档案命中：verify 后展示「你的 N 张卡」选择列表并进胶囊", async () => {
		statsQuery.mockResolvedValue({ data: { flashbackPublicStats: { archives: [], returnedCount: 0, sentCount: 0 } } });
		quotesQuery.mockResolvedValue({ data: { flashbackPublicQuotes: [] } });
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
		render(<PublicHome />);

		fireEvent.change(screen.getByLabelText("当年的手机号或邮箱"), { target: { value: "13900000001" } });
		fireEvent.click(screen.getByRole("button", { name: "找回我的档案" }));
		fireEvent.change(await screen.findByLabelText("验证码"), { target: { value: "123456" } });
		fireEvent.click(screen.getByRole("button", { name: "验证并进入" }));

		expect(await screen.findByText("找到了你的 2 张卡——它们都归你了")).toBeInTheDocument();
		expect(screen.getByText("王** · Rails Girls 北京 · 北京")).toBeInTheDocument();

		fireEvent.click(screen.getByRole("button", { name: "进入时间胶囊 →" }));
		await waitFor(() => expect(pushMock).toHaveBeenCalledWith("/flashback/capsule"));
	});

	it("单档案命中：直接绑定成功进胶囊；错码映射 code 文案", async () => {
		statsQuery.mockResolvedValue({ data: { flashbackPublicStats: { archives: [], returnedCount: 0, sentCount: 0 } } });
		quotesQuery.mockResolvedValue({ data: { flashbackPublicQuotes: [] } });
		recoverRunner.mockResolvedValue({ data: { flashbackRecover: { dispatched: true } } });
		verifyRunner.mockRejectedValue({
			errors: [{ message: "x", extensions: { code: "invalid_or_expired_code" } }],
		});
		render(<PublicHome />);

		fireEvent.change(screen.getByLabelText("当年的手机号或邮箱"), { target: { value: "13900000001" } });
		fireEvent.click(screen.getByRole("button", { name: "找回我的档案" }));
		fireEvent.change(await screen.findByLabelText("验证码"), { target: { value: "000000" } });
		fireEvent.click(screen.getByRole("button", { name: "验证并进入" }));

		await waitFor(() => expect(verifyRunner).toHaveBeenCalled());
		expect(await screen.findByRole("alert", {}, { timeout: 3000 })).toHaveTextContent("验证码不对或已过期");
	});

	it("限流 code 映射（flashback_recover_rate_limited）", async () => {
		statsQuery.mockResolvedValue({ data: { flashbackPublicStats: { archives: [], returnedCount: 0, sentCount: 0 } } });
		quotesQuery.mockResolvedValue({ data: { flashbackPublicQuotes: [] } });
		recoverRunner.mockRejectedValue({
			errors: [{ message: "x", extensions: { code: "flashback_recover_rate_limited" } }],
		});
		render(<PublicHome />);

		fireEvent.change(screen.getByLabelText("当年的手机号或邮箱"), { target: { value: "13900000001" } });
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
