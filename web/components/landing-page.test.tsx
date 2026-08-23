import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen, within } from "@testing-library/react";
import { render } from "@/test-utils";
import LandingPage from "./landing-page";

/**
 * 公开 Landing 页测试（M2 重构，2026-08）。
 *
 * 结构：顶导 → Hero（三十年叙事 + 单一主 CTA + 2016→2046 年份刻度条）→
 * 数据带 stats → 宣言（简介 + 创始人引语）→ 路径 path（加入后三步）→
 * 最新活动、精选课程（公开 API 各取前 3，失败降级为入口链接）→
 * 里程碑 journey → 报道与认可（论文 + 媒体报道）→ 合作伙伴 → 底部 CTA → footer。
 */

const { fetchPublicOfferings } = vi.hoisted(() => ({
	fetchPublicOfferings: vi.fn(),
}));

vi.mock("@/lib/public-offerings", () => ({
	fetchPublicOfferings,
}));

// ThemeProvider 依赖 usePathname 解析 workspace slug（ADR-0004）
// redirect/permanentRedirect 供 next-intl createNavigation 顶层 import（i18n Phase 1）
vi.mock("next/navigation", () => ({
	usePathname: () => "/",
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
}));

// i18n Phase 1：切换器自身在 language-switcher.test.tsx 以真实 provider 覆盖；
// 此处关注 landing 内容，mock 掉避免测试环境无 NextIntlClientProvider
vi.mock("@/components/language-switcher", () => ({
	default: () => null,
}));

const EVENT_FIXTURE = {
	id: "ev_1",
	slug: "reading-night",
	title: "程序媛夜读会",
	description: null,
	status: "open",
	visibility: "public",
	enrollmentPolicy: "open",
	registrationDeadline: null,
	enrollmentBadge: "enrolling",
} as const;

const COURSE_FIXTURE = {
	id: "cs_1",
	slug: "web-bootcamp",
	title: "零基础 Web 入门营",
	description: null,
	status: "open",
	visibility: "public",
	enrollmentPolicy: "request",
	registrationDeadline: null,
	enrollmentBadge: "full",
} as const;

beforeEach(() => {
	vi.clearAllMocks();
	fetchPublicOfferings.mockResolvedValue([]);
});

afterEach(cleanup);

