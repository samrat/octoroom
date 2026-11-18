defmodule Octoroom.Agent.STT.AssemblyAITest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.STT
  alias Octoroom.Agent.STT.AssemblyAI

  defp state(overrides \\ %{}) do
    Map.merge(%{owner: self(), format_turns: false, pending: "", terminating?: false}, overrides)
  end

  defp turn(text, fields) do
    {:text, Jason.encode!(Map.merge(%{"type" => "Turn", "transcript" => text}, fields))}
  end

  test "is registered, with its defaults" do
    assert {:ok, AssemblyAI, opts} =
             STT.resolve(model: "assembly_ai:universal-streaming-multilingual")

    assert opts[:model] == "universal-streaming-multilingual"
    assert opts[:sample_rate] == 16_000 and opts[:format_turns] == false
  end

  test "reports turns in progress as partials and ended turns as finals" do
    {:ok, state} = AssemblyAI.handle_frame(turn("hel", %{"end_of_turn" => false}), state())
    assert_receive {:stt, _, {:partial, "hel"}}
    assert state.pending == "hel"

    {:ok, state} = AssemblyAI.handle_frame(turn(" hello ", %{"end_of_turn" => true}), state)
    assert_receive {:stt, _, {:final, "hello"}}
    assert state.pending == ""
  end

  test "with format_turns, only the formatted turn is final" do
    state = state(%{format_turns: true})

    {:ok, state} =
      AssemblyAI.handle_frame(
        turn("hello world", %{"end_of_turn" => true, "turn_is_formatted" => false}),
        state
      )

    refute_receive {:stt, _, {:final, _}}
    assert state.pending == "hello world"

    {:ok, _state} =
      AssemblyAI.handle_frame(
        turn("Hello, world.", %{"end_of_turn" => true, "turn_is_formatted" => true}),
        state
      )

    assert_receive {:stt, _, {:final, "Hello, world."}}
  end

  test "finalize forces an endpoint, or answers at once when nothing is pending" do
    assert {:ok, _state} = AssemblyAI.handle_cast(:finalize, state())
    assert_receive {:stt, _, {:final, ""}}

    assert {:reply, {:text, json}, _state} =
             AssemblyAI.handle_cast(:finalize, state(%{pending: "hi"}))

    assert Jason.decode!(json) == %{"type" => "ForceEndpoint"}
  end

  test "close terminates the session, and the disconnect after it is intentional" do
    assert {:reply, {:text, json}, state} = AssemblyAI.handle_cast(:terminate_session, state())
    assert Jason.decode!(json) == %{"type" => "Terminate"}

    {:ok, _state} = AssemblyAI.handle_frame({:text, ~s({"type":"Termination"})}, state)
    assert_receive {:stt, _, :finished}

    AssemblyAI.handle_disconnect(%{reason: {:remote, 1000, ""}}, state)
    assert_receive {:stt, _, {:disconnected, {:remote, 1000, ""}, %{intentional?: true}}}

    AssemblyAI.handle_disconnect(%{reason: :closed}, state())
    assert_receive {:stt, _, {:disconnected, :closed, %{intentional?: false}}}
  end

  test "reports errors with their message" do
    {:ok, _state} = AssemblyAI.handle_frame({:text, ~s({"error":"Invalid API key"})}, state())
    assert_receive {:stt, _, {:error, %{message: "Invalid API key"} = reason}}
    assert STT.error_message(reason) == "Invalid API key"
  end

  test "sends audio as binary frames, skipping empty ones" do
    assert {:reply, {:binary, <<1, 2, 3>>}, _} =
             AssemblyAI.handle_cast({:send_audio, <<1, 2, 3>>}, state())

    assert {:ok, _} = AssemblyAI.handle_cast({:send_audio, <<>>}, state())
  end
end
