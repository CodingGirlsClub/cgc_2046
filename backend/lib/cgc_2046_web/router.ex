defmodule Cgc2046Web.Router do
  use Cgc2046Web, :router

  import Cgc2046Web.AuthPlug
  import Phoenix.LiveView.Router

  # #297.1：GraphQL 查询成本限制（非 dev 生效，照 GraphqlIntrospectionGuard 先例）。
  # 现网最大操作 complexity ~28，250 上限留约 9 倍余量；超限错误自带实际/上限值，撞线可诊断。
  # token_limit 在 lexer 层挡 MB 级 document（别名/字段炸弹的原始形态）——complexity
  # 分析发生在 parse 之后，解析开销须先截断。三选项经 @raw_options 透传进 document
  # pipeline，与 introspection guard 的 pipeline modifier 无冲突。dev（Playground）放行。
  @dev_routes Application.compile_env(:cgc_2046, :dev_routes, false)

  @graphql_abuse_opts (if @dev_routes do
                         []
                       else
                         [
                           analyze_complexity: true,
                           max_complexity: 250,
                           token_limit: 5_000
                         ]
                       end)

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
    plug(Cgc2046Web.Plugs.WechatStatePlug)
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

  # Kamal 零停机部署的健康检查（无鉴权、无 DB 依赖：DB 未就绪时
  # 不应阻止容器就绪——Phoenix 起得来即视为可切流，DB 故障由监控告警）
  scope "/healthz", Cgc2046Web do
    pipe_through(:api)

    get("/", HealthController, :show)
  end

  scope "/mcp" do
    pipe_through(:mcp)

    forward("/", Anubis.Server.Transport.StreamableHTTP.Plug, server: Cgc2046.Mcp.Server)
  end

  # 渠道回调（缴费闭环 U6，KTD4）：不过 :graphql（无 actor），鉴权 = 渠道验签；
  # raw body 验签依赖 endpoint 全局 body_reader 缓存（CachingBodyReader）。
  pipeline :webhooks do
    plug(:accepts, ["json"])
  end

  scope "/api/payments/webhooks", Cgc2046Web do
    pipe_through(:webhooks)

    post("/:provider", PaymentWebhookController, :handle)
  end

  scope "/api", Cgc2046Web do
    pipe_through([:api, :graphql])

    forward(
      "/graphql",
      Absinthe.Plug,
      [
        schema: Module.concat(["Cgc2046Web.GraphqlSchema"]),
        before_send: {Cgc2046Web.Plugs.AuthCookiePlug, :before_send},
        # VULN-001（#81）：非 dev 拒绝 __schema/__type introspection
        pipeline: {Cgc2046Web.Plug.GraphqlIntrospectionGuard, :pipeline}
      ] ++ @graphql_abuse_opts,
      alias: false
    )
  end

  # Phase 6 / R12：AshAdmin 挂载（ops 调试面）。
  # 门控双层（P0 修复）：HTTP 层 :admin_browser pipeline 末尾 PlatformAdminPlug
  # 挡首帧渲染；live_session WebSocket 通道独立于 HTTP pipeline，必须用
  # PlatformAdminLiveAuth on_mount 在 mount 生命周期再校验（否则普通用户可经
  # WebSocket 直连绕过）。session 由 session_data/1 在 HTTP 层注入 current_user_id。
  scope "/ops" do
    import AshAdmin.Router

    pipe_through([:admin_browser])

    ash_admin("/admin",
      on_mount: [Cgc2046Web.Live.PlatformAdminLiveAuth],
      session: {Cgc2046Web.Live.PlatformAdminLiveAuth, :session_data, []},
      # WebSocket 走 /ops/live（endpoint 已挂）——与 path 路由前缀一致
      live_socket_path: "/ops/live"
    )
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
