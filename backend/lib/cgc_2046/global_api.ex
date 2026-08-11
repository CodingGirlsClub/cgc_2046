defmodule Cgc2046.GlobalApi do
  use Ash.Domain,
    otp_app: :cgc_2046,
    extensions: [AshGraphql.Domain, AshAdmin.Domain]

  admin do
    # Phase 6 / R12：AshAdmin /ops/admin 暴露该 Domain（安全门控由 :admin_browser pipeline
    # 的 PlatformAdminPlug 承担，不依赖 ash_admin actor 机制）
    show?(true)
  end

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

    # Platform Admin Dashboard R6/R7：工作台创建申请（全局资源，platform_admin 审批）
    resource(Cgc2046.Accounts.WorkspaceApplication)
    resource(Cgc2046.Miniprogram.Code)
    resource(Cgc2046.Miniprogram.NotificationConsent)
  end
end
