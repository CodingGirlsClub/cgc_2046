#!/usr/bin/env node
/**
 * License compliance check for npm dependencies (AGPL-3.0 compatibility).
 *
 * Rule source: docs/开源合规/依赖引入规则.md (human-maintained allowlist)
 * CI-enforced counterpart of `mix cgc2046.check_licenses` (backend).
 *
 * Scans every package under node_modules/.pnpm (full dependency tree,
 * including transitive deps) and evaluates each declaration through
 * license-policy.mjs. Any UNKNOWN / INVALID / unapproved license prints
 * a sorted report and exits non-zero.
 */

import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { evaluateLicenseDeclaration } from "./license-policy.mjs";

const MINIPROGRAM_ROOT = join(fileURLToPath(new URL(".", import.meta.url)), "..");
const PNPM_DIR = join(MINIPROGRAM_ROOT, "node_modules", ".pnpm");

function describeLicense(license) {
	if (license === null || license === undefined) return "UNKNOWN";
	if (typeof license === "string") return license;
	if (Array.isArray(license)) return license.map(describeLicense).join(" / ");
	if (typeof license === "object") return String(license.type ?? "UNKNOWN");
	return "UNKNOWN";
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
				violations.push({ name: entry.name, license: "INVALID_JSON", reason: "INVALID" });
				continue;
			}

			const name = pkg.name ?? entry.name;
			const version = pkg.version ?? "";
			const { allowed, reason } = evaluateLicenseDeclaration(pkg.license, { name, version });
			if (!allowed) {
				violations.push({
					name: `${name}@${version}`,
					license: describeLicense(pkg.license),
					reason,
				});
			}
		}
	}

	violations.sort((a, b) => a.name.localeCompare(b.name));

	if (violations.length === 0) {
		console.log(`✓ All ${total} packages license-compatible with AGPL-3.0`);
		process.exit(0);
	}

	console.error("✗ License violations (see docs/开源合规/依赖引入规则.md):");
	for (const { name, license, reason } of violations) {
		console.error(`  ${name}: ${license} [${reason}]`);
	}
	console.error(`  (${violations.length} of ${total} packages)`);
	process.exit(1);
}

scan();
