#!/usr/bin/env node
/**
 * License compliance check for npm dependencies (AGPL-3.0 compatibility).
 *
 * Rule source: docs/开源合规/依赖引入规则.md
 * CI-enforced counterpart of `mix cgc2046.check_licenses` (backend).
 *
 * Scans every package under node_modules/.pnpm (full dependency tree,
 * including transitive deps). Blacklist hits or missing license fields
 * print a report and exit non-zero.
 *
 * Usage: node check-licenses.mjs [package-root]
 * package-root defaults to web/; pass another pnpm package root to scan it.
 */

import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const PACKAGE_ROOT = process.argv[2]
	? resolve(process.argv[2])
	: join(fileURLToPath(new URL(".", import.meta.url)), "..");
const PNPM_DIR = join(PACKAGE_ROOT, "node_modules", ".pnpm");

import { candidatesOf, isBlacklisted } from "./license-rule.mjs";

function scan() {
	if (!existsSync(PNPM_DIR)) {
		console.error("✗ node_modules/.pnpm not found — run `pnpm install` first.");
		process.exit(2);
	}

	const violations = [];
	let total = 0;

	for (const dir of readdirSync(PNPM_DIR)) {
		const scopeBase = join(PNPM_DIR, dir, "node_modules");
		if (!existsSync(scopeBase)) continue;

		const entries = readdirSync(scopeBase, { withFileTypes: true });
		// pnpm 的 .pnpm 布局里 peer 副本以 symlink 形态存在，必须一并统计
		const isPkgDir = (e) => e.isDirectory() || e.isSymbolicLink();
		const pkgDirs = [
			...entries.filter((e) => isPkgDir(e) && !e.name.startsWith("@")),
			...entries
				.filter((e) => isPkgDir(e) && e.name.startsWith("@"))
				.flatMap((e) =>
					readdirSync(join(scopeBase, e.name))
						.filter((n) => !n.startsWith("."))
						.map((n) => ({ dir: true, name: `${e.name}/${n}` })),
				),
		];

		for (const entry of pkgDirs) {
			const pkgPath = join(scopeBase, entry.name, "package.json");
			if (!existsSync(pkgPath)) continue;
			total++;

			let pkg;
			try {
				pkg = JSON.parse(readFileSync(pkgPath, "utf8"));
			} catch {
				continue;
			}

			const candidates = candidatesOf(pkg.license);
			if (candidates === null || candidates.length === 0) {
				violations.push({ name: pkg.name ?? entry.name, license: "UNKNOWN" });
				continue;
			}

			// SPDX OR / 多许可语义：存在任一允许项即放行（AGENTS.md：multi-license
			// declarations 至少一个允许选项即可；仅 GPL-2.0-only 等才违规）
			if (candidates.every(isBlacklisted)) {
				violations.push({
					name: pkg.name ?? entry.name,
					license: candidates.join(" / "),
				});
			}
		}
	}

	// 空集 fail-closed：布局认不出来时（如 pnpm 全局 virtual store，包不在 .pnpm 里）一个包都没查，不能判通过
	if (total === 0) {
		console.error("✗ Scanned 0 packages in node_modules/.pnpm — unrecognized layout (pnpm global virtual store?), nothing verified. Reinstall: rm -rf node_modules && pnpm install --frozen-lockfile --config.enable-global-virtual-store=false");
		process.exit(2);
	}

	if (violations.length === 0) {
		console.log(`✓ All ${total} packages license-compatible with AGPL-3.0`);
		process.exit(0);
	}

	console.error("✗ License violations (see docs/开源合规/依赖引入规则.md):");
	for (const { name, license } of violations) {
		console.error(`  ${name}: ${license}`);
	}
	console.error(`  (${violations.length} of ${total} packages)`);
	process.exit(1);
}

scan();
