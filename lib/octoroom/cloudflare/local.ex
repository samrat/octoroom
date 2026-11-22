defmodule Octoroom.Cloudflare.Local do
  @moduledoc """
  An in-process, localhost-only `Octoroom.Cloudflare` SFU backed by `ex_webrtc`.

  Intended for trying Octoroom locally without a Cloudflare Realtime SFU
  account. Each session runs an `ExWebRTC.PeerConnection` on host candidates
  (no STUN/TURN) and forwards audio (`:opus`) and video (`:vp8`) RTP packets
  between sessions through ETS.

  Configure it in dev with:

      config :octoroom,
        cloudflare: [client: Octoroom.Cloudflare.Local],
        ice_servers: []

  Not for production: there is no TURN, no clustering, and sessions live only
  inside this BEAM node.
  """

  @behaviour Octoroom.Cloudflare

  use Supervisor

  alias Octoroom.Cloudflare.Local.{Session, Store}

  @default_name __MODULE__

  @doc "Starts a local SFU instance (started automatically by `Octoroom.Application`)."
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, @default_name)
    Supervisor.start_link(__MODULE__, name, name: name)
  end

  @doc "Returns a `cloudflare` config map targeting this local SFU instance."
  def config(name \\ @default_name), do: %{client: __MODULE__, local: name}

  @impl true
  def init(name) do
    children = [
      {Store, name: store_name(name)},
      {DynamicSupervisor, name: sup_name(name), strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  ## Octoroom.Cloudflare callbacks

  @impl true
  def new_session(config) do
    name = instance(config)
    tables = Store.tables(store_name(name))
    session_id = "local-" <> Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)

    case DynamicSupervisor.start_child(
           sup_name(name),
           {Session, session_id: session_id, tables: tables}
         ) do
      {:ok, _pid} -> {:ok, session_id}
      error -> error
    end
  end

  @impl true
  def push_tracks(config, session_id, offer, tracks) do
    with_session(config, session_id, &Session.push_tracks(&1, offer, tracks))
  end

  @impl true
  def pull_tracks(config, session_id, tracks) do
    with_session(config, session_id, &Session.pull_tracks(&1, tracks))
  end

  @impl true
  def renegotiate(config, session_id, answer) do
    with_session(config, session_id, &Session.renegotiate(&1, answer))
  end

  @impl true
  def close_tracks(config, session_id, mids, offer) do
    with_session(config, session_id, &Session.close_tracks(&1, mids, offer))
  end

  @impl true
  def session_state(config, session_id) do
    case lookup_session(config, session_id) do
      {:ok, pid} -> Session.session_state(pid)
      :error -> {:error, :disconnected}
    end
  end

  @doc false
  def close_session(config, session_id) do
    case lookup_session(config, session_id) do
      {:ok, pid} -> Session.stop(pid)
      :error -> :ok
    end
  end

  defp with_session(config, session_id, fun) do
    case lookup_session(config, session_id) do
      {:ok, pid} ->
        try do
          fun.(pid)
        catch
          :exit, _ -> {:error, :disconnected}
        end

      :error ->
        {:error, :disconnected}
    end
  end

  defp lookup_session(config, session_id) do
    tables = Store.tables(store_name(instance(config)))

    case :ets.lookup(tables.sessions, session_id) do
      [{^session_id, pid, _pc}] ->
        if Process.alive?(pid), do: {:ok, pid}, else: :error

      [] ->
        :error
    end
  end

  defp instance(config), do: Map.get(config, :local, @default_name)
  defp store_name(name), do: Module.concat(name, Store)
  defp sup_name(name), do: Module.concat(name, SessionSupervisor)
end

defmodule Octoroom.Cloudflare.Local.Store do
  @moduledoc false

  use GenServer

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, name, name: name)
  end

  def tables(name), do: GenServer.call(name, :tables)

  @impl true
  def init(_name) do
    tables = %{
      sessions: :ets.new(:octoroom_local_sessions, [:set, :public, read_concurrency: true]),
      tracks: :ets.new(:octoroom_local_tracks, [:set, :public, read_concurrency: true]),
      subs: :ets.new(:octoroom_local_subs, [:bag, :public, read_concurrency: true])
    }

    {:ok, tables}
  end

  @impl true
  def handle_call(:tables, _from, tables), do: {:reply, tables, tables}
end
