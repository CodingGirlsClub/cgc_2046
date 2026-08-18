import { NextRequest } from "next/server";
import createMiddleware from "next-intl/middleware";
import { routing } from "./i18n/routing";

/**
 * proxy（Next 16 更名自 middleware）＝ CSP/security headers + next-intl 路由（同文件组合）。
 *
 * 组合顺序：先把安全头（CSP nonce、x-pathname）写进转发请求，再交给 next-intl
 * 中间件——其内部 `new Headers(request.headers)` 派生渲染请求头，我们的头随之
 * 透传到页面渲染（nonce 注入链路保持不变）；返回的 response（next/rewrite/redirect
 * 三态）再统一补响应头 CSP。
 *
 * x-pathname：重写前原始路径，供 [locale] 布局服务端做 User.locale 一次性对齐
 * （redirect 目标需要用户可见路径而非内部 /[locale]/... 路径）。
 */

const intlMiddleware = createMiddleware(routing);

export function proxy(request: NextRequest) {
	const nonce = Buffer.from(crypto.randomUUID()).toString("base64");
	const isDev = process.env.NODE_ENV === "development";

	const cspHeader = [
		"default-src 'self'",
		`script-src 'self' 'nonce-${nonce}' 'strict-dynamic'${isDev ? " 'unsafe-eval'" : ""}`,
		`style-src 'self'${isDev ? " 'unsafe-inline'" : ` 'nonce-${nonce}'`}`,
		"img-src 'self' data:",
		`frame-src https://www.openclacky.com`,
		"font-src 'self' data:",
		"connect-src 'self'",
		"frame-ancestors 'none'",
		"base-uri 'self'",
		"form-action 'self'",
	].join("; ");

	const requestHeaders = new Headers(request.headers);
	requestHeaders.set("x-nonce", nonce);
	requestHeaders.set("Content-Security-Policy", cspHeader);
	// 页面导航均为 GET（项目无 server actions，数据全走 /api GraphQL 且 matcher 已排除）；
	// 仍按 method/body 透传构造，保持通用性。
	const forwarded = new NextRequest(request.nextUrl, {
		method: request.method,
		headers: requestHeaders,
		...(request.body ? { body: request.body, duplex: "half" } : {}),
	});

	const response = intlMiddleware(forwarded);
	response.headers.set("Content-Security-Policy", cspHeader);

	return response;
}

export const config = {
	matcher: [
		{
			source: "/((?!api|_next/static|_next/image|favicon.ico).*)",
			missing: [
				{ type: "header", key: "next-router-prefetch" },
				{ type: "header", key: "purpose", value: "prefetch" },
			],
		},
	],
};
