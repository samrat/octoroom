defmodule Octoroom.Agent.STT.SonioxTest do
  use ExUnit.Case, async: true

  alias Octoroom.Agent.STT.Soniox

  test "sends Soniox config after the websocket connects" do
    state = %{
      owner: self(),
      final_tokens: [],
      terminating?: false,
      config: %{
        api_key: "soniox-key",
        model: "stt-rt-v6",
        audio_format: "pcm_s16le",
        sample_rate: 16_000,
        num_channels: 1,
        enable_endpoint_detection: true
      }
    }

    assert {:reply, {:text, config_json}, ^state} = Soniox.handle_info(:send_config, state)
    assert Jason.decode!(config_json) == stringify_keys(state.config)
    refute_receive {:stt, _, :connected}

    assert {:ok, ^state} = Soniox.handle_info(:notify_connected, state)
    assert_receive {:stt, _, :connected}
  end

  test "sends a finalize request and reports an empty final when nothing was pending" do
    state = %{owner: self(), final_tokens: [], config: %{}, terminating?: false}

    assert {:reply, {:text, json}, ^state} = Soniox.handle_cast(:finalize, state)
    assert Jason.decode!(json) == %{"type" => "finalize"}

    fin_frame = Jason.encode!(%{"tokens" => [%{"text" => "<fin>", "is_final" => true}]})

    assert {:ok, _state} = Soniox.handle_frame({:text, fin_frame}, state)
    assert_receive {:stt, _, {:final, ""}}
  end

  test "shows buffered final tokens as partial text until Soniox emits an endpoint marker" do
    state = %{owner: self(), final_tokens: [], config: %{}, terminating?: false}

    first_frame =
      Jason.encode!(%{
        "tokens" => [
          %{"text" => "hello", "is_final" => true},
          %{"text" => " ", "is_final" => true}
        ]
      })

    assert {:ok, %{final_tokens: ["hello", " "]} = state} =
             Soniox.handle_frame({:text, first_frame}, state)

    refute_receive {:stt, _, {:final, _text}}
    assert_receive {:stt, _, {:partial, "hello"}}

    endpoint_frame =
      Jason.encode!(%{
        "tokens" => [
          %{"text" => "world", "is_final" => true},
          %{"text" => "<end>", "is_final" => true}
        ]
      })

    assert {:ok, %{final_tokens: []}} = Soniox.handle_frame({:text, endpoint_frame}, state)
    assert_receive {:stt, _, {:final, "hello world"}}
  end

  test "flushes buffered final tokens on finished response" do
    state = %{owner: self(), final_tokens: ["done"], config: %{}, terminating?: false}
    frame = Jason.encode!(%{"tokens" => [], "finished" => true})

    assert {:ok, %{final_tokens: []}} = Soniox.handle_frame({:text, frame}, state)
    assert_receive {:stt, _, {:final, "done"}}
  end

  test "sends binary audio frames and an empty text frame to finish" do
    assert {:reply, {:binary, <<1, 2, 3>>}, %{}} =
             Soniox.handle_cast({:send_audio, <<1, 2, 3>>}, %{})

    assert {:reply, {:text, ""}, %{terminating?: true}} =
             Soniox.handle_cast(:terminate_session, %{terminating?: false})
  end

  test "marks disconnects as intentional only after termination" do
    assert {:ok, %{terminating?: false}} =
             Soniox.handle_disconnect(%{reason: {:remote, 1000, ""}}, %{
               owner: self(),
               terminating?: false
             })

    assert_receive {:stt, _, {:disconnected, {:remote, 1000, ""}, %{intentional?: false}}}

    assert {:ok, %{terminating?: true}} =
             Soniox.handle_disconnect(%{reason: {:remote, 1000, ""}}, %{
               owner: self(),
               terminating?: true
             })

    assert_receive {:stt, _, {:disconnected, {:remote, 1000, ""}, %{intentional?: true}}}
  end

  defp stringify_keys(map) do
    Map.new(map, fn {key, value} -> {Atom.to_string(key), value} end)
  end

  test "sends a keepalive after 5 s without audio, and not while audio flows" do
    now = System.monotonic_time(:millisecond)
    idle = %{last_audio: now - 6_000, terminating?: false}
    busy = %{last_audio: now - 1_000, terminating?: false}

    assert {:reply, {:text, json}, _state} = Soniox.handle_info(:keepalive, idle)
    assert Jason.decode!(json) == %{"type" => "keepalive"}
    assert {:ok, ^busy} = Soniox.handle_info(:keepalive, busy)
  end
end
