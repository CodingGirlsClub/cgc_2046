import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import LandingPage from "./landing-page";

/**
 * 公开 Landing 页测试（M2）。
 *
 * 结构：Hero（2016 → 2046 三十年叙事）、最新活动、精选课程、
 * 媒体报道、合作企业、登录/注册 CTA。
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
				name: "从 2016 到 2046，陪一代女性走进编程",
			}),
		).toBeInTheDocument();
		expect(
			screen.getByRole("heading", { name: "最新活动" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("heading", { name: "精选课程" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("heading", { name: "媒体报道" }),
		).toBeInTheDocument();
		expect(
			screen.getByRole("heading", { name: "合作企业" }),
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

	it("渲染媒体报道（3 条历史素材）与合作企业（历史同行者清单）", () => {
		render(<LandingPage />);

		// 媒体报道：纯文本列表，不放假链接
		expect(screen.getByText("果壳网 · 2017-01-14")).toBeInTheDocument();
		expect(screen.getByText("CCTV 英文频道 · 2017-02-16")).toBeInTheDocument();
		expect(
			screen.getByText("联合国开发计划署驻华代表处 · 2018-06-27"),
		).toBeInTheDocument();

		// 合作企业：历史口径，只列名称
		for (const partner of [
			"ThoughtWorks",
			"GitHub",
			"Yunbi",
			"NEO",
			"个推",
			"掘金",
			"WorldQuant",
		]) {
			expect(screen.getByText(partner)).toBeInTheDocument();
		}
	});

	it("公开 API 加载失败：降级为入口链接，整页其余区块不受影响", async () => {
		fetchPublicOfferings.mockRejectedValue(new Error("network down"));
		render(<LandingPage />);

		// 失败降级文案出现
		expect(await screen.findAllByText(/暂时无法加载/)).toHaveLength(2);
		// Hero 与静态区块仍正常渲染
		expect(
			screen.getByRole("heading", {
				name: "从 2016 到 2046，陪一代女性走进编程",
			}),
		).toBeInTheDocument();
		expect(
			screen.getByRole("heading", { name: "媒体报道" }),
		).toBeInTheDocument();
	});
});
