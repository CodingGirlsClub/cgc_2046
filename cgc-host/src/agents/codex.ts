// agents/codex.ts — Codex 这条 agent 记录：学员自己装的 `@agentclientprotocol/codex-acp`（BYO，没人装就不出现）。
// 启动语没有命令行等价物，改写成课程工作目录的 AGENTS.md（KTD5）；关闭走「优雅优先」（KTD9，实测直接 SIGKILL 会留孤儿 Codex 进程）。
import type { ClientApp } from "@agentclientprotocol/sdk";
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { realpath } from "node:fs/promises";
import { join } from "node:path";
import { spawnCodexAcp, STARTUP_PROMPT } from "../acp/client";
import { resolveLoginShellEnv } from "../shell-env";
import { managedCodexAcp } from "./install";
import { agentLocator, type AgentLocation, type AgentRecord, type Locator } from "./registry";

/** PATH 上找的适配器可执行名（npm 包的 bin） */
export const CODEX_ACP_BIN = "codex-acp";

/** 下发给 Codex 的 CGC MCP 服务器名。学员自己的 Codex 配置里可能已有 `cgc-2046`（终端插件那份）：同名会被适配器整条跳过 */
export const CODEX_MCP_SERVER_NAME = "cgc-2046-learning";

/**
 * 找到适配器（KTD12：从登录 shell 解析环境，再在它的 PATH 里找）。
 * 页面里装过（期 2）就先用 Host 托管的那一份；学员自己装在 PATH 上的作为回退。
 */
export async function resolveCodexAcp(home: string, shell?: string, timeoutMs?: number): Promise<AgentLocation> {
  const { env, envError } = await resolveLoginShellEnv(shell, timeoutMs);
  return { path: pickCodexAcp(home, env.PATH), env, envError };
}

/** 选那个要跑的适配器：页面里装过的（Host 托管）优先，其次才是学员自己放在 PATH 上的 */
export function pickCodexAcp(home: string, path: string | undefined): string | null {
  const managed = managedCodexAcp(home);
  if (existsSync(managed)) return managed;
  return Bun.which(CODEX_ACP_BIN, { PATH: path ?? "" }) ?? null;
}

/**
 * 真正要执行的命令。PATH 上的 `codex-acp` 一般是指向 npm 包入口（`dist/index.js`，`#!/usr/bin/env node`）的符号链接：
 * 直接执行它会把学员机器上的 Node 变成隐式依赖。解析到真实文件后，用 Host 自己的 Bun（`process.execPath`）跑这个入口；
 * 若学员自己包了一层非 JS 的启动脚本（Windows 的 .cmd、自写 shell 包一层），则原样执行它——那是他自己安排的环境。
 */
export async function codexCommand(bin: string): Promise<string[]> {
  const entry = await realpath(bin).catch(() => bin);
  return /\.(m|c)?js$/.test(entry) ? [process.execPath, entry] : [bin];
}

/** 缓存最近一次解析；找不到时按 retryMs 在后台重解析——学员装上适配器后不必重启 Host */
export const codexLocator = (home: string, resolve: () => Promise<AgentLocation> = () => resolveCodexAcp(home), retryMs = 10_000): Locator =>
  agentLocator(resolve, retryMs);

/** AGENTS.md 的托管标记：Host 只覆盖这个标记之后的部分，标记之前的文字是学员自己的，原样保留 */
export const AGENTS_MD_MARKER = "<!-- 由 CGC 本机 Host 维护：这一段会随 Host 更新被覆盖 -->";

/**
 * 学习模式启动语写进课程工作目录的 AGENTS.md（KTD5）：Codex 每次会话都读它，session/load 之后也还在。
 * 幂等：内容没变就不写（不动 mtime）；学员自己在同一个文件里写的内容留在标记之前。
 */
export function writeLearningAgentsMd(cwd: string, prompt = STARTUP_PROMPT): void {
  const file = join(cwd, "AGENTS.md");
  let existing: string | null = null;
  try {
    existing = readFileSync(file, "utf8");
  } catch {
    existing = null; // 还没有这个文件
  }
  const markerAt = existing?.indexOf(AGENTS_MD_MARKER) ?? -1;
  const learnerPart = (markerAt < 0 ? (existing ?? "") : existing!.slice(0, markerAt)).trimEnd();
  const content = `${learnerPart ? `${learnerPart}\n\n` : ""}${AGENTS_MD_MARKER}\n\n${prompt}\n`;
  if (existing === content) return;
  mkdirSync(cwd, { recursive: true });
  writeFileSync(file, content);
}

/** Codex 这条记录；`cwd` 是进程的工作目录（工作区根，与 OMP 同一处） */
export function codexRecord(locator: Locator, cwd: string): AgentRecord {
  return {
    kind: "codex",
    mcpServerName: CODEX_MCP_SERVER_NAME,
    locator,
    prepare: async (courseDir) => writeLearningAgentsMd(courseDir),
    async start(app: ClientApp, signal: AbortSignal) {
      const found = await locator.locate();
      signal.throwIfAborted();
      if (!found.path) throw new Error(`PATH 上没有 ${CODEX_ACP_BIN}`);
      mkdirSync(cwd, { recursive: true });
      return spawnCodexAcp(await codexCommand(found.path), found.env, app, cwd, signal);
    },
  };
}