describe("公开 Landing 页", () => {
	it("渲染 Hero 与各区块标题（IA：路径 → 活动/课程 → 信任带 → 关于我们）", () => {
		render(<LandingPage />);

		expect(
			screen.getByRole("heading", { name: "一桥飞架南北，天堑变通途" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("heading", { name: "加入之后，会发生什么" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("heading", { name: "最新活动" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("heading", { name: "精选课程" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("heading", { name: "值得托付的十年" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("heading", { name: "关于我们 · 三十年之约" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("heading", {
				name: "种一棵树最好的时机，是十年前；其次，是现在！",
			}),
		).toBeInTheDocument();
	});

	it("Hero：kicker（年份+组织+使命）、单一主 CTA、年份刻度条", () => {
		render(<LandingPage />);

		expect(
			screen.getByText(/从 2016 到 2046，程序媛汇，在女性与编程之间架起一座桥梁/),
		).toBeInTheDocument();
		// 副题已并入 kicker（2026-08 设计反馈），页面不再有独立点题句
		expect(screen.queryByText(/在女性与编程之间架一座桥/)).toBeNull();

		// 年份刻度条：2016 / 2046 刻度 + 「我们在这里」当前位置标记
		const strip = screen.getByRole("img", {
			name: "从 2016 到 2046 的三十年进度",
		});
		expect(strip).toBeInTheDocument();
		expect(within(strip).getByText("2016")).toBeInTheDocument();
		expect(within(strip).getByText("2046")).toBeInTheDocument();
		expect(screen.getByText("我们在这里")).toBeInTheDocument();
	});

	it("宣言：组织简介与创始人引语", () => {
		render(<LandingPage />);

		expect(screen.getByText(/程序媛汇创立于 2016 年/)).toBeInTheDocument();
		expect(
			screen.getByText(/以帮助女性数字赋能为使命，以平凡的姿态做不平凡的事情/),
		).toBeInTheDocument();
		expect(screen.getByText(/创始人 文洋/)).toBeInTheDocument();
	});

	it("数据带：4000+ 学员等 5 个大数字", () => {
		render(<LandingPage />);

		expect(screen.getByText("4000+")).toBeInTheDocument();
		expect(screen.getByText("1000+")).toBeInTheDocument();
		expect(screen.getByText("50+")).toBeInTheDocument();
		expect(screen.getByText("17")).toBeInTheDocument();
		expect(screen.getByText("10")).toBeInTheDocument();
		expect(screen.getByText("名学员")).toBeInTheDocument();
		expect(screen.getByText("位教练")).toBeInTheDocument();
	});

	it("路径：加入后三步（工作坊 → 课程 → 社群）", () => {
		render(<LandingPage />);

		expect(screen.getByText("参加工作坊")).toBeInTheDocument();
		expect(screen.getByText("系统学课程")).toBeInTheDocument();
		expect(screen.getByText("留在社群里")).toBeInTheDocument();
	});

	it("里程碑：2016 创立到 2046 三十年之约，含无年份荣誉备注", () => {
		render(<LandingPage />);

		expect(
			screen.getByText(/Coding Girls Club 创立，第一堂编程工作坊开课/),
		).toBeInTheDocument();
		expect(
			screen.getByText(/入选联合国开发计划署「科技与慈善」项目案例集/),
		).toBeInTheDocument();
		expect(
			screen.getByText(/获共青团中央「全国青年社会组织伙伴计划」奖项/),
		).toBeInTheDocument();
		expect(
			screen.getByText(/卡耐基梅隆大学学者合作的论文发表于 ICSE CHASE 2021/),
		).toBeInTheDocument();
		expect(screen.getByText(/我们正在路上/)).toBeInTheDocument();
		expect(screen.getByText(/#科技遇见她#/)).toBeInTheDocument();
	});

	it("登录/注册 CTA 指向 /login 与 /register", () => {
		render(<LandingPage />);

		const loginLinks = screen
			.getAllByRole("link")
			.filter((a) => a.getAttribute("href") === "/login");
		const registerLinks = screen
			.getAllByRole("link")
			.filter((a) => a.getAttribute("href") === "/register");
		expect(loginLinks.length).toBeGreaterThan(0);
		expect(registerLinks.length).toBeGreaterThan(0);
	});

	it("渲染公开活动与课程条目，链接到详情页", async () => {
		fetchPublicOfferings.mockImplementation((kind: string) =>
			Promise.resolve(kind === "event" ? [EVENT_FIXTURE] : [COURSE_FIXTURE]),
		);
		render(<LandingPage />);

		const eventLink = await screen.findByRole("link", {
			name: /程序媛夜读会/,
		});
		expect(eventLink).toHaveAttribute("href", "/events/reading-night");
		const courseLink = await screen.findByRole("link", {
			name: /零基础 Web 入门营/,
		});
		expect(courseLink).toHaveAttribute("href", "/courses/web-bootcamp");
	});

	it("行内状态标签为报名 badge（KTD1 派生口径），不再用活动状态机标签", async () => {
		fetchPublicOfferings.mockImplementation((kind: string) =>
			Promise.resolve(kind === "event" ? [EVENT_FIXTURE] : [COURSE_FIXTURE]),
		);
		render(<LandingPage />);

		const eventLink = await screen.findByRole("link", {
			name: /程序媛夜读会/,
		});
		expect(within(eventLink).getByText("报名中")).toBeInTheDocument();
		const courseLink = await screen.findByRole("link", {
			name: /零基础 Web 入门营/,
		});
		expect(within(courseLink).getByText("已满")).toBeInTheDocument();
		// EventStatusTag（开放报名）从公开面移除，仅留工作区内部页
		expect(screen.queryByText("开放报名")).toBeNull();
	});

	it("报道与认可：论文（ICSE CHASE 2021 链接）、媒体 6 条（5 条有链接）", () => {
		render(<LandingPage />);

		// 论文：computer.org 权威链接
		const paperLink = screen.getByRole("link", {
			name: /Approaches to Diversifying the Programmer Community/,
		});
		expect(paperLink).toHaveAttribute(
			"href",
			"https://www.computer.org/csdl/proceedings-article/chase/2021/140900a091/1tB7t8SZKcE",
		);
		expect(paperLink).toHaveAttribute("target", "_blank");
		expect(paperLink).toHaveAttribute("rel", expect.stringContaining("noopener"));

		// 媒体报道：前 4 条附原文链接，果壳只列媒体+标题（无链接）
		expect(
			screen.getByRole("link", { name: /Ladies Who Code/ }),
		).toHaveAttribute("href", "http://www.globaltimes.cn/content/954372.shtml");
		expect(
			screen.getByRole("link", {
				name: /Helping women to break social programming/,
			}),
		).toHaveAttribute(
			"href",
			"http://www.chinadaily.com.cn/china/2017-01/13/content_27943815.htm",
		);
		expect(
			screen.getByRole("link", { name: /Looking to crack the unwritten code/ }),
		).toHaveAttribute(
			"href",
			"http://www.chinadaily.com.cn/china/2017-01/13/content_27943492.htm",
		);
		expect(
			screen.getByRole("link", {
				name: /Chinese women take on computer programming/,
			}),
		).toHaveAttribute(
			"href",
			"https://news.cgtn.com/news/3d49544e31516a4d/share_p.html",
		);
		expect(
			screen.getByRole("link", {
				name: /性别教育，反行业歧视，志愿者社群/,
			}),
		).toHaveAttribute("href", "https://m.36kr.com/p/1129142659517446");
		expect(screen.getByText("自学编程的故事与未来")).toBeInTheDocument();
		expect(
			screen.queryByRole("link", { name: /自学编程的故事与未来/ }),
		).not.toBeInTheDocument();
	});

	it("合作伙伴：精选 5 家（历史同行者口径，无 WorldQuant/个推/掘金/freeCodeCamp）", () => {
		render(<LandingPage />);

		for (const partner of [
			"UNDP",
			"ThoughtWorks",
			"GitHub",
			"ByteDance",
			"FreeWheel",
		]) {
			expect(screen.getByText(partner)).toBeInTheDocument();
		}
		for (const removed of ["个推", "掘金", "freeCodeCamp", "WorldQuant"]) {
			expect(screen.queryByText(removed)).not.toBeInTheDocument();
		}
		expect(screen.getByText(/曾经的同行者/)).toBeInTheDocument();
	});

	it("公开 API 加载失败：降级为入口链接，整页其余区块不受影响", async () => {
		fetchPublicOfferings.mockRejectedValue(new Error("network down"));
		render(<LandingPage />);

		// 失败降级文案出现
		expect(await screen.findAllByText(/暂时无法加载/)).toHaveLength(2);
		// Hero 与静态区块仍正常渲染
		expect(
			screen.getByRole("heading", { name: "一桥飞架南北，天堑变通途" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("heading", { name: "值得托付的十年" }),
		).toBeInTheDocument();
	});
});
