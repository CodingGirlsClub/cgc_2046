import { cleanup, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { NextIntlClientProvider } from "next-intl";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import zhCN from "../messages/zh-CN.json";
import LanguageSwitcher from "./language-switcher";

/* 切换器依赖（mock 边界）：
 * - next-intl navigation：router.replace(pathname, {locale}) 是断言对象
 * - useAuthed：匿名/登录两分支
 * - updateMyLocale：登录分支的持久化 mutation（fire-and-forget）
 * cookie 写入走真实 document.cookie（断言后清理）
 */

const replaceMock = vi.fn();
const useAuthedMock = vi.fn();

vi.mock("@/i18n/navigation", () => ({
	usePathname: () => "/login",
	useRouter: () => ({ replace: replaceMock }),
}));

vi.mock("@/lib/use-authed", () => ({
	useAuthed: () => useAuthedMock(),
}));

const updateMyLocaleMock = vi.fn();

vi.mock("@/lib/profile", () => ({
	updateMyLocale: (...args: unknown[]) => updateMyLocaleMock(...args),
}));

function renderSwitcher(locale = "zh-CN") {
	return render(
		<NextIntlClientProvider locale={locale} messages={zhCN}>
			<LanguageSwitcher />
		</NextIntlClientProvider>,
	);
}

beforeEach(() => {
	// F4：组件读 window.location 原始 search/hash 拼回 query
	window.location.href = "http://localhost:3100/login?next=/orders/new";
});

function readCookie(name: string): string | undefined {
	const entry = document.cookie
		.split("; ")
		.find((c) => c.startsWith(`${name}=`));
	return entry?.split("=")[1];
}

beforeEach(() => {
	replaceMock.mockReset();
	updateMyLocaleMock.mockReset();
	updateMyLocaleMock.mockResolvedValue(undefined);
	document.cookie = "cgc_locale=; path=/; max-age=0";
});

afterEach(() => {
	cleanup();
	document.cookie = "cgc_locale=; path=/; max-age=0";
});

describe("LanguageSwitcher（i18n Phase 1 D3）", () => {
	it("两个选项均渲染，当前 locale 高亮（aria-current）", () => {
		useAuthedMock.mockReturnValue({ authed: false, confirmed: true });
		renderSwitcher("zh-CN");

		const zh = screen.getByRole("button", { name: "中文" });
		const en = screen.getByRole("button", { name: "English" });
		expect(zh).toHaveAttribute("aria-current", "true");
		expect(en).not.toHaveAttribute("aria-current");
	});

	it("匿名切换：写 cgc_locale cookie + 导航，不调 mutation", () => {
		useAuthedMock.mockReturnValue({ authed: false, confirmed: true });
		renderSwitcher("zh-CN");

		fireEvent.click(screen.getByRole("button", { name: "English" }));

		expect(readCookie("cgc_locale")).toBe("en");
		expect(replaceMock).toHaveBeenCalledWith("/login?next=/orders/new", { locale: "en" });
		expect(updateMyLocaleMock).not.toHaveBeenCalled();
	});

	it("登录切换：cookie + 静默 updateMyLocale + 导航", () => {
		useAuthedMock.mockReturnValue({ authed: true, confirmed: true });
		renderSwitcher("zh-CN");

		fireEvent.click(screen.getByRole("button", { name: "English" }));

		expect(readCookie("cgc_locale")).toBe("en");
		expect(updateMyLocaleMock).toHaveBeenCalledWith("en");
		expect(replaceMock).toHaveBeenCalledWith("/login?next=/orders/new", { locale: "en" });
	});

	it("mutation 失败不阻塞导航（fire-and-forget）", async () => {
		useAuthedMock.mockReturnValue({ authed: true, confirmed: true });
		updateMyLocaleMock.mockRejectedValue(new Error("network"));
		renderSwitcher("zh-CN");

		fireEvent.click(screen.getByRole("button", { name: "English" }));

		await waitFor(() => {
			expect(replaceMock).toHaveBeenCalledWith("/login?next=/orders/new", { locale: "en" });
		});
		expect(readCookie("cgc_locale")).toBe("en");
	});

	it("点击当前 locale 不产生副作用", () => {
		useAuthedMock.mockReturnValue({ authed: true, confirmed: true });
		renderSwitcher("zh-CN");

		fireEvent.click(screen.getByRole("button", { name: "中文" }));

		expect(readCookie("cgc_locale")).toBeUndefined();
		expect(replaceMock).not.toHaveBeenCalled();
		expect(updateMyLocaleMock).not.toHaveBeenCalled();
	});
});
