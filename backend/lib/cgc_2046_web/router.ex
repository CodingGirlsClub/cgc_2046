defmodule Cgc2046Web.Router do
  use Cgc2046Web, :router

  import Cgc2046Web.AuthPlug
  import Phoenix.LiveView.Router

  pipeline :api do
    plug(:accepts, ["json"])
  end

  # Phase 1 / R12：AshAdmin + 未来 /admin 浏览器路由门控管线。
  # 复用认证管线（AuthCookiePlug + load_from_bearer + load_actor）+ PlatformAdminPlug。
  # put_root_layout 用 AshAdmin.Layouts（前端是 Next.js，无项目级 HTML layout）。
  pipeline :admin_browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:fetch_live_flash)
    plug(:put_root_layout, html: {AshAdmin.Layouts, :root})
    plug(:protect_from_forgery)
    plug(:put_secure_browser_headers)
    plug(Cgc2046Web.Plugs.AuthCookiePlug, :read)
    plug(:load_from_bearer)
    plug(:load_actor)
    plug(Cgc2046Web.Plugs.PlatformAdminPlug)
  end

  pipeline :graphql do
    plug(Cgc2046Web.Plugs.AuthCookiePlug, :read)
    plug(:load_from_bearer)
    plug(Cgc2046Web.Plugs.AuthTokenContextPlug)
    plug(:load_actor)
    plug(AshGraphql.Plug)
  end

  # MCP endpoint（Slice D #42）：独立 Bearer 鉴权（连接 token，非 AshAuthentication token），
  # 不过 :api（anubis transport 自行处理 body/streaming）。
  # McpProtocolCompatPlug 必须在鉴权之前：OpenClacky ≤1.5.6 client 硬编码的旧版
  # protocol header 会在 anubis 协商前 400，先 shim 掉（见该模块 @moduledoc）。
  pipeline :mcp do
    plug(Cgc2046Web.Plugs.McpProtocolCompatPlug)
    plug(Cgc2046Web.Plugs.McpAuthPlug)
  end

  scope "/mcp" do
    pipe_through(:mcp)

    forward("/", Anubis.Server.Transport.StreamableHTTP.Plug, server: Cgc2046.Mcp.Server)
  end

  scope "/api", Cgc2046Web do
    pipe_through([:api, :graphql])

    forward(
      "/graphql",
      Absinthe.Plug,
      [
        schema: Module.concat(["Cgc2046Web.GraphqlSchema"]),
        before_send: {Cgc2046Web.Plugs.AuthCookiePlug, :before_send}
      ],
      alias: false
    )
  end

  # Phase 6 / R12：AshAdmin 挂载（ops 调试面）。
  # 门控由 :admin_browser pipeline 末尾的 PlatformAdminPlug 承担——
  # 非 platform_admin 在 live_session 之前被 403（不依赖 ash_admin actor impersonation）。
  scope "/ops" do
    import AshAdmin.Router

    pipe_through([:admin_browser])
    ash_admin("/admin")
  end

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:cgc_2046, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).

    # Playground (only in dev — GraphQL introspection surface)
    scope "/api" do
      pipe_through(:graphql)

      forward(
        "/playground",
        Absinthe.Plug.GraphiQL,
        [schema: Module.concat(["Cgc2046Web.GraphqlSchema"]), interface: :playground],
        alias: false
      )
    end

    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through([:fetch_session, :protect_from_forgery])

      live_dashboard("/dashboard", metrics: Cgc2046Web.Telemetry)
      forward("/mailbox", Plug.Swoosh.MailboxPreview)
    end
  end
end
