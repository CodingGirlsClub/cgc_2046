import { describe, it, expect } from "vitest";
import {
	needsFullPageLoad,
	readAuthTarget,
	resolveNextTarget,
} from "../../app/[locale]/(auth)/login/use-auth-submit";

describe("resolveNextTarget（登录后跳转同源校验）", () => {
	const origin = "http://localhost:3000";

	it("同源相对路径放行（保留 query/hash）", () => {
		expect(resolveNextTarget("/events/e-abc?x=1#top", origin)).toBe(
			"/events/e-abc?x=1#top",
		);
	});

	it("跨域完整 URL 拒绝；反斜杠绕过拒绝；空值回退 /", () => {
		expect(resolveNextTarget("https://evil.example/x", origin)).toBe("/");
		expect(resolveNextTarget("/\\evil.example", origin)).toBe("/");
		expect(resolveNextTarget("//evil.example", origin)).toBe("/");
		expect(resolveNextTarget(null, origin)).toBe("/");
		expect(resolveNextTarget("", origin)).toBe("/");
	});

	it("同源但协议相对 pathname（本域//evil.example）拒绝", () => {
		expect(resolveNextTarget("http://localhost:3000//evil.example", origin)).toBe("/");
	});
});

describe("readAuthTarget（登录后目标读取单源：return_to / next）", () => {
	it("return_to（后端授权页未登录回跳）优先于站内 next", () => {
		const params = new URLSearchParams(
			"return_to=%2Foauth%2Fauthorize%3Fclient_id%3Dabc&next=%2Fw%2Fx",
		);
		expect(readAuthTarget(params)).toBe("/oauth/authorize?client_id=abc");
	});

	it("无 return_to 时取 next；两者皆无（或未挂载）→ null", () => {
		expect(readAuthTarget(new URLSearchParams("next=/orders/new"))).toBe("/orders/new");
		expect(readAuthTarget(new URLSearchParams(""))).toBeNull();
		expect(readAuthTarget(null)).toBeNull();
	});
});

describe("needsFullPageLoad（后端渲染路径必须整页跳转）", () => {
	it("授权页由后端渲染（部署层路径路由，Next 无此路由）→ 整页跳转", () => {
		expect(needsFullPageLoad("/oauth/authorize?client_id=abc&state=s1")).toBe(true);
	});

	it("站内路径 → 客户端路由（含根路径与同前缀干扰项）", () => {
		expect(needsFullPageLoad("/orders/new")).toBe(false);
		expect(needsFullPageLoad("/")).toBe(false);
		expect(needsFullPageLoad("/oauth2/x")).toBe(false);
	});
});
