#!/usr/bin/env node
/**
 * 零导流合规检查（§2 合规红线）：抖音/小红书裁剪端产物不得含跨端引导字样。
 *
 * 扫描 dist/tt、dist/xhs 下全部 .js（含 common chunk），对 \uXXXX 转义解码后
 * 查禁词（微信/WeChat/OpenClacky/二维码/口令/加我）。命中任一即 exit 1。
 * 前置：先执行 `pnpm build:tt` / `pnpm build:xhs` 再跑本脚本。
 */

import { readdirSync, readFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(fileURLToPath(new URL(".", import.meta.url)), "..");
const BANNED = ["微信", "WeChat", "OpenClacky", "加我", "二维码", "口令"];

function decode(raw) {
  try {
    return raw.encode("utf-8").decode("unicode_escape");
  } catch {
    return raw;
  }
}

function collectJs(dir, acc = []) {
  if (!existsSync(dir)) return acc;
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) collectJs(path, acc);
    else if (entry.isFile() && entry.name.endsWith(".js")) acc.push(path);
  }
  return acc;
}

function scan(dir) {
  const hits = [];
  for (const file of collectJs(dir)) {
    const decoded = decode(readFileSync(file, "utf8"));
    for (const word of BANNED) {
      if (decoded.includes(word)) hits.push({ file, word });
    }
  }
  return hits;
}

let failed = false;
for (const env of ["tt", "xhs"]) {
  const hits = scan(join(ROOT, "dist", env));
  if (hits.length === 0) {
    console.log(`✓ dist/${env} 零导流检查通过（${collectJs(join(ROOT, "dist", env)).length} js）`);
  } else {
    failed = true;
    console.error(`✗ dist/${env} 命中跨端引导字样：`);
    for (const { file, word } of hits) console.error(`  ${file}: ${word}`);
  }
}
process.exit(failed ? 1 : 0);
