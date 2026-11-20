defmodule Call.Assistant do
  @moduledoc """
  The call assistant: one voice agent that hears everyone in the call.
  `Call.Room` adds it with `agent/3`; the agent lab's settings arrive as
  `ctx.args` (see `Call.Agent`).
  """

  use Octoroom.Agent

  alias Octoroom.Agent.Pipeline.Spec
  alias Octoroom.Agent.Tool

  @impl true
  def instructions(_ctx) do
    """
    You are the assistant in a group voice call. Each line from the call starts with the
    speaker's name in brackets. People mostly talk to each other; only answer when someone
    addresses you, or when a question is left open that you can answer. Your replies are
    spoken aloud: a sentence or two, no markdown, and don't start with a name tag.
    """
  end

  @llm_and_tts [
    llm: [provider: :google, model: "gemini-3.5-flash", reasoning_effort: :minimal],
    tts: "inworld:inworld-tts-2"
  ]

  @impl true
  def pipeline(%{args: %{pipeline: :live}}),
    do: Spec.gemini_live(model: "gemini-3.1-flash-live-preview")

  def pipeline(%{args: %{pipeline: :half}}),
    do: Spec.default([stt: false, transcriber: [model: "gemini-3.1-flash-lite"]] ++ @llm_and_tts)

  def pipeline(_ctx), do: Spec.default([stt: "soniox:stt-rt-v6"] ++ @llm_and_tts)

  @impl true
  def tools(_ctx) do
    [
      %Tool{
        name: "whos_here",
        description: "Who is in the call right now, and who is asking.",
        parameters: %{type: "object", properties: %{}},
        handler: {__MODULE__, :whos_here}
      }
    ]
  end

  def whos_here(call, ctx) do
    %{participants: people} = Octoroom.Room.state(ctx.room_id)

    response = %{
      in_the_call: Enum.map(people, & &1.meta.name),
      asking: ctx.speaker && ctx.speaker.meta.name
    }

    %{id: call.id, name: call.name, response: response}
  end
end
