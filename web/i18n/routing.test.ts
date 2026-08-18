import { describe, expect, it } from "vitest";
import { LOCALE_COOKIE, routing } from "./routing";

describe("i18n/routing（i18n Phase 1 L0 决策）", () => {
	it("locale 集合为 zh-CN + en（BCP47 对外命名）", () => {
		expect(routing.locales).toEqual(["zh-CN", "en"]);
	});

	it("默认 locale 为 zh-CN（协商链终点）", () => {
		expect(routing.defaultLocale).toBe("zh-CN");
	});

	it("localePrefix 为 as-needed：zh-CN 无前缀、en 带 /en 前缀", () => {
		expect(routing.localePrefix).toBe("as-needed");
	});

	it("locale cookie 名为 cgc_locale（L0 决策 5 协商链 cookie 层）", () => {
		expect(routing.localeCookie).toMatchObject({ name: LOCALE_COOKIE });
		expect(LOCALE_COOKIE).toBe("cgc_locale");
	});
});
