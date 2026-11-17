defmodule Octoroom.Janitor do
  @moduledoc """
  Deletes room records whose room hasn't run for longer than `:room_ttl_ms`:
  past that, no resume token can bring the room back, so the record would
  only make a new room with the same id think it's recovering.

  Workers' Cloudflare sessions need no cleanup: each ends with its peer
  connection, including when the node dies.

  Options (`config :octoroom, janitor: [...]`):

    * `:enabled` (default true)
    * `:first_sweep_ms`: delay before the first sweep after boot (default
      5 s, so rooms whose clients resume quickly start first)
    * `:interval_ms`: between sweeps (default 60 s)
    * `:room_ttl_ms`: default 10 minutes, the resume token's max age
  """

  use GenServer

  require Logger

  alias Octoroom.Store
  alias Octoroom.Room.Server

  @defaults [
    enabled: true,
    first_sweep_ms: 5_000,
    interval_ms: 60_000,
    room_ttl_ms: 600_000
  ]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  One sweep. Returns `%{deleted_rooms: [room_id]}`.

  Options: `:store`, `:room_ttl_ms`, and `:run_of` (room id => its running
  run or nil; defaults to looking up room servers on this node).
  """
  def sweep(opts \\ []) do
    opts = Keyword.merge(@defaults, opts)
    store = Keyword.get_lazy(opts, :store, &Store.config/0)
    run_of = Keyword.get(opts, :run_of, &Server.run/1)
    now = Store.now()

    deleted_rooms =
      for {room_id, r} <- Store.all(store, :rooms),
          run_of.(room_id) == nil,
          now - r.updated_at > opts[:room_ttl_ms] do
        Store.delete(store, :rooms, room_id)
        room_id
      end

    :telemetry.execute(
      [:octoroom, :janitor, :sweep],
      %{deleted_rooms: length(deleted_rooms)},
      %{}
    )

    %{deleted_rooms: deleted_rooms}
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
