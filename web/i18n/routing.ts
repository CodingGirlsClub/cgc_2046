import { defineRouting } from "next-intl/routing";

/**
 * i18n 路由配置单源（next-intl 4，i18n Phase 1）。
 *
 * - locale 集：zh-CN（默认）+ en；BCP47 对外命名（Gettext 内部 zh_CN/en 的转换
 *   单点留给 Phase 4 前接入，Phase 1 不涉及）。
 * - localePrefix 'as-needed'：zh-CN 无前缀（现有 URL 逐字节不变，零 301），
 *   en 走 /en 前缀。
 * - locale cookie 名 cgc_locale（L0 决策 5 协商链的 cookie 层；中间件读写同名）。
 */

export const LOCALE_COOKIE = "cgc_locale";

export const routing = defineRouting({
	locales: ["zh-CN", "en"],
	defaultLocale: "zh-CN",
	localePrefix: "as-needed",
	localeCookie: {
		name: LOCALE_COOKIE,
		maxAge: 60 * 60 * 24 * 365,
		sameSite: "lax",
		secure: process.env.NODE_ENV === "production",
	},
});

export type Locale = (typeof routing.locales)[number];

/** 用户可选的界面语言（语言切换器/设置页下拉共用） */
export const LOCALE_OPTIONS: ReadonlyArray<{ value: Locale; label: string }> = [
	{ value: "zh-CN", label: "中文" },
	{ value: "en", label: "English" },
];
