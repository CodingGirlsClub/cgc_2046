import type { MetadataRoute } from "next";
import { resolveWebBaseUrl } from "@/lib/seo";

/**
 * /robots.txt（#239）：私有/登录后区域禁爬（这些页面不声明 canonical，见
 * lib/seo.ts 契约）；公开面由 sitemap.xml 指路。zh 无前缀 + /en 前缀双份
 * （robots 规则是纯前缀匹配，D3 双前缀需各列一遍）。
 */

const PRIVATE_PATHS = [
	"/admin",
	"/w/",
	"/orders",
	"/participations",
	"/approvals",
	"/settings",
	"/apply",
	"/join",
	"/forgot-password",
	"/reset-password",
	"/login/wechat-callback",
	"/events/*/speaker-invite/",
];

export default function robots(): MetadataRoute.Robots {
	return {
		rules: {
			userAgent: "*",
			allow: "/",
			disallow: PRIVATE_PATHS.flatMap((p) => [p, `/en${p}`]),
		},
		sitemap: `${resolveWebBaseUrl()}/sitemap.xml`,
	};
}
