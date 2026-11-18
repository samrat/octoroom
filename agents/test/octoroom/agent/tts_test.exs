defmodule Octoroom.Agent.TTSTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.TTS

  # A provider with only `synthesize/2`, used by module, unregistered.
  defmodule OneShot do
    @behaviour Octoroom.Agent.TTS

    @impl true
    def default_options, do: [voice: "plain"]

    @impl true
    def synthesize(text, opts), do: {:ok, "#{opts[:voice]}:#{text}"}
  end

  # A provider with only `stream/3`.
  defmodule Chunks do
    @behaviour Octoroom.Agent.TTS

    @impl true
    def stream(text, on_audio, _opts) do
      text |> String.graphemes() |> Enum.each(on_audio)
      :ok
    end
  end

  test "rejects unknown providers" do
    assert {:error, {:unknown_provider, TTS, :unknown}} = TTS.synthesize(:unknown, "Hi")
    assert {:error, {:unknown_provider, TTS, "nope"}} = TTS.synthesize("nope", "Hi")
    assert {:error, {:unknown_provider, TTS, String}} = TTS.synthesize(String, "Hi")
  end

  test "resolves names, strings and provider:model specs, with the provider's defaults" do
    assert {:ok, TTS.Inworld, opts} = TTS.resolve(provider: "inworld")
    assert opts[:model] == "inworld-tts-2" and opts[:voice] == "Ashley"

    assert {:ok, TTS.Inworld, opts} = TTS.resolve(%{model: "inworld:inworld-tts-1.5-max"})
    assert opts[:model] == "inworld-tts-1.5-max"

    # Given options win over defaults; nil ones don't count.
    assert {:ok, TTS.Inworld, opts} = TTS.resolve(provider: :inworld, voice: "Dennis", model: nil)
    assert opts[:voice] == "Dennis" and opts[:model] == "inworld-tts-2"
  end

  test "a module provider works unregistered, either callback standing in for the other" do
    parent = self()

    assert {:ok, "plain:Hi"} = TTS.synthesize(OneShot, "Hi")
    assert :ok = TTS.stream(OneShot, "Hi", &send(parent, {:audio, &1}), voice: "loud")
    assert_receive {:audio, "loud:Hi"}

    assert {:ok, "abc"} = TTS.synthesize(Chunks, "abc")
  end

  test "Inworld makes one plain request with stream: false" do
    parent = self()

    request_fun = fn url, _opts ->
      send(parent, {:tts_url, url})
      {:ok, %{status: 200, body: %{"audioContent" => Base.encode64(<<1, 2, 3>>)}}}
    end

    assert :ok =
             TTS.stream(:inworld, "Hello.", fn audio -> send(parent, {:audio, audio}) end,
               api_key: "key",
               stream: false,
               request_fun: request_fun
             )

    assert_receive {:tts_url, "https://api.inworld.ai/tts/v1/voice"}
    assert_receive {:audio, <<1, 2, 3>>}
  end
end
