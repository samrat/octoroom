defmodule Octoroom.Agent.Processors.Transcriber do
  @moduledoc """
  Transcribes each `UserAudio` turn with an LLM, off the reply path.

  `UserAudio` passes through at once; the transcript follows later as a
  `Transcription` with the same `turn_id`, usually after the reply has
  started. `UserAudio` is uninterruptible, so a transcription survives the
  user interrupting the reply.

  Options: `:model` (default `"gemini-3.1-flash-lite"`), and `:transcribe`, a
  `fn pcm, sample_rate -> {:ok, text} | {:error, reason} end` that replaces
  the model (for tests).
  """

  use Octoroom.Agent.Processor

  require Logger

  alias Octoroom.Agent.Cascaded.AudioTurn
  alias Octoroom.Agent.Frames

  @impl true
  def init(opts, _ctx) do
    model = Keyword.get(opts, :model, "gemini-3.1-flash-lite")

    {:ok,
     %{
       transcribe:
         Keyword.get(opts, :transcribe) ||
           fn pcm, sample_rate -> AudioTurn.transcribe(pcm, sample_rate, model) end
     }}
  end

  @impl true
  def handle_frame(%Frames.UserAudio{} = frame, :downstream, state) do
    transcribe = state.transcribe
    task = fn _emit -> transcribe.(frame.audio, frame.sample_rate) end
    {[{:push, frame, :downstream}, {:async, {:transcribe, frame.turn_id}, task}], state}
  end

  def handle_frame(frame, direction, state), do: {[{:push, frame, direction}], state}

  @impl true
  def handle_async({:transcribe, turn_id}, {:done, {:ok, text}}, state) when text != "" do
    Logger.info("AUDIO_TURN event=transcript turn=#{turn_id} text=#{inspect(text)}")
    {[{:push, %Frames.Transcription{turn_id: turn_id, text: text}, :downstream}], state}
  end

  def handle_async({:transcribe, _turn_id}, {:done, {:ok, _empty}}, state), do: {[], state}

  def handle_async({:transcribe, turn_id}, {_status, reason}, state) do
    Logger.warning("AUDIO_TURN event=transcript_failed turn=#{turn_id} reason=#{inspect(reason)}")
    {[], state}
  end
end
