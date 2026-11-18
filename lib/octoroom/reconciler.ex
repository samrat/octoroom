defmodule Octoroom.Reconciler do
  @moduledoc """
  Diffs desired against actual room state and returns the operations that
  turn one into the other. Pure.

  `desired` maps each participant that can receive (its connection is up) to
  the tracks it should hear. `actual` has:

    * `:subscriptions`: participant id => track name =>
      `%{status: :opening | :open | :closing, gain: float}`
    * `:tracks`: the track directory, track name => `:pending | :live`

  Operations, in the order they should be applied:

    1. `{:close_subscription, participant_id, name}`: open, but no longer
       desired, no longer published, or `stale: true` (pulled from a session
       that's gone, such as a worker output's before a restart; once
       closed, it's pulled again from the track's new session).
    2. `{:open_subscription, participant_id, name, %{gain: g}}`: desired and
       live. Subscriptions to pending tracks wait until they go live.
    3. `{:update_subscription, participant_id, name, %{gain: g}}`: open and
       staying open, with a different gain.

  Subscriptions with an operation in flight (`:opening`, `:closing`) are
  left alone; the next diff after that operation settles picks them up.
  """

  alias Octoroom.Track

  @type op ::
          {:close_subscription, String.t(), String.t()}
          | {:open_subscription, String.t(), String.t(), map}
          | {:update_subscription, String.t(), String.t(), map}

  @spec diff(%{String.t() => [Track.t()]}, map) :: [op]
  def diff(desired, actual) do
    subs = Map.get(actual, :subscriptions, %{})
    tracks = Map.get(actual, :tracks, %{})
    participants = Enum.uniq(Map.keys(desired) ++ Map.keys(subs)) |> Enum.sort()

    ops =
      for pid <- participants,
          op <- diff_participant(pid, Map.get(desired, pid, []), Map.get(subs, pid, %{}), tracks),
          do: op

    Enum.sort_by(ops, &rank/1)
  end

  defp diff_participant(pid, wanted, current, tracks) do
    wanted = wanted |> Enum.map(&normalize/1) |> Map.new(&{&1.name, &1})

    closes =
      for {name, %{status: :open} = sub} <- current,
          not Map.has_key?(wanted, name) or Map.get(tracks, name) == nil or
            Map.get(sub, :stale, false),
          do: {:close_subscription, pid, name}

    opens =
      for {name, track} <- wanted,
          not Map.has_key?(current, name),
          Map.get(tracks, name) == :live,
          do: {:open_subscription, pid, name, %{gain: track.gain}}

    updates =
      for {name, track} <- wanted,
          %{status: :open, gain: gain} = sub <- [Map.get(current, name)],
          Map.get(tracks, name) != nil,
          not Map.get(sub, :stale, false),
          gain != track.gain,
          do: {:update_subscription, pid, name, %{gain: track.gain}}

    Enum.sort(closes) ++ Enum.sort(opens) ++ Enum.sort(updates)
  end

  @type worker_op ::
          {:stop_inlet, {String.t(), String.t()}}
          | {:stop_outlet, String.t()}
          | {:stop_worker, String.t()}
          | {:start_worker, map}
          | {:restart_worker, map}
          | {:update_worker, map}
          | {:start_outlet, String.t(), String.t()}
          | {:start_inlet, {String.t(), String.t()}}

  @doc """
  Diffs the worker specs `workers/1` returned against the running workers
  and their media. `actual` has:

    * `:workers`: worker id => the spec it runs
    * `:outlets`: output track name => the id of the worker it belongs to
    * `:inlets`: a list of `{worker_id, input track name}`
    * `:tracks`: the track directory, as for `diff/2`

  Operations, in the order they should be applied: tear down first, so
  capacity and billing go down before they go up.

    1. `{:stop_inlet, {worker_id, input}}`: no longer an input, or its track
       is gone.
    2. `{:stop_outlet, name}`: no longer any worker's output, or now
       another worker's: it's stopped here and started again for that
       worker.
    3. `{:stop_worker, id}`: no longer in the specs.
    4. `{:start_worker, spec}`, `{:restart_worker, spec}` (its module or args
       changed) and `{:update_worker, spec}` (only its inputs, outputs or
       data outputs changed: the worker keeps running).
    5. `{:start_outlet, name, worker_id}`: an output with no outlet of this
       worker's. If two workers name the same output, the first one in the
       specs has it.
    6. `{:start_inlet, {worker_id, input}}`: an input whose track is live.
       Inlets of pending tracks wait until they go live.
  """
  @spec diff_workers([map], map) :: [worker_op]
  def diff_workers(specs, actual) do
    running = Map.get(actual, :workers, %{})
    outlets = Map.get(actual, :outlets, %{})
    inlets = actual |> Map.get(:inlets, []) |> MapSet.new()
    tracks = Map.get(actual, :tracks, %{})

    specs = Enum.uniq_by(specs, & &1.id)
    wanted = Map.new(specs, &{&1.id, &1})

    wanted_outlets =
      specs
      |> Enum.flat_map(fn s -> Enum.map(s.outputs, &{&1, s.id}) end)
      |> Enum.uniq_by(&elem(&1, 0))

    wanted_inlets =
      for s <- specs, input <- s.inputs, Map.get(tracks, input) == :live, into: MapSet.new() do
        {s.id, input}
      end

    stop_inlets =
      for key <- Enum.sort(inlets), not MapSet.member?(wanted_inlets, key), do: {:stop_inlet, key}

    stop_outlets =
      for {name, _} = outlet <- Enum.sort(outlets),
          outlet not in wanted_outlets,
          do: {:stop_outlet, name}

    stop_workers =
      for {id, _} <- Enum.sort(running), not Map.has_key?(wanted, id), do: {:stop_worker, id}

    workers =
      for s <- specs, op = worker_op(s, running[s.id]), do: op

    start_outlets =
      for {name, id} <- wanted_outlets,
          Map.get(outlets, name) != id,
          do: {:start_outlet, name, id}

    start_inlets =
      for {id, input} = key <- Enum.sort(wanted_inlets),
          not MapSet.member?(inlets, key),
          do: {:start_inlet, {id, input}}

    stop_inlets ++ stop_outlets ++ stop_workers ++ workers ++ start_outlets ++ start_inlets
  end

  defp worker_op(spec, nil), do: {:start_worker, spec}

  defp worker_op(spec, old) do
    cond do
      old.module != spec.module or old.args != spec.args ->
        {:restart_worker, spec}

      old.inputs != spec.inputs or old.outputs != spec.outputs or
          Map.get(old, :data, []) != Map.get(spec, :data, []) ->
        {:update_worker, spec}

      true ->
        nil
    end
  end

  @doc "A policy result entry as a track: a name means full gain."
  def normalize(%Track{} = track), do: track
  def normalize(name) when is_binary(name), do: Track.new(name)

  defp rank({:close_subscription, _, _}), do: 0
  defp rank({:open_subscription, _, _, _}), do: 1
  defp rank({:update_subscription, _, _, _}), do: 2
end
