#!/usr/bin/env bun
// gen-agent-lock.mjs — 重新生成页面一键安装用的锁（期 2）。
// 用法：bun scripts/gen-agent-lock.mjs <适配器版本>
// 产出 src/agents/codex-acp.package.json + codex-acp.lock，并把 install.ts 的 CODEX_ACP_VERSION 改成同一个版本。
// 锁是 Bun 的 text lock：每个包（含 @openai/codex 的当前平台包）都带 sha512，运行期用
// `bun install --frozen-lockfile` 安装不接受任何偏离。换版本 = 重跑本脚本 + 提 PR（随 Host 发版）。
import { copyFileSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const version = process.argv[2];
if (!version || !/^\d+\.\d+\.\d+$/.test(version)) {
  console.error("用法：bun scripts/gen-agent-lock.mjs <版本，如 2.2.2>");
  process.exit(2);
}

const dir = mkdtempSync(join(tmpdir(), "cgc-agent-lock-"));
writeFileSync(join(dir, "package.json"), `${JSON.stringify({ name: "cgc-codex-agent", private: true, dependencies: { "@agentclientprotocol/codex-acp": version } }, null, 2)}\n`);
const proc = Bun.spawnSync([process.execPath, "install", "--lockfile-only", "--save-text-lockfile"], { cwd: dir, stdout: "inherit", stderr: "inherit" });
if (proc.exitCode !== 0) process.exit(proc.exitCode ?? 1);

copyFileSync(join(dir, "bun.lock"), "src/agents/codex-acp.lock");
copyFileSync(join(dir, "package.json"), "src/agents/codex-acp.package.json");

const src = readFileSync("src/agents/install.ts", "utf8");
const next = src.replace(/export const CODEX_ACP_VERSION = "[^"]+";/, `export const CODEX_ACP_VERSION = "${version}";`);
if (next === src) {
  console.error("没找到 CODEX_ACP_VERSION，请手工核对 install.ts");
  process.exit(1);
}
writeFileSync("src/agents/install.ts", next);
console.log(`已生成 codex-acp ${version} 的锁，并更新 install.ts 的常量`);
