defmodule Octoroom.Agent.Processors.TextChunker do
  @moduledoc """
  Splits the LLM's streamed text into `Text` chunks for TTS.

  `LLMText` passes through, and complete chunks follow it (see
  `Octoroom.Agent.Cascaded.TextChunker` for where chunks end). The rest is flushed
  on `LLMResponseEnd`. An interruption drops anything buffered.
  """

  use Octoroom.Agent.Processor

  alias Octoroom.Agent.Cascaded.TextChunker
  alias Octoroom.Agent.Frames

  @impl true
  def init(_opts, _ctx), do: {:ok, TextChunker.new()}

  @impl true
  def handle_frame(%Frames.LLMText{text: text} = frame, :downstream, chunker) do
    {chunks, chunker} = TextChunker.push(chunker, text)
    {[{:push, frame, :downstream} | text_frames(chunks)], chunker}
  end

  def handle_frame(%Frames.LLMResponseEnd{} = frame, :downstream, chunker) do
    {chunks, chunker} = TextChunker.flush(chunker)
    {text_frames(chunks) ++ [{:push, frame, :downstream}], chunker}
  end

  def handle_frame(%Frames.Interruption{}, _direction, _chunker), do: {[], TextChunker.new()}

  def handle_frame(frame, direction, chunker), do: {[{:push, frame, direction}], chunker}

  defp text_frames(chunks), do: Enum.map(chunks, &{:push, %Frames.Text{text: &1}, :downstream})
end
