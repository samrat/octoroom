defmodule Octoroom.Agent.TTS.OpenAITest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.TTS
  alias Octoroom.Agent.TTS.OpenAI

  test "is registered, with its defaults" do
    assert {:ok, OpenAI, opts} = TTS.resolve(model: "openai:tts-1")
    assert opts[:model] == "tts-1" and opts[:voice] == "alloy" and opts[:sample_rate] == 24_000
  end

  test "synthesizes raw PCM in one request" do
    request_fun = fn url, opts ->
      assert url == "https://api.openai.com/v1/audio/speech"
      assert {"Authorization", "Bearer key"} in opts[:headers]

      assert opts[:json] == %{
               model: "gpt-4o-mini-tts",
               voice: "coral",
               input: "Hello",
               response_format: "pcm",
               instructions: "Cheerful."
             }

      {:ok, %{status: 200, body: <<1, 0, 2, 0>>}}
    end

    assert {:ok, <<1, 0, 2, 0>>} =
             TTS.synthesize(:openai, "Hello",
               api_key: "key",
               voice: "coral",
               instructions: "Cheerful.",
               request_fun: request_fun
             )
  end

  test "streams whole samples, holding an odd byte for the next chunk" do
    parent = self()

    request_fun = fn _url, opts ->
      into = opts[:into]
      acc = {Req.new(), Req.Response.new(status: 200)}
      {:cont, acc} = into.({:data, <<1, 0, 2>>}, acc)
      {:cont, _acc} = into.({:data, <<0, 3, 0>>}, acc)
      {:ok, %{status: 200}}
    end

    assert :ok =
             TTS.stream(:openai, "Hello", &send(parent, {:audio, &1}),
               api_key: "key",
               request_fun: request_fun
             )

    assert_receive {:audio, <<1, 0>>}
    assert_receive {:audio, <<2, 0, 3, 0>>}
  end

  test "a failed stream returns the error body instead of playing it" do
    parent = self()
    error = Jason.encode!(%{"error" => %{"message" => "bad key"}})

    request_fun = fn _url, opts ->
      {:cont, {_req, resp}} =
        opts[:into].({:data, error}, {Req.new(), Req.Response.new(status: 401)})

      {:ok, resp}
    end

    assert {:error, {:openai_speech_failed, 401, %{"error" => %{"message" => "bad key"}}}} =
             TTS.stream(:openai, "Hello", &send(parent, {:audio, &1}),
               api_key: "bad",
               request_fun: request_fun
             )

    refute_receive {:audio, _}
  end

  test "only speaks at 24 kHz" do
    assert {:error, {:unsupported_sample_rate, 16_000, only: 24_000}} =
             TTS.synthesize(:openai, "Hello", api_key: "key", sample_rate: 16_000)
  end
end
