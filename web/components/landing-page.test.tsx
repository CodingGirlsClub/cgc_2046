import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import LandingPage from "./landing-page";

/**
 * 公开 Landing 页测试（M2）。
 *
 * 结构：Hero（2016 → 2046 三十年叙事 + 创始人引语 + 截至 2021 数据带）、
 * 最新活动、精选课程、报道与认可（论文 + 媒体报道 + 机构荣誉）、
 * 合作伙伴、登录/注册 CTA。
 * 活动/课程数据复用公开 API（fetchPublicOfferings），各取前 3 条；
 * 加载失败降级为入口链接，不阻塞整页。
 */

const { fetchPublicOfferings } = vi.hoisted(() => ({
	fetchPublicOfferings: vi.fn(),
}));

vi.mock("@/lib/public-offerings", () => ({
	fetchPublicOfferings,
}));

// ThemeProvider 依赖 usePathname 解析 workspace slug（ADR-0004）
vi.mock("next/navigation", () => ({
	usePathname: () => "/",
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
} as const;

beforeEach(() => {
	vi.clearAllMocks();
	fetchPublicOfferings.mockResolvedValue([]);
});

afterEach(cleanup);

describe("公开 Landing 页", () => {
	it("渲染 Hero 叙事与各区块标题", async () => {
		render(<LandingPage />);

		expect(
			screen.getByRole("heading", {
				name: "一桥飞架南北，天堑变通途",
			}),
		).toBeInTheDocument();
		expect(
			screen.getByRole("heading", { name: "最新活动" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("heading", { name: "精选课程" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("heading", { name: "报道与认可" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("heading", { name: "合作伙伴" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("heading", { name: "下一个十年，从这里开始" }),
		).toBeInTheDocument();
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

	it("Hero：历史 slogan 主标语、kicker、点题句（含中文名）、钩子、引语、数据带", () => {
		render(<LandingPage />);

		// 主标语为组织历史 slogan；「从 2016 到 2046」降级为 kicker 保留
		expect(
			screen.getByRole("heading", { name: "一桥飞架南北，天堑变通途" }),
		).toBeInTheDocument();
		expect(
			screen.getByText("从 2016 到 2046，陪一代女性走进编程"),
		).toBeInTheDocument();
		// 点题句：中英对照品牌名（中文名「程序媛汇」必须出现）
		expect(
			screen.getByText(/Coding Girls Club · 程序媛汇，在女性与编程之间架一座桥/),
		).toBeInTheDocument();

		expect(screen.getByText(/74% 的女孩对 STEM 有强烈兴趣/)).toBeInTheDocument();
		expect(
			screen.getByText(/以帮助女性数字赋能为使命，以平凡的姿态做不平凡的事情/),
		).toBeInTheDocument();
		expect(screen.getByText(/创始人 文洋/)).toBeInTheDocument();
		expect(
			screen.getByText(
				/截至 2021 年，我们走过 10 个城市、办了 50\+ 场线下工作坊/,
			),
		).toBeInTheDocument();
		expect(screen.getByText(/4000\+ 名学员/)).toBeInTheDocument();
	});

	it("页尾：GitHub 开源教程链接", () => {
		render(<LandingPage />);

		const ghLink = screen.getByRole("link", {
			name: /工作坊教程在 GitHub 开源/,
		});
		expect(ghLink).toHaveAttribute(
			"href",
			"https://github.com/CodingGirlsClub",
		);
		expect(ghLink).toHaveAttribute("target", "_blank");
	});

	it("报道与认可：论文（ICSE CHASE 2021 链接）、媒体 6 条（5 条有链接）、机构荣誉", () => {
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

		// 机构荣誉 3 条
		expect(
			screen.getByText(/2018 年入选联合国开发计划署「科技与慈善」项目案例集/),
		).toBeInTheDocument();
		expect(
			screen.getByText(/2019 年共青团中央「全国青年社会组织伙伴计划」获奖项目/),
		).toBeInTheDocument();
		expect(screen.getByText(/#科技遇见她#/)).toBeInTheDocument();
	});

	it("合作伙伴：PDF 权威版精选 8 家（历史同行者口径，无 WorldQuant）", () => {
		render(<LandingPage />);

		for (const partner of [
			"UNDP",
			"ThoughtWorks",
			"GitHub",
			"ByteDance",
			"FreeWheel",
			"个推",
			"掘金",
			"freeCodeCamp",
		]) {
			expect(screen.getByText(partner)).toBeInTheDocument();
		}
		expect(screen.queryByText("WorldQuant")).not.toBeInTheDocument();
		expect(screen.getByText(/曾经的同行者/)).toBeInTheDocument();
	});

	it("公开 API 加载失败：降级为入口链接，整页其余区块不受影响", async () => {
		fetchPublicOfferings.mockRejectedValue(new Error("network down"));
		render(<LandingPage />);

		// 失败降级文案出现
		expect(await screen.findAllByText(/暂时无法加载/)).toHaveLength(2);
		// Hero 与静态区块仍正常渲染
		expect(
			screen.getByRole("heading", {
				name: "一桥飞架南北，天堑变通途",
			}),
		).toBeInTheDocument();
		expect(
			screen.getByRole("heading", { name: "报道与认可" }),
		).toBeInTheDocument();
	});
});
