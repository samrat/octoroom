defmodule Octoroom.Store.ETS do
  @moduledoc """
  The default `Octoroom.Store`: an ETS table, snapshotted to a file so it
  survives a node restarting in place. Enough for one node; a deploy that
  replaces the machine needs a store outside it.

  Options:

    * `:name`: the table's name (default `Octoroom.Store`).
    * `:path`: the snapshot file. Defaults to `octoroom-<node>.store` in the
      system temp directory; `nil` keeps the store in memory only.
    * `:snapshot_ms`: how long writes are batched before a snapshot
      (default 50).

  Reads and writes go straight to ETS. A write schedules a snapshot, which
  is written to a temporary file and renamed, so a crash mid-write leaves
  the previous snapshot.
  """

  @behaviour Octoroom.Store

  use GenServer

  require Logger

  @impl Octoroom.Store
  def child_spec(opts) do
    %{id: {__MODULE__, name(opts)}, start: {__MODULE__, :start_link, [opts]}}
  end

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: server(name(opts)))

  @impl Octoroom.Store
  def get(opts, table, key) do
    case :ets.lookup(name(opts), {table, key}) do
      [{_, value}] -> value
      [] -> nil
    end
  end

  @impl Octoroom.Store
  def put(opts, table, key, value) do
    true = :ets.insert(name(opts), {{table, key}, value})
    dirty(opts)
  end

  @impl Octoroom.Store
  def delete(opts, table, key) do
    true = :ets.delete(name(opts), {table, key})
    dirty(opts)
  end

  @impl Octoroom.Store
  def all(opts, table) do
    :ets.match_object(name(opts), {{table, :_}, :_})
    |> Enum.map(fn {{_, key}, value} -> {key, value} end)
  end

  @doc "Writes the snapshot now. Returns once it's on disk."
  def flush(opts \\ []), do: GenServer.call(server(name(opts)), :flush)

  defp dirty(opts) do
    GenServer.cast(server(name(opts)), :dirty)
    :ok
  end

  defp name(opts), do: Keyword.get(opts, :name, Octoroom.Store)
  defp server(name), do: Module.concat(name, Server)

  ## Server

  @impl GenServer
  def init(opts) do
    name = name(opts)
    :ets.new(name, [:named_table, :public, :set, read_concurrency: true])
    # So a shutdown writes the last changes (it stops after the rooms do).
    Process.flag(:trap_exit, true)

    path =
      case Keyword.fetch(opts, :path) do
        {:ok, path} -> path
        :error -> Path.join(System.tmp_dir!(), "octoroom-#{node()}.store")
      end

    if path, do: load(name, path)

    {:ok, %{name: name, path: path, snapshot_ms: Keyword.get(opts, :snapshot_ms, 50), timer: nil}}
  end

  @impl GenServer
  def handle_cast(:dirty, %{path: nil} = state), do: {:noreply, state}
  def handle_cast(:dirty, %{timer: timer} = state) when timer != nil, do: {:noreply, state}

  def handle_cast(:dirty, state),
    do: {:noreply, %{state | timer: Process.send_after(self(), :snapshot, state.snapshot_ms)}}

  @impl GenServer
  def handle_info(:snapshot, state) do
    snapshot(state)
    {:noreply, %{state | timer: nil}}
  end

  @impl GenServer
  def handle_call(:flush, _from, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    snapshot(state)
    {:reply, :ok, %{state | timer: nil}}
  end

  @impl GenServer
  def terminate(_reason, state), do: snapshot(state)

  defp snapshot(%{path: nil}), do: :ok

  defp snapshot(%{name: name, path: path}) do
    tmp = path <> ".tmp"
    data = :erlang.term_to_binary(:ets.tab2list(name))

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(tmp, data),
         :ok <- File.rename(tmp, path) do
      :ok
    else
      {:error, reason} ->
        Logger.error("Octoroom couldn't write its store to #{path}: #{inspect(reason)}")
    end
  end

  defp load(name, path) do
    case File.read(path) do
      {:ok, data} ->
        try do
          # Not `:safe`: the snapshot holds the app's own atoms (assign
          # keys, metadata), which may not exist yet this early in boot. It's
          # this node's own file, not input from outside.
          :ets.insert(name, :erlang.binary_to_term(data))
        rescue
          error ->
            Logger.error("Octoroom couldn't read its store #{path}: #{Exception.message(error)}")
        end

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Logger.error("Octoroom couldn't read its store #{path}: #{inspect(reason)}")
    end
  end
end
