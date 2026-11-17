import Config

# OCTOROOM_CLOUDFLARE_APP_ID / OCTOROOM_CLOUDFLARE_APP_SECRET: a Cloudflare
# Realtime SFU app. A `.env` file next to mix.exs is read too.
env_file = Path.expand("../.env", __DIR__)

file_env =
  if File.exists?(env_file) do
    for line <- File.read!(env_file) |> String.split("\n"),
        [key, value] <- [String.split(String.trim(line), "=", parts: 2)],
        into: %{},
        do: {key, String.trim(value, "\"")}
  else
    %{}
  end

fetch = fn key -> System.get_env(key) || file_env[key] end

# OCTOROOM_PUBLIC_WS_URL: the public wss:// URL of Octoroom.Plug's path
# (e.g. wss://abc.trycloudflare.com/octoroom), which Cloudflare dials for
# workers.
config :octoroom,
  public_ws_url: fetch.("OCTOROOM_PUBLIC_WS_URL"),
  cloudflare: [
    app_id: fetch.("OCTOROOM_CLOUDFLARE_APP_ID"),
    app_secret: fetch.("OCTOROOM_CLOUDFLARE_APP_SECRET")
  ]

if port = System.get_env("PORT"),
  do: config(:call, Call.Endpoint, http: [port: String.to_integer(port)])
