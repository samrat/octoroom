defmodule Octoroom.Agent.Cascaded.TextToSpeechTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.Cascaded.TextToSpeech

  test "rejects unsupported TTS providers" do
    assert {:error, {:unsupported_cascaded_tts_provider, :unknown}} =
             TextToSpeech.speech(provider: :unknown)
  end

  test "uses non-streaming Inworld speech by default for chunked playback" do
    parent = self()

    request_fun = fn url, _opts ->
      send(parent, {:tts_url, url})
      {:ok, %{status: 200, body: %{"audioContent" => Base.encode64(<<1, 2, 3>>)}}}
    end

    assert :ok =
             TextToSpeech.stream_speech(
               provider: :inworld,
               token: "key",
               input: "Hello.",
               request_fun: request_fun,
               on_audio: fn audio -> send(parent, {:audio, audio}) end
             )

    assert_receive {:tts_url, "https://api.inworld.ai/tts/v1/voice"}
    assert_receive {:audio, <<1, 2, 3>>}
  end
end
