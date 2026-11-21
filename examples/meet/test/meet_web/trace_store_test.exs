defmodule MeetWeb.TraceStoreTest do
  use ExUnit.Case, async: false
  require Phoenix.LiveViewTest

  alias MeetWeb.TraceStore

  setup do
    TraceStore.clear()
    :ok
  end

  test "groups multi-agent decisions, STT, floor wait, LLM, TTS, and turn latency into one utterance" do
    ms = &System.convert_time_unit(&1, :millisecond, :native)

    # Atlas runs decisions and listens
    :telemetry.execute(
      [:octoroom_agent, :processor, :async, :stop],
      %{duration: ms.(240), outputs: 0},
      %{
        room_id: "demo",
        agent_id: "atlas",
        input: "p1/mic",
        processor: :decisions,
        task: :evaluate,
        model: "openrouter:cloudflare/clef-flash",
        modality: :transcript,
        status: :ok
      }
    )

    :telemetry.execute(
      [:octoroom_agent, :turn, :decided],
      %{speech_to_decided_ms: 1_040, decision_ms: 240},
      %{
        room_id: "demo",
        agent_id: "atlas",
        input: "p1/mic",
        speaker: "Alice",
        text: "Hey assistant, what time is it?",
        outcome: :listen,
        why: :not_addressed,
        decision: nil,
        stt_provider: :soniox,
        stt_model: "stt-rt-v6"
      }
    )

    # Assistant runs decisions, waits, then runs LLM + TTS
    :telemetry.execute(
      [:octoroom_agent, :processor, :async, :stop],
      %{duration: ms.(300), outputs: 0},
      %{
        room_id: "demo",
        agent_id: "assistant",
        input: "p1/mic",
        processor: :decisions,
        task: :evaluate,
        model: "openrouter:cloudflare/clef-flash",
        modality: :transcript,
        status: :ok
      }
    )

    :telemetry.execute(
      [:octoroom_agent, :turn, :decided],
      %{speech_to_decided_ms: 1_200, decision_ms: 300},
      %{
        room_id: "demo",
        agent_id: "assistant",
        input: "p1/mic",
        speaker: "Alice",
        text: "Hey assistant, what time is it?",
        outcome: :wait,
        why: :open_question,
        decision: nil,
        stt_provider: :reson8,
        stt_model: "rumble-2"
      }
    )

    :telemetry.execute(
      [:octoroom_agent, :turn, :floor_wait],
      %{duration_ms: 2_500},
      %{
        room_id: "demo",
        agent_id: "assistant",
        input: "p1/mic",
        speaker: "Alice",
        outcome: :replied
      }
    )

    :telemetry.execute(
      [:octoroom_agent, :processor, :async, :stop],
      %{duration: ms.(400), first_output_duration: ms.(310), outputs: 5},
      %{
        room_id: "demo",
        agent_id: "assistant",
        turn_id: 1,
        processor: :llm,
        task: :reply,
        provider: :openrouter,
        model: "nvidia/nemotron-3.5-lightning",
        status: :ok
      }
    )

    :telemetry.execute(
      [:octoroom_agent, :processor, :async, :stop],
      %{duration: ms.(60), first_output_duration: ms.(55), outputs: 1},
      %{
        room_id: "demo",
        agent_id: "assistant",
        turn_id: 1,
        processor: :tts,
        task: :speak,
        provider: :tiny_voca,
        model: "tiny-voca",
        voice: "F2",
        status: :ok
      }
    )

    :telemetry.execute(
      [:octoroom_agent, :turn, :latency],
      %{
        transcript_ms: 3_700,
        llm_ms: 4_010,
        audio_ms: 4_080,
        wait_ms: 2_500,
        processing_ms: 1_580,
        stt_and_decision_ms: 1_200
      },
      %{room_id: "demo", agent_id: "assistant", turn_id: 1, input: "p1/mic", speaker: "Alice"}
    )

    %{utterances: [u]} = TraceStore.snapshot()
    assert u.room_id == "demo"
    assert u.speaker == "Alice"
    assert u.text == "Hey assistant, what time is it?"
    assert Map.keys(u.lanes) |> Enum.sort() == ["assistant", "atlas"]

    atlas_kinds = Enum.map(u.lanes["atlas"].spans, & &1.kind)
    assert atlas_kinds == [:stt, :decisions]

    assistant_kinds = Enum.map(u.lanes["assistant"].spans, & &1.kind)
    assert :stt in assistant_kinds
    assert :decisions in assistant_kinds
    assert :floor_wait in assistant_kinds
    assert :llm in assistant_kinds
    assert :tts in assistant_kinds

    atlas_stt = Enum.find(u.lanes["atlas"].spans, &(&1.kind == :stt))
    assert atlas_stt.label == "stt (soniox/stt-rt-v6)"
    assert atlas_stt.meta.provider == :soniox
    assert atlas_stt.meta.model == "stt-rt-v6"

    assistant_stt = Enum.find(u.lanes["assistant"].spans, &(&1.kind == :stt))
    assert assistant_stt.label == "stt (reson8/rumble-2)"
    assert assistant_stt.meta.provider == :reson8
    assert assistant_stt.meta.model == "rumble-2"

    llm_span = Enum.find(u.lanes["assistant"].spans, &(&1.kind == :llm))
    assert_in_delta llm_span.first_output_ms, 310.0, 2.0
    assert u.lanes["assistant"].latency.processing_ms == 1_580
    assert u.lanes["assistant"].latency.wait_ms == 2_500

    html =
      Phoenix.LiveViewTest.render_component(&MeetWeb.OctoroomDashboardPage.render/1,
        tab: :turns,
        selected: {"u-#{u.id}", llm_span.id},
        selected_call: :latest,
        calls: TraceStore.snapshot().calls,
        utterances: [u],
        joins: []
      )

    assert html =~ "Hey assistant, what time is it?"
    assert html =~ "stt (soniox/stt-rt-v6)"
    assert html =~ "stt (reson8/rumble-2)"
    assert html =~ "floor wait"
    assert html =~ "310 ms TTFT"
    assert html =~ "nemotron-3.5-lightning"
  end

  test "separates multiple calls in the same room by room start/stop" do
    # Call 1 in "lobby"
    :telemetry.execute([:octoroom, :room, :start], %{}, %{
      room_id: "lobby",
      run: "r1",
      recovered: false
    })

    :telemetry.execute(
      [:octoroom_agent, :turn, :decided],
      %{speech_to_decided_ms: 400},
      %{
        room_id: "lobby",
        agent_id: "assistant",
        input: "p1/mic",
        speaker: "Alice",
        text: "First call question",
        outcome: :reply,
        why: :name,
        decision: nil
      }
    )

    :telemetry.execute([:octoroom, :room, :stop], %{}, %{room_id: "lobby", reason: :empty})

    # Call 2 in "lobby"
    :telemetry.execute([:octoroom, :room, :start], %{}, %{
      room_id: "lobby",
      run: "r2",
      recovered: false
    })

    :telemetry.execute(
      [:octoroom_agent, :turn, :decided],
      %{speech_to_decided_ms: 350},
      %{
        room_id: "lobby",
        agent_id: "assistant",
        input: "p1/mic",
        speaker: "Alice",
        text: "Second call question",
        outcome: :reply,
        why: :name,
        decision: nil
      }
    )

    %{calls: [call2, call1], utterances: [u2, u1]} = TraceStore.snapshot()
    assert call2.room_id == "lobby" and call2.status == :live
    assert call1.room_id == "lobby" and call1.status == :ended
    assert call1.id != call2.id
    assert u2.call_id == call2.id and u2.text == "Second call question"
    assert u1.call_id == call1.id and u1.text == "First call question"

    # Latest call view only shows Call 2's turn, not Call 1's.
    latest_html =
      Phoenix.LiveViewTest.render_component(&MeetWeb.OctoroomDashboardPage.render/1,
        tab: :turns,
        selected: nil,
        selected_call: :latest,
        calls: [call2, call1],
        utterances: [u2, u1],
        joins: []
      )

    assert latest_html =~ "Second call question"
    refute latest_html =~ "First call question"
    assert latest_html =~ "All calls (2)"
  end

  test "records OpenAI Live session and response events in the waterfall" do
    :telemetry.execute([:octoroom, :room, :start], %{}, %{
      room_id: "live-room",
      run: "r1",
      recovered: false
    })

    :telemetry.execute(
      [:octoroom_agent, :live, :session],
      %{duration_ms: 420},
      %{
        room_id: "live-room",
        agent_id: "openai",
        provider: :openai,
        model: "gpt-live-1.1",
        transport: :webrtc,
        event: :started
      }
    )

    now_ms = System.monotonic_time(:millisecond)

    :telemetry.execute(
      [:octoroom_agent, :live, :response, :stop],
      %{
        duration: System.convert_time_unit(850, :millisecond, :native),
        duration_ms: 850,
        audio_ms: 1_200,
        outputs: 40,
        ended_at_ms: now_ms,
        response_latency_ms: 310
      },
      %{
        room_id: "live-room",
        agent_id: "openai",
        provider: :openai,
        model: "gpt-live-1.1",
        voice: "marin",
        transport: :webrtc,
        status: :ok,
        typed: false,
        user_text: "OpenAI, say hello",
        assistant_text: "Hello there!"
      }
    )

    %{calls: [call], utterances: [u], joins: [join]} = TraceStore.snapshot()
    assert call.room_id == "live-room"
    assert Enum.any?(join.spans, &(&1.kind == :live_session))
    assert u.text == "OpenAI, say hello"
    assert Map.has_key?(u.lanes, "openai")
    assert Enum.any?(u.lanes["openai"].spans, &(&1.kind == :live))

    html =
      Phoenix.LiveViewTest.render_component(&MeetWeb.OctoroomDashboardPage.render/1,
        tab: :turns,
        selected: nil,
        selected_call: :latest,
        calls: [call],
        utterances: [u],
        joins: [join]
      )

    assert html =~ "OpenAI, say hello"
    assert html =~ "gpt-live-1.1"
    assert html =~ "1200 ms audio"
  end

  test "groups room join, cloudflare, peer connect, and first pull events" do
    :telemetry.execute([:octoroom, :participant, :join], %{}, %{room_id: "j1", id: "p1"})

    :telemetry.execute([:octoroom, :cloudflare, :request], %{duration_ms: 120}, %{
      room_id: "j1",
      method: :post,
      path: "/sessions/new",
      result: :ok
    })

    :telemetry.execute([:octoroom, :peer, :connect], %{duration_ms: 600}, %{
      room_id: "j1",
      worker_id: "assistant"
    })

    :telemetry.execute(
      [:octoroom, :participant, :connected],
      %{duration_ms: 1_050, before_publish_ms: 200, publish_ms: 350, connect_ms: 500},
      %{room_id: "j1", id: "p1", sources: ["mic"]}
    )

    :telemetry.execute(
      [:octoroom, :participant, :first_pull],
      %{duration_ms: 1_620, since_connected_ms: 570, tracks: 3},
      %{room_id: "j1", id: "p1"}
    )

    %{joins: [join]} = TraceStore.snapshot()
    assert join.room_id == "j1"
    kinds = Enum.map(join.spans, & &1.kind)
    assert :cloudflare in kinds
    assert :peer in kinds
    assert :pull in kinds

    # Smoke-test rendering both dashboard tabs without runtime template errors.
    snapshot = TraceStore.snapshot()

    for tab <- [:turns, :joins] do
      html =
        Phoenix.LiveViewTest.render_component(&MeetWeb.OctoroomDashboardPage.render/1,
          tab: tab,
          selected: nil,
          selected_call: :latest,
          calls: snapshot.calls,
          utterances: snapshot.utterances,
          joins: snapshot.joins
        )

      assert html =~ "octo-wf"
    end
  end
end
