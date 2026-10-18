// agents/sources.ts — Codex「来源」的只读探测（期 3 前置，见 #1154 / #1155）。
// 探测本身只读；安装决策（是否走 reuse 变体）与启动决策（CODEX_PATH 注入）在 install.ts / codex.ts 读取结果后做。
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { resolveLoginShellEnv } from "../shell-env";
import { installedVersion, managedCodex } from "./install";

/** 上报给页面的来源种类；数组顺序即推荐优先级 */
export const CODEX_SOURCES = ["managed", "codex-acp", "chatgpt-app", "codex-cli"] as const;
export type CodexSource = (typeof CODEX_SOURCES)[number];

export interface CodexSourceHit {
  source: CodexSource;
  /** Host 本机路径：只用于 Host 内部与测试，上报给页面时不含它 */
  path: string;
  version: string | null;
}

export interface DetectCodexSourcesOptions {
  /** 默认 process.platform；测试注入 */
  platform?: NodeJS.Platform;
  /** ChatGPT 桌面 App 内置 engine 的候选入口（测试注入；缺省按平台与 home 推导） */
  appCandidates?: readonly string[];
}

/**
 * ChatGPT 桌面 App 内置 Codex 的候选入口。
 * macOS 已验证（App 内置 codex-cli，见 #1154 评论）；Windows / Linux 的内置路径尚未逐平台验证，先返回空。
 */
export function chatgptAppCandidates(home: string, platform: NodeJS.Platform = process.platform): string[] {
  if (platform !== "darwin") return [];
  return [
    "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
    join(home, "Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"),
  ];
}

/** App 内置 CLI 的版本：入口上两级的 `codex-cli/codex-package.json`（实测 App 自带该文件） */
function chatgptAppVersion(entry: string): string | null {
  try {
    const parsed: unknown = JSON.parse(readFileSync(join(entry, "..", "..", "codex-package.json"), "utf8"));
    const version = (parsed as { version?: unknown }).version;
    return typeof version === "string" ? version : null;
  } catch {
    return null;
  }
}

/** 同一入口可能同时出现在 App 候选与 PATH 里：按真实路径去重，只保留优先级更高的那条 */
function realOrSelf(path: string): string {
  try {
    return realpathSync(path);
  } catch {
    return path;
  }
}

/** 探测本机可用的 Codex 来源，按优先级去重。只读、同步、不启动任何进程。 */
export function detectCodexSources(
  home: string,
  envPath: string | undefined,
  options: DetectCodexSourcesOptions = {},
): CodexSourceHit[] {
  const hits: CodexSourceHit[] = [];
  const seen = new Set<string>();
  const add = (hit: CodexSourceHit) => {
    const key = realOrSelf(hit.path);
    if (seen.has(key)) return;
    seen.add(key);
    hits.push(hit);
  };

  const managed = managedCodex(home);
  if (managed) add({ source: "managed", path: managed, version: installedVersion(home) });

  const acp = Bun.which("codex-acp", { PATH: envPath ?? "" });
  if (acp) add({ source: "codex-acp", path: acp, version: null });

  // App 内置路径只在 macOS 探测（Windows/Linux 待逐平台验证，见 #1155）；测试注入的候选同样受平台约束
  const platform = options.platform ?? process.platform;
  const appCandidates = platform === "darwin" ? (options.appCandidates ?? chatgptAppCandidates(home, platform)) : [];
  for (const entry of appCandidates) {
    if (existsSync(entry)) add({ source: "chatgpt-app", path: entry, version: chatgptAppVersion(entry) });
  }

  const cli = Bun.which("codex", { PATH: envPath ?? "" });
  if (cli) add({ source: "codex-cli", path: cli, version: null });

  return hits;
}

/** 复用安装时优先选哪条：App 内置 engine 优先于 PATH 上的 codex（App 与学员登录/配置共享得最完整） */
export function reuseEnginePath(hits: readonly CodexSourceHit[]): string | null {
  return hits.find((hit) => hit.source === "chatgpt-app")?.path ?? hits.find((hit) => hit.source === "codex-cli")?.path ?? null;
}

/**
 * 安装前解析可复用的 engine（登录 shell 的 PATH，与 Host 启动 agent 用同一份环境）。
 * 只用于「要不要走 reuse 变体」；真正启动时 codex.ts 会重新探测，engine 消失就让 present=false。
 */
export async function findReuseCodexEngine(
  home: string,
): Promise<{ path: string; source: CodexSource; env: Record<string, string> } | null> {
  const { env } = await resolveLoginShellEnv();
  const hits = detectCodexSources(home, env.PATH);
  const hit = hits.find((entry) => entry.source === "chatgpt-app") ?? hits.find((entry) => entry.source === "codex-cli");
  return hit ? { path: hit.path, source: hit.source, env } : null;
}
