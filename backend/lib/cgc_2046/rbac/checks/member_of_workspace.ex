defmodule Cgc2046.Rbac.Checks.MemberOfWorkspace do
  @moduledoc """
  Policy check:actor 是该 workspace 的成员,或平台管理员(全局放行读)。

  用于租户资源的读/退出类判定。平台管理员是全局管理员,可访问任意
  workspace 的租户资源(读),但**不**因此获得租户角色权限(见 HasPermission)。

  tenant 从 policy context 的 subject(query/changeset)提取
  (Ash.Policy.SimpleCheck 的 context 是 `%Ash.Policy.Authorizer{}`,
  attribute 多租户的 tenant 落在 subject 上)。
  """

  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is a member of the workspace (or a platform admin)"

  @impl true
  def match?(nil, _context, _opts), do: false

  def match?(actor, context, _opts) do
    case Cgc2046.Rbac.Checks.Tenant.from(context) do
      tenant when is_binary(tenant) ->
        Map.get(actor, :is_platform_admin, false) or Cgc2046.Rbac.member?(actor, tenant)

      _ ->
        false
    end
  end
end
