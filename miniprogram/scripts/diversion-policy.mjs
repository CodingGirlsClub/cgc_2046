/**
 * 零导流扫描策略（纯函数 + 目录扫描，供 CLI 与单元测试共享）。
 *
 * 解码规则：只用显式 regex 转换 \uXXXX、\u{...}、\xNN，最多两轮以覆盖
 * 双重转义；绝不 eval / Function / JSON 包裹整文件，也不执行产物内容。
 * fail-closed：目录缺失、无合格文本产物、读取失败都返回结构化 error。
 */

import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

export const BANNED_TERMS = ["微信", "WeChat", "OpenClacky", "加我", "二维码", "口令"];

export const TEXT_EXTENSIONS = [
  ".js",
  ".sjs",
  ".json",
  ".ttml",
  ".ttss",
  ".xhsml",
  ".css",
  ".txt",
];

const DECODE_ROUNDS = 2;

export function decodeTextEscapes(raw) {
  let text = String(raw);
  for (let round = 0; round < DECODE_ROUNDS; round++) {
    // 每轮先折叠一层反斜杠转义（\\ -> \），再解码 \uXXXX/\u{...}/\xNN；
    // 两轮恰好覆盖双重转义，且不 eval / Function / 执行产物内容。
    const next = text
      .replace(/\\\\/g, "\\")
      .replace(/\\u\{([0-9a-fA-F]+)\}/g, (_, hex) => String.fromCodePoint(parseInt(hex, 16)))
      .replace(/\\u([0-9a-fA-F]{4})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)))
      .replace(/\\x([0-9a-fA-F]{2})/g, (_, hex) => String.fromCharCode(parseInt(hex, 16)));
    if (next === text) break;
    text = next;
  }
  return text;
}

export function scanArtifactTree(dir) {
  const result = { filesScanned: 0, skippedNonText: 0, hits: [], error: null };
  const seen = new Set();
  let top;
  try {
    top = readdirSync(dir, { withFileTypes: true });
  } catch {
    result.error = `目录缺失或不可读：${dir}`;
    return result;
  }
  const queue = top.map((e) => ({ rel: e.name, isDir: e.isDirectory(), isFile: e.isFile() }));
  try {
    while (queue.length > 0) {
      const { rel, isDir, isFile } = queue.pop();
      const full = join(dir, rel);
      if (isDir) {
        for (const child of readdirSync(full, { withFileTypes: true })) {
          queue.push({ rel: join(rel, child.name), isDir: child.isDirectory(), isFile: child.isFile() });
        }
        continue;
      }
      if (!isFile) continue;
      const dot = rel.lastIndexOf(".");
      const ext = dot >= 0 ? rel.slice(dot).toLowerCase() : "";
      if (!TEXT_EXTENSIONS.includes(ext)) continue;
      const buf = readFileSync(full);
      if (buf.includes(0)) {
        result.skippedNonText += 1;
        continue;
      }
      result.filesScanned += 1;
      const decoded = decodeTextEscapes(buf.toString("utf8"));
      for (const term of BANNED_TERMS) {
        if (decoded.includes(term)) {
          const key = `${rel}\u0000${term}`;
          if (!seen.has(key)) {
            seen.add(key);
            result.hits.push({ file: rel, term });
          }
        }
      }
    }
  } catch (err) {
    result.error = `读取产物失败：${err.message}`;
    return result;
  }
  if (result.filesScanned === 0) {
    result.error = "没有可扫描的文本产物";
  }
  return result;
}
