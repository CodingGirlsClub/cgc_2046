defmodule Cgc2046Web.Router do
  use Cgc2046Web, :router

  import Cgc2046Web.AuthPlug

  pipeline :api do
    plug :accepts, ["json"]
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
