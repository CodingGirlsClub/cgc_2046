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

  ## 步骤四分类编译（#36）

  `build_workflow/1` 把 node_def 的步骤链编译成 DAG（先建所有节点，再按
  `steps[].next` 连边；无 `next` 字段回退数组顺序）：

  - `:auto` 步骤 → `Jido.Runic.ActionNode`（包装实现 `Jido.Action` 的模块）
  - `:manual` 步骤 → 信号门控子图：`signal_cond`（按 `data["signal_type"]` 匹配）
    → `signal_step`（透传，给信号事实正确 ancestry）→ `join`（等 [prev, signal_step]
    两路）→ `merge`（折叠成单 map）→ 下游。信号类型约定 `"workflow.<step_key>"`。
  - `:gate` 步骤 → `Condition` 节点（按 `condition` 字段路由：`%{"field" => f,
    "equals" => v}`，满足 → 放行 next；不满足 → 事实被消费）。gate 带 `action` 时
    先跑 ActionNode（副作用）再判条件。
  - `:sub_workflow` 步骤 → 递归子 workflow Step（#39：sub_definition_id 指向另一
    WorkflowDefinition，编译期预取子 node_def 注入闭包，运行时递归执行）。

  门控语义已用 runic 公开 API 验证（条件节点透传事实、join 两路合并、下游收到
  合并后的 map）。阶段 4 在此之上接 hibernate/thaw + SignalMatch 完整形态。

  ## 持久化（阶段 4 用 Postgres）

  `hibernate/3` + `thaw/2` 包装 `Jido.Persist`，storage 用 Postgres 适配器
  （`Cgc2046.Workflows.JidoStoragePostgres`，表 `jido_checkpoints` /
  `jido_thread_entries` / `jido_thread_meta`）。载体是
  `Cgc2046.Workflows.RunAgent`（最小 Jido Agent 形态，state 持 workflow 快照）。
  checkpoint 数据 `term_to_binary` 编码存 `bytea`（workflow struct 含匿名闭包，
  同 BEAM 内 round-trip 安全——单节点部署）。

  ## 信号总线

  `publish/3` + `subscribe/3` 包装 `Jido.Signal.Bus`（进程名 `:cgc_workflow_bus`，
  Application 启动时挂载）。阶段 2 用于异步事件通道（ADR-0002 决策 5 的 2 成异步路径）。
  """

  alias Runic.Workflow
  alias Runic.Workflow.{Condition, Fact, Invokable, Join, Step}
  alias Jido.Runic.ActionNode
  alias Cgc2046.Workflows.{RunAgent, StepHandlerRegistry}

  @storage {Cgc2046.Workflows.JidoStoragePostgres, repo: Cgc2046.Repo}
  @bus_name :cgc_workflow_bus

  @type workflow :: Workflow.t()
  @type run_status :: :succeeded | :waiting | :failed

  @doc "信号总线进程名（Application 启动时挂载）"
  def bus_name, do: @bus_name

  # --- 1. DAG 构建 -----------------------------------------------------------

  @doc """
  把 node_def 的步骤链编译成 runic DAG（#36 四分类 + next 顺序解锁）。

  `node_def` 形态（#34 契约）：`%{"steps" => [%{"id" => ..., "type" => :auto|:manual|
  :gate|:sub_workflow, "action" => "Elixir....", "next" => [...], "condition" => %{...}}]}`。

  ## 构建策略（先建节点，再连边）

  1. 先建所有节点（auto→ActionNode；manual→门控子图；gate→Condition；sub_workflow→递归子 workflow）
  2. 再按 `steps[].next` 连边：`Workflow.add(child, to: parent)`（parent 为 prev 输出组件）
  3. 无 `next` 字段 → 回退数组顺序（向后兼容阶段 2 的 node_def 形态）
  4. `next` 为空数组或不存在 → 链尾，不连下游边

  顺序解锁语义：runic 图边天然保证——child 的 `:runnable` 边只在 parent 产出 fact 后
  出现（阶段 2 已实证）。`next` 只是显式声明这条边。

  `opts` 支持 `:tenant`（#39）：sub_workflow 步骤编译期预取子定义 node_def 的租户
  （work fn 运行时无 tenant 上下文，闭包捕获编译期预取的 node_def）。

  返回 `{:ok, workflow}`；步骤为空、含未知类型或 next 引用不存在的步骤返回
  `{:error, reason}`。
  """
  @spec build_workflow(map(), keyword()) :: {:ok, workflow()} | {:error, term()}
  def build_workflow(node_def, opts \\ []) do
    steps = Map.get(node_def || %{}, "steps", [])

    if steps == [] do
      {:error, :no_steps}
    else
      with {:ok, nodes} <- build_nodes(steps, Keyword.get(opts, :tenant)),
           {:ok, wf} <- connect_nodes(Workflow.new(name: :cgc_workflow), steps, nodes) do
        {:ok, wf}
      end
    end
  rescue
    e -> {:error, {:build_workflow_failed, Exception.message(e)}}
  end

  # --- 1a. 建节点：steps → %{step_key => 输出组件} -----------------------------

  defp build_nodes(steps, tenant) do
    Enum.reduce_while(steps, {:ok, %{}}, fn step, {:ok, acc} ->
      case build_node(step, tenant) do
        {:ok, key, component} -> {:cont, {:ok, Map.put(acc, key, component)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp build_node(%{"type" => "auto"} = step, _tenant) do
    step_key = validate_step_id!(step)
    action_mod = resolve_action!(step)
    node = ActionNode.new(action_mod, %{}, name: String.to_atom(step_key))
    {:ok, step_key, node}
  end

  defp build_node(%{"type" => "manual"} = step, _tenant) do
    step_key = validate_step_id!(step)
    {:ok, step_key, build_manual_gate(step_key)}
  end

  defp build_node(%{"type" => "gate"} = step, _tenant) do
    step_key = validate_step_id!(step)
    {:ok, step_key, build_gate(step)}
  end

  defp build_node(%{"type" => "sub_workflow"} = step, tenant) do
    step_key = validate_step_id!(step)
    {:ok, step_key, build_sub_workflow(step_key, step, tenant)}
  end

  defp build_node(%{"type" => type}, _tenant) do
    {:error, {:unsupported_step_type, type}}
  end

  defp build_node(step, _tenant) do
    {:error, {:step_missing_required_fields, step}}
  end

  # 人工步骤门控子图（阶段 2 形态，语义已用 runic 公开 API 验证）：
  #
  #     prev ──────────────► join ──► merge ──► next
  #     signal_cond ──► signal_step ──┘
  #
  # - `signal_cond`：按 `data["signal_type"] == "workflow.<step_key>"` 匹配信号事实
  # - `signal_step`：透传（给信号事实正确 ancestry）
  # - `join`：等 [prev, signal_step] 两路（eager 构建，prev 为 nil 时只等信号）
  # - `merge`：join 产物是 [prev_value, signal_value] 列表，折叠成单 map 供下游消费
  #
  # join 在接线时创建（依赖 prev 是否存在），返回门控子图（map），输出组件是
  # merge step（作为下游的 parent）。
  defp build_manual_gate(step_key) do
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

    # join 产物是 [prev_value, signal_value] 列表，merge 折叠成单 map 供下游 Action 消费
    merge =
      Step.new(
        work: fn values when is_list(values) ->
          Enum.reduce(values, %{}, fn v, acc -> Map.merge(acc, v) end)
        end,
        name: :"#{step_key}_merge",
        hash: :erlang.phash2({:merge, step_key})
      )

    %{signal_cond: signal_cond, signal_step: signal_step, merge: merge}
  end

  # gate 步骤编译为 runic Condition 节点（v1 只支持 equals 单值比较）：
  #
  #     prev ──► condition ──► next
  #
  # - 条件满足 → 放行 next（runic Condition 语义：prepare_next_runnables 把事实
  #   连到下游）
  # - 条件不满足 → 事实被消费（mark_runnable_as_ran，不传播）
  #
  # gate 带 `action` 时先跑 ActionNode（有副作用的 gate），再判条件。
  defp build_gate(step) do
    condition = Map.get(step, "condition", %{})

    cond_node =
      Condition.new(
        work: fn data -> condition_satisfied?(condition, data) end,
        name: :"#{step["id"]}_gate_cond",
        hash: :erlang.phash2({:gate_cond, step["id"]}),
        arity: 1
      )

    case Map.get(step, "action") do
      nil ->
        cond_node

      action ->
        action_mod = resolve_action_module!(action)
        node = ActionNode.new(action_mod, %{}, name: String.to_atom(step["id"]))
        %{action: node, condition: cond_node}
    end
  end

  # sub_workflow 步骤（#39 真实嵌套）：编译期（有 tenant）预取子定义 node_def，
  # 注入 work fn 闭包——work fn 运行时无 tenant 上下文（runic Step work fn 只收
  # data），闭包捕获编译期预取的 node_def。
  #
  # - 无 sub_definition_id → 透传输入（该字段缺失 = 合法形态，保留阶段 3 stub 行为）
  # - sub_definition_id 是 id 但查不到子定义 → raise（#9：配置错误应暴露为 run failed，
  #   不得静默透传——否则父 run succeeded 但子 workflow 从未执行）
  # - 子定义含 manual 步骤 → 子 workflow 挂起（:waiting），v1 不支持嵌套 waiting
  #   （父 workflow 需 hibernate 子 workflow 状态），raise 领域错误 → 父 run failed
  # - 子 workflow 失败 → raise 领域错误（#3：不能返回 {:error, ...}——runic Step
  #   work fn 的返回值一律当作 fact 值，错误 tuple 会嵌入父 facts 且持久化时
  #   Jason 编码崩溃；raise 被 runic Invokable.execute 捕获 → Step runnable 标
  #   :failed → 父 run failed）
  # - 子 workflow 的 list_run_facts 产物（%{step_key => value}）作为本步骤的 fact value，
  #   父 list_run_facts 聚合时 facts["sub_step_key"] = 子 facts map（嵌套）。
  defp build_sub_workflow(step_key, step, tenant) do
    sub_definition_id = Map.get(step, "sub_definition_id")

    sub_node_def =
      if is_binary(sub_definition_id) and is_binary(tenant) do
        case Ash.get(Cgc2046.Workflows.WorkflowDefinition, sub_definition_id,
               tenant: tenant,
               authorize?: false
             ) do
          {:ok, defn} ->
            defn.node_def

          {:error, _} ->
            raise ArgumentError,
                  "sub_workflow #{step_key} references unknown sub_definition_id #{inspect(sub_definition_id)}"
        end
      end

    Step.new(
      work: fn data ->
        case sub_node_def do
          nil ->
            data

          node_def ->
            with {:ok, sub_workflow} <- build_workflow(node_def, tenant: tenant),
                 {:ok, sub_workflow} <- react_until_satisfied(sub_workflow, data) do
              case run_status(sub_workflow) do
                :succeeded ->
                  list_run_facts(sub_workflow)

                :waiting ->
                  raise "sub_workflow #{step_key} nested waiting not supported"

                :failed ->
                  raise "sub_workflow #{step_key} failed"
              end
            else
              {:error, reason} ->
                raise "sub_workflow #{step_key} execution failed: #{inspect(reason)}"
            end
        end
      end,
      name: String.to_atom(step_key),
      hash: :erlang.phash2({:sub_workflow, step_key, sub_definition_id})
    )
  end

  # condition 字段形态：%{"field" => "status", "equals" => "full"}。
  # v1 只做 equals 单值比较：data[field] == value。
  # 无 condition 字段 → 恒真（纯放行）。
  # field 按字符串匹配；data 可能是 string key（输入快照）或 atom key
  # （Jido Action 产物），两种都查。
  defp condition_satisfied?(condition, data) when is_map(condition) do
    case {Map.get(condition, "field"), Map.get(condition, "equals")} do
      {field, value} when is_binary(field) ->
        field_value(data, field) == value

      _ ->
        true
    end
  end

  defp condition_satisfied?(_condition, _data), do: true

  # 按字符串 field 取 data 值：string key 直接取；atom key 遍历比较
  # （不 String.to_atom——node_def 的 field 是租户输入，造原子会耗尽原子表，
  # 见 /check SC2-002）
  defp field_value(data, field) do
    case Map.get(data, field) do
      nil ->
        case Enum.find(data, fn {k, _v} -> is_atom(k) and Atom.to_string(k) == field end) do
          {_k, v} -> v
          nil -> nil
        end

      value ->
        value
    end
  end

  # --- 1b. 连边：按 next 拓扑（无任何 next 时回退数组顺序） --------------------

  # 构建策略：
  # 1. 先接线所有子图（manual 门控 / gate 带 action），join 按上游输出 hash 创建
  # 2. 再连边：next 驱动（有 next 字段）或数组顺序（全部无 next，阶段 2 兼容）
  #
  # next 驱动语义（#36 顺序解锁）：
  # - 每个 step 连到其 next 列表中的步骤（child 的 parent 是本步骤输出组件）
  # - next 为空/不存在 → 链尾，不连下游边
  # - 无上游的步骤（入口）连到 root
  defp connect_nodes(wf, steps, nodes) do
    with :ok <- validate_next_refs!(steps, nodes) do
      next_driven? = Enum.any?(steps, &has_next?/1)
      upstream_keys = compute_upstream_keys(steps, next_driven?)

      upstreams =
        Map.new(upstream_keys, fn {key, upstream} ->
          {key, upstream && output_hash(Map.fetch!(nodes, upstream))}
        end)

      # 1. 接线所有子图 → %{step_key => {input, output}}
      {wf, outputs} =
        Enum.reduce(steps, {wf, %{}}, fn step, {wf, outputs} ->
          step_key = step["id"]
          component = Map.fetch!(nodes, step_key)
          {wf, input, output} = connect_step_subgraph(wf, component, Map.get(upstreams, step_key))
          {wf, Map.put(outputs, step_key, {input, output})}
        end)

      # 2. 连边
      wf =
        if next_driven? do
          # 入口步骤（无上游）连 root
          wf =
            Enum.reduce(steps, wf, fn step, wf ->
              step_key = step["id"]
              {input, _output} = Map.fetch!(outputs, step_key)

              if Map.get(upstream_keys, step_key) == nil do
                connect_upstream(wf, input, nil)
              else
                wf
              end
            end)

          # next 边：本步骤输出 → next 步骤输入
          Enum.reduce(steps, wf, fn step, wf ->
            step_key = step["id"]
            {_input, output} = Map.fetch!(outputs, step_key)

            case Map.get(step, "next") do
              next when is_list(next) and next != [] ->
                Enum.reduce(next, wf, fn child_key, wf ->
                  {child_input, _child_output} = Map.fetch!(outputs, child_key)
                  connect_upstream(wf, child_input, output)
                end)

              _ ->
                wf
            end
          end)
        else
          # 数组顺序链（阶段 2 兼容）：prev 是上一步输出组件
          {wf, _} =
            Enum.reduce(steps, {wf, nil}, fn step, {wf, prev_out} ->
              step_key = step["id"]
              {input, output} = Map.fetch!(outputs, step_key)
              {connect_upstream(wf, input, prev_out), output}
            end)

          wf
        end

      {:ok, wf}
    end
  end

  defp has_next?(step) do
    case Map.get(step, "next") do
      next when is_list(next) and next != [] -> true
      _ -> false
    end
  end

  # 每个 step 的上游 step id：
  # - next 驱动：在 next 中引用它的 step（v1 线性 next，至多一个）
  # - 数组顺序：前一个 step
  defp compute_upstream_keys(steps, true) do
    Map.new(steps, fn step ->
      step_key = step["id"]

      upstream =
        Enum.find_value(steps, fn s ->
          if step_key in (Map.get(s, "next") || []), do: s["id"], else: nil
        end)

      {step_key, upstream}
    end)
  end

  defp compute_upstream_keys(steps, false) do
    {map, _} =
      Enum.reduce(steps, {%{}, nil}, fn step, {acc, prev_key} ->
        {Map.put(acc, step["id"], prev_key), step["id"]}
      end)

    map
  end

  # 步骤输出组件的 hash（join 的 joins 列表需要知道等谁）：
  # - manual：merge step（phash2({:merge, key})，建节点时已固定）
  # - gate 带 action：condition 节点
  # - 其余：组件自身
  defp output_hash(%{merge: merge}), do: merge.hash
  defp output_hash(%{condition: condition}), do: condition.hash
  defp output_hash(component), do: component.hash

  # 上游连接：把 prev 输出连到本步骤输入。
  # - manual 门控的输入是 join（无 Component impl，用 raw add_step）
  # - prev 为 nil（入口步骤）：连 root；manual 门控入口的 signal_cond 已在
  #   子图接线时连 root，join 只等信号
  defp connect_upstream(wf, %Join{}, nil), do: wf

  defp connect_upstream(wf, input, nil), do: Workflow.add(wf, input, to: nil)

  defp connect_upstream(wf, %Join{} = join, prev_out) do
    Workflow.add_step(wf, prev_out, join)
  end

  defp connect_upstream(wf, input, prev_out) do
    Workflow.add(wf, input, to: prev_out)
  end

  # 步骤子图接线，返回 {wf, input, output}（输入 = 上游连到哪，输出 = 下游从哪连）：
  #
  # - manual：signal_cond → signal_step → join（← 上游）→ merge；输入 join，输出 merge
  # - gate 带 action：action → condition；输入 action，输出 condition
  # - 其余（auto / sub_workflow / 纯条件 gate）：输入 = 输出 = 组件自身
  defp connect_step_subgraph(wf, %{signal_cond: sc, signal_step: ss, merge: merge}, upstream_hash) do
    # 门控 join：等 [上游输出, signal_step] 两路（无上游时只等信号）
    join =
      case upstream_hash do
        nil -> Join.new([ss.hash])
        _ -> Join.new([upstream_hash, ss.hash])
      end

    wf =
      wf
      |> Workflow.add(sc)
      |> Workflow.add(ss, to: :"#{sc.name}")
      |> Workflow.add_step([ss], join)
      |> Workflow.add(merge, to: join)

    {wf, join, merge}
  end

  defp connect_step_subgraph(wf, %{action: action, condition: condition}, _upstream_hash) do
    {Workflow.add(wf, condition, to: action), action, condition}
  end

  defp connect_step_subgraph(wf, component, _upstream_hash), do: {wf, component, component}

  # next 引用完整性：next 指向的 step 必须存在。唯一实现在本模块构建期校验
  # （#10：Engine 侧重复实现会各自腐烂，保留一份；Engine 只校验 input_schema），
  # 构建期提前失败，避免 runic 图里出现悬空引用。
  defp validate_next_refs!(steps, nodes) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      case Map.get(step, "next") do
        next when is_list(next) ->
          case Enum.find(next, &(not Map.has_key?(nodes, &1))) do
            nil -> {:cont, :ok}
            missing -> {:halt, {:error, {:unknown_next, missing}}}
          end

        _ ->
          {:cont, :ok}
      end
    end)
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
  #
  # #11：不直接 Module.concat(action)——租户可控字符串会永久创建 BEAM atom，
  # 耗尽原子表。改为字符串 → 注册表反向解析：只有 action 恰等于某已注册模块名
  # 时返回该模块（此时模块 atom 已存在，无新原子产生）；否则拒绝。
  @action_regex ~r/^[A-Za-z][A-Za-z0-9_.]{0,255}$/

  defp resolve_action_module!(action) when is_binary(action) do
    if Regex.match?(@action_regex, action) do
      case Enum.find(StepHandlerRegistry.registered(), fn mod ->
             Atom.to_string(mod) == action
           end) do
        nil ->
          raise ArgumentError,
                "action #{inspect(action)} is not a registered step handler (StepHandlerRegistry)"

        mod ->
          mod
      end
    else
      raise ArgumentError, "invalid action module name #{inspect(action)}"
    end
  end

  defp resolve_action_module!(action) do
    raise ArgumentError, "invalid action module name #{inspect(action)}"
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
  挂起 run：把 workflow 快照写入 checkpoint（Postgres storage）。

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

  @doc """
  删除 run 的 checkpoint（执行完成/失败后清理）。

  返回 `:ok` 或 `{:error, reason}`。
  """
  @spec delete_checkpoint(term(), term()) :: :ok | {:error, term()}
  def delete_checkpoint(run_id, partition) do
    key = Jido.partition_key(run_id, partition)

    case Jido.Storage.fetch_checkpoint(elem(@storage, 0), {RunAgent, key}, elem(@storage, 1)) do
      {:ok, _} -> do_delete_checkpoint(key)
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp do_delete_checkpoint(key) do
    {adapter, opts} = @storage
    adapter.delete_checkpoint({RunAgent, key}, opts)
  end

  # --- 4. 信号总线 ------------------------------------------------------------

  @doc """
  发布信号到总线（异步事件通道，ADR-0002 决策 5 的 2 成异步路径）。

  `signal_type` 为字符串（如 `"workflow.run.completed"`），`payload` 为 map。
  返回 `:ok` 或 `{:error, reason}`。
  """
  @spec publish(String.t(), map()) :: :ok | {:error, term()}
  def publish(signal_type, payload) when is_binary(signal_type) and is_map(payload) do
    with {:ok, signal} <- Jido.Signal.new(signal_type, payload, source: "/cgc/workflows") do
      case Jido.Signal.Bus.publish(@bus_name, [signal]) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc """
  订阅信号（异步消费；plan 2026-08-14-003 D1 唯一语义 = 崩溃隔离）。

  `pattern` 为路径模式（如 `"workflow.run.*"`）；`fun` 为
  `(signal_type, data) -> any`——Jido.Signal struct 在本 adapter 解包，不外泄
  （Jido 升级只影响本模块）。转发进程 `spawn` 接收总线投递并调用 `fun`，
  与调用者崩溃隔离（历史 `spawn_link` 连坐变体已删：转发进程崩溃连带调用者
  死亡，测试沙箱下连锁重启耗尽监督预算——E-7 #122 实锤）。反向收割由转发
  进程 monitor 调用者保证：调用者死亡 → 转发进程自退，不留僵尸订阅消费
  总线投递（spawn_link 变体的隐性清道夫语义，崩溃隔离后必须显式补回）。

  调用者持有返回的 monitor：转发进程死亡收 `{:DOWN, ref, :process, pid, reason}`
  后自行重建订阅（`Cgc2046.Workflows.SignalSubscriber` 骨架统一持有）。返回
  `{:ok, subscription_id, monitor_ref, forwarder_pid}`——forwarder pid 供骨架在
  bus 重启时显式回收旧转发进程（spawn 无 link，不回收则泄漏；#120），或
  `{:error, reason}`（bus 未注册时为 `:not_found`）。

  `bus_pid` 显式指定时按 pid 而非名字订阅（advisor M2）：订阅方骨架先
  `whereis_bus` → `Process.monitor(pid)` → 按 pid 订阅，保证订阅行与 monitor
  落在同一 bus incarnation——按名字订阅会在 subscribe → whereis 间隙遭遇
  incarnation 替换（订阅落 B1、monitor B2 → B1 死亡无感知，静默失聪）。
  """
  @spec subscribe(String.t(), (String.t(), map() -> any())) ::
          {:ok, term(), reference(), pid()} | {:error, term()}
  @spec subscribe(String.t(), (String.t(), map() -> any()), pid() | nil) ::
          {:ok, term(), reference(), pid()} | {:error, term()}
  def subscribe(pattern, fun, bus_pid \\ nil)
      when is_binary(pattern) and is_function(fun, 2) and (is_pid(bus_pid) or is_nil(bus_pid)) do
    caller = self()
    subscriber = spawn(fn -> forward_loop(fun, caller) end)
    monitor_ref = Process.monitor(subscriber)
    # 按名字（nil）或显式 pid 解析 bus（jido bus_call_target 对 pid 直通）
    bus = if is_pid(bus_pid), do: bus_pid, else: @bus_name

    case Jido.Signal.Bus.subscribe(bus, pattern,
           dispatch: {:pid, target: subscriber, delivery_mode: :async}
         ) do
      {:ok, subscription_id} ->
        {:ok, subscription_id, monitor_ref, subscriber}

      {:error, reason} ->
        # 订阅失败：回收无信号来源的转发进程，避免泄漏
        Process.demonitor(monitor_ref, [:flush])
        Process.exit(subscriber, :kill)
        {:error, reason}
    end
  end

  @doc """
  解析信号总线进程 pid（#120：订阅方骨架 monitor bus、bus 重启后重订阅用）。

  返回 `{:ok, pid}` 或 `{:error, :not_found}`（bus 未注册——启动间隙或已死）。
  """
  @spec whereis_bus() :: {:ok, pid()} | {:error, :not_found}
  def whereis_bus, do: Jido.Signal.Util.whereis(@bus_name)

  @drain_default_timeout_ms 5_000

  @doc """
  drain 协议优雅回收 forwarder（#245）：spawn 一次性 waiter，对每个 pid
  先 `Process.monitor` 再投递 `:reclaim`（顺序保证 pid 先死也能收 DOWN），
  等全部 forwarder 处理完在途投递后自退；超时（默认 #{@drain_default_timeout_ms}ms，
  可注入缩短供测试）仍未退者 `Process.exit(pid, :kill)` 强杀兜底。立即返回
  waiter pid 不阻塞调用方——bus DOWN 恢复路径（重订阅退避）不被在途投递拖住。

  截断窗口闭合的机制前提：claim 与 effects 在 forwarder 进程内**同步**执行
  （`SignalSubscriber.do_run` 内联 claim→handle），forwarder 在 `fun.()`
  执行中收不到消息——`:reclaim` 落邮箱仅在 fun 跑完、循环回到 `receive` 时
  被处理，「处理 :reclaim 前」=「claim/effects 要么都完成要么都没开始」。
  若未来 effects 异步化，此前提失效，drain 降级为超时强杀的旧 kill 行为
  （不劣化现状）。

  残余窗口：fun 卡死超过 `timeout` 仍被强杀截断——概率缩小非零，兜底仍是
  SignalIdempotency claim + E-10 对账。
  """
  @spec drain_forwarders([pid()], pos_integer()) :: pid()
  def drain_forwarders(pids, timeout \\ @drain_default_timeout_ms)
      when is_list(pids) and is_integer(timeout) and timeout > 0 do
    spawn(fn ->
      pending =
        Map.new(pids, fn pid ->
          ref = Process.monitor(pid)
          send(pid, :reclaim)
          {ref, pid}
        end)

      deadline = System.monotonic_time(:millisecond) + timeout
      await_drain(pending, deadline)
    end)
  end

  # 等全部 forwarder 退出（自退或强杀后）：pending 空即收工；到 deadline 仍有
  # 未退者（fun 卡死/消息被业务 receive 吞掉）强杀残余——kill 后 monitor 的
  # DOWN 必然到达，转入无 deadline 收割，waiter 必退不泄漏。
  defp await_drain(pending, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      Enum.each(pending, fn {_ref, pid} -> Process.exit(pid, :kill) end)
      await_downs(pending)
    else
      receive do
        {:DOWN, ref, :process, _pid, _reason} ->
          case Map.pop(pending, ref) do
            {nil, _} -> await_drain(pending, deadline)
            {_pid, rest} -> if map_size(rest) == 0, do: :ok, else: await_drain(rest, deadline)
          end
      after
        remaining ->
          Enum.each(pending, fn {_ref, pid} -> Process.exit(pid, :kill) end)
          await_downs(pending)
      end
    end
  end

  defp await_downs(pending) do
    if map_size(pending) == 0 do
      :ok
    else
      receive do
        {:DOWN, ref, :process, _pid, _reason} ->
          await_downs(Map.delete(pending, ref))
      end
    end
  end

  defp forward_loop(fun, caller) do
    caller_ref = Process.monitor(caller)

    forward_loop(fun, caller, caller_ref)
  end

  defp forward_loop(fun, caller, caller_ref) do
    receive do
      # 订阅方进程已死：转发进程自退（残余总线路由指向死 pid，投递为 no-op）
      {:DOWN, ^caller_ref, :process, ^caller, _reason} ->
        :ok

      # #245 drain：骨架回收时请求自退。fun 执行中本消息落邮箱，fun 跑完
      # 回到 receive 才处理——在途投递（claim+effects 同步链）不被截断。
      :reclaim ->
        :ok

      {:signal, signal} ->
        fun.(Map.get(signal, :type), Map.get(signal, :data) || %{})
        forward_loop(fun, caller, caller_ref)

      _other ->
        forward_loop(fun, caller, caller_ref)
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

  # 步骤失败：节点有 :ran 边但无 :produced 边（runic 失败语义：
  # mark_runnable_as_ran + skip_downstream_subgraph，不产生产物事实）。
  # 检查 ActionNode（auto 步骤）与 Step（sub_workflow 步骤，#3：work fn raise
  # 被 runic 捕获 → Step runnable 标 :failed → 同样有 :ran 无 :produced）。
  # Condition/Join 等门控节点合法地有 :ran 无 :produced，不检查。
  defp failed?(workflow) do
    ran_nodes =
      workflow.graph
      |> Multigraph.edges(by: :ran)
      |> Enum.map(& &1.v2)
      |> Enum.filter(&match?(%Jido.Runic.ActionNode{}, &1))

    ran_steps =
      workflow.graph
      |> Multigraph.edges(by: :ran)
      |> Enum.map(& &1.v2)
      |> Enum.filter(&match?(%Runic.Workflow.Step{}, &1))

    produced_nodes =
      workflow.graph
      |> Multigraph.edges(by: :produced)
      |> Enum.map(& &1.v1)

    Enum.any?(ran_nodes, fn node -> node not in produced_nodes end) or
      Enum.any?(ran_steps, fn node -> node not in produced_nodes end)
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
