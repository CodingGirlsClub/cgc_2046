// shell-env.ts — 登录 shell 环境解析（KTD12）：launchd 不加载登录 shell 的环境，而模型凭证常写在 ~/.zshrc 里，
// 所以从学员的登录 shell 解析进程环境，再在它的 PATH 里找 agent 的入口。解析出的环境只留在内存里，不写进 plist，也不进日志。
import { randomUUID } from "node:crypto";
import { userInfo } from "node:os";

export type EnvError = "timeout" | "failed";

export interface LoginShellEnv {
  env: Record<string, string>;
  /** 登录 shell 解析失败的原因；失败时退回 Host 自己的（launchd 给的最小）环境 */
  envError: EnvError | null;
}

const ENV_TIMEOUT_MS = 10_000;

/**
 * 与 VS Code 解析 shell 环境同法：起一个交互式登录 shell，在两个随机标记之间打印 `env -0`，
 * 只取标记之间的部分，避开 rc 文件启动时的输出噪音。超时就杀掉 shell，退回最小环境。
 */
export async function resolveLoginShellEnv(shell = userInfo().shell || "/bin/zsh", timeoutMs = ENV_TIMEOUT_MS): Promise<LoginShellEnv> {
  // Windows 没有「登录 shell」的等价物：自启项（Startup 快捷方式）已在完整用户环境里拉起 Host，
  // 进程环境就是学员的 PATH；在这里解析 shell 只会白等一个注定失败的进程。
  if (process.platform === "win32") {
    return { env: process.env as Record<string, string>, envError: null };
  }
  const mark = randomUUID();
  let env: Record<string, string> | null = null;
  let envError: EnvError | null = null;
  try {
    const proc = Bun.spawn([shell, "-i", "-l", "-c", `command printf '%s' ${mark}; command /usr/bin/env -0; command printf '%s' ${mark}`], {
      stdin: "ignore",
      stdout: "pipe",
      stderr: "ignore",
    });
    let timer: Timer | undefined;
    // 读 stdout 也要限时：rc 文件留在后台的进程可能一直占着管道
    const out = await Promise.race([
      new Response(proc.stdout).text(),
      new Promise<null>((resolve) => {
        timer = setTimeout(() => {
          proc.kill();
          resolve(null);
        }, timeoutMs);
      }),
    ]);
    clearTimeout(timer);
    const start = out === null ? -1 : out.indexOf(mark);
    const end = out === null ? -1 : out.lastIndexOf(mark);
    if (out === null) envError = "timeout";
    else if (start < 0 || end <= start) envError = "failed";
    else {
      env = {};
      for (const pair of out.slice(start + mark.length, end).split("\0")) {
        const eq = pair.indexOf("=");
        if (eq > 0) env[pair.slice(0, eq)] = pair.slice(eq + 1);
      }
    }
  } catch {
    envError = "failed";
  }
  const finalEnv = env ?? (process.env as Record<string, string>);
  if (envError) console.error(`cgc-host: 解析登录 shell 环境失败（${envError}），退回最小环境`);
  return { env: finalEnv, envError };
}
