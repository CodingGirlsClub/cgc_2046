defmodule Cgc2046.Workflows.Engine do
  @moduledoc """
  Workflow 引擎纯函数入口（Slice C #35，ADR-0003「无状态引擎 + 有状态壳」）。

  本模块是**无状态纯函数**：不持有任何状态、不启动进程、不写数据库。执行状态全部
  落在 `Cgc2046.Workflows.WorkflowRun` 资源（有状态壳）；引擎只接收 run 快照 +
  node_def，返回执行结果，由调用方（业务 context / Runner 壳）落库。

  ## 主路径（避 F1 死锁）

  执行走 `Cgc2046.Workflows.JidoAdapter.react_until_satisfied/2`（Workflow 层 runic
  runner，图边状态驱动），不走 Agent 策略层 join——后者有 F1 死锁缺陷
  （见 `JidoAdapter` moduledoc 与 docs/04-引擎验证/poc-验证报告.md §3.3）。

  ## 契约

      run(node_def, input) ::
        {:ok, facts, workflow}        # 全部完成（succeeded）
        | {:waiting, facts, workflow} # 人工步骤挂起（waiting，等信号）
        | {:error, reason}            # 步骤失败（failed）

  `workflow` 随返回携带，供阶段 4 的 hibernate/thaw 与信号放行复用。

  ## ADR-0003 纪律

  - 审计走事件订阅：本模块只发 telemetry 事件（`[:cgc, :workflow, :run, ...]`），
    产品层按需订阅记录，不嵌入引擎核心。
  - checkpoint 经回调不进核心：阶段 4 的 checkpoint 服务经 `transformContext`
    回调接入，本模块不内建。
  """

  alias Cgc2046.Workflows.JidoAdapter

  @telemetry_prefix [:cgc, :workflow, :run]

  @doc """
  执行 workflow（无状态）。

  ## 参数

  - `node_def`：WorkflowDefinition 的执行拓扑（`%{"steps" => [...]}`，#34 契约）
  - `input`：run 输入（input_snapshot）

  ## 返回

  - `{:ok, facts, workflow}`：全部自动步骤完成，`facts` 为按 step_key 聚合的产物
  - `{:waiting, facts, workflow}`：执行到人工步骤挂起（阶段 4 接信号放行）
  - `{:error, reason}`：构建或执行失败
  """
  @spec run(map(), map()) ::
          {:ok, map(), term()} | {:waiting, map(), term()} | {:error, term()}
  def run(node_def, input) when is_map(node_def) and is_map(input) do
    :telemetry.execute(@telemetry_prefix ++ [:start], %{}, %{node_def: node_def, input: input})

    with {:ok, workflow} <- JidoAdapter.build_workflow(node_def),
         {:ok, workflow} <- JidoAdapter.react_until_satisfied(workflow, input) do
      case JidoAdapter.run_status(workflow) do
        :succeeded ->
          facts = JidoAdapter.list_run_facts(workflow)
          :telemetry.execute(@telemetry_prefix ++ [:complete], %{}, %{facts: facts})
          {:ok, facts, workflow}

        :waiting ->
          facts = JidoAdapter.list_run_facts(workflow)
          :telemetry.execute(@telemetry_prefix ++ [:waiting], %{}, %{facts: facts})
          {:waiting, facts, workflow}

        :failed ->
          :telemetry.execute(@telemetry_prefix ++ [:fail], %{}, %{})
          {:error, :step_failed}
      end
    else
      {:error, reason} ->
        :telemetry.execute(@telemetry_prefix ++ [:fail], %{}, %{reason: reason})
        {:error, reason}
    end
  end

  @doc """
  注入外部信号（人工步骤放行，阶段 4 完整接入）。

  信号事实值约定含 `"signal_type"` 键（`"workflow.<step_key>"`），由
  `JidoAdapter.feed_signal/2` 的门控匹配。返回与 `run/2` 相同契约。
  """
  @spec feed_signal(term(), map()) ::
          {:ok, map(), term()} | {:waiting, map(), term()} | {:error, term()}
  def feed_signal(workflow, signal) when is_map(signal) do
    with {:ok, workflow} <- JidoAdapter.feed_signal(workflow, signal) do
      case JidoAdapter.run_status(workflow) do
        :succeeded ->
          facts = JidoAdapter.list_run_facts(workflow)
          :telemetry.execute(@telemetry_prefix ++ [:complete], %{}, %{facts: facts})
          {:ok, facts, workflow}

        :waiting ->
          facts = JidoAdapter.list_run_facts(workflow)
          :telemetry.execute(@telemetry_prefix ++ [:waiting], %{}, %{facts: facts})
          {:waiting, facts, workflow}

        :failed ->
          :telemetry.execute(@telemetry_prefix ++ [:fail], %{}, %{})
          {:error, :step_failed}
      end
    else
      {:error, reason} ->
        :telemetry.execute(@telemetry_prefix ++ [:fail], %{}, %{reason: reason})
        {:error, reason}
    end
  end
end
