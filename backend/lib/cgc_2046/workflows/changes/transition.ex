defmodule Cgc2046.Workflows.Changes.Transition do
  @moduledoc """
  状态迁移守卫 change（PR-G；plan 2026-08-15-008 决策 D1-D7）。

  workflow_run 状态迁移 action 的纯声明式守卫：
  `status ∈ from` → `force_change :status = to`；否则 `add_error`（错误串逐字保持
  现有格式「cannot <verb> from status=<s>」，verb = action 名）。

  用法（编译期字面量）：

      change {Cgc2046.Workflows.Changes.Transition, from: [:running, :waiting], to: :succeeded}

  - `from`：允许的起始 status 列表（必填）。
  - `to`：目标 status（必填）。
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    from = Keyword.fetch!(opts, :from)
    to = Keyword.fetch!(opts, :to)

    case Ash.Changeset.get_data(changeset, :status) do
      status ->
        if Enum.member?(from, status) do
          Ash.Changeset.force_change_attribute(changeset, :status, to)
        else
          Ash.Changeset.add_error(changeset, "cannot #{verb(changeset)} from status=#{status}")
        end
    end
  end

  # 错误串 verb = action 名（「cannot <verb> from status=<s>」逐字保持现有格式；
  # action 缺失为编程错误，兜底不崩）。
  defp verb(%{action: %{name: name}}), do: to_string(name)
  defp verb(_changeset), do: "transition"
end
