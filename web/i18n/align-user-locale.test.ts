import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { alignUserLocale } from "./align-user-locale";

// 只 mock RSC-only 的 next/headers；redirect/unstable_rethrow 用真实实现，
// 验证「NEXT_REDIRECT 穿透 catch、其余错误静默降级」的真实语义（#283）
const state = vi.hoisted(() => ({
	cookies: new Map<string, string>(),
	xPathname: "/" as string | null,
}));

vi.mock("next/headers", () => ({
	cookies: async () => ({
		get: (name: string) =>
			state.cookies.has(name)
				? { name, value: state.cookies.get(name)! }
				: undefined,
	}),
	headers: async () => ({
		get: (name: string) => (name === "x-pathname" ? state.xPathname : null),
	}),
}));

function meResponse(locale: string | null) {
	return new Response(JSON.stringify({ data: { me: { locale } } }), {
		status: 200,
		headers: { "content-type": "application/json" },
	});
}

describe("alignUserLocale（#283 生产 500 回归）", () => {
	const fetchMock = vi.fn();

	beforeEach(() => {
		state.cookies.clear();
		state.xPathname = "/";
		fetchMock.mockReset();
		vi.stubGlobal("fetch", fetchMock);
		vi.stubEnv("BACKEND_URL", "http://backend:4000");
	});

	afterEach(() => {
		vi.unstubAllGlobals();
		vi.unstubAllEnvs();
	});

	it("#283 主案例：带 token 无 locale cookie 且运行时缺 BACKEND_URL——按匿名降级，不抛不 fetch", async () => {
		vi.stubEnv("BACKEND_URL", "");
		delete process.env.BACKEND_URL;
		state.cookies.set("cgc_token", "stale-token");
		const errorSpy = vi.spyOn(console, "error").mockImplementation(() => {});

		await expect(alignUserLocale()).resolves.toBeUndefined();
		expect(fetchMock).not.toHaveBeenCalled();
		expect(errorSpy).toHaveBeenCalledOnce();
		errorSpy.mockRestore();
	});

	it("token 无效（me 为 null）：静默降级，不 redirect", async () => {
		state.cookies.set("cgc_token", "expired");
		fetchMock.mockResolvedValue(
			new Response(JSON.stringify({ data: { me: null } }), { status: 200 }),
		);

		await expect(alignUserLocale()).resolves.toBeUndefined();
	});

	it("token 无效（401 非 JSON body）：静默降级", async () => {
		state.cookies.set("cgc_token", "expired");
		fetchMock.mockResolvedValue(new Response("unauthorized", { status: 401 }));

		await expect(alignUserLocale()).resolves.toBeUndefined();
	});

	it("me 查询网络失败/超时：静默降级", async () => {
		state.cookies.set("cgc_token", "t");
		fetchMock.mockRejectedValue(new Error("network down"));

		await expect(alignUserLocale()).resolves.toBeUndefined();
	});

	it("正常路径保持：me.locale=en 时 redirect 到 /en?_ul=en（NEXT_REDIRECT 穿透 catch）", async () => {
		state.cookies.set("cgc_token", "valid");
		// Response body 只能读一次，每次调用需新实例
		fetchMock.mockImplementation(() => Promise.resolve(meResponse("en")));

		await expect(alignUserLocale()).rejects.toMatchObject({
			digest: expect.stringContaining("NEXT_REDIRECT"),
		});
		await expect(alignUserLocale()).rejects.toMatchObject({
			digest: expect.stringContaining("/en?_ul=en"),
		});
	});

	it("正常路径保持：深链 /en/w/foo + me.locale=zh-CN 时剥前缀 redirect", async () => {
		state.cookies.set("cgc_token", "valid");
		state.xPathname = "/en/w/foo?tab=1";
		fetchMock.mockResolvedValue(meResponse("zh-CN"));

		await expect(alignUserLocale()).rejects.toMatchObject({
			digest: expect.stringContaining("/w/foo?tab=1&_ul=zh-CN"),
		});
	});

	it("已有 locale cookie：早退不 fetch", async () => {
		state.cookies.set("cgc_locale", "zh-CN");
		state.cookies.set("cgc_token", "valid");

		await alignUserLocale();
		expect(fetchMock).not.toHaveBeenCalled();
	});

	it("无 token：早退不 fetch", async () => {
		await alignUserLocale();
		expect(fetchMock).not.toHaveBeenCalled();
	});
});
