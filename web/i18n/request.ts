import * as rootParams from "next/root-params";
import { hasLocale } from "next-intl";
import { getRequestConfig } from "next-intl/server";
import { notFound } from "next/navigation";
import { routing } from "./routing";

/**
 * 服务端请求级 i18n 配置（Next 16.3 经 next/root-params 读取 [locale] 段；
 * setRequestLocale 为 legacy API，不再使用）。
 *
 * [locale] 段对未知路径是 catch-all，非法 locale 值 → notFound()。
 * 静态渲染由 [locale]/layout.tsx 的 generateStaticParams 覆盖。
 */
export default getRequestConfig(async ({ locale }) => {
	if (!locale) {
		const paramValue = await rootParams.locale();
		if (hasLocale(routing.locales, paramValue)) {
			locale = paramValue;
		} else {
			notFound();
		}
	}

	return {
		locale,
		messages: (await import(`../messages/${locale}.json`)).default,
	};
});
