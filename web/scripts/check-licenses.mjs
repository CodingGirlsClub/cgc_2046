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
 */

import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const WEB_ROOT = join(fileURLToPath(new URL(".", import.meta.url)), "..");
const PNPM_DIR = join(WEB_ROOT, "node_modules", ".pnpm");

// Blacklist (rule file §3). Substring match after normalization (same as backend).
const BLACKLIST = [
	"gpl-2-0",
	"sspl",
	"busl",
	"elastic",
	"proprietary",
	"commercial",
];

function normalize(license) {
	return license.toLowerCase().replace(/[^a-z0-9]/g, "-");
}

function isBlacklisted(candidate) {
	const norm = normalize(candidate);
	return BLACKLIST.some((bad) => norm.includes(bad));
}

/**
 * Normalize a package.json `license` field into a list of candidate
 * licenses. Handles: string, SPDX "A OR B" expressions, {type,url} objects.
 * Returns null when no license is declared.
 */
function candidatesOf(license) {
	if (!license) return null;
	if (typeof license === "string") {
		return license
			.split(/\s+OR\s+/i)
			.map((s) => s.trim())
			.filter(Boolean);
	}
	if (typeof license === "object" && typeof license.type === "string") {
		return [license.type];
	}
	if (Array.isArray(license)) {
		const flat = license.flatMap((l) => candidatesOf(l) ?? []);
		return flat.length ? flat : null;
	}
	return null;
}

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
			if (candidates === null) {
				violations.push({ name: pkg.name ?? entry.name, license: "UNKNOWN" });
				continue;
			}

			const hit = candidates.filter(isBlacklisted);
			if (hit.length > 0) {
				violations.push({
					name: pkg.name ?? entry.name,
					license: hit.join(" / "),
				});
			}
		}
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
