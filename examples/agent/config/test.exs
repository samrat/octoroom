import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :hello, HelloWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "EoYZ7kuBQThBIEGvdhwWkESdNWzw9sAMz1QrkDsGIuTadDjX9b7QfWEaqbp4X+iS",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Keep the room store in memory: a snapshot file would be the dev server's
# (both run as nonode@nohost), and a test run would overwrite it.
config :octoroom, store: {Octoroom.Store.ETS, path: nil}, janitor: [enabled: false]
