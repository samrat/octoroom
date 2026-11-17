import Config

# ex_libsrtp's precompiled libsrtp links a libcrypto that Homebrew doesn't
# put on the default path, so it fails to load; build against the system's
# libsrtp instead (`brew install srtp`, or libsrtp2-dev on Debian/Ubuntu).
config :bundlex, :disable_precompiled_os_deps, apps: [:ex_libsrtp]

if config_env() == :test do
  config :logger, level: :warning
  config :octoroom, store: {Octoroom.Store.ETS, path: nil}, janitor: [enabled: false]
end
