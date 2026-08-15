defmodule Cgc2046.Workflows.LearningProgress do
  @moduledoc """
  学习 workflow 进度投影的纯函数。

  执行拓扑来自 `WorkflowDefinition.node_def`；步骤标题来自独立的 `Step` 资源。
  两者只通过 `node_def.steps[].id == step.step_key` 关联，facts 只按 step key
  判断是否已完成。
  """

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
