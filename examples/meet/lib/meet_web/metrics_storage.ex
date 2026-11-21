defmodule MeetWeb.MetricsStorage do
  @moduledoc """
  In-memory ETS ring buffer for `Phoenix.LiveDashboard` `metrics_history`.

  Attaches to every `:telemetry` event referenced by `MeetWeb.Telemetry.metrics/0`
  and keeps the most recent datapoints per metric so LiveDashboard charts stay
  populated when you open the dashboard after a call or switch tabs.
  """
  use GenServer

  alias Phoenix.LiveDashboard.TelemetryListener

  @table __MODULE__
  @max_points 500
  @prune_interval_ms 30_000

  def start_link(metrics) when is_list(metrics) do
    GenServer.start_link(__MODULE__, metrics, name: __MODULE__)
  end

  @doc "Callback for LiveDashboard's `metrics_history: {#{inspect(__MODULE__)}, :metrics_history, []}`."
  def metrics_history(metric) do
    case :ets.whereis(@table) do
      :undefined ->
        []

      _tid ->
        @table
        |> :ets.match_object({{metric_key(metric), :_}, :_})
        |> Enum.take(-@max_points)
        |> Enum.map(&elem(&1, 1))
    end
  end

  @impl true
  def init(metrics) do
    :ets.new(@table, [:named_table, :ordered_set, :public, write_concurrency: true])

    grouped = Enum.group_by(metrics, & &1.event_name)
    handler_ids = for {event, list} <- grouped, do: attach(event, list)
    keys = Enum.map(metrics, &metric_key/1) |> Enum.uniq()

    Process.send_after(self(), :prune, @prune_interval_ms)
    {:ok, %{handler_ids: handler_ids, keys: keys}}
  end

  @impl true
  def handle_info(:prune, state) do
    Enum.each(state.keys, &prune_key/1)
    Process.send_after(self(), :prune, @prune_interval_ms)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    Enum.each(state.handler_ids, &:telemetry.detach/1)
    :ok
  end

  defp attach(event, metrics) do
    id = {__MODULE__, event}
    entries = Enum.map(metrics, &{&1, metric_key(&1)})
    :telemetry.attach(id, event, &__MODULE__.handle_event/4, entries)
    id
  end

  @doc false
  def handle_event(_event, measurements, metadata, entries) do
    if :ets.whereis(@table) != :undefined do
      time = System.system_time(:microsecond)

      for {metric, key} <- entries do
        case TelemetryListener.extract_datapoint_for_metric(metric, measurements, metadata, time) do
          nil ->
            :ok

          point ->
            :ets.insert(@table, {{key, System.unique_integer([:monotonic, :positive])}, point})
        end
      end
    end
  end

  defp prune_key(key) do
    entries = :ets.match_object(@table, {{key, :_}, :_})
    excess = length(entries) - @max_points

    if excess > 0 do
      entries
      |> Enum.take(excess)
      |> Enum.each(fn {ets_key, _point} -> :ets.delete(@table, ets_key) end)
    end
  end

  # Pure-data key (no closures) so freshly built Telemetry.Metrics structs match.
  defp metric_key(metric), do: {metric.__struct__, metric.name, metric.event_name, metric.tags}
end
