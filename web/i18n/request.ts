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
 * 注：根 layout 持有 await connection()，全站为动态渲染——
 * generateStaticParams 在该动态树下不产生构建期静态页（保留以兼容未来静态化）。
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
