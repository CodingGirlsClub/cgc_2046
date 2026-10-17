// agent-lock.test.ts — 锁解析的覆盖度：多空格、多行数组、尾逗号都不能让条目被静默漏查
import { describe, expect, test } from "bun:test";
import { parseBunLock } from "../scripts/lib/bun-lock.mjs";

describe("parseBunLock", () => {
	test("按 packages 的键取 spec 与 integrity：单空格、多空格、多行数组都覆盖", () => {
		const lock = `{
  "lockfileVersion": 2,
  "packages": {
    "a": ["a@1.0.0", "", {}, "sha512-x"],
    "b":  ["b@2.0.0", "", {}, "sha512-y"],
    "c": [
      "c@3.0.0",
      "",
      {},
      "sha512-z"
    ]
  }
}`;
		expect(parseBunLock(lock)).toEqual({
			keys: ["a", "b", "c"],
			specs: ["a@1.0.0", "b@2.0.0", "c@3.0.0"],
			integrities: ["sha512-x", "sha512-y", "sha512-z"],
		});
	});

	test("尾逗号（JSONC）照常解析", () => {
		const lock = `{"packages": {"a": ["a@1.0.0", "", {}, "sha512-x"],},}`;
		expect(parseBunLock(lock).specs).toEqual(["a@1.0.0"]);
	});

	test("条目畸形或缺少 packages 时抛错（fail-closed，不静默少查）", () => {
		expect(() => parseBunLock(`{"packages": {"a": "oops"}}`)).toThrow();
		expect(parseBunLock(`{"packages": {}}`).specs).toEqual([]);
		expect(() => parseBunLock(`{"packages": {"a": []}}`)).toThrow();
		expect(() => parseBunLock(`{"packages": null}`)).toThrow();
		expect(() => parseBunLock(`not json`)).toThrow();
	});

	test("缺少 sha512 的条目标记为 null（门禁据此报错，而不是当它已校验）", () => {
		expect(parseBunLock(`{"packages": {"a": ["a@1.0.0", "", {}]}}`).integrities).toEqual([null]);
	});

	test("随包发布的真实锁：30 个条目、全部带 sha512、六个平台包齐全", async () => {
		const text = await Bun.file(new URL("../src/agents/codex-acp.lock", import.meta.url)).text();
		const { keys, specs, integrities } = parseBunLock(text);
		expect(keys).toHaveLength(30);
		expect(integrities.every((integrity) => typeof integrity === "string" && integrity.startsWith("sha512-"))).toBe(true);
		for (const platform of ["darwin-arm64", "darwin-x64", "linux-arm64", "linux-x64", "win32-arm64", "win32-x64"]) {
			expect(keys, platform).toContain(`@openai/codex-${platform}`);
			expect(specs.some((spec) => spec.endsWith(`-${platform}`)), platform).toBe(true);
		}
	});
});
