/**
 * 上传门（#786）的纯逻辑：不碰网络 / git / 文件系统，便于 vitest 钉住。
 * CLI 见 check-release-schema.mjs。
 */

import { buildSchema, parse, validate } from "graphql";

// Kamal deploy 传入 `--version ${github.sha}-pb${PLAYBOOK_HASH}`（.github/workflows/deploy.yml），
// 容器里即 KAMAL_VERSION，/healthz 以 `x-cgc-version` 头回传。sha 恒为 40 位小写 hex。
const DEPLOYED_VERSION_RE = /^([0-9a-f]{40})(?:-pb[0-9a-f]+)?$/;

export function parseDeployedSha(header) {
  const match = DEPLOYED_VERSION_RE.exec(header ?? "");
  if (!match) {
    throw new Error(`x-cgc-version 形态无法解析（期望 <40位sha>[-pb<hash>]）：${JSON.stringify(header)}`);
  }
  return match[1];
}

/**
 * 用 sdl 校验每个 operation；返回不兼容的 `[{ name, errors }]`（全兼容 → `[]`）。
 * SDL 非法会直接抛错（buildSchema）——不能把「没法校验」当成「全部通过」。
 * operation 自身语法错误同样算不兼容。
 */
export function findIncompatibleOperations(sdl, operations) {
  const schema = buildSchema(sdl);
  const incompatible = [];
  for (const [name, source] of Object.entries(operations)) {
    let errors;
    try {
      errors = validate(schema, parse(source));
    } catch (error) {
      errors = [error];
    }
    if (errors.length > 0) incompatible.push({ name, errors: errors.map((e) => e.message) });
  }
  return incompatible;
}
