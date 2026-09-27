#!/usr/bin/env node
/**
 * 小红书插件分享钩子配对——产物级守卫（见 patches/@tarojs__plugin-platform-xhs@1.2.2.patch）。
 *
 * 为什么看产物而不是看 node_modules：产物（dist/xhs）才是实际上传到 IDE / 提审的东西；
 * node_modules 里补丁打对了，也可能因为 dist 是旧的构建缓存而没反映出来。
 *
 * @tarojs/plugin-platform-xhs@1.2.2 的 runtime 给每个页面注入 onShareChat，却不配对
 * onShareAppMessage；小红书基础库要求两者成对注册，否则页面 mount 时报 RUNTIME ERROR，
 * 审核被拒、线上全页崩。仓库用 pnpm patch 让 onShareChat 注入时顺带注入
 * onShareAppMessage，但补丁有三条失效路径都拦不住旧检查：
 *   ① node_modules 没重装（补丁停留在 patches/ 里，从未生效）；
 *   ② 插件升级后 patch key（@1.2.2）不再匹配，install 时被跳过；
 *   ③ 上游改了代码结构，补丁 hunk 位置对不上。
 * 本守卫直接扫构建产物，三条路都拦得住。
 *
 * 实测的 minified 形状（`taro build --type xhs` 后 dist/xhs/taro.js，terser 输出）：
 *   未打补丁：indexOf("onShareChat")&&e.push("onShareChat"),-1===e.indexOf("onCopyUrl")&&e.push("onCopyUrl")
 *   打了补丁：indexOf("onShareChat")&&(e.push("onShareChat"),-1===e.indexOf("onShareAppMessage")&&e.push("onShareAppMessage")),-1===e.indexOf("onCopyUrl")&&...
 *
 * 注意："onShareAppMessage" 字符串在页面代码里也大量出现（useShareAppMessage），
 * 只搜这个字符串不能当判据，必须锚定在 onShareChat 注入点附近（到下一个 onCopyUrl 之间）。
 */

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(fileURLToPath(new URL(".", import.meta.url)), "..");
const XHS_DIST = join(ROOT, "dist", "xhs");

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
  files = listJsFiles(XHS_DIST);
} catch {
  console.error("✗ dist/xhs 不存在，先执行 pnpm build:xhs");
  process.exit(1);
}

const SHARE_CHAT_RE = /indexOf\(["']onShareChat["']\)/g;
const COPY_URL_RE = /["']onCopyUrl["']/;
const SHARE_APP_MESSAGE_PUSH_RE = /push\(["']onShareAppMessage["']\)/;

let anchorCount = 0;
let failed = false;

for (const file of files) {
  const content = readFileSync(file, "utf8");
  const rel = file.slice(ROOT.length + 1);
  let match;
  SHARE_CHAT_RE.lastIndex = 0;
  while ((match = SHARE_CHAT_RE.exec(content)) !== null) {
    anchorCount += 1;
    const from = match.index;
    const copyUrlMatch = COPY_URL_RE.exec(content.slice(from));
    const windowEnd = copyUrlMatch ? from + copyUrlMatch.index : from + 300;
    const window = content.slice(from, windowEnd);
    if (!SHARE_APP_MESSAGE_PUSH_RE.test(window)) {
      failed = true;
      console.error(
        `✗ ${rel} 的 onShareChat 注入未配对 onShareAppMessage——插件补丁未生效。先 pnpm install --frozen-lockfile 再构建；见 patches/ 与 pnpm-workspace.yaml`,
      );
    }
  }
}

if (anchorCount === 0) {
  console.error(
    "✗ dist/xhs 全部产物里找不到 indexOf(\"onShareChat\")——插件结构可能已变化，守卫失去锚点，需人工复核",
  );
  process.exit(1);
}

if (failed) process.exit(1);

console.log(`✓ dist/xhs 分享钩子配对检查通过（${anchorCount} 处注入点）`);
