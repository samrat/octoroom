import Config

config :teleprompter, Teleprompter.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  http: [ip: {127, 0, 0, 1}, port: 4360],
  server: config_env() != :test,
  # A demo key: this app has no sessions or cookies worth protecting.
  secret_key_base: String.duplicate("octoroom-teleprompter-demo-", 3),
  live_view: [signing_salt: "octoroom-teleprompter"],
  pubsub_server: Teleprompter.PubSub,
  check_origin: false,
  render_errors: [formats: [html: Teleprompter.ErrorHTML], layout: false]

config :phoenix, :json_library, Jason

# Octoroom's workers use ex_webrtc, whose libsrtp is built against the
# system's (`brew install srtp`; see Octoroom's README).
config :bundlex, :disable_precompiled_os_deps, apps: [:ex_libsrtp]
config :logger, level: :info
