import Config

# OCTOROOM_CLOUDFLARE_APP_ID / OCTOROOM_CLOUDFLARE_APP_SECRET: a Cloudflare
# Realtime SFU app. A `.env` file next to mix.exs is read too.
env_file = Path.expand("../.env", __DIR__)

# KEY=value, KEY="value" or KEY='value', as a shell reads them.
unquote_value = fn value ->
  case Regex.run(~r/^(["'])(.*)\1$/, value) do
    [_, _quote, inner] -> inner
    nil -> value
  end
end

file_env =
  if File.exists?(env_file) do
    for line <- File.read!(env_file) |> String.split("\n"),
        [key, value] <- [String.split(String.trim(line), "=", parts: 2)],
        into: %{},
        do: {key, unquote_value.(String.trim(value))}
  else
    %{}
  end

fetch = fn key -> System.get_env(key) || file_env[key] end

app_id = fetch.("OCTOROOM_CLOUDFLARE_APP_ID")
app_secret = fetch.("OCTOROOM_CLOUDFLARE_APP_SECRET")

if app_id not in [nil, ""] and app_secret not in [nil, ""] do
  config :octoroom,
    cloudflare: [
      app_id: app_id,
      app_secret: app_secret
    ]
else
  IO.puts(
    "Octoroom: no Cloudflare credentials set — using Octoroom.Cloudflare.Local (localhost dev SFU)."
  )

  config :octoroom,
    cloudflare: [client: Octoroom.Cloudflare.Local],
    ice_servers: []
end

# SONIOX_API_KEY: for live captions (optional).
config :call, soniox_api_key: fetch.("SONIOX_API_KEY")

port = String.to_integer(System.get_env("PORT") || "4300")

# OCTOROOM_STORE: where the room store's snapshot lives, so rooms survive a
# restart of this app. Defaults to one per port in tmp/ (matching examples/meet
# and examples/agent) so other local servers don't overwrite the snapshot.
store_path =
  fetch.("OCTOROOM_STORE") || Path.expand("../tmp/octoroom-#{port}.store", __DIR__)

config :octoroom, store: {Octoroom.Store.ETS, path: store_path}

if System.get_env("PORT"),
  do: config(:call, Call.Endpoint, http: [port: port])
