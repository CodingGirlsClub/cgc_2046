import { describe, expect, it } from "vitest";
import { NextRequest } from "next/server";
import { resolveProxyPlan } from "./proxy";

/* proxy 决策层单测（纯函数 resolveProxyPlan；编排层 Set-Cookie/CSP/跳转
 * 由 curl E2E 实证——happy-dom 下 mock next-intl 存在模块双实例不可靠）：
 * - F0：?_ul 合法值 → 转发 URL 剥参 + 请求注入 cgc_locale cookie
 * - F0 防伪造：非法 _ul（用户手输）→ 剥参但不注入 cookie
 * - F1：转发请求头携带 x-pathname（原始路径 + query，不重序列化）
 * - CSP-REG：malformed 路径（/%zz）→ malformed 标记，编排层返回受控 404
 */

function planFor(path: string) {
	return resolveProxyPlan(
		new NextRequest(new URL(`http://localhost:3100${path}`)),
	);
}

describe("resolveProxyPlan（F0 _ul / F1 x-pathname / CSP-REG malformed）", () => {
	it("F0：合法 _ul → URL 剥参 + 请求头注入 cgc_locale", () => {
		const plan = planFor("/?_ul=zh-CN");

		expect(plan.ulLocale).toBe("zh-CN");
		expect(plan.url.searchParams.get("_ul")).toBeNull();
		expect(plan.url.pathname).toBe("/");
		expect(plan.requestHeaders.get("cookie")).toBe("cgc_locale=zh-CN");
	});

	it("F0：既有 cookie 的追加合并由 curl E2E 实证（happy-dom 丢 request cookie header）", () => {
		// 环境怪癖记录：vitest/happy-dom 下 new NextRequest({headers:{cookie}})
		// 不保留 cookie 头（node 下正常），单测只锁「无既有 cookie」分支；
		// 追加分支的端到端证据见报告 curl 场景（登录 _ul 跳转带 cgc_token）。
		const plan = planFor("/?_ul=en");
		expect(plan.requestHeaders.get("cookie")).toBe("cgc_locale=en");
	});

	it("F0 防伪造：非法 _ul → 剥参、ulLocale null、不注入 cookie", () => {
		const plan = planFor("/?_ul=fr");

		expect(plan.ulLocale).toBeNull();
		expect(plan.url.searchParams.get("_ul")).toBeNull();
		expect(plan.requestHeaders.get("cookie")).toBeNull();
	});

	it("无 _ul：URL 原样、无 cookie 注入", () => {
		const plan = planFor("/login");

		expect(plan.ulLocale).toBeNull();
		expect(plan.url.pathname).toBe("/login");
		expect(plan.requestHeaders.get("cookie")).toBeNull();
	});

	it("F1：x-pathname 携带原始路径 + query（不重序列化）", () => {
		expect(
			planFor("/orders/new?enrollmentId=e1").requestHeaders.get("x-pathname"),
		).toBe("/orders/new?enrollmentId=e1");
		// 原始串保真：next=/bar 不被 URLSearchParams 重序列化成 next=%2Fbar
		expect(planFor("/w/foo?next=/bar").requestHeaders.get("x-pathname")).toBe(
			"/w/foo?next=/bar",
		);
	});

	it("x-nonce 注入且 CSP 含 strict-dynamic + 同一 nonce", () => {
		const plan = planFor("/");

		const nonce = plan.requestHeaders.get("x-nonce") ?? "";
		expect(nonce).toMatch(/^[A-Za-z0-9+/=]{20,}$/);
		expect(plan.cspHeader).toContain("'strict-dynamic'");
		expect(plan.cspHeader).toContain(`'nonce-${nonce}'`);
	});

	it("CSP-REG：malformed 路径标记 malformed（编排层返回受控静态 404（零 script + 全安全头））", () => {
		expect(planFor("/%zz").malformed).toBe(true);
		expect(planFor("/%%").malformed).toBe(true);
		expect(planFor("/login").malformed).toBe(false);
		expect(planFor("/w/café").malformed).toBe(false);
	});
});
