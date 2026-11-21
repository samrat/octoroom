defmodule Octoroom.Agent.Processors.Transcriber do
  @moduledoc """
  Transcribes each `UserAudio` turn with an LLM, off the reply path.

  `UserAudio` passes through at once; the transcript follows later as a
  `Transcription` with the same `turn_id`, usually after the reply has
  started. `UserAudio` is uninterruptible, so a transcription survives the
  user interrupting the reply.

  Options: `:model` (a Gemini model, such as `"gemini-3.1-flash-lite"`;
  needed), and `:transcribe`, a
  `fn pcm, sample_rate -> {:ok, text} | {:error, reason} end` that replaces
  the model (for tests).
  """

  use Octoroom.Agent.Processor

  require Logger

  alias Octoroom.Agent.Cascaded.AudioTurn
  alias Octoroom.Agent.Frames

  @impl true
  def init(opts, _ctx) do
    model = Keyword.get(opts, :model)

    case {Keyword.get(opts, :transcribe), model} do
      {transcribe, _model} when is_function(transcribe, 2) ->
        {:ok, %{transcribe: transcribe, model: model}}

      {nil, model} when is_binary(model) ->
        {:ok,
         %{transcribe: fn pcm, rate -> AudioTurn.transcribe(pcm, rate, model) end, model: model}}

      _neither ->
        {:error, {:no_model, __MODULE__}}
    end
  end

  @impl true
  def handle_frame(%Frames.UserAudio{} = frame, :downstream, state) do
    transcribe = state.transcribe
    task = fn _emit -> transcribe.(frame.audio, frame.sample_rate) end

    meta = %{
      model: state.model,
      turn_id: frame.turn_id,
      audio_ms: audio_ms(frame.audio, frame.sample_rate)
    }

    {[{:push, frame, :downstream}, {:async, {:transcribe, frame.turn_id}, task, meta}], state}
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

  defp audio_ms(pcm, rate) when is_binary(pcm) and is_integer(rate) and rate > 0,
    do: div(byte_size(pcm) * 1_000, rate * 2)

  defp audio_ms(_pcm, _rate), do: nil
end
