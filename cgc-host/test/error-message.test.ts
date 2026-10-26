import { describe, expect, test } from "bun:test";
import * as acp from "@agentclientprotocol/sdk";
import { message, redact } from "../src/acp/errors";

describe("日志脱敏（凭证不原样进日志）", () => {
	test("学习凭证与 Bearer 头只在日志里留前缀", () => {
		const fakeToken = "cgch_live-token-abcdefgh";
		const error = Object.assign(new Error(`load failed for ${fakeToken}`), {
			data: { headers: [{ name: "authorization", value: `Bearer ${fakeToken}` }] },
		});
		const logged = message(error);
		expect(logged).not.toContain(fakeToken);
		expect(logged).toContain("cgch_***");
		expect(logged).not.toContain("Bearer cgch_");
		expect(redact("terminal cgc_terminal-token-123456")).toBe("terminal cgc_***");
	});

	test("普通错误文本不受影响", () => {
		expect(message(new Error("Internal error"))).toBe("Internal error");
	});
});

describe("错误摘要（Host 日志）", () => {
	test("ACP 错误带 data：message 后附上 data 详情（如 load 失败的真实原因）", () => {
		const e = acp.RequestError.internalError({ details: "Could not restore model magpie/mirasim/deepseek-flash" });
		expect(message(e)).toBe('Internal error {"details":"Could not restore model magpie/mirasim/deepseek-flash"}');
	});

	test("没有 data：只有 message", () => {
		expect(message(new Error("boom"))).toBe("boom");
		expect(message(acp.RequestError.internalError())).toBe("Internal error");
	});

	test("超长 data 截断到 500 字符以内，以省略号收尾", () => {
		const out = message(acp.RequestError.internalError({ details: "x".repeat(900) }));
		expect(out.length).toBeLessThanOrEqual("Internal error ".length + 501);
		expect(out.endsWith("…")).toBe(true);
	});
});
