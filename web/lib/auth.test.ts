import { describe, it, expect, vi } from "vitest";

const { mutate, clearStore } = vi.hoisted(() => ({
	mutate: vi.fn().mockResolvedValue({ data: { signOut: "signed_out" } }),
	clearStore: vi.fn().mockResolvedValue(undefined),
}));

vi.mock("./apollo-client", () => ({
	client: { mutate, clearStore },
}));

describe("auth 登录态工具 (#61)", () => {
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
});
