defmodule Octoroom.Agent.Cascaded.AudioTurn do
  @moduledoc false

  # Helpers for the audio-input mode of the cascaded backend
  # (`speech_to_text: false`), where the LLM hears each user turn as audio
  # instead of an STT transcript.

  alias ReqLLM.Context
  alias ReqLLM.Message.ContentPart

  @transcribe_prompt "Transcribe this audio verbatim. Reply with only the transcript, " <>
                       "or nothing if no words are spoken."

  @doc """
  A history message carrying one user turn as WAV audio, after a `[speaker]`
  label when there is one.
  """
  def message(pcm, sample_rate, turn_id, speaker \\ nil) do
    label = if speaker, do: [ContentPart.text("[#{speaker}]")], else: []
    audio = ContentPart.file(wav(pcm, sample_rate), "turn-#{turn_id}.wav", "audio/wav")
    %{role: "user", content: label ++ [audio], audio_turn_id: turn_id}
  end

  @doc "Replaces the audio of turn `turn_id` in `history` with its transcript."
  def replace_with_transcript(history, turn_id, text) do
    Enum.map(history, fn
      %{audio_turn_id: ^turn_id} -> %{role: "user", content: text}
      message -> message
    end)
  end

  @doc "Transcribes one turn with a Gemini model through ReqLLM."
  def transcribe(pcm, sample_rate, model) do
    message =
      Context.user([
        ContentPart.text(@transcribe_prompt),
        ContentPart.file(wav(pcm, sample_rate), "turn.wav", "audio/wav")
      ])

    with {:ok, response} <-
           ReqLLM.generate_text(%{provider: :google, id: model}, [message],
             reasoning_effort: :minimal
           ) do
      {:ok, String.trim(ReqLLM.Response.text(response) || "")}
    end
  end

  @doc "Wraps 16-bit mono PCM in a WAV header."
  def wav(pcm, sample_rate) do
    byte_rate = sample_rate * 2

    <<"RIFF", 36 + byte_size(pcm)::little-32, "WAVE", "fmt ", 16::little-32, 1::little-16,
      1::little-16, sample_rate::little-32, byte_rate::little-32, 2::little-16, 16::little-16,
      "data", byte_size(pcm)::little-32, pcm::binary>>
  end

  def duration_ms(pcm, sample_rate), do: div(byte_size(pcm) * 1_000, sample_rate * 2)
end
