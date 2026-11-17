defmodule Octoroom.Telemetry do
  @moduledoc """
  The `:telemetry` events Octoroom emits. Measurements are maps of numbers;
  metadata always includes `room_id` where there is a room.

  Cloudflare:

    * `[:octoroom, :cloudflare, :request]`: one HTTP attempt.
      Measurements `duration_ms`; metadata `method`, `path`.
    * `[:octoroom, :adapter, :create]`: adapters created in one call.
      Measurements `count`.
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
    * `[:octoroom, :janitor, :sweep]`: measurements `closed` (adapters),
      `deleted_rooms`.
  """

  @doc "Every event name above, for `:telemetry.attach_many/4`."
  def events do
    [
      [:octoroom, :cloudflare, :request],
      [:octoroom, :adapter, :create],
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
      [:octoroom, :janitor, :sweep]
    ]
  end
end
