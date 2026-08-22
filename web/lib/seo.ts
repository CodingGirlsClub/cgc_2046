import type { Metadata } from "next";

/**
 * SEO URL 单源（#239 hreflang 逐页化）。
 *
 * - resolveWebBaseUrl：生产由 NEXT_PUBLIC_WEB_BASE_URL 构建期注入（#254 部署链）；
 *   空串视同未设置（CI sed 注空的防御），尾斜杠剥除防拼出 `//`。
 * - localizedUrl / pageAlternates：D3 决策——zh-CN 无前缀、en 带 /en 前缀
 *   （i18n/routing.ts localePrefix "as-needed" 的 URL 镜像）；canonical 指当前
 *   locale 页，languages 双向互指。
 *
 * 契约：只有公开可索引页在自己的 generateMetadata 里调用 pageAlternates——
 * 私有页（admin/w/orders 等）不输出 canonical，由 app/robots.ts disallow 兜底。
 * 新增公开页时：页面调 pageAlternates + app/sitemap.ts 静态清单加一行。
 */

export function resolveWebBaseUrl(): string {
	const raw =
		process.env.NEXT_PUBLIC_WEB_BASE_URL?.trim() ||
		process.env.NEXT_PUBLIC_SITE_URL?.trim() ||
		"http://localhost:3000";
	return raw.replace(/\/+$/, "");
}

/** pathname 为无 locale 前缀的规范路径（"/"、"/events/xx"）；en 根路径输出 /en 无尾斜杠 */
export function localizedUrl(pathname: string, locale: string): string {
	const base = resolveWebBaseUrl();
	if (locale === "en") {
		return pathname === "/" ? `${base}/en` : `${base}/en${pathname}`;
	}
	return `${base}${pathname}`;
}

export function pageAlternates(
	pathname: string,
	locale: string,
): Metadata["alternates"] {
	return {
		canonical: localizedUrl(pathname, locale),
		languages: {
			"zh-CN": localizedUrl(pathname, "zh-CN"),
			en: localizedUrl(pathname, "en"),
		},
	};
}
