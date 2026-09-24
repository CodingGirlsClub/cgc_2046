import { describe, it, expect, vi } from "vitest";
import { cleanup, screen } from "@testing-library/react";
import { render } from "@/test-utils";
import SiteFooter from "./site-footer";

// next-intl Link 挂载依赖 app router useRouter（法务链接渲染需要）
vi.mock("next/navigation", () => ({
	usePathname: () => "/events",
	useRouter: () => ({ push: vi.fn(), replace: vi.fn(), prefetch: vi.fn() }),
	useParams: () => ({}),
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
}));

afterEach(() => {
	cleanup();
});

describe("SiteFooter 全站页脚（瘦身收敛：与顶导零重复）", () => {
	it("渲染品牌、法务链接、版权与 ICP 备案", () => {
		render(<SiteFooter />);

		// 品牌锁板（非链接，parity 对齐原 landing 页脚）
		expect(screen.getByText("程序媛汇")).toBeInTheDocument();
		expect(screen.getByText(/2016 → 2046/)).toBeInTheDocument();

		// 法务链接：header 没有的入口，全站可达（原仅首页页脚，目录/详情/法务页裸奔）
		expect(screen.getByRole("link", { name: "隐私政策" })).toHaveAttribute(
			"href",
			"/privacy",
		);
		expect(screen.getByRole("link", { name: "服务条款" })).toHaveAttribute(
			"href",
			"/terms",
		);

		// ICP 备案：外链官方查询页，新标签打开
		const icp = screen.getByRole("link", { name: "京ICP备16008426号-2" });
		expect(icp).toHaveAttribute("href", "https://beian.miit.gov.cn");
		expect(icp).toHaveAttribute("target", "_blank");
		expect(icp).toHaveAttribute("rel", expect.stringContaining("noopener"));
		expect(screen.getByText("© CodingGirlsClub")).toBeInTheDocument();
	});

	it("不放顶导已有的东西：站点导航链接与语言切换一律移除", () => {
		render(<SiteFooter />);

		// 导航在头部与抽屉平铺，页脚不再重复（决策 2026-09 user review）
		for (const name of [
			"Hacker Start 1024",
			"活动",
			"课程",
			"倡导活动",
			"闪念间",
			"金句墙",
			"许愿树",
		]) {
			expect(screen.queryByRole("link", { name })).not.toBeInTheDocument();
		}
		// 语言切换常驻顶导与抽屉，页脚不再重复承载
		expect(screen.queryByRole("group", { name: "语言" })).not.toBeInTheDocument();
	});

	it("en locale：法务链接走英文并带 /en 前缀", () => {
		render(<SiteFooter />, { locale: "en" });
		expect(
			screen.getByRole("link", { name: "Privacy Policy" }),
		).toHaveAttribute("href", "/en/privacy");
		expect(
			screen.getByRole("link", { name: "Terms of Service" }),
		).toHaveAttribute("href", "/en/terms");
	});
});
