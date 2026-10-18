// agents/install.ts — 把缺的 agent 装进 Host 自己管的目录（期 2：页面里点一下，不用终端、不用 npm/node）。
// 两套安装变体，同一套落位与原子替换流程：
// - full（默认）：`codex-acp.package.json` + `codex-acp.lock`，含 `@openai/codex` 本体（约 337MB 落盘）；
// - reuse（#1154）：`codex-acp-reuse.package.json` + `codex-acp-reuse.lock`，用本地 stub 顶掉 `@openai/codex`，
//   只装适配器（约 18MB 落盘 / 2MB 下载）；装完用 ACP `initialize` 探针确认学员已有的 Codex engine
//   （ChatGPT App 内置 / PATH 上的 codex）兼容，探针失败自动回退 full。
// 依据是随 Host 包发布的锁：版本与整棵依赖树的 sha512 都在锁里，用 Host 自己的 Bun 跑
// `bun install --frozen-lockfile --production`——锁对不上或下载内容不符即中止。
// 安装在 `~/.cgc2046/agents/.tmp-*` 里做完再 rename 就位：失败只会删掉那个临时目录，已有的安装与课程作业不受影响。
// 上次被 SIGKILL 留下的 `.tmp-*` / `.old-*` 在**下一次安装开头**清理（不在启动时扫，Host 平时不碰这个目录）。
import { existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import codexLock from "./codex-acp.lock" with { type: "text" };
import codexReusePackage from "./codex-acp-reuse.package.json" with { type: "text" };
import codexReuseLock from "./codex-acp-reuse.lock" with { type: "text" };

/** 钉住的适配器版本：与两份锁、两份 package.json 同源，改一处必须同时重算（scripts/gen-agent-lock.mjs） */
export const CODEX_ACP_VERSION = "2.2.2";
/** `~/.cgc2046/agents/<这个目录>` */
export const CODEX_AGENT_DIR = "codex-acp";
export const AGENTS_DIR = "agents";
/** 冷缓存下实测约 350MB、一分钟上下；给足余量，超时就当失败并清理临时目录 */
export const INSTALL_TIMEOUT_MS = 15 * 60_000;

export type InstallErrorCode = "install_failed" | "version_mismatch" | "timeout";
export type InstallVariant = "full" | "reuse";

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

/** 复用变体的 package.json / 锁：与 `codex-acp-reuse.*` 同源（gen 脚本生成），内容必须逐字节写回临时目录 */
export const CODEX_ACP_REUSE_PACKAGE_JSON = codexReusePackage;
export const CODEX_ACP_REUSE_LOCK = codexReuseLock;
/** Host 在临时目录写出的 stub；与生成锁时使用的 stub 内容一致 */
export const REUSE_STUB_PACKAGE_JSON = JSON.stringify({ name: "@openai/codex", version: "0.0.0-stub" });
/** 记录本次安装用的变体；旧安装没有这个文件时按 full 处理 */
export const VARIANT_FILE = "variant.json";

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
  /** 可复用的 Codex engine（ChatGPT App 内置 / PATH codex）：给了就先试 reuse，失败回退 full */
  reuseEngine?: string;
  /** 解析出的登录 shell 环境：探针要和实际启动用同一份 PATH，否则 npm 安装的 codex 在 launchd 下会误判不兼容 */
  reuseEnv?: Record<string, string>;
  /** 测试注入：reuse 变体的 ACP initialize 探针；缺省 probeCodexAcp */
  probe?(entry: string, codexPath: string): Promise<boolean>;
}

export interface InstalledAgent {
  version: string;
  variant: InstallVariant;
}

let inflight: Promise<InstalledAgent> | null = null;

/** 探针要和实际启动用同一份环境：登录 shell 解析出的 PATH 常是 npm 安装的 codex 唯一能找到 node 的地方 */
function runProbe(opts: InstallOptions, entry: string, engine: string): Promise<boolean> {
  return opts.probe ? opts.probe(entry, engine) : probeCodexAcp(entry, engine, undefined, opts.reuseEnv);
}

