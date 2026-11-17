defmodule Octoroom.Agent.Processors.AssistantCollector do
  @moduledoc """
  Collects the assistant's reply and sends it back to the context as an
  `AssistantMessage`.

  Place it after TTS: `LLMResponseEnd` reaches it once the reply's audio is
  out. Text from rounds that end in tool calls (a spoken preamble such as
  "let me check", or the tools stage's progress message) joins the final
  reply. On an interruption, what was said
  so far goes upstream marked `interrupted?: true`.
  """

  use Octoroom.Agent.Processor

  alias Octoroom.Agent.Frames

  @impl true
  def init(_opts, _ctx), do: {:ok, %{text: "", tool_round?: false, active?: false}}

  @impl true
  # A round after tool calls continues the reply, separated by a space.
  def handle_frame(%Frames.LLMResponseStart{} = frame, :downstream, state) do
    text = if state.text == "", do: "", else: String.trim_trailing(state.text) <> " "
    {[{:push, frame, :downstream}], %{state | text: text, active?: true, tool_round?: false}}
  end

  def handle_frame(%Frames.LLMText{text: text} = frame, :downstream, state) do
    # Progress speech arrives as " message" between rounds.
    text = if state.text == "", do: String.trim_leading(text), else: text
    {[{:push, frame, :downstream}], %{state | text: state.text <> text}}
  end

  def handle_frame(%Frames.ToolCalls{} = frame, :downstream, state),
    do: {[{:push, frame, :downstream}], %{state | tool_round?: true}}

  def handle_frame(%Frames.LLMResponseEnd{} = frame, :downstream, %{tool_round?: true} = state),
    do: {[{:push, frame, :downstream}], state}

  def handle_frame(%Frames.LLMResponseEnd{} = frame, :downstream, state) do
    message = %Frames.AssistantMessage{text: String.trim(state.text)}

    {[{:push, frame, :downstream}, {:push, message, :upstream}],
     %{state | text: "", active?: false}}
  end

  def handle_frame(%Frames.Interruption{}, _direction, %{active?: true} = state) do
    message = %Frames.AssistantMessage{text: String.trim(state.text), interrupted?: true}
    {[{:push, message, :upstream}], %{state | text: "", active?: false, tool_round?: false}}
  end

  def handle_frame(%Frames.Interruption{}, _direction, state), do: {[], state}

  def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}
end
