defmodule Cgc2046.GlobalApi do
  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshGraphql.Domain]

  graphql do
    authorize?(true)
  end

  resources do
    # Global resources (User / Workspace) are registered here as the domain model is agreed on.
    resource(Cgc2046.Accounts.User)
    resource(Cgc2046.Accounts.Token)
    # Phase 1 身份基座：小程序平台身份绑定（provider/uid/unionid/user_id）
    resource(Cgc2046.Accounts.UserIdentity)
    resource(Cgc2046.Accounts.Workspace)
    # Tenant-scoped resources (#64): isolated by workspace_id, policies enforced.
    resource(Cgc2046.Accounts.WorkspaceMembership)
    resource(Cgc2046.Accounts.MembershipRole)
    resource(Cgc2046.Accounts.Role)
    # P1-4 G9：用户作品集条目（ADR-0004 后为租户资源，加 workspace_id）
    resource(Cgc2046.Accounts.PortfolioItem)
    # ADR-0004：per-workspace 成员公开资料（租户资源）
    resource(Cgc2046.Accounts.WorkspaceProfile)
    # B-1 #30：加入申请
    resource(Cgc2046.Accounts.JoinRequest)
    # B-2 #31：邀请
    resource(Cgc2046.Accounts.Invitation)
  end
end
