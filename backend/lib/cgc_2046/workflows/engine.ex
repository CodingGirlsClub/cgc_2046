defmodule Cgc2046.Workflows.Engine do
  @moduledoc """
  纯数据线性人工门控 Workflow 引擎（ADR-0002 / ADR-0003「无状态引擎 + 有状态壳」）。

  本模块是**无状态纯函数**：不持有任何状态、不启动进程、不写数据库、不执行闭包或
  自动 Action。执行状态与信号审计全部落在 `Cgc2046.Workflows.WorkflowRun` 与
  `Cgc2046.Workflows.SignalLog`；引擎只基于 `node_def` 与历史信号推导门控进度。

  ## 契约

      run(node_def, input, opts \\\\ []) ::
        {:waiting, facts}   # 校验通过，停在首个 manual 门控等信号
        | {:error, reason}  # schema / node_def 校验失败

      resume(node_def, prior_signal_types, signal) ::
        {:ok, facts}        # 全部 manual 门控已按序放行（succeeded）
        | {:waiting, facts} # 仍有剩余 manual 门控等待信号
        | {:error, reason}  # node_def 校验失败

  ## ADR-0003 纪律

  - 审计走事件订阅：本模块只发 telemetry 事件（`[:cgc, :workflow, :run, ...]`），
    产品层按需订阅记录，不嵌入引擎核心。
  - 授权外置：Step 执行角色授权（#38）在 `Cgc2046.Workflows.StepAuthorization`，
    本模块不直接读库。
  """

  @telemetry_prefix [:cgc, :workflow, :run]
  @step_id_regex ~r/^[a-z][a-z0-9_]{0,63}$/

  # --- 校验层（#36 阶段 3：prepare_all） --------------------------------------

  @doc """
  执行前校验（#36 阶段 3，Engine 的 prepare 层）。

  校验 input_schema：每个 step 的 `input_schema`（map，字段 → 类型字符串）与
  run 输入匹配——必填字段存在 + 类型匹配（string/integer/boolean/map/list）。

  返回 `:ok` 或 `{:error, {:prepare_failed, reason}}`，其中 reason 为：

  - `{:missing_field, step_key, field}`：输入缺必填字段
  - `{:type_mismatch, step_key, field, expected, actual}`：字段类型不匹配

  `run/3` 执行前先调本函数；校验失败不进入执行。
  """
  @spec prepare_all(map(), map()) :: :ok | {:error, term()}
  def prepare_all(node_def, input) when is_map(node_def) and is_map(input) do
    case validate_all(node_def, input) do
      :ok -> :ok
      {:error, reason} -> {:error, {:prepare_failed, reason}}
    end
  end

  defp validate_all(node_def, input) do
    case Map.get(node_def, "steps", []) do
      steps when is_list(steps) -> validate_input_schemas(steps, input)
      _ -> :ok
    end
  end

  defp validate_input_schemas(steps, input) do
    Enum.reduce_while(steps, :ok, fn
      step, :ok when is_map(step) ->
        case Map.get(step, "input_schema") do
          schema when is_map(schema) and map_size(schema) > 0 ->
            case validate_schema(step["id"], schema, input) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          _ ->
            {:cont, :ok}
        end

      _step, :ok ->
        {:cont, :ok}
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

  # --- 纯数据步骤校验与拓扑排序 -----------------------------------------------

  @doc """
  校验 `node_def["steps"]` 并按线性拓扑确定门控顺序。

  规则：
  - `steps` 必须为非空 list（否则 `{:error, :no_steps}`）
  - 每个 step 必须为 map，含非空字符串 `"id"` 与 `"type"`（否则 `{:error, {:step_missing_required_fields, step}}`）
  - `"id"` 必须匹配 `~r/^[a-z][a-z0-9_]{0,63}$/`（否则 `{:error, {:invalid_step_id, id}}`）
  - `"id"` 不可重复（否则 `{:error, {:duplicate_step_id, id}}`）
  - `"type"` 必须为 `"manual"`（否则 `{:error, {:unsupported_step_type, type}}`）
  - 若存在 `"next"`，必须为 list 且元素全部为已定义 step id（否则 `{:error, {:invalid_next, next}}` / `{:error, {:unknown_next, missing}}`）
  - 若任一步骤含非空 `"next"`，按 Kahn 拓扑排序（入度为 0 按原数组顺序出队；有环返回 `{:error, :cycle_detected}`）；否则沿用原数组顺序
  """
  @spec validate_and_order_steps(map() | nil) :: {:ok, [map()]} | {:error, term()}
  def validate_and_order_steps(node_def) do
    steps =
      if is_map(node_def) do
        Map.get(node_def, "steps", [])
      else
        []
      end

    if not is_list(steps) or steps == [] do
      {:error, :no_steps}
    else
      with {:ok, id_set} <- validate_steps(steps),
           :ok <- validate_next_refs(steps, id_set) do
        order_steps(steps)
      end
    end
  end

  defp validate_steps(steps) do
    Enum.reduce_while(steps, {:ok, MapSet.new()}, fn step, {:ok, seen_ids} ->
      case validate_step(step, seen_ids) do
        {:ok, id} -> {:cont, {:ok, MapSet.put(seen_ids, id)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp validate_step(step, _seen_ids) when not is_map(step) do
    {:error, {:step_missing_required_fields, step}}
  end

  defp validate_step(step, seen_ids) do
    id = Map.get(step, "id")
    type = Map.get(step, "type")

    cond do
      not (is_binary(id) and id != "") or is_nil(type) ->
        {:error, {:step_missing_required_fields, step}}

      not Regex.match?(@step_id_regex, id) ->
        {:error, {:invalid_step_id, id}}

      MapSet.member?(seen_ids, id) ->
        {:error, {:duplicate_step_id, id}}

      type != "manual" ->
        {:error, {:unsupported_step_type, type}}

      true ->
        {:ok, id}
    end
  end

  defp validate_next_refs(steps, id_set) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      case Map.get(step, "next") do
        nil ->
          {:cont, :ok}

        next when is_list(next) ->
          case validate_next_list(next, id_set) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, reason}}
          end

        invalid ->
          {:halt, {:error, {:invalid_next, invalid}}}
      end
    end)
  end

  defp validate_next_list(next, id_set) do
    cond do
      not Enum.all?(next, &is_binary/1) ->
        {:error, {:invalid_next, next}}

      missing = Enum.find(next, &(not MapSet.member?(id_set, &1))) ->
        {:error, {:unknown_next, missing}}

      true ->
        :ok
    end
  end

  defp order_steps(steps) do
    has_next? = Enum.any?(steps, fn step -> match?([_ | _], Map.get(step, "next")) end)

    if not has_next? do
      {:ok, steps}
    else
      kahn_sort(steps)
    end
  end

  defp kahn_sort(steps) do
    index_by_id =
      steps
      |> Enum.with_index()
      |> Map.new(fn {step, idx} -> {step["id"], idx} end)

    step_by_id = Map.new(steps, fn step -> {step["id"], step} end)

    outgoing =
      Map.new(steps, fn step ->
        next = step |> Map.get("next", []) |> List.wrap() |> Enum.uniq()
        {step["id"], next}
      end)

    initial_indegree = Map.new(steps, fn step -> {step["id"], 0} end)

    indegree =
      Enum.reduce(outgoing, initial_indegree, fn {_u, children}, acc ->
        Enum.reduce(children, acc, fn v, inner -> Map.update!(inner, v, &(&1 + 1)) end)
      end)

    ready =
      steps
      |> Enum.map(& &1["id"])
      |> Enum.filter(&(Map.fetch!(indegree, &1) == 0))

    ordered_ids = kahn_loop(ready, indegree, outgoing, index_by_id, [])

    if length(ordered_ids) < length(steps) do
      {:error, :cycle_detected}
    else
      {:ok, Enum.map(ordered_ids, &Map.fetch!(step_by_id, &1))}
    end
  end

  defp kahn_loop([], _indegree, _outgoing, _index_by_id, acc), do: Enum.reverse(acc)

  defp kahn_loop([u | rest], indegree, outgoing, index_by_id, acc) do
    {next_indegree, newly_ready} =
      Enum.reduce(Map.get(outgoing, u, []), {indegree, []}, fn v, {deg, ready_acc} ->
        new_deg = Map.fetch!(deg, v) - 1
        updated_deg = Map.put(deg, v, new_deg)
        updated_ready = if new_deg == 0, do: [v | ready_acc], else: ready_acc
        {updated_deg, updated_ready}
      end)

    next_ready =
      (rest ++ newly_ready)
      |> Enum.sort_by(&Map.fetch!(index_by_id, &1))

    kahn_loop(next_ready, next_indegree, outgoing, index_by_id, [u | acc])
  end

  # --- 引擎入口（纯函数，无 DB/IO） -------------------------------------------

  @doc """
  启动校验并进入首个 manual 门控等待状态（纯函数）。

  - 校验通过：`{:waiting, %{}}`
  - 校验失败：`{:error, reason}`
  """
  @spec run(map() | nil, map(), keyword()) :: {:waiting, map()} | {:error, term()}
  def run(node_def, input, _opts \\ []) when is_map(input) do
    :telemetry.execute(@telemetry_prefix ++ [:start], %{}, %{node_def: node_def, input: input})

    with :ok <- if(is_map(node_def), do: prepare_all(node_def, input), else: :ok),
         {:ok, _ordered_steps} <- validate_and_order_steps(node_def) do
      facts = %{}
      :telemetry.execute(@telemetry_prefix ++ [:waiting], %{}, %{facts: facts})
      {:waiting, facts}
    else
      {:error, reason} ->
        :telemetry.execute(@telemetry_prefix ++ [:fail], %{}, %{reason: reason})
        {:error, reason}
    end
  end

  @doc """
  基于 `node_def`、升序历史信号列表 `prior_signal_types` 与当前 `signal` 纯函数推导门控进度。

  严格按拓扑顺序逐个消费 `"workflow.<step_id>"` 信号：
  - 所有步骤均已按序放行：`{:ok, %{}}`
  - 仍有剩余步骤未放行：`{:waiting, %{}}`
  - `node_def` 无效：`{:error, reason}`
  """
  @spec resume(map() | nil, [term()], map() | String.t() | nil) ::
          {:ok, map()} | {:waiting, map()} | {:error, term()}
  def resume(node_def, prior_signal_types, signal) when is_list(prior_signal_types) do
    case validate_and_order_steps(node_def) do
      {:ok, ordered_steps} ->
        all_signals = prior_signal_types ++ [extract_signal_type(signal)]

        remaining =
          Enum.reduce(all_signals, ordered_steps, fn
            _sig, [] ->
              []

            sig, [%{"id" => step_id} | rest] = pending ->
              if is_binary(sig) and sig == "workflow.#{step_id}", do: rest, else: pending
          end)

        facts = %{}

        case remaining do
          [] ->
            :telemetry.execute(@telemetry_prefix ++ [:complete], %{}, %{facts: facts})
            {:ok, facts}

          _ ->
            :telemetry.execute(@telemetry_prefix ++ [:waiting], %{}, %{facts: facts})
            {:waiting, facts}
        end

      {:error, reason} ->
        :telemetry.execute(@telemetry_prefix ++ [:fail], %{}, %{reason: reason})
        {:error, reason}
    end
  end

  defp extract_signal_type(sig) when is_binary(sig), do: sig
  defp extract_signal_type(%{"signal_type" => sig}) when is_binary(sig), do: sig
  defp extract_signal_type(%{signal_type: sig}) when is_binary(sig), do: sig
  defp extract_signal_type(_), do: nil
end
