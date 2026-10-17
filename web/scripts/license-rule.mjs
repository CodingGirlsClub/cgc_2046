/**
 * license-rule.mjs — 依赖许可判定的唯一实现（AGPL-3.0 兼容性）。
 * 规则来源：docs/开源合规/依赖引入规则.md §3。被两个扫描共用：
 * - web/scripts/check-licenses.mjs：扫 pnpm 的 node_modules/.pnpm（Host 自己的依赖）
 * - cgc-host/scripts/check-agent-lock.mjs：扫页面一键安装的锁里每个包（含各平台二进制包）
 */

// Blacklist (rule file §3). Substring match after normalization (same as backend).
export const BLACKLIST = [
	"gpl-2-0",
	"sspl",
	"busl",
	"elastic",
	"proprietary",
	"commercial",
];

export function normalize(license) {
	return license.toLowerCase().replace(/[^a-z0-9]/g, "-");
}

export function isBlacklisted(candidate) {
	const norm = normalize(candidate);
	return BLACKLIST.some((bad) => norm.includes(bad));
}

/**
 * Normalize a package.json `license` field into a list of candidate
 * licenses. Handles: string, SPDX "A OR B" expressions（含外层括号分组）,
 * {type,url} objects. Returns null when no license is declared.
 */
export function candidatesOf(license) {
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

