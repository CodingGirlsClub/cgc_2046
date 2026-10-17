// builtin.test.ts — 开箱支持的 agent 必须都接线（写了记录却忘了注册，单测各自造注册表是抓不到的）
import { expect, test } from "bun:test";
import { builtinAgents } from "../src/agents/builtin";
import { tempHome } from "./helpers";

test("OMP 与 Codex 都在注册表里，各自的下发服务器名互不相同", () => {
  const agents = builtinAgents(tempHome());

  expect(agents.map((record) => record.kind)).toEqual(["omp", "codex"]);
  // 字面量：Codex 侧改名是为了避开学员自己配置里的 cgc-2046（同名会被适配器整条跳过）
  expect(agents.map((record) => record.mcpServerName)).toEqual(["cgc-2046", "cgc-2046-learning"]);
  expect(agents.find((record) => record.kind === "codex")?.prepare).toBeTypeOf("function");
});
