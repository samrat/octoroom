defmodule Octoroom.Adapter do
  @moduledoc false

  # Registration of the processes that own adapter sockets, by role and an
  # unguessable id. `Octoroom.Plug` only upgrades requests for registered ids.

  @registry Octoroom.Registry

  def new_id, do: Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

  def register(role, id) when role in [:ingest, :egress],
    do: Registry.register(@registry, {:adapter, role, id}, nil)

  def lookup(role, id) do
    case Registry.lookup(@registry, {:adapter, role, id}) do
      [{pid, _} | _] -> pid
      [] -> nil
    end
  end

  @doc "The URL Cloudflare dials for `role` and `id`, under `public_ws_url`."
  def url(public_ws_url, role, id),
    do: "#{String.trim_trailing(public_ws_url, "/")}/#{role}/#{id}"
end
