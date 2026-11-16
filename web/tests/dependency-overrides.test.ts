// @vitest-environment node
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

// 安全收敛的 overrides 必须真的落进锁文件。pnpm 10.28.2（package.json 的
// packageManager 钉的版本，也是 CI 跑的版本）只读 package.json 的
// "pnpm.overrides"，pnpm 11 只读 pnpm-workspace.yaml——放错文件时安装照样
// 成功，override 却静默失效（miniprogram 因此退回 22 条 Dependabot 告警，
// 见 #1288）。锁文件的 overrides 段是 pnpm 实际生效配置的回执，这里拿它
// 对齐 package.json，把「安装成功」与「收敛生效」分开。
const pkg = JSON.parse(readFileSync(new URL("../package.json", import.meta.url), "utf8")) as {
	pnpm?: { overrides?: Record<string, string> };
};
const pnpmWorkspace = readFileSync(new URL("../pnpm-workspace.yaml", import.meta.url), "utf8");
const lock = readFileSync(new URL("../pnpm-lock.yaml", import.meta.url), "utf8");

function lockOverrides(text: string): Map<string, string> {
	const lines = text.split("\n");
	const out = new Map<string, string>();
	const start = lines.indexOf("overrides:");
	if (start === -1) return out;
	for (const line of lines.slice(start + 1)) {
		const match = /^ {2}(.+?): (.+)$/.exec(line);
		if (!match) break; // 后续为下一顶层键或空行
		out.set(match[1].replace(/^'|'$/g, ""), match[2]);
	}
	return out;
}

describe("dependency overrides", () => {
	it("lockfile 记录了 package.json 的全部 overrides", () => {
		const expected = pkg.pnpm?.overrides ?? {};
		expect(Object.keys(expected).length).toBeGreaterThan(0);

		const actual = lockOverrides(lock);
		const missing = Object.keys(expected).filter((key) => !actual.has(key));
		const mismatched = Object.entries(expected)
			.filter(([key, value]) => actual.has(key) && actual.get(key) !== String(value))
			.map(([key, value]) => `${key}: package.json ${value} / 锁文件 ${actual.get(key)}`);

		expect(
			missing,
			"锁文件缺少这些 overrides：当前 pnpm 未读取配置真源，或锁文件未重算",
		).toEqual([]);
		expect(mismatched, "overrides 取值不一致").toEqual([]);
	});

	it("pnpm-workspace.yaml 不再持有 overrides（pnpm 10 忽略它）", () => {
		expect(
			pnpmWorkspace,
			"overrides 出现在 pnpm-workspace.yaml：CI 的 pnpm 10 会静默忽略，统一放 package.json",
		).not.toMatch(/^overrides:/m);
	});
});
