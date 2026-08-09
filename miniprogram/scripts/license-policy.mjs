/**
 * 许可证政策求值器（纯函数，供 CLI 与单元测试共享）。
 *
 * 规则来源：docs/开源合规/依赖引入规则.md §2 白名单（2026-08-09，含 human 裁定 Zlib）。
 * fail-closed：解析失败、UNLICENSED、SEE LICENSE IN、空值、未列出 ID 一律拒绝。
 * SPDX 语义：OR 任一完整分支允许即可；AND 同一分支全部允许；WITH exception 与
 * LicenseRef-* 只有持续规则明确列出才允许（当前未列 → 拒绝）。
 */

import parse from "spdx-expression-parse";

// §2 白名单（宽松 + 弱 copyleft），逐项对应规则表当前书面结论。
export const ALLOWED_LICENSES = new Set([
  "MIT",
  "Apache-2.0",
  "BSD-2-Clause",
  "BSD-3-Clause",
  "ISC",
  "0BSD",
  "CC0-1.0",
  "Unlicense",
  "BlueOak-1.0.0",
  "MIT-0",
  "Python-2.0",
  "Zlib",
  "MPL-2.0",
  "LGPL-3.0-only",
  "LGPL-3.0-or-later",
  "EPL-2.0",
]);

// CC-BY 数据许可只允许窄名单数据包（规则表 §2 数据/内容类）；新包名 fail-closed。
// spdx-exceptions 于 2026-08-09 由 orchestrator 按现有规则裁定加入（SPDX 标准数据包，
// license 例外列表，无代码；CC-BY-3.0 属 CC-BY 系）。
export const DATA_PACKAGE_NAMES = new Set(["caniuse-lite", "spdx-exceptions"]);
const CC_BY_RE = /^CC-BY-\d+(\.\d+)*$/;

// 缺 license 字段的已知包 → 实际许可证（包内 LICENSE + npm registry 查证，2026-08-09）。
// 精确到 name@version；版本对不上时视为 UNKNOWN。
export const KNOWN_NO_FIELD = new Map([
  ["exif-parser@0.1.12", "MIT"],
  ["dom-walk@0.1.2", "MIT"],
  ["qrcode-terminal@0.12.0", "Apache-2.0"],
  ["string.fromcodepoint@0.2.1", "MIT"],
]);

export function knownNoFieldLicense(name, version) {
  return KNOWN_NO_FIELD.get(`${name}@${version}`) ?? null;
}

function isAllowedLicense(id, name) {
  if (ALLOWED_LICENSES.has(id)) return true;
  if (DATA_PACKAGE_NAMES.has(name) && CC_BY_RE.test(id)) return true;
  return false;
}

function evaluateAst(node, name) {
  if (node.conjunction === "or") {
    return evaluateAst(node.left, name).allowed || evaluateAst(node.right, name).allowed
      ? { allowed: true, reason: "approved" }
      : { allowed: false, reason: "unapproved" };
  }
  if (node.conjunction === "and") {
    return evaluateAst(node.left, name).allowed && evaluateAst(node.right, name).allowed
      ? { allowed: true, reason: "approved" }
      : { allowed: false, reason: "unapproved" };
  }
  // license leaf
  if (node.exception || node.plus) return { allowed: false, reason: "unapproved" };
  if (isAllowedLicense(node.license, name)) return { allowed: true, reason: "approved" };
  return { allowed: false, reason: "unapproved" };
}

function evaluateString(str, name) {
  if (str === "") return { allowed: false, reason: "UNKNOWN" };
  if (str === "UNLICENSED" || str === "NOASSERTION") return { allowed: false, reason: "UNKNOWN" };
  if (str.startsWith("SEE LICENSE IN")) return { allowed: false, reason: "UNKNOWN" };
  let ast;
  try {
    ast = parse(str);
  } catch {
    return { allowed: false, reason: "INVALID" };
  }
  return evaluateAst(ast, name);
}

/**
 * 求值单包许可证声明。context 至少含 { name, version }；返回 { allowed, reason }，
 * 不直接退出进程。
 */
export function evaluateLicenseDeclaration(raw, context) {
  const name = context.name ?? "";
  const version = context.version ?? "";
  if (raw === null || raw === undefined || raw === "") {
    const known = knownNoFieldLicense(name, version);
    if (known) return evaluateString(known, name);
    return { allowed: false, reason: "UNKNOWN" };
  }
  if (typeof raw === "string") return evaluateString(raw.trim(), name);
  if (typeof raw === "object" && typeof raw.type === "string") {
    return evaluateString(raw.type.trim(), name);
  }
  if (Array.isArray(raw)) {
    if (raw.length === 0) return { allowed: false, reason: "UNKNOWN" };
    for (const item of raw) {
      if (evaluateLicenseDeclaration(item, { name, version }).allowed) {
        return { allowed: true, reason: "approved" };
      }
    }
    return { allowed: false, reason: "unapproved" };
  }
  return { allowed: false, reason: "UNKNOWN" };
}
