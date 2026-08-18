import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { NextIntlClientProvider } from "next-intl";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import zhCN from "../messages/zh-CN.json";
import en from "../messages/en.json";
import { ProfileLocaleSelect } from "./profile-locale-select";

/* 语言小节（设置页）：select 变化即 cookie + updateMyLocale + 导航，
 * 与 LanguageSwitcher 同语义；此处验证下拉形态与保存调用。
 */

const replaceMock = vi.fn();

vi.mock("@/i18n/navigation", () => ({
	usePathname: () => "/w/2046/settings/account/profile",
	useRouter: () => ({ replace: replaceMock }),
}));

const updateMyLocaleMock = vi.fn();

vi.mock("@/lib/profile", () => ({
	updateMyLocale: (...args: unknown[]) => updateMyLocaleMock(...args),
}));

function renderSelect(locale: "zh-CN" | "en" = "zh-CN") {
	return render(
		<NextIntlClientProvider locale={locale} messages={locale === "en" ? en : zhCN}>
			<ProfileLocaleSelect />
		</NextIntlClientProvider>,
	);
}

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

describe("ProfileLocaleSelect（i18n Phase 1 D3 设置页语言小节）", () => {
	it("语言下拉存在，当前 locale 选中", () => {
		renderSelect("zh-CN");

		const select = screen.getByTestId("profile-locale-input");
		expect(select).toHaveValue("zh-CN");
		expect(
			screen.getByText(zhCN.settings.languageDescription as string),
		).toBeInTheDocument();
	});

	it("选择新语言：cookie + updateMyLocale + 导航到对应 locale", () => {
		renderSelect("zh-CN");

		fireEvent.change(screen.getByTestId("profile-locale-input"), {
			target: { value: "en" },
		});

		expect(readCookie("cgc_locale")).toBe("en");
		expect(updateMyLocaleMock).toHaveBeenCalledWith("en");
		expect(replaceMock).toHaveBeenCalledWith(
			"/w/2046/settings/account/profile",
			{ locale: "en" },
		);
	});

	it("英文 locale 下文案与选中值同步", () => {
		renderSelect("en");

		const select = screen.getByTestId("profile-locale-input");
		expect(select).toHaveValue("en");
		expect(
			screen.getByText(en.settings.languageDescription as string),
		).toBeInTheDocument();
	});
});
