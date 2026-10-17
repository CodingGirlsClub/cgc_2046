// agents/omp.ts — OMP 这条 agent 记录：找到学员的 `omp`（KTD12）。
// launchd 不加载登录 shell 的环境，而模型凭证常写在 ~/.zshrc 里，所以从登录 shell 解析出环境再在它的 PATH 里找。
import { resolveLoginShellEnv } from "../shell-env";
import { agentLocator, type AgentLocation, type Locator } from "./registry";

export async function resolveOmp(shell?: string, timeoutMs?: number): Promise<AgentLocation> {
  const { env, envError } = await resolveLoginShellEnv(shell, timeoutMs);
  return { path: Bun.which("omp", { PATH: env.PATH ?? "" }), env, envError };
}

/** 缓存最近一次解析；找不到时按 retryMs 在后台重解析——学员装上 OMP 后不必重启 Host */
export const ompLocator = (resolve: () => Promise<AgentLocation> = () => resolveOmp(), retryMs = 10_000): Locator =>
  agentLocator(resolve, retryMs);
