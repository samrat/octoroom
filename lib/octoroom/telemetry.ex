defmodule Octoroom.Telemetry do
  @moduledoc """
  The `:telemetry` events Octoroom emits. Measurements are maps of numbers;
  metadata always includes `room_id` where there is a room.

  Joining, step by step (`attach_default_logger/1` logs these):

    * `[:octoroom, :participant, :connected]`: a participant's own media is
      up, after its first publish (and after each publish on a new session).
      Measured by the server, in ms: `duration_ms` (join to connected),
      `before_publish_ms` (join to the publish arriving: the client's mic
      prompt and candidate gathering), `publish_ms` (creating its Cloudflare
      session and pushing its tracks) and `connect_ms` (the answer to the
      client reporting it connected). Measured by the client, when it sends
      them (the browser client does): `client_join_ms`, `client_media_ms`
      (getUserMedia, with any permission prompt), `client_ice_ms` (the wait
      for a first ICE candidate), `client_publish_ms` and
      `client_connect_ms`. Metadata `id`, `sources` and, from the client,
      `ice_timed_out`.
    * `[:octoroom, :participant, :first_pull]`: the first pull into a
      connected participant's session finished, so it hears someone.
      Measurements `duration_ms` (since joining), `since_connected_ms`,
      `tracks`; metadata `id`.
    * `[:octoroom, :outlet, :live]`: a worker's output sent its first
      packet, so listeners can pull it. Until then nobody hears it.
      Measurements `duration_ms` (since the outlet started); metadata
      `name`, `worker_id`.

  Cloudflare:

    * `[:octoroom, :cloudflare, :request]`: one HTTP attempt.
      Measurements `duration_ms`; metadata `method`, `path`, `result`
      (`:ok` or `:error`).
    * `[:octoroom, :peer, :connect]`: a worker's peer connection to
      Cloudflare came up. Measurements `duration_ms` (from the peer's
      start); metadata `worker_id`.
    * `[:octoroom, :pull, :stop]`: a batched pull finished, from the
      Cloudflare call to the browser's answer. Measurements `duration_ms`,
      `tracks`; metadata `participant_id`.

  Rooms and participants:

    * `[:octoroom, :room, :start]`: metadata `run`, `recovered` (the previous
      run didn't stop cleanly).
    * `[:octoroom, :room, :stop]`: metadata `reason`.
    * `[:octoroom, :room, :recovered]`: a recovered room's grace period
      ended. Measurements `ghosts`: tracks still held for participants who
      never came back.
    * `[:octoroom, :participant, :join]`: metadata `id`.
    * `[:octoroom, :participant, :resume]`: metadata `id`, `kind`
      (`:rejoin` when the room kept running, `:adopt` when its Cloudflare
      session was adopted by a new run).
    * `[:octoroom, :participant, :leave]`: metadata `id`, `reason`.

  Workers and failures:

    * `[:octoroom, :worker, :start]`: metadata `id`, `module`, `resumed`.
    * `[:octoroom, :worker, :exit]`: a worker the room didn't stop.
      Metadata `id`, `reason`.
    * `[:octoroom, :failure]`: something will be retried with backoff, or,
      with `given_up: true`, won't be. Measurements `count`; metadata `id`
      (participant id, `:worker` or `:media`), `name`, `reason`, `given_up`.
    * `[:octoroom, :policy, :error]`: a room module callback raised,
      threw, exited or returned the wrong shape, and the room kept its last
      good answer (see `Octoroom.Room`). Emitted when a failure starts or
      changes, not on every reconcile. Metadata `callback` (`:mount`,
      `:workers`, `:subscriptions` or `:update_meta`), `participant_id`
      (the listener, or the participant being updated; nil otherwise),
      `reason`.
    * `[:octoroom, :janitor, :sweep]`: measurements `deleted_rooms`.
  """

  require Logger

  @doc "Every event name above, for `:telemetry.attach_many/4`."
  def events do
    [
      [:octoroom, :participant, :connected],
      [:octoroom, :participant, :first_pull],
      [:octoroom, :outlet, :live],
      [:octoroom, :cloudflare, :request],
      [:octoroom, :peer, :connect],
      [:octoroom, :pull, :stop],
      [:octoroom, :room, :start],
      [:octoroom, :room, :stop],
      [:octoroom, :room, :recovered],
      [:octoroom, :participant, :join],
      [:octoroom, :participant, :resume],
      [:octoroom, :participant, :leave],
      [:octoroom, :worker, :start],
      [:octoroom, :worker, :exit],
      [:octoroom, :failure],
      [:octoroom, :policy, :error],
      [:octoroom, :janitor, :sweep]
    ]
  end

  @join_events [
    [:octoroom, :participant, :connected],
    [:octoroom, :participant, :first_pull],
    [:octoroom, :outlet, :live]
  ]

  @doc """
  Logs a line for each step of a join, to see where the time goes:

      [info] Octoroom room-1 4f2a connected in 3412 ms: join 80, media 600, ice 2001 (timed out), publish 410, connect 190
      [info] Octoroom room-1 4f2a hears someone 905 ms after connecting (4317 ms after joining)
      [info] Octoroom room-1 output assistant/voice live after 2210 ms

  Options: `:level` (default `:info`). Call it once, e.g. in your
  application's `start/2`; `detach_default_logger/0` undoes it.
  """
  def attach_default_logger(opts \\ []) do
    level = Keyword.get(opts, :level, :info)

    :telemetry.attach_many(
      __MODULE__.DefaultLogger,
      @join_events,
      &__MODULE__.handle_event/4,
      %{level: level}
    )
  end

  @doc "Detaches the handler `attach_default_logger/1` attached."
  def detach_default_logger, do: :telemetry.detach(__MODULE__.DefaultLogger)

  @doc false
  def handle_event(event, measurements, meta, %{level: level}) do
    Logger.log(level, fn -> format(event, measurements, meta) end)
  end

  @doc false
  def format([:octoroom, :participant, :connected], m, meta) do
    steps =
      if Map.has_key?(m, :client_ice_ms) do
        ice = if meta[:ice_timed_out], do: " (timed out)", else: ""

        [
          {"join", m[:client_join_ms]},
          {"media", m[:client_media_ms]},
          {"ice", m.client_ice_ms, ice},
          {"publish", m[:client_publish_ms]},
          {"connect", m[:client_connect_ms]}
        ]
      else
        [
          {"before publish", m.before_publish_ms},
          {"publish", m.publish_ms},
          {"connect", m.connect_ms}
        ]
      end

    steps =
      for step <- steps, elem(step, 1) != nil do
        case step do
          {name, ms} -> "#{name} #{round(ms)}"
          {name, ms, note} -> "#{name} #{round(ms)}#{note}"
        end
      end

    "Octoroom #{meta.room_id} #{meta.id} connected in #{m.duration_ms} ms: " <>
      Enum.join(steps, ", ")
  end

  def format([:octoroom, :participant, :first_pull], m, meta) do
    "Octoroom #{meta.room_id} #{meta.id} hears someone #{m.since_connected_ms} ms " <>
      "after connecting (#{m.duration_ms} ms after joining)"
  end

  def format([:octoroom, :outlet, :live], m, meta) do
    "Octoroom #{meta.room_id} output #{meta.name} live after #{m.duration_ms} ms"
  end
end
