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
// 与仓里提交的 codex-acp.package.json 同格式（紧凑），避免重算时产生无关格式 diff
writeFileSync(join(dir, "package.json"), JSON.stringify({ name: "cgc-codex-agent", private: true, dependencies: { "@agentclientprotocol/codex-acp": version } }));
const proc = Bun.spawnSync([process.execPath, "install", "--lockfile-only", "--save-text-lockfile"], { cwd: dir, stdout: "inherit", stderr: "inherit" });
if (proc.exitCode !== 0) process.exit(proc.exitCode ?? 1);

copyFileSync(join(dir, "bun.lock"), "src/agents/codex-acp.lock");
copyFileSync(join(dir, "package.json"), "src/agents/codex-acp.package.json");

// 同版本重跑是幂等的：只重算锁，不动常量（之前用「replace 后是否变化」判断，会把同版本重跑误报成找不到常量）
const CONSTANT = /export const CODEX_ACP_VERSION = "([^"]+)";/;
const src = readFileSync("src/agents/install.ts", "utf8");
const match = src.match(CONSTANT);
if (!match) {
  console.error("没找到 CODEX_ACP_VERSION，请手工核对 install.ts");
  process.exit(1);
}
if (match[1] !== version) writeFileSync("src/agents/install.ts", src.replace(CONSTANT, `export const CODEX_ACP_VERSION = "${version}";`));
console.log(match[1] === version ? `锁已重算；install.ts 的常量已是 ${version}（未改动）` : `已生成 codex-acp ${version} 的锁，并更新 install.ts 的常量`);
