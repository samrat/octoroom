import Config

if config_env() == :test do
  config :logger, level: :warning
  config :octoroom, store: {Octoroom.Store.ETS, path: nil}, janitor: [enabled: false]
end
