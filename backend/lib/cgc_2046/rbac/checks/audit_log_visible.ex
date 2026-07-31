defmodule Cgc2046.Rbac.Checks.AuditLogVisible do
  @moduledoc """
  审计读隔离(T05,spec §11):行级 filter 兼容 check。

  可见记录 = **actor 自己的** 或 **actor 拥有 `audit:view` 的 workspace 的**。
  - 用户查自己的:任何成员
  - Owner/Admin 查 workspace 的:`audit:view`(见 Rbac 默认权限)

  AuditLog 是全局资源(无多租户),必须用 filter 表达式做行级隔离
  (SimpleCheck 是 query 级,无法表达)。`filter/3` 在 policy 求值时执行一次,
  返回表达式附加到查询。
  """

  use Ash.Policy.FilterCheck

  @impl true
  def filter(nil, _authorizer, _opts), do: expr(false)

  def filter(actor, _authorizer, _opts) do
    import Ecto.Query

    workspace_ids =
      Cgc2046.Repo.all(
        from m in "workspace_memberships",
          where: m.user_id == type(^actor.id, Ecto.UUID),
          select: m.workspace_id
      )
      |> Enum.filter(&Cgc2046.Rbac.can?(actor, "audit:view", tenant: &1))

    expr(actor_id == ^actor.id or workspace_id in ^workspace_ids)
  end

  @impl true
  def describe(_opts), do: "审计可见:自己的记录,或拥有 audit:view 的 workspace 的记录"
end
