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
  - checkpoint 不进核心：checkpoint 生命周期（waiting→hibernate、终态→delete）
    在 `Cgc2046.Workflows.CheckpointLifecycle`（架构评审候选 #2），本模块只执行、
    不调原语。
  - 授权外置：Step 执行角色授权（#38）在 `Cgc2046.Workflows.StepAuthorization`，
    本模块不直接读库。
  """

  alias Cgc2046.Workflows.JidoAdapter

  @telemetry_prefix [:cgc, :workflow, :run]

  # --- 校验层（#36 阶段 3：prepare_all） --------------------------------------

  @doc """
  执行前校验（#36 阶段 3，Engine 的 prepare 层）。

  校验 input_schema：每个 step 的 `input_schema`（map，字段 → 类型字符串）与
  run 输入匹配——必填字段存在 + 类型匹配（string/integer/boolean/map/list）。
  next 引用完整性由 JidoAdapter.build_workflow 构建期校验（#10，不在此重复）。

  返回 `:ok` 或 `{:error, {:prepare_failed, reason}}`，其中 reason 为：

  - `{:missing_field, step_key, field}`：输入缺必填字段
  - `{:type_mismatch, step_key, field, expected, actual}`：字段类型不匹配

  `run/2` 执行前先调本函数；校验失败不进入执行。
  """
  @spec prepare_all(map(), map()) :: :ok | {:error, term()}
  def prepare_all(node_def, input) when is_map(node_def) and is_map(input) do
    case validate_all(node_def, input) do
      :ok -> :ok
      {:error, reason} -> {:error, {:prepare_failed, reason}}
    end
  end

  # next 引用完整性由 JidoAdapter.build_workflow 构建期校验（#10：Engine 侧
  # 重复实现会各自腐烂，保留一份）。Engine 只校验 input_schema。
  defp validate_all(node_def, input) do
    steps = Map.get(node_def, "steps", [])

    case validate_input_schemas(steps, input) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_input_schemas(steps, input) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      case Map.get(step, "input_schema") do
        schema when is_map(schema) and map_size(schema) > 0 ->
          case validate_schema(step["id"], schema, input) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        _ ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_schema(step_key, schema, input) do
    Enum.reduce_while(schema, :ok, fn {field, expected_type}, :ok ->
      cond do
        not Map.has_key?(input, field) ->
          {:halt, {:error, {:missing_field, step_key, field}}}

        not type_matches?(expected_type, Map.get(input, field)) ->
          {:halt,
           {:error,
            {:type_mismatch, step_key, field, expected_type, Map.get(input, field) |> type_name()}}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  # 类型支持：string/integer/boolean/map/list（未知类型不校验，向后兼容）
  defp type_matches?("string", value), do: is_binary(value)
  defp type_matches?("integer", value), do: is_integer(value)
  defp type_matches?("boolean", value), do: is_boolean(value)
  defp type_matches?("map", value), do: is_map(value)
  defp type_matches?("list", value), do: is_list(value)
  defp type_matches?(_unknown_type, _value), do: true

  defp type_name(value) when is_binary(value), do: "string"
  defp type_name(value) when is_integer(value), do: "integer"
  defp type_name(value) when is_boolean(value), do: "boolean"
  defp type_name(value) when is_map(value), do: "map"
  defp type_name(value) when is_list(value), do: "list"
  defp type_name(_value), do: "unknown"

  @doc """
  执行 workflow（无状态）。

  ## 参数

  - `node_def`：WorkflowDefinition 的执行拓扑（`%{"steps" => [...]}`，#34 契约）
  - `input`：run 输入（input_snapshot）
  - `opts`：可选，`tenant`（sub_workflow 步骤编译期预取子定义 node_def 的租户，#39）

  ## 返回

  - `{:ok, facts, workflow}`：全部自动步骤完成，`facts` 为按 step_key 聚合的产物
  - `{:waiting, facts, workflow}`：执行到人工步骤挂起（checkpoint 生命周期由产品层
    `CheckpointLifecycle` 接线，接信号放行）
  - `{:error, reason}`：构建或执行失败（含 `{:prepare_failed, ...}` 校验失败）
  """
  @spec run(map(), map(), keyword()) ::
          {:ok, map(), term()} | {:waiting, map(), term()} | {:error, term()}
  def run(node_def, input, opts \\ []) when is_map(node_def) and is_map(input) do
    :telemetry.execute(@telemetry_prefix ++ [:start], %{}, %{node_def: node_def, input: input})

    with :ok <- prepare_all(node_def, input),
         {:ok, workflow} <-
           JidoAdapter.build_workflow(node_def, tenant: Keyword.get(opts, :tenant)),
         {:ok, workflow} <- JidoAdapter.react_until_satisfied(workflow, input) do
      case JidoAdapter.run_status(workflow) do
        :succeeded ->
          facts = JidoAdapter.list_run_facts(workflow)
          :telemetry.execute(@telemetry_prefix ++ [:complete], %{}, %{facts: facts})
          {:ok, facts, workflow}

        :waiting ->
          # checkpoint 生命周期（hibernate）由产品层 CheckpointLifecycle 接线
          # （架构评审候选 #2，ADR-0003「checkpoint 剥离出引擎核心」）。
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
  恢复挂起的 run（阶段 4 #37）：thaw checkpoint → feed_signal → 判定状态。

  参数：`run_id`（WorkflowRun.id）、`partition`（= workspace_id）、`signal`
  （含 `signal_type`，如 `%{"signal_type" => "workflow.approval", "approved_by" => "u1"}`）。

  返回与 `run/2` 相同契约。SignalLog 记录由调用方（产品层 action）写入，
  引擎核心不碰审计资源（ADR-0003 审计走事件订阅）。

  checkpoint 生命周期由产品层 `CheckpointLifecycle` 接线（架构评审候选 #2）：
  `waiting` → 存回新 checkpoint（下次信号续传）；终态 → 删除 checkpoint（run 结束清理）。
  """
  @spec resume(term(), term(), map()) ::
          {:ok, map(), term()} | {:waiting, map(), term()} | {:error, term()}
  def resume(run_id, partition, signal) when is_map(signal) do
    with {:ok, workflow} <- JidoAdapter.thaw(run_id, partition),
         {:ok, workflow} <- JidoAdapter.feed_signal(workflow, signal) do
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
    end
  end
end
