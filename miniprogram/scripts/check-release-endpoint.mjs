#!/usr/bin/env node
/**
 * 上传前 endpoint 自检（plan 013）。
 *
 * 为什么不进 check:ci：CI 本就故意用 `config/index.ts` 的开发回落值
 * （`http://localhost:4001/api/graphql`）构建（无后端、不上传），硬拒会让 check:ci
 * 永远红。真正的风险窗口是「本地/worktree 构建后上传」——某次在没有 `.env.prod` 的
 * worktree 里构建，产物会把 localhost 回落值打进去，上传后所有请求失败。
 *
 * 本脚本与 check-xhs-share-pairing.mjs 同属「上传前」检查：都只看构建产物（dist/），
 * 不看 node_modules / 源码，因为产物才是实际上传到 IDE / 提审的东西。
 *
 * 只做存在性 fail-closed 检查，不读取也不打印 .env* 文件内容。
 */

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(fileURLToPath(new URL(".", import.meta.url)), "..");

const env = process.argv[2];
if (env !== "weapp" && env !== "xhs") {
  console.error("用法：node scripts/check-release-endpoint.mjs <weapp|xhs>");
  process.exit(2);
}

const DIST = join(ROOT, "dist", env);

function listJsFiles(dir) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    const st = statSync(full);
    if (st.isDirectory()) out.push(...listJsFiles(full));
    else if (name.endsWith(".js")) out.push(full);
  }
  return out;
}

let files;
try {
  files = listJsFiles(DIST);
} catch {
  console.error(`✗ dist/${env} 不存在，先构建`);
  process.exit(1);
}

// graphqlEndpoint 恒以 JSON.stringify(url) 的字面量形式落进产物，url 恒带协议
// （config/index.ts：`process.env.CGC_GRAPHQL_ENDPOINT ?? 'http://localhost:4001/api/graphql'`）。
const ENDPOINT_RE = /(https?):\/\/([^"'\\]+?)\/api\/graphql/;

let hit = null;
for (const file of files) {
  const content = readFileSync(file, "utf8");
  const match = ENDPOINT_RE.exec(content);
  if (match) {
    hit = match;
    break;
  }
}

if (!hit) {
  console.error(
    `✗ dist/${env} 里找不到 .../api/graphql 字面量——可能被拆分/编码，脚本抓不到实际形态，需人工复核`,
  );
  process.exit(1);
}

const [full, protocol, host] = hit;
const isDevFallback = protocol !== "https" || /localhost|127\.0\.0\.1/.test(host);

if (isDevFallback) {
  console.error(
    `✗ dist/${env} 的 GraphQL endpoint 指向 ${full}——这是开发回落值，不能上传。检查构建所在 checkout 是否有 .env.prod（只查存在，不要打印内容）`,
  );
  process.exit(1);
}

console.log(`✓ dist/${env} endpoint 为 https（${host}）`);
