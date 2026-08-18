import { describe, it, expect } from "vitest";
import { resolveNextTarget } from "../../app/[locale]/(auth)/login/use-auth-submit";

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
