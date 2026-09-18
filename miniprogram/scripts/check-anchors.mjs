#!/usr/bin/env node
/**
 * E2E 锚点静态自检（CI 门）：构建后逐锚验证 dist 产物里可解析且哈希唯一。
 *
 * 目的：样式类改名/删除/重构导致锚点腐坏时 CI 当场红，不用等本地 GUI e2e 才发现
 * （journey.e2e.mjs 不进 CI——需要开发者工具 GUI 与人工授权）。
 * 锚点表与解析器和 journey 共用 e2e/anchors.mjs（单源）。
 *
 * 诚实边界：本脚本只验「锚点可唯一定位」，盖不住渲染树多匹配（tap 锚点错）与
 * 交互链——那部分仍靠 pnpm e2e。
 */
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { resolveAnchorSelectors } from "../e2e/anchors.mjs";

const miniprogramRoot = join(fileURLToPath(new URL(".", import.meta.url)), "..");
const distRoot = join(miniprogramRoot, "dist", "weapp");

try {
	resolveAnchorSelectors(distRoot);
} catch (error) {
	console.error(`✗ ${error.message}`);
	process.exit(1);
}

console.log("✓ E2E 锚点全部可唯一定位（dist/weapp 产物校验通过）");
