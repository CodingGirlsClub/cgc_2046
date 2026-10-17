// agents/sources.ts — Codex「来源」的只读探测（期 3 前置，见 #1154 / #1155）。
// 只回答「这台机器上已有哪些可复用的 Codex 来源」，不改变安装与启动优先级：
// install/start 仍走 codex.ts 的既有选择（托管安装优先、其次 PATH 上的 codex-acp）。
import { existsSync, readFileSync, realpathSync } from "node:fs";
import { join } from "node:path";
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
