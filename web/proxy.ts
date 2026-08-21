import { NextRequest, NextResponse } from "next/server";
import createMiddleware from "next-intl/middleware";
import { hasLocale } from "next-intl";
import { LOCALE_COOKIE, routing } from "./i18n/routing";
import { USER_LOCALE_PARAM } from "./i18n/user-locale";

/**
 * proxy（Next 16 更名自 middleware）＝ CSP/security headers + next-intl 路由（同文件组合）。
 *
 * 组合顺序：先把安全头（CSP nonce、x-pathname）写进转发请求，再交给 next-intl
 * 中间件——其内部 `new Headers(request.headers)` 派生渲染请求头，我们的头随之
 * 透传到页面渲染（nonce 注入链路保持不变）；返回的 response（next/rewrite/redirect
 * 三态）再统一补响应头 CSP。
 *
 * 决策（resolveProxyPlan，纯函数可单测）与编排（proxy，副作用）分离：
 * - x-pathname（F1）：重写前用户可见路径（含 query），供 [locale] 布局做
 *   User.locale 一次性对齐——redirect 目标需要用户可见路径而非内部路径。
 * - _ul（F0/F2b，方案 A）：布局对齐 redirect 携带 ?_ul=<locale>；检测到参数 →
 *   转发请求注入 cgc_locale cookie（next-intl 立即按该 locale 协商，跳过
 *   Accept-Language 二次重定向）+ 响应 Set-Cookie 永久固化，并从转发 URL 剥除。
 *   值过 hasLocale 白名单，非法（用户伪造）只剥参数不写 cookie。
 * - malformed 路径（CSP-REG）：next-intl 对 decodeURI 抛错的路径（/%zz）走裸
 *   `NextResponse.next()` 分支，丢请求头 override → 渲染层拿不到 x-nonce。
 *   以同语义 decodeURI 预检拦截，自组带 headers 的 next() 保 nonce 链完整
 *   （恢复 baseline：404 + nonce）；另以 try/catch 兜底意外异常。
 *
 * 编排层行为（Set-Cookie/CSP/重定向跳数）由 curl E2E 实证（见 writer02 报告）。
 */

const intlMiddleware = createMiddleware(routing);

export type ProxyPlan = {
	/** 剥除 _ul 后的转发 URL（search 已清理） */
	url: URL;
	/** 合法 _ul 值；非法或缺失为 null（参数无论合法与否都已剥除） */
	ulLocale: string | null;
	/** malformed 路径（decodeURI 抛错）→ 绕过 next-intl */
	malformed: boolean;
	/** 含 x-nonce / x-pathname /（有 _ul 时）cookie 注入的转发请求头 */
	requestHeaders: Headers;
	/** CSP 头（nonce 已嵌入） */
	cspHeader: string;
};

/** 与 next-intl middleware 同语义的 malformed 预检（decodeURI 对非法 % 序列抛错） */
function decodePathname(pathname: string): string | null {
	try {
		return decodeURI(pathname);
	} catch {
		return null;
	}
}

/** 决策纯函数：不产生副作用，单测覆盖（proxy.test.ts） */
export function resolveProxyPlan(request: NextRequest): ProxyPlan {
	const nonce = Buffer.from(crypto.randomUUID()).toString("base64");
	const isDev = process.env.NODE_ENV === "development";

	const cspHeader = [
		"default-src 'self'",
		`script-src 'self' 'nonce-${nonce}' 'strict-dynamic'${isDev ? " 'unsafe-eval'" : ""}`,
		`style-src 'self'${isDev ? " 'unsafe-inline'" : ` 'nonce-${nonce}'`}`,
		"img-src 'self' data:",
		`frame-src https://www.openclacky.com https://open.weixin.qq.com`,
		"font-src 'self' data:",
		"connect-src 'self'",
		"frame-ancestors 'none'",
		"base-uri 'self'",
		"form-action 'self'",
	].join("; ");

	const url = request.nextUrl.clone();
	const ulParam = url.searchParams.get(USER_LOCALE_PARAM);
	const ulLocale =
		ulParam !== null && hasLocale(routing.locales, ulParam) ? ulParam : null;
	if (ulParam !== null) url.searchParams.delete(USER_LOCALE_PARAM);

	const requestHeaders = new Headers(request.headers);
	requestHeaders.set("x-nonce", nonce);
	requestHeaders.set("Content-Security-Policy", cspHeader);
	// x-pathname 用原始（未剥 _ul、未重序列化）的用户可见路径：URLSearchParams
	// 重序列化会破坏既有参数编码（next=%2Fbar）。_ul 跳转必伴随 cookie 注入，
	// 布局仅在无 cookie 时消费 x-pathname → 带 _ul 无害。
	requestHeaders.set(
		"x-pathname",
		`${request.nextUrl.pathname}${request.nextUrl.search}`,
	);
	if (ulLocale) {
		// 等价于 cookie 已写入：next-intl 按 _ul locale 协商，不再走 Accept-Language
		const cookie = requestHeaders.get("cookie");
		requestHeaders.set(
			"cookie",
			cookie
				? `${cookie}; ${LOCALE_COOKIE}=${ulLocale}`
				: `${LOCALE_COOKIE}=${ulLocale}`,
		);
	}

	return {
		url,
		ulLocale,
		malformed: decodePathname(url.pathname) === null,
		requestHeaders,
		cspHeader,
	};
}

/** malformed 路径的受控 404 页（零 script，无需 nonce；文案双语简版） */
const MALFORMED_404_HTML = `<!DOCTYPE html>
<html lang="zh-CN">
<head><meta charset="utf-8"><title>404</title></head>
<body style="font-family:system-ui;display:grid;place-items:center;min-height:100vh;margin:0">
<p>页面不存在 / Page not found</p>
</body>
</html>`;

export function proxy(request: NextRequest) {
	const plan = resolveProxyPlan(request);

	if (plan.malformed) {
		// CSP-REG：malformed 路径不放大行（Next 内部对非法 % 序列的处理不可控：
		// dev 400 / prod 500 空体且响应丢失安全头），直接返回受控静态 404——
		// 零 script（无 nonce 需求）+ 全安全头，环境间行为一致。
		return new NextResponse(MALFORMED_404_HTML, {
			status: 404,
			headers: {
				"content-type": "text/html; charset=utf-8",
				"Cache-Control": "no-store",
				"Content-Security-Policy": plan.cspHeader,
				"X-Content-Type-Options": "nosniff",
				"Referrer-Policy": "strict-origin-when-cross-origin",
				"X-Frame-Options": "DENY",
			},
		});
	}

	// 页面导航均为 GET（项目无 server actions，数据全走 /api GraphQL 且 matcher 已排除）；
	// 仍按 method/body 透传构造，保持通用性。
	let response: NextResponse;
	const forwarded = new NextRequest(plan.url, {
		method: request.method,
		headers: plan.requestHeaders,
		...(request.body ? { body: request.body, duplex: "half" } : {}),
	});
	try {
		response = intlMiddleware(forwarded);
	} catch {
		// 兜底：next-intl 意外异常时不裸奔，保安全头链路
		response = NextResponse.next({ request: { headers: plan.requestHeaders } });
	}

	if (plan.ulLocale) {
		// F0 固化：与 routing.ts localeCookie 配置一致（365d / lax / secure 生产）
		response.cookies.set({
			name: LOCALE_COOKIE,
			value: plan.ulLocale,
			path: "/",
			maxAge: 60 * 60 * 24 * 365,
			sameSite: "lax",
			secure: process.env.NODE_ENV === "production",
		});
	}
	response.headers.set("Content-Security-Policy", plan.cspHeader);

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
