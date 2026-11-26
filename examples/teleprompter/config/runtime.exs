import Config

env_file = Path.expand("../.env", __DIR__)

unquote_value = fn value ->
  case Regex.run(~r/^(["'])(.*)\1$/, value) do
    [_, _quote, inner] -> inner
    nil -> value
  end
end

file_env =
  if File.exists?(env_file) do
    for line <- File.read!(env_file) |> String.split("\n"),
        trimmed = String.trim(line),
        trimmed != "" and not String.starts_with?(trimmed, "#"),
        [key, value] <- [String.split(trimmed, "=", parts: 2)],
        into: %{},
        do: {String.trim(key), unquote_value.(String.trim(value))}
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

for key <- ~w(OPENROUTER_API_KEY ASSEMBLY_AI_API_KEY SONIOX_API_KEY),
    value = fetch.(key),
    value not in [nil, ""],
    do: System.put_env(key, value)

port = String.to_integer(System.get_env("PORT") || "4360")

store_path =
  fetch.("OCTOROOM_STORE") || Path.expand("../tmp/octoroom-#{port}.store", __DIR__)

config :octoroom, store: {Octoroom.Store.ETS, path: store_path}

if System.get_env("PORT"),
  do: config(:teleprompter, Teleprompter.Endpoint, http: [port: port])
