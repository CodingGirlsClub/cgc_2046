defmodule Cgc2046.Policies.OwnUser do
  @moduledoc """
  User 写授权：actor 是目标用户本人（`changeset.data.id == actor.id`）。

  用于 `update_display_name`（ADR-0004：displayName 保留全局身份字段，仅本人可改）。

  使用 SimpleCheck 而非 expr：expr(FilterCheck) 在 update 动作的 strict 阶段
  无法对字段引用求值（:unknown），SimpleCheck 在 strict 阶段即可访问
  changeset.data 判定。
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is the subject user (changeset.data.id == actor.id)"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{subject: %Ash.Changeset{data: %{id: id}}}, _opts) when not is_nil(id) do
    {:ok, actor.id == id}
  end

  def match?(_actor, _context, _opts), do: false
end
