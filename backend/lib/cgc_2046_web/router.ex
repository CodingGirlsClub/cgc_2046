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
    post "/workspaces", WorkspacesController, :create

    # T05 审计查询(spec §11 读隔离)
    get "/audit_logs", AuditLogsController, :index
    get "/workspaces/:workspace_id/audit_logs", AuditLogsController, :workspace_index

    # T05 Workflow / Step(spec §4:workflow:create;Step 执行=角色交集非空)
    post "/workspaces/:workspace_id/workflows", WorkflowsController, :create
    post "/workspaces/:workspace_id/workflows/:workflow_id/steps", StepsController, :create
    post "/workspaces/:workspace_id/steps/:step_id/execute", StepsController, :execute

    # T05 Agent(个人=owner;公共增删改按权限矩阵)
    post "/workspaces/:workspace_id/agents", AgentsController, :create
    patch "/workspaces/:workspace_id/agents/:id", AgentsController, :update
    delete "/workspaces/:workspace_id/agents/:id", AgentsController, :destroy

    # T05 邀请(spec §12:invitation:create;Volunteer 不可预授权 Admin 级角色)
    post "/workspaces/:workspace_id/invitations", InvitationsController, :create
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
