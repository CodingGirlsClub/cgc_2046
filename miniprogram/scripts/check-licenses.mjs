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

const MINIPROGRAM_ROOT = join(fileURLToPath(new URL(".", import.meta.url)), "..");
const PNPM_DIR = join(MINIPROGRAM_ROOT, "node_modules", ".pnpm");

// Blacklist (rule file §3). Substring match after normalization (same as backend).
const BLACKLIST = [
	"gpl-2-0",
	"sspl",
	"busl",
	"elastic",
	"proprietary",
	"commercial",
];

// 无 license 字段的已知包 → 实际许可证（包内 LICENSE 文件 + npm registry 查证，2026-08-09）。
// 对齐后端 mix cgc2046.check_licenses 的 @known_no_field 惯例。全部为构建/工具链传递依赖。
const KNOWN_NO_FIELD = {
	"exif-parser": "MIT",
	"dom-walk": "MIT",
	"qrcode-terminal": "Apache-2.0",
	"string.fromcodepoint": "MIT",
};

function normalize(license) {
	return license.toLowerCase().replace(/[^a-z0-9]/g, "-");
}

function isBlacklisted(candidate) {
	const norm = normalize(candidate);
	return BLACKLIST.some((bad) => norm.includes(bad));
}

/**
 * Normalize a package.json `license` field into a list of candidate
 * licenses. Handles: string, SPDX "A OR B" expressions（含外层括号分组）,
 * {type,url} objects. Returns null when no license is declared.
 */
function candidatesOf(license) {
	if (!license) return null;
	if (typeof license === "string") {
		// 剥离 SPDX 分组括号，如 "(BSD-3-Clause OR GPL-2.0)" → ["BSD-3-Clause", "GPL-2.0"]
		const stripped = license.trim().replace(/^\(+/, "").replace(/\)+$/, "");
		return stripped
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

			// 无 license 字段的已知包回退内置映射表（对齐后端 @known_no_field 惯例）
			const candidates =
				candidatesOf(pkg.license) ??
				(pkg.name && KNOWN_NO_FIELD[pkg.name] ? [KNOWN_NO_FIELD[pkg.name]] : null);
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
