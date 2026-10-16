import { describe, expect, test } from "bun:test";
import * as acp from "@agentclientprotocol/sdk";
import { message } from "../src/acp/session";

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
