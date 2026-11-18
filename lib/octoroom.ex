defmodule Octoroom do
  @moduledoc """
  Voice rooms for Phoenix apps, carried by Cloudflare Realtime SFU.

  See `Octoroom.Room` for writing a room and `docs/architecture.md` for the design.
  """

  @events Octoroom.Events

  @doc """
  Subscribes the calling process to a room's events. It then receives
  `{:octoroom, room_id, event}` messages. `scope:` is required and says
  which events:

    * `scope: {:participant, id}`: what participant `id`'s client is sent,
      and nothing else. Use it for a process that renders a room for one
      user, such as a LiveView. The id isn't checked against anything: pass
      the id of the participant your code authenticated.
    * `scope: :room`: everything, for trusted code that doesn't act for a
      user (a recorder, analytics, an admin view).

  With `scope: {:participant, id}`, `event` is one of:

    * `{:joined, participant}` and `{:left, participant}`, for other
      participants
    * `{:updated, participant}`: its metadata changed, or a source it
      publishes was muted, unmuted or unpublished (see its `tracks`)
    * `{:published, participant}`: a source it publishes (mic, camera,
      screen) is live at Cloudflare
    * `{:worker, :added | :updated | :removed, presence}`: a worker it now
      sees (it's subscribed to one of the worker's outputs), whose presence
      changed, or that it no longer sees. `presence` is `%{id, outputs,
      data, state, attributes}`, or just `%{id}` when removed.
    * `{:worker_notify, worker_id, output, type, data}`: a worker's
      `notify:` on an output it's subscribed to

  With `scope: :room`, those (including the participant's own joins and
  leaves, every `notify:` except those sent to one participant, and
  `{:worker, :updated, presence}` for every presence change, but no
  `:added` or `:removed`) plus:

    * `{:subscriptions, participant_id, track_names}`: what it now hears
    * `{:disconnected, participant}`: its connection dropped; it's kept
      for the grace period
    * `{:output_live, track_name}`: a worker output sent its first packet
    * `{:worker_event, worker_id, event}`: whatever a worker `emit`s
    * `{:worker_down, worker_id, reason}`: a worker crashed
    * `{:error, what, reason}`: the room gave up on something

  The subscription is kept across room restarts, and a process may
  subscribe before the room or the participant exists.
  """
  def subscribe(room_id, opts) when is_list(opts) do
    case Keyword.fetch(opts, :scope) do
      {:ok, :room} ->
        Registry.register(@events, room_id, :room)

      {:ok, {:participant, id} = scope} when is_binary(id) ->
        Registry.register(@events, room_id, scope)

      _ ->
        raise ArgumentError,
              "Octoroom.subscribe/2 needs scope: :room or scope: {:participant, id}, got #{inspect(opts)}"
    end
  end

  @doc "Removes every subscription the calling process has to the room's events."
  def unsubscribe(room_id), do: Registry.unregister(@events, room_id)

  @doc false
  # To `scope: :room` subscribers.
  def broadcast(room_id, event) do
    Registry.dispatch(@events, room_id, fn entries ->
      for {pid, :room} <- entries, do: send(pid, {:octoroom, room_id, event})
    end)
  end

  @doc false
  # To `scope: {:participant, id}` subscribers, for each id in `ids`.
  def deliver(_room_id, [], _event), do: :ok

  def deliver(room_id, ids, event) do
    ids = MapSet.new(ids)

    Registry.dispatch(@events, room_id, fn entries ->
      for {pid, {:participant, id}} <- entries,
          MapSet.member?(ids, id),
          do: send(pid, {:octoroom, room_id, event})
    end)
  end

  @doc false
  # Limits on clients' messages to workers, from `config :octoroom,
  # worker_messages: [...]` and then `overrides`: `max_bytes` per message
  # (as JSON), and a bucket per participant per worker that refills at
  # `per_second` up to `burst`.
  def worker_message_limits(overrides \\ []) do
    [max_bytes: 16_384, per_second: 10, burst: 20]
    |> Keyword.merge(Application.get_env(:octoroom, :worker_messages, []))
    |> Keyword.merge(overrides)
    |> Map.new()
  end

  @doc false
  def ice_servers,
    do: Application.get_env(:octoroom, :ice_servers, [%{urls: "stun:stun.cloudflare.com:3478"}])
end
