defmodule Cgc2046.Workflows.JidoAdapter do
  @moduledoc """
  jido_runic / runic alpha 适配层（ADR-0002 锁版本 + 隔离）。

  所有 jido 内部 API 经本模块包装；升级 jido_runic 或替换自研 DAG 只改本文件。
  产品层（Engine / 业务 context）只依赖本模块的公开函数，不直接触碰
  `Runic.Workflow` / `Jido.Runic.ActionNode` / `Jido.Persist` 等内部结构。

  ## 主路径（避 F1 死锁）

  执行走 **Workflow 层 runic 原生 runner**（`Runic.Workflow.react_until_satisfied/3`，
  图边状态驱动），不走 Agent 策略层 join——后者有 F1 死锁缺陷
  （jido_runic 1.0 `handle_apply_result` 把 `result=:waiting` 的 join 占位也算
  「已运行」，第二次 feed 被 ran_nodes 过滤 → 死锁，见 docs/04-引擎验证/poc-验证报告.md §3.3）。

  ## 人工步骤门控（阶段 2 形态）

  `build_workflow/1` 把 node_def 的线性步骤链编译成 DAG：

  - `:auto` 步骤 → `Jido.Runic.ActionNode`（包装实现 `Jido.Action` 的模块）
  - `:manual` 步骤 → 信号门控子图：`signal_cond`（按 `data["signal_type"]` 匹配）
    → `signal_step`（透传，给信号事实正确 ancestry）→ `join`（等 [prev, signal_step]
    两路）→ 下游。信号类型约定 `"workflow.<step_key>"`。

  门控语义已用 runic 公开 API 验证（条件节点透传事实、join 两路合并、下游收到
  合并后的 map）。阶段 4 在此之上接 hibernate/thaw + SignalMatch 完整形态。

  ## 持久化（阶段 2 用 ETS）

  `hibernate/3` + `thaw/2` 包装 `Jido.Persist`，storage 用 Jido 内置 ETS
  （`Jido.Storage.ETS`，表 `:cgc_jido_storage_*`，on-demand 建表）。载体是
  `Cgc2046.Workflows.RunAgent`（最小 Jido Agent 形态，state 持 workflow 快照）。
  Postgres Jido.Storage 适配器推迟到阶段 4。

  ## 信号总线

  `publish/3` + `subscribe/3` 包装 `Jido.Signal.Bus`（进程名 `:cgc_workflow_bus`，
  Application 启动时挂载）。阶段 2 用于异步事件通道（ADR-0002 决策 5 的 2 成异步路径）。
  """

  alias Runic.Workflow
  alias Runic.Workflow.{Condition, Fact, Invokable, Join, Step}
  alias Jido.Runic.ActionNode
  alias Cgc2046.Workflows.{RunAgent, StepHandlerRegistry}

  @storage {Jido.Storage.ETS, table: :cgc_jido_storage}
  @bus_name :cgc_workflow_bus

  @type workflow :: Workflow.t()
  @type run_status :: :succeeded | :waiting | :failed

  @doc "信号总线进程名（Application 启动时挂载）"
  def bus_name, do: @bus_name

  @doc "阶段 2 的 ETS storage 配置（Postgres 适配器阶段 4 替换）"
  def storage, do: @storage

  # --- 1. DAG 构建 -----------------------------------------------------------

  @doc """
  把 node_def 的线性步骤链编译成 runic DAG。

  `node_def` 形态（#34 契约）：`%{"steps" => [%{"id" => ..., "type" => :auto|:manual,
  "action" => "Elixir...."}]}`。v1 只做线性链（`next` 顺序解锁，#36 阶段 3 扩展）。

  人工步骤门控子图（阶段 2 形态，语义已用 runic 公开 API 验证）：

      prev ──────────────► join ──► next
      signal_cond ──► signal_step ──┘

  - `signal_cond`：按 `data["signal_type"] == "workflow.<step_key>"` 匹配信号事实
  - `signal_step`：透传（给信号事实正确 ancestry）
  - `join`：等 [prev, signal_step] 两路，合并后放行下游

  返回 `{:ok, workflow}`；步骤为空或含未知类型返回 `{:error, reason}`。
  """
  @spec build_workflow(map()) :: {:ok, workflow()} | {:error, term()}
  def build_workflow(node_def) do
    steps = Map.get(node_def || %{}, "steps", [])

    if steps == [] do
      {:error, :no_steps}
    else
      {:ok, build_chain(steps, Workflow.new(name: :cgc_workflow), nil)}
    end
  rescue
    e -> {:error, {:build_workflow_failed, Exception.message(e)}}
  end

  # 线性链构建：prev 是上一步的输出组件（auto 步骤的 ActionNode / manual 门控的 merge step）
  defp build_chain([], wf, _prev), do: wf

  defp build_chain([%{"type" => "auto"} = step | rest], wf, prev) do
    step_key = validate_step_id!(step)
    action_mod = resolve_action!(step)
    node = ActionNode.new(action_mod, %{}, name: String.to_atom(step_key))

    wf = Workflow.add(wf, node, to: prev)
    build_chain(rest, wf, node)
  end

  defp build_chain([%{"type" => "manual"} = step | rest], wf, prev) do
    step_key = validate_step_id!(step)
    signal_type = "workflow.#{step_key}"

    signal_cond =
      Condition.new(
        work: fn data ->
          is_map(data) and Map.get(data, "signal_type") == signal_type
        end,
        name: :"#{step_key}_signal_cond",
        hash: :erlang.phash2({:signal_cond, step_key}),
        arity: 1
      )

    # 显式 hash（含 step_key）：Runic.step 宏按 work 函数内容 hash，两个 manual 步骤的
    # 透传/merge work 相同会碰撞（顶点合并 → 门控串门/绕过），见 /check SC2-009
    signal_step =
      Step.new(
        work: fn data -> data end,
        name: :"#{step_key}_signal_step",
        hash: :erlang.phash2({:signal_step, step_key})
      )

    # 门控 join：等 [prev, signal_step] 两路（eager 构建，prev 为 nil 时只等信号）
    join =
      case prev do
        nil -> Join.new([signal_step.hash])
        _ -> Join.new([prev.hash, signal_step.hash])
      end

    # join 产物是 [prev_value, signal_value] 列表，merge 折叠成单 map 供下游 Action 消费
    merge =
      Step.new(
        work: fn values when is_list(values) ->
          Enum.reduce(values, %{}, fn v, acc -> Map.merge(acc, v) end)
        end,
        name: :"#{step_key}_merge",
        hash: :erlang.phash2({:merge, step_key})
      )

    wf =
      wf
      |> Workflow.add(signal_cond)
      |> Workflow.add(signal_step, to: :"#{step_key}_signal_cond")
      |> then(fn wf ->
        case prev do
          nil -> Workflow.add_step(wf, [signal_step], join)
          _ -> Workflow.add_step(wf, [prev, signal_step], join)
        end
      end)
      |> Workflow.add(merge, to: join)

    build_chain(rest, wf, merge)
  end

  defp build_chain([%{"type" => type} | _], _wf, _prev) do
    raise ArgumentError, "unsupported step type: #{inspect(type)}"
  end

  defp build_chain([step | _], _wf, _prev) do
    raise ArgumentError, "step missing required fields: #{inspect(step)}"
  end

  # step id 校验：受限字符集 + 长度上限，把 String.to_atom 的原子集限定在有界范围
  # （/check SC2-002：无校验时租户可用唯一 step id 永久耗尽 BEAM 原子表）
  @step_id_regex ~r/^[a-z][a-z0-9_]{0,63}$/

  defp validate_step_id!(step) do
    case Map.get(step, "id") do
      id when is_binary(id) and id != "" ->
        if Regex.match?(@step_id_regex, id) do
          id
        else
          raise ArgumentError,
                "invalid step id #{inspect(id)}: must match #{inspect(@step_id_regex)}"
        end

      other ->
        raise ArgumentError, "step missing valid id: #{inspect(other)}"
    end
  end

  defp resolve_action!(step) do
    case Map.get(step, "action") do
      nil -> raise ArgumentError, "auto step #{inspect(step["id"])} missing action"
      action -> resolve_action_module!(action)
    end
  end

  # action 模块校验：必须经 StepHandlerRegistry 显式注册（ADR-0003 两阶段初始化）。
  # /check SC2-001：无校验时租户可让引擎执行任意带 run/2 的模块
  # （如 Jido.Tools.Files.WriteFile → 任意宿主文件读写）；Jido.Action 的 schema/0
  # 导出无法区分（WriteFile 也导出），必须用注册表白名单。
  defp resolve_action_module!(action) do
    mod = Module.concat([action])

    if StepHandlerRegistry.allowed?(mod) do
      mod
    else
      raise ArgumentError,
            "action #{inspect(action)} is not a registered step handler (StepHandlerRegistry)"
    end
  end

  # --- 2. 执行（Workflow 层 runner，避 F1 死锁） ------------------------------

  @doc """
  执行 workflow 直到满足（无 runnable 为止）。

  返回 `{:ok, workflow}`（全部完成）或 `{:error, reason}`（步骤失败）。
  调用方（Engine）用 `run_status/1` 判定 succeeded/waiting/failed。
  """
  @spec react_until_satisfied(workflow(), map()) :: {:ok, workflow()} | {:error, term()}
  def react_until_satisfied(workflow, input) when is_map(input) do
    {:ok, Workflow.react_until_satisfied(workflow, input)}
  rescue
    e -> {:error, {:react_failed, Exception.message(e)}}
  end

  @doc """
  注入外部信号（人工步骤放行）。

  信号事实值约定含 `"signal_type"` 键（`"workflow.<step_key>"`）。信号事实直接
  invoke 到对应 `signal_cond` 门控组件（避免从 root 注入重新激活所有根组件），
  匹配则放行下游。返回 `{:ok, workflow}` 或 `{:error, reason}`。
  """
  @spec feed_signal(workflow(), map()) :: {:ok, workflow()} | {:error, term()}
  def feed_signal(workflow, signal) when is_map(signal) do
    case Map.get(signal, "signal_type") do
      "workflow." <> step_key ->
        # 按字符串匹配已存在的门控组件名，不创建原子（/check SC2-003：
        # 未知/畸形 signal_type 不得永久分配原子）
        case find_gate_component(workflow, step_key) do
          # 信号不匹配任何门控 → 无操作（workflow 原样返回，仍 waiting）
          nil ->
            {:ok, workflow}

          cond_comp ->
            workflow =
              cond_comp
              |> Invokable.invoke(workflow, Fact.new(value: signal))
              |> Workflow.react_until_satisfied()

            {:ok, workflow}
        end

      other ->
        {:error, {:invalid_signal_type, other}}
    end
  rescue
    e -> {:error, {:feed_signal_failed, Exception.message(e)}}
  end

  # 在 components map（atom key）中按字符串名查找门控组件，全程不创建新原子
  defp find_gate_component(workflow, step_key) do
    target = step_key <> "_signal_cond"

    case Enum.find(workflow.components, fn {name, _hash} -> to_string(name) == target end) do
      {_name, hash} -> Map.get(workflow.graph.vertices, hash)
      nil -> nil
    end
  end

  # --- 3. 持久化：hibernate/thaw（阶段 2 用 ETS） -----------------------------

  @doc """
  挂起 run：把 workflow 快照写入 checkpoint（ETS storage）。

  载体是 `Cgc2046.Workflows.RunAgent`（最小 Jido Agent 形态，state 持 workflow）。
  返回 `:ok` 或 `{:error, reason}`。
  """
  @spec hibernate(term(), term(), workflow()) :: :ok | {:error, term()}
  def hibernate(run_id, partition, workflow) do
    agent = RunAgent.new!(run_id, partition, workflow)
    Jido.Persist.hibernate(@storage, RunAgent, Jido.partition_key(run_id, partition), agent)
  end

  @doc """
  恢复 run：从 checkpoint 读回 workflow 快照。

  返回 `{:ok, workflow}` 或 `{:error, :not_found | reason}`。
  """
  @spec thaw(term(), term()) :: {:ok, workflow()} | {:error, term()}
  def thaw(run_id, partition) do
    case Jido.Persist.thaw(@storage, RunAgent, Jido.partition_key(run_id, partition)) do
      {:ok, %RunAgent{state: %{workflow: workflow}}} -> {:ok, workflow}
      {:ok, _other} -> {:error, :invalid_checkpoint}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- 4. 信号总线 ------------------------------------------------------------

  @doc """
  发布信号到总线（异步事件通道，ADR-0002 决策 5 的 2 成异步路径）。

  `signal_type` 为字符串（如 `"workflow.run.completed"`），`payload` 为 map。
  返回 `:ok` 或 `{:error, reason}`。
  """
  @spec publish(String.t(), map(), term()) :: :ok | {:error, term()}
  def publish(signal_type, payload, _partition) when is_binary(signal_type) and is_map(payload) do
    with {:ok, signal} <- Jido.Signal.new(signal_type, payload, source: "/cgc/workflows") do
      case Jido.Signal.Bus.publish(@bus_name, [signal]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  订阅信号（异步消费）。

  `pattern` 为路径模式（如 `"workflow.run.*"`），`fun` 为 `(signal -> any)` 回调。
  内部 spawn 一个转发进程接收总线投递的 `{:signal, signal}` 消息并调用 `fun`。
  返回 `{:ok, subscription_id}` 或 `{:error, reason}`。
  """
  @spec subscribe(String.t(), (Jido.Signal.t() -> any()), term()) ::
          {:ok, term()} | {:error, term()}
  def subscribe(pattern, fun, _partition) when is_binary(pattern) and is_function(fun, 1) do
    subscriber =
      spawn_link(fn ->
        forward_loop(fun)
      end)

    Jido.Signal.Bus.subscribe(@bus_name, pattern,
      dispatch: {:pid, target: subscriber, delivery_mode: :async}
    )
  end

  defp forward_loop(fun) do
    receive do
      {:signal, signal} ->
        fun.(signal)
        forward_loop(fun)

      _other ->
        forward_loop(fun)
    end
  end

  # --- 5. 读路径：run facts ---------------------------------------------------

  @doc """
  按 step_key 聚合的产物 facts（避免 runic Fact 内部结构泄露到产品层/#40）。

  返回 `%{step_key_string => value}`（key 与 node_def 的 step id 一致）；
  未产生产物的步骤不在 map 中。manual 门控的内部组件
  （`*_signal_cond` / `*_signal_step` / `*_merge`）被过滤，不进入产品层
  （/check SC2-010：泄漏会污染 WorkflowRun.facts 持久化与 #40 展示）。
  """
  @spec list_run_facts(workflow()) :: map()
  def list_run_facts(workflow) do
    workflow
    |> Workflow.productions_by_component()
    |> Enum.reduce(%{}, fn {name, facts}, acc ->
      case facts do
        [] -> acc
        [%Fact{value: value} | _] -> maybe_put_fact(acc, name, value)
      end
    end)
  end

  defp maybe_put_fact(acc, name, value) do
    name = to_string(name)

    if String.ends_with?(name, "_signal_cond") or
         String.ends_with?(name, "_signal_step") or
         String.ends_with?(name, "_merge") do
      acc
    else
      Map.put(acc, name, value)
    end
  end

  # --- 6. 状态判定 ------------------------------------------------------------

  @doc """
  判定 workflow 执行状态（runic 图边细节不外泄）。

  - `:succeeded`：无失败且无挂起门控
  - `:waiting`：人工门控挂起（join 已收到上游事实但信号未到，`:joined` 边存在）
  - `:failed`：有步骤失败（ActionNode 有 :ran 无 :produced）
  """
  @spec run_status(workflow()) :: run_status()
  def run_status(workflow) do
    cond do
      failed?(workflow) -> :failed
      waiting?(workflow) -> :waiting
      true -> :succeeded
    end
  end

  # 步骤失败：ActionNode 有 :ran 边但无 :produced 边（runic 失败语义：
  # mark_runnable_as_ran + skip_downstream_subgraph，不产生产物事实）。
  # 仅检查 ActionNode——Condition/Join 等门控节点合法地有 :ran 无 :produced。
  defp failed?(workflow) do
    ran_nodes =
      workflow.graph
      |> Multigraph.edges(by: :ran)
      |> Enum.map(& &1.v2)
      |> Enum.filter(&match?(%Jido.Runic.ActionNode{}, &1))

    produced_nodes =
      workflow.graph
      |> Multigraph.edges(by: :produced)
      |> Enum.map(& &1.v1)

    Enum.any?(ran_nodes, fn node -> node not in produced_nodes end)
  end

  # 人工门控挂起：门控 merge 步骤（join 输出）尚无产物。
  # 覆盖两种形态：首步 manual（join 无 :joined 边，等信号）与链中 manual
  # （join 已收到上游事实，:joined 边存在，仍等信号）。
  defp waiting?(workflow) do
    workflow
    |> Workflow.productions_by_component()
    |> Enum.any?(fn {name, facts} ->
      String.ends_with?(to_string(name), "_merge") and facts == []
    end)
  end
end
