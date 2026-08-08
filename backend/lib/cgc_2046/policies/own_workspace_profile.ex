defmodule Cgc2046.Policies.OwnWorkspaceProfile do
  @moduledoc """
  WorkspaceProfile 写授权：actor 是该档案本人（`changeset.data.user_id == actor.id`）。

  用 SimpleCheck 而非 expr（与 UpdateOwnProfile 同理）：expr(FilterCheck) 在
  update 动作的 strict 阶段无法对字段引用求值（:unknown），SimpleCheck 在 strict
  阶段即可访问 changeset.data 判定。

  区别于 `UpdateOwnProfile`（User 资源用，检查 `data.id`）：WorkspaceProfile 的
  数据主体是 `user_id`（档案所属成员），`id` 是档案主键。
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is the profile owner (changeset.data.user_id == actor.id)"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, %{subject: %Ash.Changeset{data: %{user_id: user_id}}}, _opts)
      when not is_nil(user_id) do
    {:ok, actor.id == user_id}
  end

  def match?(_actor, _context, _opts), do: false
end
