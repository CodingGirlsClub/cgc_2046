import { describe, it, expect, vi, beforeEach } from "vitest";

const { mutate, clearStore } = vi.hoisted(() => ({
	mutate: vi.fn().mockResolvedValue({ data: { signOut: "signed_out" } }),
	clearStore: vi.fn().mockResolvedValue(undefined),
}));

vi.mock("./apollo-client", () => ({
	client: { mutate, clearStore },
}));

describe("auth 登录态工具 (#61)", () => {
	beforeEach(() => {
		vi.clearAllMocks();
	});

	it("clearSession 调 signOut mutation 并清 Apollo 缓存", async () => {
		const { clearSession } = await import("./auth");
		await clearSession();

		// 正向 regression guard：mutate 必须以 signOut mutation document 被调。
		// 弱断言 toHaveBeenCalled() 不能发现 clearSession 误改成调别的 mutation。
		expect(mutate).toHaveBeenCalledTimes(1);
		// mutate({ mutation: DocumentNode })——document 嵌在 call.mutation
		const { mutation } = mutate.mock.calls[0][0] as { mutation: { definitions: unknown[] } };
		expect(mutation.definitions).toEqual(
			expect.arrayContaining([
				expect.objectContaining({
					operation: "mutation",
					name: expect.objectContaining({ value: "SignOut" }),
				}),
			]),
		);
		expect(clearStore).toHaveBeenCalledTimes(1);
	});

	it("signOut 成功：返回 { ok: true }（#018 上报契约）", async () => {
		const { clearSession } = await import("./auth");
		await expect(clearSession()).resolves.toEqual({ ok: true });
		expect(clearStore).toHaveBeenCalledTimes(1);
	});

	it("signOut 失败：返回 { ok: false, error }，clearStore 仍被调（#018）", async () => {
		const { clearSession } = await import("./auth");
		mutate.mockRejectedValueOnce(new Error("network down"));
		const result = await clearSession();

		expect(result.ok).toBe(false);
		expect(result.error).toBeInstanceOf(Error);
		// 即便 mutation 失败也清本地缓存（换用户不串数据的底线）
		expect(clearStore).toHaveBeenCalledTimes(1);
	});
});
