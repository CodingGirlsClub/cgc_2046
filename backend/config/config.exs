# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :cgc_2046,
  ecto_repos: [Cgc2046.Repo],
  ash_domains: [Cgc2046.Api, Cgc2046.GlobalApi],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :cgc_2046, AshPostgres,
  repo: Cgc2046.Repo,
  migrations: true

# Configure the endpoint
config :cgc_2046, Cgc2046Web.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: Cgc2046Web.ErrorJSON],
    layout: false
  ],
  pubsub_server: Cgc2046.PubSub,
  live_view: [signing_salt: "HG0TqgPo"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :cgc_2046, Cgc2046.Mailer, adapter: Swoosh.Adapters.Local

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# JWT signing secret for ash_authentication.
# Dev/test use a static dev-only value; prod MUST override via TOKEN_SIGNING_SECRET
# in config/runtime.exs (never commit a real secret).
config :cgc_2046, :token_signing_secret, "dev-only-token-signing-secret-change-me"

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
