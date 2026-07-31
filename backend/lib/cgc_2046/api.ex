defmodule Cgc2046.Api do
  @moduledoc """
  租户域(Tenant Api):承载按 `workspace_id` 隔离的租户资源 ——
  WorkspaceMembership、MembershipRole、Role、Workflow、Step、Agent、
  AgentRun、Invitation、JoinRequest、Profile 等。

  租户资源在资源级声明 `multitenancy strategy: :attribute, attribute: :workspace_id`,
  查询/写入必须显式 set_tenant(见 docs/multitenancy-调研.md 决策点)。

  T01 阶段仅接线,资源由后续票据注册:
  - T04 成员与角色:Role / WorkspaceMembership / MembershipRole
  - 其余资源随 M1/M2 里程碑落地。

  GraphQL 出口:`authorize? false` 仅为脚手架默认,严格授权链(T05)落地后
  改为真实授权判定。
  """

  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshGraphql.Domain]

  graphql do
    authorize?(false)
  end

  resources do
    # 租户资源在此注册(按票据顺序):
    # T03 Workspace 与多租户地基:WorkspaceMembership 最小骨架(隔离验证载体,T04 扩展)
    resource Cgc2046.Workspaces.WorkspaceMembership
    # resource Cgc2046.Resources.MembershipRole
    # resource Cgc2046.Resources.Role
  end
end
