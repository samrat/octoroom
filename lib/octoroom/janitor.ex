defmodule Octoroom.Janitor do
  @moduledoc """
  Closes adapters nothing owns any more, so Cloudflare stops billing them.

  Every adapter is recorded in `Octoroom.Store` with its room and the run
  (one room server's lifetime) that created it, before Cloudflare is asked to
  create it. An adapter is owned while its room is running on this node with
  that same run. Anything else (a room that crashed, a node that restarted)
  is closed at Cloudflare and its record deleted. Closing is idempotent, and
  Cloudflare can't tell us whether a dropped adapter is still billed, so
  closing is always the safe answer.

  It also deletes room records whose room hasn't run for longer than
  `:room_ttl_ms`: past that, no resume token can bring the room back.

  Options (`config :octoroom, janitor: [...]`):

    * `:enabled` (default true)
    * `:first_sweep_ms`: delay before the first sweep after boot (default
      5 s, so rooms whose clients resume quickly start first)
    * `:interval_ms`: between sweeps (default 60 s)
    * `:room_ttl_ms`: default 10 minutes, the resume token's max age
    * `:min_age_ms`: an adapter record younger than this, still waiting for
      Cloudflare's id, is left alone (default 30 s)
  """

  use GenServer

  require Logger

  alias Octoroom.{Cloudflare, Store}
  alias Octoroom.Room.Server

  @defaults [
    enabled: true,
    first_sweep_ms: 5_000,
    interval_ms: 60_000,
    room_ttl_ms: 600_000,
    min_age_ms: 30_000
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  One sweep. Returns `%{closed: [adapter_id], deleted_rooms: [room_id]}`.

  Options: `:store`, `:cloudflare`, `:room_ttl_ms`, `:min_age_ms`, and
  `:run_of` (room id => its running run or nil; defaults to looking up room
  servers on this node).
  """
  def sweep(opts \\ []) do
    opts = Keyword.merge(@defaults, opts)
    store = Keyword.get_lazy(opts, :store, &Store.config/0)
    cf = Keyword.get_lazy(opts, :cloudflare, &Cloudflare.config/0)
    run_of = Keyword.get(opts, :run_of, &Server.run/1)
    now = Store.now()

    {stale, orphans} =
      store
      |> Store.all(:adapters)
      |> Enum.reject(fn {_key, a} -> run_of.(a.room_id) == a.run end)
      |> Enum.split_with(fn {_key, a} -> a.adapter_id != nil end)

    # Records Cloudflare never answered for: the request died with its run.
    for {key, a} <- orphans,
        now - a.created_at > opts[:min_age_ms],
        do: Store.delete(store, :adapters, key)

    closed =
      case Enum.map(stale, fn {_key, a} -> a.adapter_id end) do
        [] ->
          []

        ids ->
          case Cloudflare.close_adapters(cf, ids) do
            :ok ->
              for {key, _} <- stale, do: Store.delete(store, :adapters, key)
              ids

            {:error, reason} ->
              Logger.warning("Octoroom janitor couldn't close adapters: #{inspect(reason)}")
              []
          end
      end

    deleted_rooms =
      for {room_id, r} <- Store.all(store, :rooms),
          run_of.(room_id) == nil,
          now - r.updated_at > opts[:room_ttl_ms] do
        Store.delete(store, :rooms, room_id)
        room_id
      end

    result = %{closed: closed, deleted_rooms: deleted_rooms}

    :telemetry.execute(
      [:octoroom, :janitor, :sweep],
      %{closed: length(closed), deleted_rooms: length(deleted_rooms)},
      %{}
    )

    if closed != [], do: Logger.info("Octoroom janitor closed #{length(closed)} adapter(s)")
    result
  end

  @impl true
  def init(opts) do
    opts = Keyword.merge(@defaults, opts)
    if opts[:enabled], do: Process.send_after(self(), :sweep, opts[:first_sweep_ms])
    {:ok, opts}
  end

  @impl true
  def handle_info(:sweep, opts) do
    try do
      sweep(Keyword.drop(opts, [:enabled, :first_sweep_ms, :interval_ms]))
    rescue
      error -> Logger.error("Octoroom janitor sweep failed: #{Exception.message(error)}")
    end

    Process.send_after(self(), :sweep, opts[:interval_ms])
    {:noreply, opts}
  end
end
