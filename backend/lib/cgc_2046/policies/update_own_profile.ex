defmodule Cgc2046.Policies.UpdateOwnProfile do
  @moduledoc """
  用户只能更新自己的个人资料（#68）。

  使用 SimpleCheck 而非 expr：expr(FilterCheck) 在 update 动作的 strict 阶段
  无法对字段引用求值（:unknown），无法在 strict 阶段完成授权判定。
  SimpleCheck 在 strict 阶段即可访问 changeset.data 判定。

  注意：User 资源不能使用 `policy always() forbid_if(always())` 做默认拒绝，
  否则 Ash 表达式求解会把本 check 从授权要求中吸收（#68 已踩坑）。
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
