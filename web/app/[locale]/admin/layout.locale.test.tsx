import { describe, it, expect, vi, afterEach } from "vitest";
import { screen, cleanup } from "@testing-library/react";
import { render } from "@/test-utils";
import AdminLayout from "./layout";

/**
 * EN locale 回归钉测（2026-08-22 诊断，同 workspace-shell.locale.test）：
 * /en 前缀下 admin 导航激活态（pathname 与不带前缀的 ADMIN_NAV href 比较）
 * 必须仍然成立。根因与修复同壳：usePathname 走 @/i18n/navigation 去前缀版。
 */

const { pathnameRef } = vi.hoisted(() => ({
	pathnameRef: { value: "/admin" },
}));

vi.mock("next/navigation", () => ({
	usePathname: () => pathnameRef.value,
	useRouter: () => ({ push: vi.fn(), replace: vi.fn(), prefetch: vi.fn() }),
	useParams: () => ({}),
	redirect: vi.fn(),
	permanentRedirect: vi.fn(),
}));
// 布局测试只关心导航激活态；守卫逻辑有自己的 admin-guard.test
vi.mock("@/components/admin-guard", () => ({
	default: ({ children }: { children: React.ReactNode }) => <>{children}</>,
}));

afterEach(cleanup);

function currentLinks() {
	return screen
		.getAllByRole("link")
		.filter((l) => l.getAttribute("aria-current") === "page");
}

describe("AdminLayout 的 locale 前缀路径判定", () => {
	it("EN（/en/admin/users）：navUsers 项 aria-current=page", () => {
		pathnameRef.value = "/en/admin/users";
		render(<AdminLayout>x</AdminLayout>, { locale: "en" });

		const current = currentLinks();
		expect(current).toHaveLength(1);
		expect(current[0].getAttribute("href")).toContain("/admin/users");
	});

	it("zh-CN（无前缀 /admin/users）：激活态不回归（对照）", () => {
		pathnameRef.value = "/admin/users";
		render(<AdminLayout>x</AdminLayout>);

		const current = currentLinks();
		expect(current).toHaveLength(1);
		expect(current[0].getAttribute("href")).toContain("/admin/users");
	});
});
