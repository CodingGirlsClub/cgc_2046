// agents/builtin.ts — 这台机器上开箱支持哪些 agent：main.ts 与测试共用同一份接线，避免「写了记录忘了注册」。
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { spawnOmp } from "../acp/client";
import { WORKSPACE_DIR } from "../state";
import { codexLocator, codexRecord } from "./codex";
import { ompLocator } from "./omp";
import type { AgentRecord } from "./registry";

/** 记录随进程起一份定位器（缓存登录 shell 的解析结果）；`home` 用来算 agent 进程的工作目录 */
export function builtinAgents(home: string): AgentRecord[] {
  const omp = ompLocator();
  const workspace = join(home, WORKSPACE_DIR);
  return [
    {
      kind: "omp",
      mcpServerName: "cgc-2046", // 与终端插件同名（学员的 OMP 配置里那份）；Codex 侧才需要换名字避开撞名
      locator: omp,
      async start(app, signal) {
        const found = await omp.locate();
        signal.throwIfAborted();
        if (!found.path) throw new Error("找不到 omp");
        mkdirSync(workspace, { recursive: true });
        return spawnOmp({ ...found, path: found.path }, app, workspace, signal);
      },
    },
    codexRecord(codexLocator(home), workspace),
  ];
}
