/**
 * locale cookie 写入（i18n Phase 1，L0 决策 5 协商链的 cookie 层）。
 *
 * 独立模块函数而非组件内联赋值：document.cookie 属性赋值在 React Compiler 的
 * react-hooks/immutability 规则下属于全局 mutation，提出来也让切换器与设置页
 * 下拉共用同一写法（365d，samesite=lax，与 next-intl localeCookie 配置一致）。
 */

import { LOCALE_COOKIE, type Locale } from "@/i18n/routing";

export function writeLocaleCookie(locale: Locale): void {
	if (typeof document === "undefined") return;
	document.cookie = `${LOCALE_COOKIE}=${locale}; path=/; max-age=31536000; samesite=lax`;
}
