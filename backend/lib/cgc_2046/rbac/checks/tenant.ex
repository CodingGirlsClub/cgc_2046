defmodule Cgc2046.Rbac.Checks.Tenant do
  @moduledoc """
  共享 helper:从 Ash policy check 的 context 提取 attribute 多租户 tenant。

  `Ash.Policy.SimpleCheck` 的 `match?/3` 第二参数是 `%Ash.Policy.Authorizer{}`
  (defstruct 无 `:tenant` 字段);attribute 多租户的 tenant 落在
  `context.subject`(`%Ash.Query{}` / `%Ash.Changeset{}`)上。无 tenant 返回 nil。
  """

  @doc "从 policy check context 提取 tenant(workspace_id),无则 nil。"
  def from(%{subject: %Ash.Query{tenant: tenant}}), do: tenant
  def from(%{subject: %Ash.Changeset{tenant: tenant}}), do: tenant
  def from(_context), do: nil
end
