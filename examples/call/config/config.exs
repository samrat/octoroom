import Config

config :call, Call.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4300],
  server: true,
  # A demo key: this app has no sessions or cookies worth protecting.
  secret_key_base: String.duplicate("octoroom-call-demo-", 4),
  live_view: [signing_salt: "octoroom-call"],
  pubsub_server: Call.PubSub,
  check_origin: false,
  render_errors: [formats: [html: Call.ErrorHTML], layout: false]

config :phoenix, :json_library, Jason
config :logger, level: :info
