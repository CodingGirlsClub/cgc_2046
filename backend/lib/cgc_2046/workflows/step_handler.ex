defmodule Cgc2046.Workflows.StepHandler do
  @moduledoc """
  Workflow step handler 契约（ADR-0003 两阶段初始化）。

  引擎只依赖本 behaviour，不 import 任何业务实现模块。Step handler 通过两阶段初始化接入：

  - **阶段一（注册期）**：handler 模块 `@behaviour Cgc2046.Workflows.StepHandler`，提供
    `input_schema/0` + `capabilities/0`。引擎/校验器此时可加载模块、读 schema、校验 Step 的
    `action` 指向的模块是否实现本 behaviour——不调用 `execute/1`。
  - **阶段二（运行期）**：WorkflowRun 执行到某 step，引擎解析 `action` 模块 → 校验实现本
    behaviour → 调 `execute/1`。

  这把 ADR-0002「业务不得反向调引擎」从团队纪律提升到代码结构：引擎永远只 import 本 behaviour，
  不 import `Cgc2046.Workflows.Actions.*`。
  """

  @type run_context :: %{
          # WorkflowRun 快照（阶段 2 实现 #35 后补全字段）
          run: map(),
          step: map(),
          facts: map(),
          actor: term(),
          tenant: term()
        }

  @type step_result :: {:ok, map()} | {:waiting, map()} | {:error, term()}

  @doc "步骤输入 schema（注册期声明，throwing stub 阶段即可提供）"
  @callback input_schema() :: map()

  @doc "步骤能力声明（capability clamping，ADR-0003）"
  @callback capabilities() :: [atom()]

  @doc "执行步骤（运行期注入真实实现后调用）"
  @callback execute(run_context()) :: step_result()
end
