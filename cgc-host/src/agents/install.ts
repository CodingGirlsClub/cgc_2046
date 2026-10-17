// agents/install.ts — 把缺的 agent 装进 Host 自己管的目录（期 2：页面里点一下，不用终端、不用 npm/node）。
// 依据是随 Host 包发布的 `codex-acp.package.json` + `codex-acp.lock`：版本与整棵依赖树的 sha512 都在锁里，
// 用 Host 自己的 Bun 跑 `bun install --frozen-lockfile --production`——锁对不上或下载内容不符即中止。
// 安装在 `~/.cgc2046/agents/.tmp-*` 里做完再 rename 就位：失败只会删掉那个临时目录，已有的安装与课程作业不受影响。
// 上次被 SIGKILL 留下的 `.tmp-*` / `.old-*` 在**下一次安装开头**清理（不在启动时扫，Host 平时不碰这个目录）。
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import codexLock from "./codex-acp.lock" with { type: "text" };

/** 钉住的适配器版本：与 codex-acp.lock / codex-acp.package.json 同源，改一处必须同时重算锁（scripts/gen-agent-lock.mjs） */
export const CODEX_ACP_VERSION = "2.2.2";
/** `~/.cgc2046/agents/<这个目录>` */
export const CODEX_AGENT_DIR = "codex-acp";
export const AGENTS_DIR = "agents";
/** 冷缓存下实测约 350MB、一分钟上下；给足余量，超时就当失败并清理临时目录 */
export const INSTALL_TIMEOUT_MS = 15 * 60_000;

export type InstallErrorCode = "install_failed" | "version_mismatch" | "timeout";

export class InstallError extends Error {
  constructor(
    readonly code: InstallErrorCode,
    message: string,
  ) {
    super(message);
    this.name = "InstallError";
  }
}

/** 安装时落进临时目录的 package.json：只钉一个适配器，其余依赖由锁文件固定 */
export const CODEX_ACP_PACKAGE_JSON = `${JSON.stringify(
  { name: "cgc-codex-agent", private: true, dependencies: { "@agentclientprotocol/codex-acp": CODEX_ACP_VERSION } },
  null,
  2,
)}\n`;

export const stateRoot = (home: string) => join(home, ".cgc2046");
export const agentsDir = (home: string) => join(stateRoot(home), AGENTS_DIR);
export const codexAgentDir = (home: string) => join(agentsDir(home), CODEX_AGENT_DIR);
/** 装好的适配器包目录 */
export const codexPackageDir = (home: string) => join(codexAgentDir(home), "node_modules", "@agentclientprotocol", "codex-acp");

export interface InstallOptions {
  home: string;
  /** 进度回调：目前只有一个阶段（bun install 不提供字节进度），页面据此显示「安装中」 */
  onPhase?(phase: "installing"): void;
  /** 测试注入：在临时目录里执行安装，返回退出码；缺省用 Host 自己的 Bun */
  run?(cwd: string): Promise<number>;
  timeoutMs?: number;
}

export interface InstalledAgent {
  version: string;
}

let inflight: Promise<InstalledAgent> | null = null;

/** 安装 Codex 适配器；正在装时再调一次拿同一个结果（single-flight），装完返回版本 */
export function installCodexAcp(opts: InstallOptions): Promise<InstalledAgent> {
  // 幂等短路：已经装着钉住的版本就不再下载（重复点击、两个标签页、恶意页面都只能触发一次）
  if (managedCodex(opts.home)) return Promise.resolve({ version: CODEX_ACP_VERSION });
  return (inflight ??= runInstall(opts).finally(() => {
    inflight = null;
  }));
}

interface CodexPackageJson {
  version?: unknown;
  bin?: unknown;
}

function readPackageJson(home: string): CodexPackageJson | null {
  try {
    return JSON.parse(readFileSync(join(codexPackageDir(home), "package.json"), "utf8")) as CodexPackageJson;
  } catch {
    return null;
  }
}

/** 已装版本；没装或读不出来返回 null（不抛错：调用方在探测路径上） */
export function installedVersion(home: string): string | null {
  const version = readPackageJson(home)?.version;
  return typeof version === "string" ? version : null;
}

/**
 * 托管安装的入口文件。从包 manifest 的 `bin["codex-acp"]` 解析，而不是拼 `node_modules/.bin/codex-acp`：
 * Windows 上 Bun 生成的是 `codex-acp.exe` / `codex-acp.bunx`，没有无扩展名文件；`codexCommand` 会把 JS 入口交给 Bun 跑。
 */
