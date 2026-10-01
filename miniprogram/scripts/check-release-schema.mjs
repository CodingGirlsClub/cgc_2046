#!/usr/bin/env node
/**
 * 上传前 schema 兼容门（#786，ADR-0020）：用线上实际部署的后端 schema 校验小程序
 * `src/api/operations.ts` 的全部 operation，不兼容就拒绝上传。
 *
 * 为什么需要：GraphQL 先校验后执行，一个未知字段就让整条 document 被拒（「新小程序 +
 * 旧后端」时整页挂）；小程序过审在 deploy 流水线之外，只能在上传前挡住——对标 web 的
 * `needs: backend`。后端 deploy 失败时 kamal-proxy 不切流，/healthz 报的仍是旧 SHA，
 * 校验自然失败。
 *
 * 用法：
 *   node scripts/check-release-schema.mjs            # 默认：读线上 /healthz 的 x-cgc-version
 *   node scripts/check-release-schema.mjs --ref <sha> # 跳过 healthz，直接用指定 SHA
 *                                                    # （回滚后端前用目标 SHA 预检）
 *
 * fail-closed：请求失败、缺头、SHA 解析失败、git 失败、任一校验错误 → exit 1。
 * backend 带 x-cgc-version 头的版本上线前，线上没有这个头，默认模式会 fail-closed，属预期。
 *
 * 为什么不进 check:ci：它依赖线上网络状态，同 check-release-endpoint.mjs 的理由——
 * 只属于「上传前」，CI 里跑会让无关 PR 因线上状态变红。
 */

import { execFileSync } from "node:child_process";
import { join } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import { findIncompatibleOperations, parseDeployedSha } from "./release-schema.mjs";

const ROOT = join(fileURLToPath(new URL(".", import.meta.url)), "..");
const HEALTHZ_URL = "https://api.codingirlsclub.com/healthz";
const SCHEMA_PATH = "backend/priv/graphql/schema.graphql";

function fail(message) {
  console.error(`✗ ${message}`);
  process.exit(1);
}

function parseArgs(argv) {
  const i = argv.indexOf("--ref");
  if (i === -1) return { ref: null };
  const ref = argv[i + 1];
  if (!ref || ref.startsWith("-")) fail("用法：check-release-schema.mjs [--ref <sha>]（--ref 缺少值）");
  return { ref };
}

function git(...args) {
  return execFileSync("git", args, { cwd: ROOT, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"] });
}

async function deployedSha() {
  let response;
  try {
    response = await fetch(HEALTHZ_URL, { signal: AbortSignal.timeout(10_000) });
  } catch (error) {
    fail(`请求 ${HEALTHZ_URL} 失败：${error.message}`);
  }
  if (!response.ok) fail(`${HEALTHZ_URL} 返回 ${response.status}`);
  const header = response.headers.get("x-cgc-version");
  if (!header) {
    fail(`${HEALTHZ_URL} 响应缺少 x-cgc-version 头（后端尚未部署带该头的版本？）`);
  }
  try {
    return parseDeployedSha(header);
  } catch (error) {
    fail(error.message);
  }
}

function schemaAt(ref) {
  try {
    git("cat-file", "-e", `${ref}^{commit}`);
  } catch {
    try {
      git("fetch", "origin", ref);
    } catch (error) {
      fail(`本地没有 ${ref} 且 git fetch origin ${ref} 失败：${error.stderr || error.message}`);
    }
  }
  try {
    return git("show", `${ref}:${SCHEMA_PATH}`);
  } catch (error) {
    fail(`git show ${ref}:${SCHEMA_PATH} 失败：${error.stderr || error.message}`);
  }
}

const { ref: refArg } = parseArgs(process.argv.slice(2));
const ref = refArg ?? (await deployedSha());
console.log(`校验基线：${refArg ? "--ref " : "线上部署 "}${ref}`);

const sdl = schemaAt(ref);

// operations.ts 零 import，Node 原生剥离类型即可直接加载；
// 它会触发 MODULE_TYPELESS_PACKAGE_JSON 警告（package.json 无 type 字段，改了会波及 Taro 构建），一次性 CLI 里直接静音。
process.removeAllListeners("warning");
const operations = Object.fromEntries(
  Object.entries(await import(pathToFileURL(join(ROOT, "src/api/operations.ts")))).filter(
    ([, value]) => typeof value === "string",
  ),
);
const total = Object.keys(operations).length;
if (total === 0) fail("src/api/operations.ts 没有任何字符串 export——脚本抓不到 operation，需人工复核");

let incompatible;
try {
  incompatible = findIncompatibleOperations(sdl, operations);
} catch (error) {
  fail(`${ref} 的 schema 无法解析：${error.message}`);
}

if (incompatible.length > 0) {
  for (const { name, errors } of incompatible) {
    console.error(`✗ ${name}`);
    for (const message of errors) console.error(`    ${message}`);
  }
  fail(`${incompatible.length}/${total} 个 operation 与 ${ref} 的后端 schema 不兼容，不能上传（先部署后端，或回退小程序改动）`);
}

console.log(`✓ ${total} 个 operation 全部兼容 ${ref} 的后端 schema`);
