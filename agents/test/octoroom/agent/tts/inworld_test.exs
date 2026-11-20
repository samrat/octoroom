defmodule Octoroom.Agent.TTS.InworldTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.TTS.Inworld

  defp fake_socket(parent) do
    spawn(fn ->
      receive do
        {:"$websockex_cast", {:speak, caller, ref, text, config}} ->
          send(parent, {:speak, text, config})
          send(caller, {ref, {:audio, <<9, 9>>}})
          send(caller, {ref, :done})
      end

      Process.sleep(:infinity)
    end)
  end

  test "speaks a context on the connection it is given" do
    parent = self()

    assert :ok =
             Inworld.stream("Hello", &send(parent, {:audio, &1}),
               api_key: "key",
               connection: fake_socket(parent),
               model: "inworld-tts-2",
               voice: "Dennis",
               delivery_mode: "STABLE"
             )

    assert_receive {:speak, "Hello", config}

    assert config == %{
             voiceId: "Dennis",
             modelId: "inworld-tts-2",
             audioConfig: %{audioEncoding: "LINEAR16", sampleRateHertz: 24_000},
             deliveryMode: "STABLE"
           }

    assert_receive {:audio, <<9, 9>>}
  end

  test "connect/1 keeps a connection it is given" do
    opts = [api_key: "key", connection: self()]
    assert {:ok, ^opts} = Inworld.connect(opts)
  end

  test "without a key, connect/1 opens nothing and speaking reports it" do
    assert {:ok, opts} = Inworld.connect(api_key: "")
    refute Keyword.has_key?(opts, :connection)

    assert {:error, {:missing_env, "INWORLD_API_KEY"}} =
             Inworld.stream("Hello", fn _ -> :ok end, api_key: "")
  end
end