/** 安装 Codex 适配器；正在装时再调一次拿同一个结果（single-flight），装完返回版本与变体 */
export function installCodexAcp(opts: InstallOptions): Promise<InstalledAgent> {
  // 幂等短路：已经装着钉住的版本就不再下载（重复点击、两个标签页、恶意页面都只能触发一次）。
  // reuse 变体例外：engine 可能被卸载、替换或升级，必须先用安装好的适配器重新探针；
  // 探针失败就继续走安装（reuse 再试一次，仍失败回退 full），不能只凭 reuseEngine 存在就回报成功。
  const managedVariant = installVariant(opts.home);
  const managed = managedCodex(opts.home);
  const reuseManaged = managed !== null && managedVariant === "reuse";
  // full 变体可以安全短路；reuse 变体一律往下走：有 engine 先探针，没 engine 直接重装 full
  if (managed && !reuseManaged) return Promise.resolve({ version: CODEX_ACP_VERSION, variant: managedVariant ?? "full" });
  return (inflight ??= (async () => {
    if (managed && reuseManaged && opts.reuseEngine) {
      let compatible = false;
      try {
        compatible = await runProbe(opts, managed, opts.reuseEngine);
      } catch {
        compatible = false; // 探针本身失败也按不兼容处理，走重装
      }
      if (compatible) return { version: CODEX_ACP_VERSION, variant: "reuse" as const };
    }
    if (opts.reuseEngine) {
      try {
        return await runInstall(opts, "reuse", opts.reuseEngine);
      } catch (e) {
        // 探针/复用安装失败：静默回退 full；安装输出含本地路径，日志只记原因码
        console.error(`cgc-host: 复用安装未通过（${e instanceof InstallError ? e.code : "install_failed"}），回退全量安装`);
      }
    }
    return runInstall(opts, "full");
  })().finally(() => {
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

/** 某个 agent 目录里的适配器入口（从包 manifest 的 bin 解析；不拼 node_modules/.bin） */
function entryIn(agentDir: string): string | null {
  try {
    const parsed: CodexPackageJson = JSON.parse(readFileSync(join(agentDir, "node_modules", "@agentclientprotocol", "codex-acp", "package.json"), "utf8"));
    const bin = parsed.bin;
    const relative = typeof bin === "string" ? bin : bin && typeof bin === "object" ? (bin as Record<string, unknown>)["codex-acp"] : undefined;
    if (typeof relative !== "string") return null;
    const entry = resolve(join(agentDir, "node_modules", "@agentclientprotocol", "codex-acp"), relative);
    return existsSync(entry) ? entry : null;
  } catch {
    return null;
  }
}

/**
 * 托管安装的入口文件。从包 manifest 的 `bin["codex-acp"]` 解析，而不是拼 `node_modules/.bin/codex-acp`：
 * Windows 上 Bun 生成的是 `codex-acp.exe` / `codex-acp.bunx`，没有无扩展名文件；`codexCommand` 会把 JS 入口交给 Bun 跑。
 */
export function managedCodexEntry(home: string): string | null {
  return entryIn(codexAgentDir(home));
}

/**
 * 可用的托管安装：版本必须与 Host 钉住的一致。Host 升级 `CODEX_ACP_VERSION` 后，旧副本自动让位（页面重新给出安装入口），
 * 否则存量学员永远停在旧适配器上。
 */
export function managedCodex(home: string): string | null {
  return installedVersion(home) === CODEX_ACP_VERSION ? managedCodexEntry(home) : null;
}

/** 已装副本的变体；没装返回 null。旧安装没有 variant.json，按 full 处理（它一定带 Codex 本体）。 */
export function installVariant(home: string): InstallVariant | null {
  if (!managedCodexEntry(home)) return null;
  try {
    const parsed = JSON.parse(readFileSync(join(codexAgentDir(home), VARIANT_FILE), "utf8")) as { variant?: unknown };
    return parsed.variant === "reuse" ? "reuse" : "full";
  } catch {
    return "full";
  }
}

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

async function readUntilId(stream: ReadableStream<Uint8Array>, id: number): Promise<boolean> {
  const reader = stream.getReader();
  const decoder = new TextDecoder();
  let buffer = "";
  for (;;) {
    const chunk = await reader.read();
    if (chunk.done) return false;
    buffer += decoder.decode(chunk.value, { stream: true });
    let newline: number;
    while ((newline = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, newline);
      buffer = buffer.slice(newline + 1);
      try {
        // 只认成功的 result：适配器对 initialize 回 error（如旧 engine 不兼容）时不能当探针通过
        const message = JSON.parse(line) as { id?: unknown; result?: unknown; error?: unknown };
        if (message.id === id) return message.error === undefined && message.result !== undefined;
      } catch {
        // 非 JSON 行（适配器日志之类）忽略
      }
    }
  }
}

/**
 * 复用变体的兼容性探针：用刚装好的适配器 + 学员已有的 engine 做一次 ACP `initialize`。
 * 只握手、不建会话、不发 prompt（不消耗模型额度）；失败由调用方回退 full。
 */
export async function probeCodexAcp(
  entry: string,
  codexPath: string,
  timeoutMs = 10_000,
  extraEnv?: Record<string, string>,
): Promise<boolean> {
  const proc = Bun.spawn([process.execPath, entry], {
    // 与实际启动同一份环境（登录 shell 的 PATH），再覆盖 CODEX_PATH；否则 launchd 下会误判 CLI 不兼容
    env: { ...process.env, ...extraEnv, CODEX_PATH: codexPath },
    stdin: "pipe",
    stdout: "pipe",
    stderr: "ignore",
  });
  try {
    const initialize = {
      jsonrpc: "2.0",
      id: 1,
      method: "initialize",
      params: {
        protocolVersion: 1,
        clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } },
        clientInfo: { name: "cgc-host", version: "probe" },
      },
    };
    proc.stdin.write(`${JSON.stringify(initialize)}\n`);
    await proc.stdin.flush();
    return await Promise.race([readUntilId(proc.stdout, 1), sleep(timeoutMs).then(() => false)]);
  } finally {
    try {
      proc.stdin.end(); // 关 stdin 让适配器把它拉起的 Codex 一起收掉（KTD9）
    } catch {
      // 进程可能已经退出
    }
    await Promise.race([proc.exited.then(() => true), sleep(3_000).then(() => false)]);
    try {
      proc.kill("SIGKILL");
    } catch {
      // 已退出
    }
  }
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

async function runInstall(opts: InstallOptions, variant: InstallVariant, reuseEngine?: string): Promise<InstalledAgent> {
  const root = agentsDir(opts.home);
  mkdirSync(root, { recursive: true });
  sweepStale(root); // 上次被杀掉留下的 .tmp-* / .old-*：不属于任何一次成功安装
  const tmp = mkdtempSync(join(root, ".tmp-"));
  try {
    writeFileSync(join(tmp, "package.json"), variant === "reuse" ? CODEX_ACP_REUSE_PACKAGE_JSON : CODEX_ACP_PACKAGE_JSON);
    writeFileSync(join(tmp, "bun.lock"), variant === "reuse" ? CODEX_ACP_REUSE_LOCK : codexLock);
    if (variant === "reuse") {
      mkdirSync(join(tmp, "stub"), { recursive: true });
      writeFileSync(join(tmp, "stub", "package.json"), REUSE_STUB_PACKAGE_JSON);
    }
    writeFileSync(join(tmp, VARIANT_FILE), JSON.stringify({ variant }));
    opts.onPhase?.("installing");
    const timeoutMs = opts.timeoutMs ?? INSTALL_TIMEOUT_MS;
    const code = opts.run ? await withTimeout(opts.run(tmp), timeoutMs) : await bunInstall(tmp, timeoutMs);
    if (code !== 0) throw new InstallError("install_failed", `bun install 退出码 ${code}`);
    const version = versionIn(tmp);
    if (version !== CODEX_ACP_VERSION) throw new InstallError("version_mismatch", `装上的是 ${version ?? "未知版本"}`);
    if (variant === "reuse") {
      const entry = entryIn(tmp);
      if (!entry) throw new InstallError("install_failed", "复用安装缺少适配器入口");
      if (!(await runProbe(opts, entry, reuseEngine ?? ""))) throw new InstallError("install_failed", "复用探针未通过");
    }
    swap(tmp, codexAgentDir(opts.home), root);
    return { version, variant };
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
