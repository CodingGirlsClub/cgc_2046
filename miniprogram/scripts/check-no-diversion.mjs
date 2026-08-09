#!/usr/bin/env node
/**
 * 零导流合规检查（§2 合规红线）：抖音/小红书裁剪端产物不得含跨端引导字样。
 *
 * 对 dist/tt、dist/xhs 各调用一次 scanArtifactTree；任一目录缺失、无文本产物、
 * 读取失败或有 hit 都整体 exit 1。规则与解码策略见 diversion-policy.mjs。
 * 前置：先执行 `pnpm build:tt` / `pnpm build:xhs` 再跑本脚本。
 */

import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { scanArtifactTree } from "./diversion-policy.mjs";

const ROOT = join(fileURLToPath(new URL(".", import.meta.url)), "..");

let failed = false;
for (const env of ["tt", "xhs"]) {
  const { filesScanned, hits, error } = scanArtifactTree(join(ROOT, "dist", env));
  if (error) {
    failed = true;
    console.error(`✗ dist/${env} ${error}`);
    continue;
  }
  if (hits.length === 0) {
    console.log(`✓ dist/${env} 零导流检查通过（${filesScanned} 个文本文件）`);
  } else {
    failed = true;
    console.error(`✗ dist/${env} 命中跨端引导字样：`);
    for (const { file, term } of hits) console.error(`  dist/${env}/${file}: ${term}`);
  }
}
process.exit(failed ? 1 : 0);
