defmodule Octoroom.ReconcilerPropertyTest do
  @moduledoc """
  Property tests for the reconciler: for any desired and actual state, the
  operations are the right ones, come in the documented order, and applying
  them reaches a state that needs no more.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Octoroom.{Reconciler, Track}

  # Small pools, so desired and actual state overlap often.
  @participants ~w(a b c)
  @tracks ~w(a/mic b/mic c/mic a/camera bot/out)
  @gains [0.0, 0.15, 0.5, 1.0]

  ## diff/2

  defp gain, do: member_of(@gains)

  # What subscriptions/2 may return for one listener: tracks or bare names,
  # at most one entry per track.
  defp wanted do
    gen all(
          names <- subset(@tracks),
          entries <- fixed_list(Enum.map(names, &entry/1))
        ) do
      entries
    end
  end

  defp subset(pool), do: map(list_of(member_of(pool), max_length: length(pool)), &Enum.uniq/1)

  # A map with some of `keys`. (map_of/2 gives up on key pools this small.)
  defp some_of(keys, value) do
    bind(subset(keys), fn keys -> fixed_map(Map.new(keys, &{&1, value})) end)
  end

  defp entry(name) do
    one_of([constant(name), map(gain(), &%Track{name: name, gain: &1})])
  end

  defp subscription do
    gen all(
          status <- member_of([:opening, :open, :closing]),
          gain <- gain(),
          stale <- member_of([nil, false, true])
        ) do
      sub = %{status: status, gain: gain}
      if stale == nil, do: sub, else: Map.put(sub, :stale, stale)
    end
  end

  defp desired, do: some_of(@participants, wanted())

  defp actual do
    gen all(
          subs <- some_of(@participants, some_of(@tracks, subscription())),
          tracks <- some_of(@tracks, member_of([:pending, :live]))
        ) do
      %{subscriptions: subs, tracks: tracks}
    end
  end

  defp gain_of(%Track{gain: gain}), do: gain
  defp gain_of(name) when is_binary(name), do: 1.0

  defp name_of(%Track{name: name}), do: name
  defp name_of(name) when is_binary(name), do: name

  # The operation one (participant, track) cell calls for, straight from the
  # moduledoc's rules.
  defp expected(pid, name, want, sub, track) do
    case {want, sub, track} do
      {nil, nil, _} -> nil
      {want, nil, :live} -> {:open_subscription, pid, name, %{gain: gain_of(want)}}
      {_, nil, _} -> nil
      {_, %{status: status}, _} when status != :open -> nil
      {nil, _, _} -> {:close_subscription, pid, name}
      {_, _, nil} -> {:close_subscription, pid, name}
      {_, %{stale: true}, _} -> {:close_subscription, pid, name}
      {want, %{gain: gain}, _} -> if gain != gain_of(want), do: update(pid, name, want)
    end
  end

  defp update(pid, name, want), do: {:update_subscription, pid, name, %{gain: gain_of(want)}}

  defp rank({:close_subscription, _, _}), do: 0
  defp rank({:open_subscription, _, _, _}), do: 1
  defp rank({:update_subscription, _, _, _}), do: 2

  # Applies operations the way the room server does: each starts something
  # at Cloudflare, which then settles. Raises if an operation doesn't fit
  # the state it's applied to.
  defp apply_ops(ops, actual) do
    subs =
      Enum.reduce(ops, actual.subscriptions, fn
        {:close_subscription, pid, name}, subs ->
          %{status: :open} = subs[pid][name]
          put_in(subs[pid][name].status, :closing)

        {:open_subscription, pid, name, %{gain: gain}}, subs ->
          false = Map.has_key?(Map.get(subs, pid, %{}), name)
          Map.update(subs, pid, %{name => opening(gain)}, &Map.put(&1, name, opening(gain)))

        {:update_subscription, pid, name, %{gain: gain}}, subs ->
          %{status: :open} = subs[pid][name]
          put_in(subs[pid][name].gain, gain)
      end)

    %{actual | subscriptions: subs}
  end

  defp opening(gain), do: %{status: :opening, gain: gain}

  # Every operation in flight finishes: closes go, opens are open.
  defp settle(actual) do
    subs =
      Map.new(actual.subscriptions, fn {pid, subs} ->
        {pid,
         for {name, sub} <- subs, sub.status != :closing, into: %{} do
           {name, %{sub | status: :open}}
         end}
      end)

    %{actual | subscriptions: subs}
  end

  property "diff/2 returns exactly the operation each (participant, track) calls for" do
    check all(desired <- desired(), actual <- actual()) do
      expected =
        for pid <- @participants,
            name <- @tracks,
            want <- [Enum.find(Map.get(desired, pid, []), &(name_of(&1) == name))],
            sub <- [get_in(actual.subscriptions, [pid, name])],
            op = expected(pid, name, want, sub, actual.tracks[name]),
            do: op

      assert Enum.sort(Reconciler.diff(desired, actual)) == Enum.sort(expected)
    end
  end

  property "diff/2 puts closes before opens before gain changes" do
    check all(desired <- desired(), actual <- actual()) do
      ranks = desired |> Reconciler.diff(actual) |> Enum.map(&rank/1)
      assert ranks == Enum.sort(ranks)
    end
  end

  property "diff/2 treats a bare name as that track at full gain" do
    check all(desired <- desired(), actual <- actual()) do
      as_tracks =
        Map.new(desired, fn {pid, wanted} -> {pid, Enum.map(wanted, &Reconciler.normalize/1)} end)

      assert Reconciler.diff(desired, actual) == Reconciler.diff(as_tracks, actual)
    end
  end

  property "diff/2 never touches a subscription with an operation in flight" do
    check all(desired <- desired(), actual <- actual()) do
      for op <- Reconciler.diff(desired, actual),
          sub = get_in(actual.subscriptions, [elem(op, 1), elem(op, 2)]) do
        assert sub.status == :open
      end
    end
  end

  property "diff/2 never opens a subscription to a track that isn't live" do
    check all(desired <- desired(), actual <- actual()) do
      for {:open_subscription, _pid, name, _} <- Reconciler.diff(desired, actual) do
        assert actual.tracks[name] == :live
      end
    end
  end

  property "applying diff/2's operations converges on the desired subscriptions" do
    check all(desired <- desired(), actual <- actual()) do
      # One pass settles what was in flight and closes what's stale or
      # unwanted; a second reopens the stale ones and fixes what settled.
      final =
        Enum.reduce(1..3, actual, fn _, actual ->
          desired |> Reconciler.diff(actual) |> apply_ops(actual) |> settle()
        end)

      assert Reconciler.diff(desired, final) == []

      for pid <- @participants do
        wanted = Map.new(Map.get(desired, pid, []), &{name_of(&1), gain_of(&1)})
        subs = Map.get(final.subscriptions, pid, %{})

        for {name, sub} <- subs do
          assert %{status: :open, gain: gain} = sub
          assert wanted[name] == gain
          assert Map.has_key?(final.tracks, name)
        end

        for {name, _} <- wanted, final.tracks[name] == :live do
          assert Map.has_key?(subs, name)
        end
      end
    end
  end

  ## diff_workers/2

  @workers ~w(w1 w2 w3)
  @inputs ~w(a/mic b/mic c/mic)
  @outputs ~w(out1 out2 out3)

  defp spec, do: bind(member_of(@workers), &spec/1)

  defp spec(id) do
    gen all(
          module <- member_of([M, N]),
          args <- member_of([%{}, %{n: 1}]),
          inputs <- subset(@inputs),
          outputs <- subset(@outputs)
        ) do
      Octoroom.Room.worker(id, module, inputs: inputs, outputs: outputs, args: args)
    end
  end

  defp running do
    gen all(
          ids <- subset(@workers),
          specs <- fixed_list(Enum.map(ids, &spec/1))
        ) do
      Map.new(specs, &{&1.id, &1})
    end
  end

  defp worker_state do
    gen all(
          workers <- running(),
          outlets <- some_of(@outputs, member_of(@workers)),
          inlets <- subset(for id <- @workers, input <- @inputs, do: {id, input}),
          tracks <- some_of(@inputs, member_of([:pending, :live]))
        ) do
      %{workers: workers, outlets: outlets, inlets: inlets, tracks: tracks}
    end
  end

  # Specs as workers/1 might return them, and a state they might meet: often
  # the state an earlier, different list of specs left behind.
  defp specs_and_state do
    gen all(
          specs <- list_of(spec(), max_length: 4),
          actual <-
            one_of([
              worker_state(),
              map({list_of(spec(), max_length: 4), worker_state()}, fn {earlier, actual} ->
                apply_worker_ops(Reconciler.diff_workers(earlier, actual), actual)
              end)
            ])
        ) do
      {specs, actual}
    end
  end

  defp phase({:stop_inlet, _}), do: 0
  defp phase({:stop_outlet, _}), do: 1
  defp phase({:stop_worker, _}), do: 2
  defp phase({op, _}) when op in [:start_worker, :restart_worker, :update_worker], do: 3
  defp phase({:start_outlet, _, _}), do: 4
  defp phase({:start_inlet, _}), do: 5

  # Applies operations in order, as the room server does. Raises if one
  # doesn't fit the state it's applied to: stopping what isn't there,
  # starting what is.
  defp apply_worker_ops(ops, actual) do
    Enum.reduce(ops, actual, fn
      {:stop_inlet, key}, actual ->
        true = key in actual.inlets
        %{actual | inlets: List.delete(actual.inlets, key)}

      {:stop_outlet, name}, actual ->
        true = Map.has_key?(actual.outlets, name)
        %{actual | outlets: Map.delete(actual.outlets, name)}

      {:stop_worker, id}, actual ->
        true = Map.has_key?(actual.workers, id)
        %{actual | workers: Map.delete(actual.workers, id)}

      {:start_worker, spec}, actual ->
        false = Map.has_key?(actual.workers, spec.id)
        put_in(actual.workers[spec.id], spec)

      {:restart_worker, spec}, actual ->
        old = Map.fetch!(actual.workers, spec.id)
        true = {old.module, old.args} != {spec.module, spec.args}
        put_in(actual.workers[spec.id], spec)

      {:update_worker, spec}, actual ->
        old = Map.fetch!(actual.workers, spec.id)
        true = {old.module, old.args} == {spec.module, spec.args}
        true = {old.inputs, old.outputs} != {spec.inputs, spec.outputs}
        put_in(actual.workers[spec.id], spec)

      {:start_outlet, name, id}, actual ->
        false = Map.has_key?(actual.outlets, name)
        true = Map.has_key?(actual.workers, id)
        put_in(actual.outlets[name], id)

      {:start_inlet, {id, input} = key}, actual ->
        false = key in actual.inlets
        true = Map.has_key?(actual.workers, id)
        :live = actual.tracks[input]
        %{actual | inlets: [key | actual.inlets]}
    end)
  end

  property "diff_workers/2 tears down before it builds up" do
    check all({specs, actual} <- specs_and_state()) do
      phases = specs |> Reconciler.diff_workers(actual) |> Enum.map(&phase/1)
      assert phases == Enum.sort(phases)
    end
  end

  property "applying diff_workers/2's operations reaches the specs in one pass" do
    check all({specs, actual} <- specs_and_state()) do
      final = specs |> Reconciler.diff_workers(actual) |> apply_worker_ops(actual)
      specs = Enum.uniq_by(specs, & &1.id)

      assert final.workers == Map.new(specs, &{&1.id, &1})

      # Each output belongs to the first worker in the specs that names it.
      assert final.outlets ==
               specs
               |> Enum.flat_map(fn s -> Enum.map(s.outputs, &{&1, s.id}) end)
               |> Enum.reverse()
               |> Map.new()

      # Each worker has an inlet for each of its inputs that's live.
      assert Enum.sort(final.inlets) ==
               Enum.sort(for s <- specs, i <- s.inputs, actual.tracks[i] == :live, do: {s.id, i})

      assert Reconciler.diff_workers(specs, final) == []
    end
  end

  property "diff_workers/2 leaves a worker alone when its spec hasn't changed" do
    check all({specs, actual} <- specs_and_state()) do
      for {op, spec} when op in [:start_worker, :restart_worker, :update_worker] <-
            Reconciler.diff_workers(specs, actual) do
        assert actual.workers[spec.id] != spec
      end
    end
  end
end
