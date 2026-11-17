defmodule Octoroom.Agent.Cascaded.InworldTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.Cascaded.Inworld

  test "sends an Inworld TTS request and decodes returned audio content" do
    request_fun = fn url, opts ->
      assert url == "https://api.inworld.ai/tts/v1/voice"
      assert {"Authorization", "Basic base64-key"} in opts[:headers]
      assert {"Content-Type", "application/json"} in opts[:headers]
      assert opts[:receive_timeout] == 60_000

      assert opts[:json] == %{
               text: "Hello",
               voice_id: "Dennis",
               model_id: "inworld-tts-2",
               audio_config: %{
                 audio_encoding: "LINEAR16",
                 sample_rate_hertz: 24_000
               }
             }

      {:ok, %{status: 200, body: %{"audioContent" => Base.encode64(<<1, 2, 3>>)}}}
    end

    assert {:ok, <<1, 2, 3>>} =
             Inworld.speech(
               token: "base64-key",
               input: "Hello",
               voice: "Dennis",
               model: "inworld-tts-2",
               request_fun: request_fun
             )
  end

  test "returns provider tagged errors for non-success responses" do
    request_fun = fn _url, _opts -> {:ok, %{status: 401, body: %{"error" => "bad auth"}}} end

    assert {:error, {:inworld_speech_failed, 401, %{"error" => "bad auth"}}} =
             Inworld.speech(token: "bad-key", input: "Hello", request_fun: request_fun)
  end

  test "returns a tagged error for invalid audio content" do
    request_fun = fn _url, _opts -> {:ok, %{status: 200, body: %{"audioContent" => "%%%"}}} end

    assert {:error, :invalid_inworld_audio_content} =
             Inworld.speech(token: "key", input: "Hello", request_fun: request_fun)
  end

  test "strips the wav header from non-streaming speech responses" do
    pcm = <<1, 0, 2, 0, 3, 0>>

    wav =
      "RIFF" <>
        <<0::32-little>> <>
        "WAVEfmt " <> <<0::size(128)>> <> "data" <> <<byte_size(pcm)::32-little>> <> pcm

    request_fun = fn _url, _opts ->
      {:ok, %{status: 200, body: %{"audioContent" => Base.encode64(wav)}}}
    end

    assert {:ok, ^pcm} = Inworld.speech(token: "key", input: "Hello", request_fun: request_fun)
  end

  test "keeps audio that looks like a truncated wav header" do
    audio = "RIFF" <> <<0::32-little>> <> "data"

    request_fun = fn _url, _opts ->
      {:ok, %{status: 200, body: %{"audioContent" => Base.encode64(audio)}}}
    end

    assert {:ok, ^audio} = Inworld.speech(token: "key", input: "Hello", request_fun: request_fun)
  end

  test "streams Inworld audio chunks and strips wav headers" do
    parent = self()

    wav_chunk =
      "RIFF" <>
        <<0::32-little>> <> "WAVEfmt " <> <<0::size(128)>> <> "data" <> <<3::32-little, 1, 2, 3>>

    raw_chunk = <<4, 5, 6>>

    request_fun = fn url, opts ->
      assert url == "https://api.inworld.ai/tts/v1/voice:stream"
      assert {"Authorization", "Basic base64-key"} in opts[:headers]
      assert opts[:decode_body] == false

      assert opts[:json] == %{
               text: "Hello",
               voiceId: "Dennis",
               modelId: "inworld-tts-2",
               audioConfig: %{
                 audioEncoding: "LINEAR16",
                 sampleRateHertz: 24_000
               }
             }

      into = opts[:into]
      req = Req.new()
      resp = Req.Response.new(status: 200)

      first =
        Jason.encode!(%{
          "result" => %{"audioChunk" => %{"audioContent" => Base.encode64(wav_chunk)}}
        })

      second = Jason.encode!(%{"result" => %{"audioContent" => Base.encode64(raw_chunk)}})

      {:cont, {req, resp}} = into.({:data, first <> "\n"}, {req, resp})
      {:cont, {_req, _resp}} = into.({:data, second}, {req, resp})

      {:ok, %{status: 200, body: ""}}
    end

    assert :ok =
             Inworld.stream_speech(
               token: "base64-key",
               input: "Hello",
               voice: "Dennis",
               model: "inworld-tts-2",
               request_fun: request_fun,
               on_audio: fn audio -> send(parent, {:audio, audio}) end
             )

    assert_receive {:audio, <<1, 2, 3>>}
    assert_receive {:audio, <<4, 5, 6>>}
  end
end
