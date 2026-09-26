// @vitest-environment node
import { spawnSync } from "node:child_process";
import { copyFileSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

describe("check-licenses", () => {
	// 临时根里放一份脚本，node_modules/.pnpm 仿 pnpm 全局 virtual store 的布局：
	// 只有 lock.yaml 与空的 node_modules，一个包都扫不到
	it("fails closed (exit 2) instead of reporting all-compatible when no package is scanned", () => {
		const root = mkdtempSync(join(tmpdir(), "license-scan-"));
		try {
			mkdirSync(join(root, "scripts"));
			copyFileSync(new URL("./check-licenses.mjs", import.meta.url), join(root, "scripts/check-licenses.mjs"));
			mkdirSync(join(root, "node_modules/.pnpm/node_modules"), { recursive: true });
			writeFileSync(join(root, "node_modules/.pnpm/lock.yaml"), "");

			const r = spawnSync(process.execPath, [join(root, "scripts/check-licenses.mjs")], { encoding: "utf8" });
			expect(r.status, r.stdout + r.stderr).toBe(2);
		} finally {
			rmSync(root, { recursive: true, force: true });
		}
	});
});
