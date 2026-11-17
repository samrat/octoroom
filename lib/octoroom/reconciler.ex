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
       desired or no longer published.
    2. `{:open_subscription, participant_id, name, %{gain: g}}`: desired and
       live. Subscriptions to pending tracks wait until they go live.
    3. `{:update_subscription, participant_id, name, %{gain: g}}`: open, with
       a different gain.

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
      for {name, %{status: :open}} <- current,
          not Map.has_key?(wanted, name) or Map.get(tracks, name) == nil,
          do: {:close_subscription, pid, name}

    opens =
      for {name, track} <- wanted,
          not Map.has_key?(current, name),
          Map.get(tracks, name) == :live,
          do: {:open_subscription, pid, name, %{gain: track.gain}}

    updates =
      for {name, track} <- wanted,
          %{status: :open, gain: gain} <- [Map.get(current, name)],
          Map.get(tracks, name) != nil,
          gain != track.gain,
          do: {:update_subscription, pid, name, %{gain: track.gain}}

    Enum.sort(closes) ++ Enum.sort(opens) ++ Enum.sort(updates)
  end

  @doc "A policy result entry as a track: a name means full gain."
  def normalize(%Track{} = track), do: track
  def normalize(name) when is_binary(name), do: %Track{name: name}

  defp rank({:close_subscription, _, _}), do: 0
  defp rank({:open_subscription, _, _, _}), do: 1
  defp rank({:update_subscription, _, _, _}), do: 2
end
