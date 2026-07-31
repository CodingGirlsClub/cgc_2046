defmodule Cgc2046Web.Router do
  use Cgc2046Web, :router

  import Cgc2046Web.AuthPlug

  pipeline :api do
    plug :accepts, ["json"]
    # T05 审计:每次 API 请求(成功或失败)落审计记录;放最前,用
    # register_before_send 保证即使后续 401/403 halt 也会写入。
    plug Cgc2046Web.AuditMiddleware
  end

  pipeline :graphql do
    plug AshGraphql.Plug
  end

  pipeline :bearer_auth do
    plug :load_from_bearer
    # T07:JWT 会话认证失败后,尝试 ApiToken 机器凭证(每请求白名单校验,
    # 撤销/过期即时全局失效;绑定 workspace 不一致 → 403)
    plug Cgc2046Web.ApiTokenAuth
  end

  pipeline :require_auth do
    plug Cgc2046Web.RequireAuth
  end

  scope "/api", Cgc2046Web do
    pipe_through [:api, :graphql]

    forward "/graphql",
            Absinthe.Plug,
            [schema: Module.concat(["Cgc2046Web.GraphqlSchema"])],
            alias: false
  end

  scope "/api/v1", Cgc2046Web do
    pipe_through [:api, :bearer_auth, :require_auth]

    get "/me", MeController, :show

    # T07 ApiToken 机器凭证(签发 = workspace 成员为自己签发;撤销 = 仅本人)
    post "/workspaces/:workspace_id/api_tokens", ApiTokensController, :create
    post "/workspaces/:workspace_id/api_tokens/:id/revoke", ApiTokensController, :revoke

    # T06 发现列表(仅 open/request 可见;invite_only 私密)+ 创建
    get "/workspaces", WorkspacesController, :index
    post "/workspaces", WorkspacesController, :create
    # T06 加入流程(open 直接加入 / request 提交申请 / invite_only 仅链接)
    post "/workspaces/:workspace_id/join", WorkspacesController, :join

    # T06 JoinRequest 审批流程(spec §12)
    get "/workspaces/:workspace_id/join_requests", JoinRequestsController, :index
    post "/workspaces/:workspace_id/join_requests", JoinRequestsController, :create
    post "/workspaces/:workspace_id/join_requests/:id/approve", JoinRequestsController, :approve
    post "/workspaces/:workspace_id/join_requests/:id/reject", JoinRequestsController, :reject

    # T06 Profile CRUD(租户内可见,写=本人)
    get "/workspaces/:workspace_id/profiles", ProfilesController, :index
    get "/workspaces/:workspace_id/profiles/:user_id", ProfilesController, :show
    post "/workspaces/:workspace_id/profiles", ProfilesController, :create
    patch "/workspaces/:workspace_id/profiles/:user_id", ProfilesController, :update
    delete "/workspaces/:workspace_id/profiles/:user_id", ProfilesController, :delete

    # T05 审计查询(spec §11 读隔离)
    get "/audit_logs", AuditLogsController, :index
    get "/workspaces/:workspace_id/audit_logs", AuditLogsController, :workspace_index

    # T05 Workflow / Step(spec §4:workflow:create;Step 执行=角色交集非空)
    # T08:workflows create 升级为 DSL 部署(workflow:deploy,幂等);archive 归档;
    #      step execute 顺序解锁;step complete 标记完成
    post "/workspaces/:workspace_id/workflows", WorkflowsController, :create
    post "/workspaces/:workspace_id/workflows/:id/archive", WorkflowsController, :archive
    post "/workspaces/:workspace_id/workflows/:workflow_id/steps", StepsController, :create
    post "/workspaces/:workspace_id/steps/:step_id/execute", StepsController, :execute
    post "/workspaces/:workspace_id/steps/:step_id/complete", StepsController, :complete

    # T05 Agent(个人=owner;公共增删改按权限矩阵)
    post "/workspaces/:workspace_id/agents", AgentsController, :create
    patch "/workspaces/:workspace_id/agents/:id", AgentsController, :update
    delete "/workspaces/:workspace_id/agents/:id", AgentsController, :destroy

    # T05 邀请(spec §12:invitation:create;Volunteer 不可预授权 Admin 级角色)
    post "/workspaces/:workspace_id/invitations", InvitationsController, :create
    # T06 邀请消费(凭 token 加入)/ 撤销(置 revoked 立即失效)
    post "/workspaces/:workspace_id/invitations/consume", InvitationsController, :consume
    post "/workspaces/:workspace_id/invitations/:id/revoke", InvitationsController, :revoke
  end

  scope "/api" do
    pipe_through :graphql

    forward "/playground",
            Absinthe.Plug.GraphiQL,
            [schema: Module.concat(["Cgc2046Web.GraphqlSchema"]), interface: :playground],
            alias: false
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:cgc_2046, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:fetch_session, :protect_from_forgery]

      live_dashboard "/dashboard", metrics: Cgc2046Web.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
