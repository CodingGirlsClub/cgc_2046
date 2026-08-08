import { describe, it, expect, vi, afterEach } from "vitest";
import { copyText } from "./clipboard";

describe("copyText", () => {
	afterEach(() => {
		vi.unstubAllGlobals();
		vi.restoreAllMocks();
	});

	it("成功写入返回 true", async () => {
		const writeText = vi.fn().mockResolvedValue(undefined);
		Object.defineProperty(navigator, "clipboard", {
			value: { writeText },
			configurable: true,
		});
		await expect(copyText("hello")).resolves.toBe(true);
		expect(writeText).toHaveBeenCalledWith("hello");
	});

	it("权限拒绝（rejected promise）返回 false 而不抛出", async () => {
		Object.defineProperty(navigator, "clipboard", {
			value: { writeText: vi.fn().mockRejectedValue(new Error("denied")) },
			configurable: true,
		});
		await expect(copyText("hello")).resolves.toBe(false);
	});

	it("clipboard API 不存在（非安全上下文）返回 false", async () => {
		Object.defineProperty(navigator, "clipboard", {
			value: undefined,
			configurable: true,
		});
		await expect(copyText("hello")).resolves.toBe(false);
	});
});
