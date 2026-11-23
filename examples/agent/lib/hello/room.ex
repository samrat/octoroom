defmodule Hello.Room do
  @moduledoc """
  One person and a voice agent. Each page opens its own room, so the agent
  only ever talks to one person.

  The agent (`Hello.Assistant`, or `Hello.Booking` with
  `HELLO_AGENT=booking`) joins with the person (`workers/1`), hears their mic, and
  answers every turn (`respond: :always`). The person hears only the
  agent (`subscriptions/2`).
  """
  use Octoroom.Room
  import Octoroom.Agent, only: [agent: 3]

  @impl true
  def join(params, _socket) do
    meta = %{name: "Guest"}

    case params["pipeline"] do
      id when is_binary(id) ->
        if Hello.Assistant.valid_pipeline?(id),
          do: {:ok, Map.put(meta, :pipeline, id)},
          else: {:ok, meta}

      _ ->
        {:ok, meta}
    end
  end

  @impl true
  def workers(%{participants: []}), do: []

  def workers(room) do
    pipeline = selected_pipeline(room)
    info = Hello.Assistant.pipeline_info(pipeline)

    video? = Map.get(info, :video, false)

    opts =
      [
        hears: Enum.map(room.participants, &mic/1),
        sees: Enum.map(room.participants, &camera/1),
        video: video?,
        video_inputs: if(video?, do: :rtp, else: :client)
      ] ++
        if info.agent == Hello.Booking do
          [respond: :always]
        else
          [args: %{pipeline: info.id}]
        end

    [agent("assistant", info.agent, opts)]
  end

  defp selected_pipeline(room) do
    room.assigns[:pipeline] ||
      Enum.find_value(room.participants, fn p -> p.meta[:pipeline] || p.meta["pipeline"] end) ||
      Hello.Assistant.default_pipeline()
  end

  @impl true
  def subscriptions(_listener, _room), do: [track("assistant"), track("assistant/video")]
end
