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
  alias Cgc2046.Accounts.MembershipContext
  alias Cgc2046.Workflows.Step
  alias Cgc2046.Workflows.StepRole

  require Ash.Query

  @telemetry_prefix [:cgc, :workflow, :run]

  # --- 校验层（#36 阶段 3：prepare_all + 三阶段钩子） --------------------------

  @doc """
  执行前校验（#36 阶段 3，Engine 三阶段的 prepare 层）。

  校验两件事：

  1. **input_schema**：每个 step 的 `input_schema`（map，字段 → 类型字符串）与
     run 输入匹配——必填字段存在 + 类型匹配（string/integer/boolean/map/list）
  2. **next 引用完整性**：`steps[].next` 引用的 step 必须存在

  返回 `:ok` 或 `{:error, {:prepare_failed, reason}}`，其中 reason 为：

  - `{:missing_field, step_key, field}`：输入缺必填字段
  - `{:type_mismatch, step_key, field, expected, actual}`：字段类型不匹配
  - `{:unknown_next, step_key}`：next 引用不存在的 step

  `run/2` 执行前先调本函数；校验失败不进入执行。
  """
  @spec prepare_all(map(), map()) :: :ok | {:error, term()}
  def prepare_all(node_def, input) when is_map(node_def) and is_map(input) do
    case validate_all(node_def, input) do
      :ok -> :ok
      {:error, reason} -> {:error, {:prepare_failed, reason}}
    end
  end

  @doc """
  单步 prepare 钩子（阶段 4/5 的 checkpoint 回调、StepRole 授权复用）。

  校验单个 step 的 input_schema 与输入匹配。返回 `:ok` 或
  `{:error, {:missing_field, step_key, field}}` / `{:error, {:type_mismatch, ...}}`。
  """
  @spec prepare_step(map(), map(), map()) :: :ok | {:error, term()}
  def prepare_step(step, input, _ctx) when is_map(step) and is_map(input) do
    case Map.get(step, "input_schema") do
      schema when is_map(schema) and map_size(schema) > 0 ->
        validate_schema(step["id"], schema, input)

      _ ->
        :ok
    end
  end

  @doc """
  StepRole 授权判定（#38，prepare 阶段钩子，ADR-0003 外置声明式）。

  manual 步骤的信号发起人授权：actor 角色集 ∩ step 执行角色集 → 非空放行
  （领域模型定稿 §3.2 授权最小单元 = Step，多角色并集命中即放行）。

  - **Owner/Admin 豁免**：领域模型 §3.4 权限矩阵「执行 Workflow Step」全放行
  - **无 StepRole 配置放行**：Step 行不存在或未关联角色 → 不限制（向后兼容，
    未配置授权 = 不限制）
  - **非 manual 步骤不授权**：自动/gate/sub_workflow 由引擎执行（§4.3），
    本函数只服务 manual 信号授权

  参数：actor（含 `:id` 的 map 或 User 记录）、workspace_id（租户）、
  definition_id（WorkflowDefinition.id）、step_key（node_def 步骤标识）。

  返回 `:ok` 或 `{:error, :unauthorized}`。
  """
  @spec authorize_signal(term(), String.t(), String.t(), String.t()) ::
          :ok | {:error, :unauthorized}
  def authorize_signal(actor, workspace_id, definition_id, step_key)
      when is_binary(workspace_id) and is_binary(definition_id) and is_binary(step_key) do
    roles = MembershipContext.role_names(actor, workspace_id)

    cond do
      Enum.any?(roles, &(&1 in [:owner, :admin])) ->
        :ok

      true ->
        case step_allowed_roles(workspace_id, definition_id, step_key) do
          [] -> :ok
          allowed -> if Enum.any?(roles, &(&1 in allowed)), do: :ok, else: {:error, :unauthorized}
        end
    end
  end

  # 查 Step 行（definition_id + step_key）→ step_roles → role.name 原子列表。
  # Step 行不存在 → []（未配置授权 = 不限制）。
  defp step_allowed_roles(workspace_id, definition_id, step_key) do
    case Ash.Query.filter(Step, definition_id == ^definition_id and step_key == ^step_key)
         |> Ash.read_one(tenant: workspace_id, authorize?: false) do
      {:ok, %Step{} = step} ->
        case Ash.Query.filter(StepRole, step_id == ^step.id)
             |> Ash.Query.load(:role)
             |> Ash.read(tenant: workspace_id, authorize?: false) do
          {:ok, step_roles} -> Enum.map(step_roles, & &1.role.name)
          _ -> []
        end

      _ ->
        []
    end
  end

  @doc """
  单步 execute 钩子（阶段 4/5 复用；主路径仍走 `run/2` 的 runic 整体执行）。

  把单个 step 编译成单节点 workflow 并执行，返回与 `run/2` 相同的状态契约
  （auto→执行；manual→waiting；gate→条件路由；sub_workflow→透传）。
  """
  @spec execute_step(map(), map(), map()) ::
          {:ok, map()} | {:waiting, map()} | {:error, term()}
  def execute_step(step, input, _ctx) when is_map(step) and is_map(input) do
    node_def = %{"steps" => [step]}

    with {:ok, workflow} <- JidoAdapter.build_workflow(node_def),
         {:ok, workflow} <- JidoAdapter.react_until_satisfied(workflow, input) do
      case JidoAdapter.run_status(workflow) do
        :succeeded -> {:ok, JidoAdapter.list_run_facts(workflow)}
        :waiting -> {:waiting, JidoAdapter.list_run_facts(workflow)}
        :failed -> {:error, :step_failed}
      end
    end
  end

  @doc """
  单步 finalize 钩子（规范化 facts + telemetry，阶段 4/5 复用）。

  把 execute 结果规范化为 `%{step_key => value}` 形态并发出 telemetry 事件。
  返回 `{:ok, facts}`。
  """
  @spec finalize_step(map(), term(), map()) :: {:ok, map()}
  def finalize_step(step, result, _ctx) when is_map(step) do
    facts = normalize_step_facts(step["id"], result)

    :telemetry.execute(@telemetry_prefix ++ [:step, :complete], %{}, %{
      step: step["id"],
      facts: facts
    })

    {:ok, facts}
  end

  defp validate_all(node_def, input) do
    steps = Map.get(node_def, "steps", [])
    step_keys = MapSet.new(steps, & &1["id"])

    with :ok <- validate_next_refs(steps, step_keys),
         :ok <- validate_input_schemas(steps, input) do
      :ok
    end
  end

  defp validate_next_refs(steps, step_keys) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      case Map.get(step, "next") do
        next when is_list(next) ->
          case Enum.find(next, &(not MapSet.member?(step_keys, &1))) do
            nil -> {:cont, :ok}
            missing -> {:halt, {:error, {:unknown_next, missing}}}
          end

        _ ->
          {:cont, :ok}
      end
    end)
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

  # execute_step 结果规范化：%{step_key => value}（facts 已是该形态时原样返回）
  defp normalize_step_facts(step_key, %{} = facts) do
    case Map.get(facts, step_key) do
      nil -> %{step_key => facts}
      _ -> facts
    end
  end

  defp normalize_step_facts(step_key, value), do: %{step_key => value}

  @doc """
  执行 workflow（无状态）。

  ## 参数

  - `node_def`：WorkflowDefinition 的执行拓扑（`%{"steps" => [...]}`，#34 契约）
  - `input`：run 输入（input_snapshot）
  - `opts`：可选，`run_id` + `partition`（挂起时自动 hibernate checkpoint）、
    `tenant`（sub_workflow 步骤编译期预取子定义 node_def 的租户，#39）

  ## 返回

  - `{:ok, facts, workflow}`：全部自动步骤完成，`facts` 为按 step_key 聚合的产物
  - `{:waiting, facts, workflow}`：执行到人工步骤挂起（已 hibernate，接信号放行）
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
          facts = JidoAdapter.list_run_facts(workflow)

          # 产品层传入 run_id/partition 时自动 hibernate checkpoint（阶段 4 #37）。
          # #2：hibernate 失败必须上抛——否则 run 标 waiting 但无 checkpoint，
          # 下次信号 thaw 死路，run 永久卡死。失败 → :failed（与 resume/3 的
          # `:ok =` 严格模式一致，但以 error 返回而非 raise）。
          case {Keyword.get(opts, :run_id), Keyword.get(opts, :partition)} do
            {nil, _} ->
              :telemetry.execute(@telemetry_prefix ++ [:waiting], %{}, %{facts: facts})
              {:waiting, facts, workflow}

            {_, nil} ->
              :telemetry.execute(@telemetry_prefix ++ [:waiting], %{}, %{facts: facts})
              {:waiting, facts, workflow}

            {run_id, partition} ->
              case JidoAdapter.hibernate(run_id, partition, workflow) do
                :ok ->
                  :telemetry.execute(@telemetry_prefix ++ [:waiting], %{}, %{facts: facts})
                  {:waiting, facts, workflow}

                {:error, reason} ->
                  :telemetry.execute(@telemetry_prefix ++ [:fail], %{}, %{reason: reason})
                  {:error, {:hibernate_failed, reason}}
              end
          end

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

  checkpoint 生命周期：`waiting` → 存回新 checkpoint（下次信号续传）；
  `succeeded`/`failed` → 删除 checkpoint（run 结束清理）。
  """
  @spec resume(term(), term(), map()) ::
          {:ok, map(), term()} | {:waiting, map(), term()} | {:error, term()}
  def resume(run_id, partition, signal) when is_map(signal) do
    with {:ok, workflow} <- JidoAdapter.thaw(run_id, partition),
         {:ok, workflow} <- JidoAdapter.feed_signal(workflow, signal) do
      case JidoAdapter.run_status(workflow) do
        :succeeded ->
          JidoAdapter.delete_checkpoint(run_id, partition)
          facts = JidoAdapter.list_run_facts(workflow)
          :telemetry.execute(@telemetry_prefix ++ [:complete], %{}, %{facts: facts})
          {:ok, facts, workflow}

        :waiting ->
          :ok = JidoAdapter.hibernate(run_id, partition, workflow)
          facts = JidoAdapter.list_run_facts(workflow)
          :telemetry.execute(@telemetry_prefix ++ [:waiting], %{}, %{facts: facts})
          {:waiting, facts, workflow}

        :failed ->
          JidoAdapter.delete_checkpoint(run_id, partition)
          :telemetry.execute(@telemetry_prefix ++ [:fail], %{}, %{})
          {:error, :step_failed}
      end
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
