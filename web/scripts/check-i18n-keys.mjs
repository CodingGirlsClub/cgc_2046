#!/usr/bin/env node
/**
 * i18n key 覆盖检查（i18n Phase 1，D4）。
 *
 * 不变量：en 的 key 集合必须与 zh-CN 完全相等（source=zh-CN / pivot=en 分层，
 * L0 决策 3：英文用户不见中文兜底，en 上线门槛 = 100% key 覆盖）。
 * 嵌套 key 展开为点路径后集合比对；en 缺 key 即 fail（exit 1）。
 *
 * 用法：node scripts/check-i18n-keys.mjs（也可 import 调 checkKeysEqual）
 */

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const webRoot = dirname(dirname(fileURLToPath(import.meta.url)));
const MESSAGES_DIR = join(webRoot, "messages");
const SOURCE_LOCALE = "zh-CN";
const PIVOT_LOCALE = "en";

/** 递归展开嵌套对象为点路径 key 集合 */
export function flattenKeys(obj, prefix = "") {
	const keys = [];
	for (const [k, v] of Object.entries(obj)) {
		const path = prefix ? `${prefix}.${k}` : k;
		if (v !== null && typeof v === "object" && !Array.isArray(v)) {
			keys.push(...flattenKeys(v, path));
		} else {
			keys.push(path);
		}
	}
	return keys;
}

/**
 * 比对 source（zh-CN）与 pivot（en）的 key 集合。
 * 返回缺失列表；相等时为空数组。
 */
export function checkKeysEqual(sourceMessages, pivotMessages) {
	const source = new Set(flattenKeys(sourceMessages));
	const pivot = new Set(flattenKeys(pivotMessages));
	return [...source].filter((k) => !pivot.has(k));
}

function loadMessages(locale) {
	return JSON.parse(readFileSync(join(MESSAGES_DIR, `${locale}.json`), "utf8"));
}

function main() {
	const source = loadMessages(SOURCE_LOCALE);
	const pivot = loadMessages(PIVOT_LOCALE);
	const missing = checkKeysEqual(source, pivot);

	if (missing.length > 0) {
		console.error(
			`✗ ${PIVOT_LOCALE}.json is missing ${missing.length} key(s) present in ${SOURCE_LOCALE}.json:`,
		);
		for (const key of missing) console.error(`  - ${key}`);
		process.exit(1);
	}

	const total = flattenKeys(source).length;
	console.log(`✓ ${SOURCE_LOCALE} / ${PIVOT_LOCALE} key sets match (${total} keys)`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
	main();
}
