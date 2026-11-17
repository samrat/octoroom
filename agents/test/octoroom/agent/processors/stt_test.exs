defmodule Octoroom.Agent.Processors.STTTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.Processors.STT

  # A stage that had a socket, with this test process as its host.
  defp stage(socket) do
    {:ok, state} = STT.init([provider: :soniox], %{})
    %{state | socket: socket, connected?: true, runner: self(), api_key: "key"}
  end

  test "a failed socket is dropped and a reconnect is scheduled" do
    socket = spawn(fn -> :ok end)
    state = stage(socket)
    error = %{"error_code" => 408, "error_message" => "Request timeout."}

    {_effects, state} = STT.handle_info({:soniox_socket, socket, {:error, error}}, state)
    assert state.socket == nil and state.failed?

    # Late events from the old socket no longer reach the stage.
    assert {[], ^state} =
             STT.handle_info({:soniox_socket, socket, {:disconnected, :closed, %{}}}, state)

    ref = state.ref
    assert_receive {:octoroom_agent_stt_reconnect, ^ref}, 1_500
  end

  test "an intentional disconnect doesn't reconnect" do
    socket = spawn(fn -> :ok end)
    state = stage(socket)

    {_effects, state} =
      STT.handle_info(
        {:soniox_socket, socket, {:disconnected, :closed, %{intentional?: true}}},
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

  defp audio(ms),
    do: %Octoroom.Agent.Frames.InputAudio{audio: :binary.copy(<<0, 0>>, div(16_000 * ms, 1_000))}
end
