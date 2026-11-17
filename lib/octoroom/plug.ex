defmodule Octoroom.Plug do
  @moduledoc """
  Serves the WebSockets Cloudflare's adapters dial for server-side workers:
  `<path>/ingest/<id>` and `<path>/egress/<id>`. Requests outside `path` pass
  through untouched, so it can sit in an endpoint's plug list:

      plug Octoroom.Plug, path: "/octoroom"

  `config :octoroom, public_ws_url: ...` must be the public `wss://` URL of
  `path`. Ids are unguessable and only registered while their owner lives;
  unknown ids get a 404.
  """

  @behaviour Plug

  require Logger

  alias Octoroom.Adapter

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, "/")
    %{prefix: String.split(path, "/", trim: true)}
  end

  @impl true
  def call(conn, %{prefix: prefix}) do
    case Enum.split(conn.path_info, length(prefix)) do
      {^prefix, [role, id]} when role in ["ingest", "egress"] ->
        upgrade(conn, role, id)

      {^prefix, rest} ->
        # Under our path but not an adapter URL: pass it on, but say so,
        # since a refused adapter dial otherwise leaves no trace.
        Logger.warning(
          "Octoroom.Plug ignoring #{conn.method} #{conn.request_path} (#{inspect(rest)})"
        )

        conn

      _ ->
        conn
    end
  end

  defp upgrade(conn, role, id) do
    role = String.to_existing_atom(role)

    case Adapter.lookup(role, id) do
      nil ->
        Logger.warning("Octoroom.Plug: no #{role} adapter is registered as #{id}")
        conn |> Plug.Conn.send_resp(404, "not found") |> Plug.Conn.halt()

      owner ->
        # An ingest socket only sends, so it must not time out for lack of
        # incoming data; it closes when its owner stops.
        conn
        |> WebSockAdapter.upgrade(Adapter.Socket, %{role: role, owner: owner}, timeout: :infinity)
        |> Plug.Conn.halt()
    end
  rescue
    error in WebSockAdapter.UpgradeError ->
      Logger.warning("Octoroom.Plug refused #{conn.request_path}: #{Exception.message(error)}")
      conn |> Plug.Conn.send_resp(400, Exception.message(error)) |> Plug.Conn.halt()
  end
end
