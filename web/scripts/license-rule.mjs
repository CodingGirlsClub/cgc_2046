/**
 * license-rule.mjs — 依赖许可判定的共享规则（AGPL-3.0 兼容性）。
 * 规则来源：docs/开源合规/依赖引入规则.md §2（白名单）/ §3（黑名单兜底）/ §6（未列出 → 先开 issue）。
 * 被一处使用：
 * - web/scripts/check-licenses.mjs：pnpm 全树的基础扫描（规则 §5 的黑名单兜底）
 * 数据类 CC-BY 的窄名单与 miniprogram/scripts/license-policy.mjs 保持一致。
 */

// §3 黑名单（§5 的 CI 兜底用）
export const BLACKLIST = [
	"gpl-2-0",
	"sspl",
	"busl",
	"elastic",
	"proprietary",
	"commercial",
];

// §2 白名单（宽松 + 弱 copyleft）；逐项对应规则表。
export const ALLOWED = new Set(
	[
		"MIT", "Apache-2.0", "BSD-2-Clause", "BSD-3-Clause", "ISC", "0BSD", "CC0-1.0", "Unlicense",
		"BlueOak-1.0.0", "MIT-0", "Python-2.0", "Zlib",
		"MPL-2.0", "LGPL-3.0-only", "LGPL-3.0-or-later", "EPL-2.0",
	].map((id) => id.toLowerCase()),
);

/** §2 数据/内容类：CC-BY 只对这些包名放行（与 miniprogram 的 DATA_PACKAGE_NAMES 同步） */
export const DATA_PACKAGE_NAMES = new Set(["caniuse-lite", "spdx-exceptions"]);
const CC_BY_RE = /^cc-by-\d+(\.\d+)*$/;

export function normalize(license) {
	return license.toLowerCase().replace(/[^a-z0-9]/g, "-");
}

export function isBlacklisted(candidate) {
	const norm = normalize(candidate);
	return BLACKLIST.some((bad) => norm.includes(bad));
}

/**
 * 按 §2 白名单判定（fail-closed）：
 * - SPDX：OR 任一完整分支放行、AND 同一分支全部放行、括号分组；
 * - `/` 是规则里的「多选」写法（任选其一），`MIT/Apache-2.0` 这种无空格写法同样按多选处理；
 * - `WITH` 例外、未列出 ID、UNKNOWN、畸形表达式一律拒绝；
 * - CC-BY 只对 `options.packageName` 在数据包窄名单内时放行（§2「仅用于数据」）。
 */
export function licenseAllows(license, options = {}) {
	if (typeof license === "string") return expressionAllows(license, options);
	if (Array.isArray(license)) return license.some((item) => licenseAllows(item, options));
	if (license && typeof license === "object" && typeof license.type === "string") return licenseAllows(license.type, options);
	return false;
}

function expressionAllows(expression, options) {
	const tokens = expression
		.replace(/\(/g, " ( ")
		.replace(/\)/g, " ) ")
		.split(/\s+/)
		.filter(Boolean)
		// 规则 §2 的「多选声明」：单独的 `/` 与 OR 同义（无空格写法如 MIT/Apache-2.0 在 parseAtom 里处理）
		.map((token) => (token === "/" ? "OR" : token));
	if (tokens.length === 0) return false;
	const state = { at: 0, tokens, options };
	try {
		const value = parseOr(state);
		return value && state.at === state.tokens.length; // 没解析完 = 形态不认识，fail-closed
	} catch {
		return false;
	}
}

function parseOr(state) {
	let value = parseAnd(state);
	while (state.tokens[state.at]?.toUpperCase() === "OR") {
		state.at += 1;
		value = parseAnd(state) || value;
	}
	return value;
}

function parseAnd(state) {
	let value = parseAtom(state);
	while (state.tokens[state.at]?.toUpperCase() === "AND") {
		state.at += 1;
		value = parseAtom(state) && value;
	}
	return value;
}

function parseAtom(state) {
	const token = state.tokens[state.at];
	if (token === undefined) throw new Error("表达式缺操作数");
	if (token === "(") {
		state.at += 1;
		const value = parseOr(state);
		if (state.tokens[state.at] !== ")") throw new Error("括号不配对");
		state.at += 1;
		return value;
	}
	if (token === ")" || /^(AND|OR|WITH)$/i.test(token)) throw new Error(`表达式畸形：${token}`);
	state.at += 1;
	// 规则 §2 的「多选声明」：任意一项放行即可
	return token.split("/").some((part) => allowedId(part.trim(), state.options));
}

function allowedId(id, options) {
	if (!id) return false;
	if (id.endsWith("+")) return false; // SPDX 的 `+`（或更高版本）不在白名单表里
	const lower = id.toLowerCase();
	if (CC_BY_RE.test(lower)) return DATA_PACKAGE_NAMES.has(options.packageName);
	return ALLOWED.has(lower);
}

/**
 * 黑名单口径的候选拆分（供 pnpm 全树扫描使用）：字符串 / SPDX 的 OR / `/` 多选 / {type} / 数组。
 * 返回 null 表示没有声明。
 */
export function candidatesOf(license) {
	if (!license) return null;
	if (typeof license === "string") {
		const stripped = license.trim().replace(/^\(+/, "").replace(/\)+$/, "");
		return stripped
			.split(/\s+OR\s+/i)
			.flatMap((part) => part.split("/"))
			.map((part) => part.trim())
			.filter(Boolean);
	}
	if (typeof license === "object" && typeof license.type === "string") return [license.type];
	if (Array.isArray(license)) {
		const flat = license.flatMap((item) => candidatesOf(item) ?? []);
		return flat.length ? flat : null;
	}
	return null;
}
