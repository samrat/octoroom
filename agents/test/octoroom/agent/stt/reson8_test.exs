defmodule Octoroom.Agent.STT.Reson8Test do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.STT
  alias Octoroom.Agent.STT.Reson8

  defp state(overrides \\ %{}) do
    Map.merge(
      %{owner: self(), flushes: 0, flushed: [], next_id: 0, terminating?: false},
      overrides
    )
  end

  defp transcript(text, fields \\ %{}) do
    {:text, Jason.encode!(Map.merge(%{"type" => "transcript", "text" => text}, fields))}
  end

  defp confirmation(id), do: {:text, Jason.encode!(%{"type" => "flush_confirmation", "id" => id})}

  test "is registered, with rumble-2 by default" do
    assert {:ok, Reson8, opts} = STT.resolve(provider: :reson8)
    assert opts[:model] == "rumble-2" and opts[:sample_rate] == 16_000

    assert {:ok, Reson8, opts} = STT.resolve(model: "reson8:resonant-1")
    assert opts[:model] == "resonant-1"
  end

  test "needs RESON8_API_KEY" do
    if System.get_env("RESON8_API_KEY") == nil do
      assert {:error, {:missing_env, "RESON8_API_KEY"}} = STT.start_link(:reson8)
    end
  end

  test "reports interim transcripts as partials and final ones as finals" do
    {:ok, state} = Reson8.handle_frame(transcript(" hel ", %{"is_final" => false}), state())
    assert_receive {:stt, _, {:partial, "hel"}}

    {:ok, _state} = Reson8.handle_frame(transcript("hello", %{"is_final" => true}), state)
    assert_receive {:stt, _, {:final, "hello"}}

    {:ok, _state} = Reson8.handle_frame(transcript(""), state())
    refute_receive {:stt, _, _}
  end

  test "finalize flushes, and answers with one final when Reson8 confirms" do
    assert {:reply, {:text, json}, state} = Reson8.handle_cast(:finalize, state())
    assert Jason.decode!(json) == %{"type" => "flush_request", "id" => "0"}

    {:ok, state} = Reson8.handle_frame(transcript("hello", %{"is_final" => true}), state)
    {:ok, state} = Reson8.handle_frame(transcript("world", %{"is_final" => true}), state)
    refute_receive {:stt, _, {:final, _}}

    {:ok, state} = Reson8.handle_frame(confirmation("0"), state)
    assert_receive {:stt, _, {:final, "hello world"}}
    assert state.flushes == 0

    {:reply, _, state} = Reson8.handle_cast(:finalize, state)
    {:ok, _state} = Reson8.handle_frame(confirmation("1"), state)
    assert_receive {:stt, _, {:final, ""}}
  end

  test "close flushes, then finishes and closes the socket" do
    assert {:reply, {:text, json}, state} = Reson8.handle_cast(:terminate_session, state())
    assert Jason.decode!(json) == %{"type" => "flush_request", "id" => "close"}
    assert {:ok, _} = Reson8.handle_cast({:send_audio, <<1>>}, state)

    {:ok, state} = Reson8.handle_frame(transcript("bye", %{"is_final" => true}), state)
    assert_receive {:stt, _, {:final, "bye"}}

    assert {:close, state} = Reson8.handle_frame(confirmation("close"), state)
    assert_receive {:stt, _, :finished}

    Reson8.handle_disconnect(%{reason: {:local, :normal}}, state)
    assert_receive {:stt, _, {:disconnected, {:local, :normal}, %{intentional?: true}}}

    Reson8.handle_disconnect(%{reason: {:remote, 1011, "internal_error"}}, state())

    assert_receive {:stt, _,
                    {:disconnected, {:remote, 1011, "internal_error"}, %{intentional?: false}}}
  end

  test "sends audio as binary frames, skipping empty ones" do
    assert {:reply, {:binary, <<1, 2, 3>>}, _} =
             Reson8.handle_cast({:send_audio, <<1, 2, 3>>}, state())

    assert {:ok, _} = Reson8.handle_cast({:send_audio, <<>>}, state())
  end
end
