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
/**
 * §2 白名单：只有列在这里的许可证（或它们的 OR 组合）可以直接引入。
 * §6 明确：未列出的许可证（WTFPL、CC-BY-SA、EPL-1.0、GPL-3.0-only…）先开 issue，不能直接引入。
 * 与黑名单（§3/§5 的 CI 兜底）并存：新引入的依赖按白名单判，fail-closed。
 */
export const ALLOWED = new Set(
	[
		"MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "0BSD", "CC0-1.0", "Unlicense",
		"BlueOak-1.0.0", "MIT-0", "Python-2.0", "Zlib",
		"MPL-2.0", "LGPL-3.0-only", "LGPL-3.0-or-later", "EPL-2.0",
		"CC-BY-3.0", "CC-BY-4.0",
	].map((id) => id.toLowerCase()),
);

const canonical = (token) => token.trim().replace(/^\+/, "").toLowerCase();

/** SPDX 表达式的白名单判定：OR 任一分支放行即可；AND 必须全部放行；括号分组；未列出/UNKNOWN 一律不放行 */
export function licenseAllows(license) {
	if (!license) return false;
	if (typeof license === "string") return expressionAllows(license);
	if (Array.isArray(license)) return license.some((item) => licenseAllows(item)); // 多个声明 = 任选
	if (typeof license === "object" && typeof license.type === "string") return licenseAllows(license.type);
	return false;
}

function expressionAllows(expression) {
	const tokens = expression
		.replace(/\(/g, " ( ")
		.replace(/\)/g, " ) ")
		.split(/\s+/)
		.filter(Boolean);
	let at = 0;
	const peek = () => tokens[at];
	const take = () => tokens[at++];

	// or := and (OR and)*        and := atom (AND atom)*        atom := IDENT | "(" or ")"
	function parseOr() {
		let value = parseAnd();
		while (peek()?.toUpperCase() === "OR") {
			take();
			value = parseAnd() || value;
		}
		return value;
	}
	function parseAnd() {
		let value = parseAtom();
		while (peek()?.toUpperCase() === "AND") {
			take();
			value = parseAtom() && value;
		}
		while (peek() === "/") {
			take();
			value = parseAtom() || value; // §2 的「多选声明」用 / 分隔
		}
		return value;
	}
	function parseAtom() {
		const token = take();
		if (token === "(") {
			const value = parseOr();
			if (peek() === ")") take();
			return value;
		}
		if (!token) return false;
		if (token.toUpperCase() === "WITH") return false; // 例外条款未在白名单内：fail-closed
		return ALLOWED.has(canonical(token));
	}

	const allowed = parseOr();
	return at >= tokens.length ? allowed : false; // 没解析完 = 表达式形态不认识，不放行
}

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

