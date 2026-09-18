#!/usr/bin/env node
/**
 * i18n 存量抽取覆盖率检查（i18n Phase 2，D4）。
 *
 * 不变量：web 源码（app/components/lib/i18n）中的中文 UI 字符串必须全部迁入
 * messages/zh-CN.json；除白名单（见下）外不允许残留硬编码中文。
 *
 * 实现：TypeScript AST 遍历（精确区分注释/字符串），对每个含中文的
 * 字符串字面量 / 模板片段 / JSX 文本节点判定白名单：
 *   - 注释（AST 天然排除，注释不是节点）
 *   - 正则字面量（匹配中文输入等）
 *   - console.* 调用的参数（调试输出，非 UI）
 *   - data-testid / testid 属性值（测试钩子）
 *   - URL（http/https 开头的字符串）
 *   - 字符串中仅作子串出现的 CJK 且整体是 URL 或查询参数
 * 非白名单即 fail（exit 1），列出文件:行 与上下文。
 *
 * 用法：node scripts/check-i18n-coverage.mjs [--json]
 * 说明：消息文件 messages/*.json 与测试文件（*.test.*）不在扫描范围。
 */

import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import ts from "typescript";

const webRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const SCAN_DIRS = ["app", "components", "lib", "i18n"];
const CJK = /[\u4e00-\u9fff]/;

// 法务文本以中文为准（plan 2026-08-20-008 设计决策），locale 无关、不迁移 messages；
// 内容同步义务：docs/合规上架/*.md ↔ 页面。
const LEGAL_PAGE_EXEMPT = [
	"app/[locale]/terms/page.tsx",
	"app/[locale]/privacy/page.tsx",
];

/** 收集目录下所有 .ts/.tsx 源码（排除 *.test.*、*.d.ts） */
function collectSourceFiles(dir) {
	const out = [];
	for (const entry of readdirSync(dir)) {
		if (entry === "node_modules" || entry === ".next") continue;
		const full = join(dir, entry);
		const st = statSync(full);
		if (st.isDirectory()) {
			out.push(...collectSourceFiles(full));
		} else if (
			/\.(ts|tsx)$/.test(entry) &&
			!/\.test\./.test(entry) &&
			!/\.d\.ts$/.test(entry)
		) {
			out.push(full);
		}
	}
	return out;
}

/** 从模板表达式提取纯文本部分（含中文的片段） */
function templateTextFragments(node) {
	const parts = [node.head.text];
	for (const span of node.templateSpans) {
		parts.push(span.literal.text);
	}
	return parts.filter((p) => CJK.test(p));
}

/**
 * 判定节点是否命中白名单。
 * 返回 true = 放行（不报告）；false = 残留需报告。
 */
function isWhitelisted(node, parent, file) {
	// 法务页整页豁免（LEGAL_PAGE_EXEMPT，见常量注释）
	if (LEGAL_PAGE_EXEMPT.some((p) => file.includes(p))) return true;
	// console.xxx("...") 参数
	if (
		parent &&
		ts.isCallExpression(parent) &&
		ts.isPropertyAccessExpression(parent.expression) &&
		ts.isIdentifier(parent.expression.expression) &&
		parent.expression.expression.text === "console"
	) {
		return true;
	}
	// data-testid / testid 属性值（JSX 或普通对象均可由字符串字面量充当，仅在 JSX 属性判定）
	if (
		parent &&
		ts.isJsxAttribute(parent) &&
		(ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node))
	) {
		const name = parent.name?.text ?? "";
		if (name === "data-testid" || name === "testid") return true;
	}

	if (ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) {
		const text = node.text;
		// URL：整体为 URL 或以协议开头的串（含中文路径/query 视为合法残留）
		if (/^https?:\/\//.test(text.trim())) return true;
		// 语言选择器的 locale 显示名（语言本地名，永不翻译）
		if (text === "中文" || text === "English") {
			if (parent && ts.isPropertyAssignment(parent)) return true;
		}
		// zh-CN 日期格式模板（lib/format.ts formatJoinedDate：` 年 `/` 月 ` 是本地化格式字符，非 UI 文案）
		if (
			file.includes("lib/format.ts") &&
			(text === " 年 " || text === " 月" || text === "年" || text === "月")
		) {
			return true;
		}
		// 函数签名默认参数兜底（step-handoff-copy buildHandoffText toolHint 默认值；
		// 生产路径调用方总是传 t()，默认值仅供纯函数/测试直调；label 已走 t("copy")）
		if (
			file.includes("components/step-handoff-copy.tsx") &&
			text === "工具提示：用 save_step_output 写回该 step"
		) {
			return true;
		}
	}
	// TemplateExpression：format.ts 的 `${date.getFullYear()} 年 ${date.getMonth() + 1} 月`
	if (ts.isTemplateExpression(node) && file.includes("lib/format.ts")) {
		const frags = templateTextFragments(node).filter(Boolean);
		if (frags.length > 0 && frags.every((f) => f === " 年 " || f === " 月")) return true;
	}
	return false;
}

/**
 * 遍历 AST，返回 [ { file, line, text } ] 残留列表。
 */
function scanFile(file) {
	const source = readFileSync(file, "utf8");
	const sf = ts.createSourceFile(file, source, ts.ScriptTarget.Latest, true);
	const hits = [];
	const report = (node, text) => {
		const { line } = sf.getLineAndCharacterOfPosition(node.getStart());
		hits.push({ file, line: line + 1, text: text.slice(0, 90) });
	};

	const visit = (node) => {
		// 正则字面量：白名单（不报告），但仍遍历内部无子节点
		if (ts.isRegularExpressionLiteral(node)) {
			// 正则可能包含 flags 之后的注释，忽略
			return;
		}
		const parent = node.parent;

		if (
			(ts.isStringLiteral(node) || ts.isNoSubstitutionTemplateLiteral(node)) &&
			CJK.test(node.text)
		) {
			if (!isWhitelisted(node, parent, file)) report(node, node.text);
		} else if (ts.isTemplateExpression(node)) {
			const frags = templateTextFragments(node);
			if (frags.length > 0 && !isWhitelisted(node, parent, file)) {
				report(node, frags.join("…"));
			}
		} else if (ts.isJsxText(node)) {
			const text = node.text.trim();
			if (CJK.test(text) && !isWhitelisted(node, parent, file)) report(node, text);
		}
		ts.forEachChild(node, visit);
	};
	visit(sf);
	return hits;
}

function main() {
	const allHits = [];
	for (const dir of SCAN_DIRS) {
		const abs = join(webRoot, dir);
		if (!statSync(abs, { throwIfNoEntry: false })) continue;
		for (const file of collectSourceFiles(abs)) {
			allHits.push(...scanFile(file));
		}
	}

	if (allHits.length > 0) {
		console.error(
			`✗ ${allHits.length} 处中文残留（白名单外），需迁入 messages/zh-CN.json：`,
		);
		const seen = new Set();
		for (const h of allHits) {
			const rel = relative(webRoot, h.file);
			const key = `${rel}:${h.line}`;
			if (seen.has(key)) continue;
			seen.add(key);
			console.error(`  - ${rel}:${h.line}: ${h.text}`);
		}
		process.exit(1);
	}

	console.log("✓ 源码无白名单外中文残留（check-i18n-coverage）");
}

if (import.meta.url === `file://${process.argv[1]}`) {
	main();
}
