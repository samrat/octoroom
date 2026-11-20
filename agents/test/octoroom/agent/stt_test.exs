defmodule Octoroom.Agent.STTTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.STT

  # An unregistered provider that echoes audio back as finals, without
  # `finalize/1`.
  defmodule Echo do
    @behaviour Octoroom.Agent.STT

    @impl true
    def default_options, do: [model: "echo-1", sample_rate: 8_000]

    @impl true
    def start_link(opts) do
      owner = Keyword.fetch!(opts, :owner)
      pid = spawn_link(fn -> loop(owner) end)
      send(pid, {:connect, opts})
      {:ok, pid}
    end

    @impl true
    def send_audio(pid, audio), do: send(pid, {:audio, audio}) && :ok

    @impl true
    def close(pid), do: send(pid, :close) && :ok

    defp loop(owner) do
      receive do
        {:connect, opts} ->
          STT.notify(owner, {:partial, "#{opts[:model]}@#{opts[:sample_rate]}"})
          STT.notify(owner, :connected)
          loop(owner)

        {:audio, audio} ->
          STT.notify(owner, {:final, audio})
          loop(owner)

        :close ->
          STT.notify(owner, :finished)
      end
    end
  end

  test "a module provider runs unregistered, with its defaults, and reports to the owner" do
    assert {:ok, stt} = STT.start_link(Echo, sample_rate: 16_000)
    assert_receive {:stt, ^stt, {:partial, "echo-1@16000"}}
    assert_receive {:stt, ^stt, :connected}

    Echo.send_audio(stt, "hello")
    assert_receive {:stt, ^stt, {:final, "hello"}}

    # No `finalize/1`: asking is a no-op.
    assert :ok = STT.finalize(Echo, stt)

    Echo.close(stt)
    assert_receive {:stt, ^stt, :finished}
  end

  test "resolves provider:model specs and rejects unknown providers" do
    assert {:ok, STT.Soniox, opts} = STT.resolve(model: "soniox:stt-rt-v4")
    assert opts[:model] == "stt-rt-v4" and opts[:sample_rate] == 16_000

    assert {:error, {:unknown_provider, STT, "deepgram"}} = STT.start_link("deepgram")
    assert {:error, {:no_provider, STT}} = STT.resolve(model: "stt-rt-v4")
    assert {:error, {:no_model, STT.Soniox}} = STT.start_link(:soniox)
  end

  test "a missing API key fails before connecting" do
    if System.get_env("SONIOX_API_KEY") == nil do
      assert {:error, {:missing_env, "SONIOX_API_KEY"}} = STT.start_link("soniox:stt-rt-v6")
    end
  end

  test "error messages for users" do
    assert STT.error_message(%{code: 408, message: "Request timeout."}) == "Request timeout."
    assert STT.error_message(%{code: 408, message: nil}) == "STT error 408"
    assert STT.error_message(:closed) == "STT error"
  end
end
