defmodule Cgc2046.Policies.PlatformAdmin do
  @moduledoc """
  判断 actor 是否为平台管理员（Platform Admin）——`is_platform_admin` 判定的唯一真源。

  平台管理员 = User 上的全局布尔标记（非租户角色，可多人，见 CONTEXT.md「平台管理员」）。
  ≥1 名平台管理员不变量由 `User :demote_platform_admin` action 守卫，不在本模块。

  ## 双面契约（policy 面 vs 能力面，刻意不同答）

  - **policy 面（本 check）**：跨租户治理读取放行。各资源 read policy 中的
    `authorize_if(Cgc2046.Policies.PlatformAdmin)` 允许非成员平台管理员读取
    成员列表/审计/工作流等治理数据——成员列表放行是 load-bearing（实 bug
    `7f925b7`：缺它 admin 详情页成员列表为空 → 误报「Owner 未就位」）。
  - **能力面（Rbac abilities / myAbilities）**：工作台壳 affordance。
    不给非成员平台管理员管理类 ability（list_members/manage_members/assign_roles/manage_events，
    #66 P2 方向①）——治理读取 ≠ 在工作台壳里开管理入口。

  修改任一面前先读对面。能力面入口见 `Cgc2046.Rbac.abilities_for/2`。

  本模块两个 surface：Ash check interface（`match?/3`，policy 语境）+
  纯谓词 `platform_admin?/1`（plug/live/graphql/change 等命令式语境），nil-safe。
  """
  use Ash.Policy.SimpleCheck

  @impl true
  def describe(_opts), do: "actor is a platform admin"

  @impl true
  def match?(nil, _context, _opts), do: false
  def match?(actor, _context, _opts), do: platform_admin?(actor)

  @doc "平台管理员谓词：nil 与缺失字段一律 false（fail-closed）。"
  def platform_admin?(nil), do: false
  def platform_admin?(actor), do: Map.get(actor, :is_platform_admin, false) == true
end
