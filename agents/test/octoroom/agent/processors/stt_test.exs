defmodule Octoroom.Agent.Processors.STTTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.Processors.STT

  # A stage that had a socket, with this test process as its host.
  defp stage(socket) do
    {:ok, state} = STT.init([provider: :soniox, model: "stt-rt-v6"], %{})
    %{state | socket: socket, connected?: true, runner: self()}
  end

  test "a failed socket is dropped and a reconnect is scheduled" do
    socket = spawn(fn -> :ok end)
    state = stage(socket)

    {_effects, state} =
      STT.handle_info({:stt, socket, {:error, %{code: 408, message: "Request timeout."}}}, state)

    assert state.socket == nil and state.failed?

    # Late events from the old socket no longer reach the stage.
    assert {[], ^state} =
             STT.handle_info({:stt, socket, {:disconnected, :closed, %{}}}, state)

    ref = state.ref
    assert_receive {:octoroom_agent_stt_reconnect, ^ref}, 1_500
  end

  test "an intentional disconnect doesn't reconnect" do
    socket = spawn(fn -> :ok end)
    state = stage(socket)

    {_effects, state} =
      STT.handle_info(
        {:stt, socket, {:disconnected, :closed, %{intentional?: true}}},
        state
      )

    refute state.failed?
    refute_receive {:octoroom_agent_stt_reconnect, _}, 1_200
  end

  test "audio held while connecting is capped at 5 s" do
    state = %{stage(nil) | connected?: false}
    {_effects, state} = STT.handle_frame(audio(8_000), :downstream, state)
    assert byte_size(state.buffer) == 16_000 * 2 * 5
  end

  defmodule CaptureSTT do
    @behaviour Octoroom.Agent.STT

    @impl true
    def default_options, do: [sample_rate: 16_000]

    @impl true
    def start_link(_opts), do: {:ok, self()}

    @impl true
    def send_audio(pid, audio), do: send(pid, {:sent_audio, byte_size(audio)}) && :ok

    @impl true
    def finalize(pid), do: send(pid, :finalized) && :ok

    @impl true
    def close(_pid), do: :ok
  end

  test "sends 20 ms chunks immediately by default and respects provider chunk_ms" do
    {:ok, state} = STT.init([provider: CaptureSTT, model: "m"], %{})
    state = %{state | socket: self(), connected?: true}

    {_effects, state} = STT.handle_frame(audio(20), :downstream, state)
    assert_received {:sent_audio, 640}
    assert state.buffer == <<>>

    {:ok, aai} = STT.init([provider: :assembly_ai, model: "assemblyai-stt-3-7-realtime"], %{})
    assert aai.target_chunk_bytes == div(16_000 * 2 * 50, 1_000)
  end

  test "FinalizeTranscript flushes eligible buffered audio before finalizing" do
    {:ok, state} = STT.init([provider: CaptureSTT, model: "m", chunk_ms: 20], %{})
    state = %{state | socket: self(), connected?: true, buffer: audio(20).audio}

    assert {[], %{buffer: <<>>}} =
             STT.handle_frame(%Octoroom.Agent.Frames.FinalizeTranscript{}, :upstream, state)

    assert_received {:sent_audio, 640}
    assert_received :finalized
  end

  defp audio(ms),
    do: %Octoroom.Agent.Frames.InputAudio{audio: :binary.copy(<<0, 0>>, div(16_000 * ms, 1_000))}
end