export function managedCodexEntry(home: string): string | null {
  const pkg = readPackageJson(home);
  const bin = pkg?.bin;
  const relative = typeof bin === "string" ? bin : bin && typeof bin === "object" ? (bin as Record<string, unknown>)["codex-acp"] : undefined;
  if (typeof relative !== "string") return null;
  const entry = resolve(codexPackageDir(home), relative);
  return existsSync(entry) ? entry : null;
}

/**
 * 可用的托管安装：版本必须与 Host 钉住的一致。Host 升级 `CODEX_ACP_VERSION` 后，旧副本自动让位（页面重新给出安装入口），
 * 否则存量学员永远停在旧适配器上。
 */
export function managedCodex(home: string): string | null {
  return installedVersion(home) === CODEX_ACP_VERSION ? managedCodexEntry(home) : null;
}

function withTimeout<T>(work: Promise<T>, timeoutMs: number): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    const timer = setTimeout(() => reject(new InstallError("timeout", `安装超过 ${Math.round(timeoutMs / 60_000)} 分钟`)), timeoutMs);
    work.then(
      (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      (e) => {
        clearTimeout(timer);
        reject(e);
      },
    );
  });
}

async function bunInstall(cwd: string, timeoutMs: number): Promise<number> {
  // --ignore-scripts：第三方依赖的 postinstall 不在学员机器上跑（平台二进制由包本身携带，不需要脚本）
  const proc = Bun.spawn([process.execPath, "install", "--frozen-lockfile", "--production", "--ignore-scripts"], {
    cwd,
    env: process.env,
    stdin: "ignore",
    stdout: "ignore", // 安装输出里有本地路径，不进 Host 日志；失败只用退出码/错误码
    stderr: "ignore",
  });
  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    proc.kill("SIGKILL");
  }, timeoutMs);
  const code = await proc.exited;
  clearTimeout(timer);
  if (timedOut) throw new InstallError("timeout", `安装超过 ${Math.round(timeoutMs / 60_000)} 分钟`);
  return code;
}

async function runInstall(opts: InstallOptions): Promise<InstalledAgent> {
  const root = agentsDir(opts.home);
  mkdirSync(root, { recursive: true });
  sweepStale(root); // 上次被杀掉留下的 .tmp-* / .old-*：不属于任何一次成功安装
  const tmp = mkdtempSync(join(root, ".tmp-"));
  try {
    writeFileSync(join(tmp, "package.json"), CODEX_ACP_PACKAGE_JSON);
    writeFileSync(join(tmp, "bun.lock"), codexLock);
    opts.onPhase?.("installing");
    const timeoutMs = opts.timeoutMs ?? INSTALL_TIMEOUT_MS;
    const code = opts.run ? await withTimeout(opts.run(tmp), timeoutMs) : await bunInstall(tmp, timeoutMs);
    if (code !== 0) throw new InstallError("install_failed", `bun install 退出码 ${code}`);
    const version = versionIn(tmp);
    if (version !== CODEX_ACP_VERSION) throw new InstallError("version_mismatch", `装上的是 ${version ?? "未知版本"}`);
    swap(tmp, codexAgentDir(opts.home), root);
    return { version };
  } catch (e) {
    rmSync(tmp, { recursive: true, force: true });
    throw e;
  }
}

function versionIn(dir: string): string | null {
  try {
    const parsed: unknown = JSON.parse(readFileSync(join(dir, "node_modules", "@agentclientprotocol", "codex-acp", "package.json"), "utf8"));
    const version = (parsed as { version?: unknown }).version;
    return typeof version === "string" ? version : null;
  } catch {
    return null;
  }
}

/** 原子替换：先把旧目录挪开，再把新目录 rename 就位；rename 失败就把旧的挪回去 */
function swap(from: string, target: string, root: string): void {
  const old = existsSync(target) ? join(root, `.old-${Date.now()}`) : null;
  if (old) renameSync(target, old);
  try {
    renameSync(from, target);
  } catch (e) {
    if (old) renameSync(old, target);
    throw e;
  }
  if (old) rmSync(old, { recursive: true, force: true });
}

function sweepStale(root: string): void {
  for (const name of readdirSync(root)) {
    if (name.startsWith(".tmp-") || name.startsWith(".old-")) rmSync(join(root, name), { recursive: true, force: true });
  }
}
