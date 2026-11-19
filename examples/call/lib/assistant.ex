defmodule Call.Assistant do
  @moduledoc """
  The call assistant: one voice agent that hears everyone in the call.
  `Call.Room` adds it with `agent/3`; the agent lab's settings arrive as
  `ctx.args` (see `Call.Agent`).
  """

  use Octoroom.Agent

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

  @impl true
  def backend(%{args: %{pipeline: :half}}), do: %{stt: false}
  def backend(%{args: %{pipeline: :live}}), do: %Octoroom.Agent.Backend.GeminiLive{}
  def backend(_ctx), do: %{}

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
