defmodule Cgc2046.Workflows.LearningProgress do
  @moduledoc """
  学习 workflow 进度投影的纯函数。

  执行拓扑来自 `WorkflowDefinition.node_def`；步骤标题来自独立的 `Step` 资源。
  两者只通过 `node_def.steps[].id == step.step_key` 关联，facts 只按 step key
  判断是否已完成。

  另承载学习 run 停滞口径（E-9 #122 补差同源常量）：`stagnant_cutoff/1` 同时是
  `LearningProgressWorker` 停滞提醒（D6-③）与 E-10 对账规则⑦
  `learning_run_stalled` 的判定基准——两消费方只引用，不各自定义阈值。
  """

  # 停滞阈值（天，D6-③）：LearningProgressWorker 提醒与 ReconciliationScanWorker
  # 规则⑦同源——修改只在此一处。
  @stagnation_threshold_days 7

  @doc "学习 run 停滞阈值（天；D6-③ 口径，提醒与对账规则⑦同源）"
  def stagnation_threshold_days, do: @stagnation_threshold_days

  @doc """
  停滞判定 cutoff：`updated_at` 早于 cutoff（严格小于，7 天）视为停滞。
  与 LearningProgressWorker 停滞提醒（D6-③）同一判定；E-10 对账规则⑦复用。
  """
  @spec stagnant_cutoff(DateTime.t()) :: DateTime.t()
  def stagnant_cutoff(now \\ DateTime.utc_now()) do
    DateTime.add(now, -@stagnation_threshold_days, :day)
  end

  @type step :: %{optional(:step_key | String.t()) => term()}

  @spec project(
          String.t(),
          String.t(),
          String.t() | nil,
          atom() | String.t(),
          map(),
          [step()],
          map() | nil
        ) :: %{
          run_id: String.t(),
          enrollment_id: String.t(),
          target_title: String.t() | nil,
          status: String.t(),
          completed_manual_steps: non_neg_integer(),
          total_manual_steps: non_neg_integer(),
          current_step_title: String.t() | nil
        }
  def project(run_id, enrollment_id, target_title, status, node_def, steps, facts) do
    manual_steps = manual_steps(node_def)
    facts = if is_map(facts), do: facts, else: %{}
    titles = step_titles(steps)

    %{
      run_id: run_id,
      enrollment_id: enrollment_id,
      target_title: target_title,
      status: to_string(status),
      completed_manual_steps: Enum.count(manual_steps, &Map.has_key?(facts, &1)),
      total_manual_steps: length(manual_steps),
      current_step_title: current_step_title(manual_steps, titles, facts)
    }
  end

  defp manual_steps(%{"steps" => steps}) when is_list(steps) do
    Enum.flat_map(steps, fn
      %{"type" => type, "id" => id} when type in ["manual", :manual] and is_binary(id) -> [id]
      %{type: type, id: id} when type in ["manual", :manual] and is_binary(id) -> [id]
      _ -> []
    end)
  end

  defp manual_steps(_node_def), do: []

  defp step_titles(steps) when is_list(steps) do
    Enum.reduce(steps, %{}, fn step, titles ->
      case step_key_and_title(step) do
        {key, title} when is_binary(key) and is_binary(title) -> Map.put(titles, key, title)
        _ -> titles
      end
    end)
  end

  defp step_titles(_steps), do: %{}

  defp step_key_and_title(%{step_key: key, title: title}), do: {key, title}
  defp step_key_and_title(%{"step_key" => key, "title" => title}), do: {key, title}
  defp step_key_and_title(_step), do: nil

  defp current_step_title(manual_steps, titles, facts) do
    case Enum.find(manual_steps, &(not Map.has_key?(facts, &1))) do
      nil -> nil
      step_key -> Map.get(titles, step_key)
    end
  end
end
