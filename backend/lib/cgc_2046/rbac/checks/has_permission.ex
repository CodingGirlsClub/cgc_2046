defmodule Cgc2046.Rbac.Checks.HasPermission do
  @moduledoc """
  Policy check:actor 在租户内拥有指定权限(多角色权限并集判定)。

  opts 必传 `:permission`(string 或 atom)。平台管理员**不**自动放行:
  平台管理员只保证"能读到租户数据",写操作仍需租户角色权限。

  tenant 从 policy context 的 subject(query/changeset)提取
  (Ash.Policy.SimpleCheck 的 context 是 `%Ash.Policy.Authorizer{}`,
  attribute 多租户的 tenant 落在 subject 上)。
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(opts), do: "actor has permission #{inspect(opts[:permission])} in the workspace"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, context, opts) do
    case Cgc2046.Rbac.Checks.Tenant.from(context) do
      tenant when is_binary(tenant) ->
        Cgc2046.Rbac.can?(actor, opts[:permission], tenant: tenant)

      _ ->
        false
    end
  end
end
