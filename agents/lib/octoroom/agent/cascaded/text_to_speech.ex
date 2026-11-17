defmodule Octoroom.Agent.Cascaded.TextToSpeech do
  @moduledoc false

  # Inworld only so far; more providers come over from Subvocal as wanted.

  alias Octoroom.Agent.Cascaded.Inworld

  def speech(opts) do
    case Keyword.fetch!(opts, :provider) do
      :inworld -> Inworld.speech(opts)
      provider -> {:error, {:unsupported_cascaded_tts_provider, provider}}
    end
  end

  def stream_speech(opts) do
    case Keyword.fetch!(opts, :provider) do
      :inworld -> stream_inworld(opts)
      provider -> {:error, {:unsupported_cascaded_tts_provider, provider}}
    end
  end

  defp stream_inworld(opts) do
    if Keyword.get(opts, :stream, false) do
      Inworld.stream_speech(opts)
    else
      on_audio = Keyword.get(opts, :on_audio, fn _audio -> :ok end)

      with {:ok, audio} <- speech(opts) do
        on_audio.(audio)
        :ok
      end
    end
  end
end
