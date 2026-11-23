defmodule HelloWeb.MetricsStorageTest do
  use ExUnit.Case, async: false

  alias HelloWeb.{MetricsStorage, Telemetry}

  test "records agent async and turn latency metrics for LiveDashboard history" do
    duration = System.convert_time_unit(250, :millisecond, :native)
    first = System.convert_time_unit(80, :millisecond, :native)

    :telemetry.execute(
      [:octoroom_agent, :processor, :async, :stop],
      %{duration: duration, first_output_duration: first, outputs: 4},
      %{
        room_id: "r1",
        agent_id: "assistant",
        processor: :llm,
        task: :reply,
        status: :ok
      }
    )

    :telemetry.execute(
      [:octoroom_agent, :turn, :latency],
      %{transcript_ms: 120, llm_ms: 210, audio_ms: 340},
      %{room_id: "r1", agent_id: "assistant", speaker: "Alice"}
    )

    metrics = Telemetry.metrics()

    async_dur =
      Enum.find(
        metrics,
        &(&1.name == [:octoroom_agent, :processor, :async, :stop, :duration])
      )

    first_out =
      Enum.find(
        metrics,
        &(&1.name == [:octoroom_agent, :processor, :async, :stop, :first_output_duration])
      )

    turn_audio =
      Enum.find(metrics, &(&1.name == [:octoroom_agent, :turn, :latency, :audio_ms]))

    # All agent metrics are grouped under the :octoroom LiveDashboard nav tab.
    assert async_dur.reporter_options[:nav] == :octoroom
    assert first_out.reporter_options[:nav] == :octoroom
    assert turn_audio.reporter_options[:nav] == :octoroom

    assert Enum.any?(MetricsStorage.metrics_history(async_dur), fn p ->
             p.label == "assistant llm reply ok" and p.measurement >= 249 and p.measurement <= 251
           end)

    assert Enum.any?(MetricsStorage.metrics_history(first_out), fn p ->
             p.label == "assistant llm" and p.measurement >= 79 and p.measurement <= 81
           end)

    assert Enum.any?(MetricsStorage.metrics_history(turn_audio), fn p ->
             p.label == "assistant" and p.measurement == 340
           end)
  end

  test "formats tuple failure names without crashing the telemetry handler" do
    :telemetry.execute(
      [:octoroom, :failure],
      %{count: 1},
      %{
        room_id: "r1",
        id: :media,
        name: {:peer, "assistant"},
        reason: {:shutdown, :connect_timeout},
        given_up: false
      }
    )

    :telemetry.execute(
      [:octoroom, :failure],
      %{count: 2},
      %{
        room_id: "r1",
        id: :media,
        name: {:inlet, {"assistant", "p1/mic"}},
        reason: :empty_track,
        given_up: true
      }
    )

    failure_metric =
      Enum.find(Telemetry.metrics(), &(&1.name == [:octoroom, :failure, :count]))

    history = MetricsStorage.metrics_history(failure_metric)
    assert Enum.any?(history, &(&1.label == "peer:assistant false"))
    assert Enum.any?(history, &(&1.label == "inlet:assistant:p1/mic true"))
  end
end
