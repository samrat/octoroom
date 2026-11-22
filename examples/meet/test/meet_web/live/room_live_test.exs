defmodule MeetWeb.RoomLiveTest do
  use MeetWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  defp assistant(view, event, id \\ "assistant"),
    do: send(view.pid, {:octoroom, "test", {:worker_event, id, {:agent, event}}})

  test "shows the lobby until the browser has joined", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/r/test")
    assert has_element?(view, "#join-form")
    assert has_element?(view, "#lobby-preview")

    render_hook(view, "client", %{"state" => "joined", "participant_id" => "p1"})
    refute has_element?(view, "#join-form")
    refute has_element?(view, "#lobby-preview")
    assert has_element?(view, "#transcript-panel")
    assert has_element?(view, "#voice-timeline")
    assert has_element?(view, "#toggle-timeline")
  end

  test "a page that mounts again rebuilds the transcript from what the assistants saved",
       %{conn: conn} do
    room = "restored-#{System.unique_integer([:positive])}"
    store = Octoroom.Store.config()
    at = System.system_time(:millisecond)

    turn = %{role: "user", message_id: "u1", text: "Capital of Peru?", speaker: "Ada", at: at}
    reply = %{role: "assistant", message_id: "a1", text: "Lima.", status: "completed", at: at + 1}

    # The general assistant heard the turn; Atlas heard it too, and replied.
    Octoroom.Store.put(store, :workers, {room, "assistant"}, %{items: [turn]})
    Octoroom.Store.put(store, :workers, {room, "atlas"}, %{items: [turn, reply]})
    on_exit(fn -> Octoroom.Worker.forget_room(store, room) end)

    {:ok, view, _html} = live(conn, ~p"/r/#{room}")
    render_hook(view, "client", %{"state" => "joined", "participant_id" => "p1"})

    assert has_element?(view, "#transcript-turn-1", "Capital of Peru?")
    assert has_element?(view, "#transcript-reply-atlas-a1", "Lima.")
    refute has_element?(view, "#transcript-turn-2")
  end

  test "the transcript tags each turn with the decision", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/r/test")
    render_hook(view, "client", %{"state" => "joined", "participant_id" => "p1"})

    assistant(
      view,
      {:transcription, %{status: "partial", text: "what's the", source: "p1/mic", speaker: "Ada"}}
    )

    assert has_element?(view, "#partial-p1\\/mic", "what's the")

    assistant(view, {
      :decision,
      %{
        source: "p1/mic",
        speaker: "Ada",
        text: "What's the capital of Peru?",
        outcome: :reply,
        why: :addressed,
        decision: %{
          addressee: "assistant",
          confidence: 0.92,
          probabilities: %{"assistant" => 0.92},
          answerable: 0.97,
          latency_ms: 410,
          audio_ms: 1800
        }
      }
    })

    refute has_element?(view, "#partial-p1\\/mic")
    assert has_element?(view, "#transcript-turn-1", "What's the capital of Peru?")
    assert has_element?(view, "#transcript-turn-1-assistant .badge", "replied")
    assert has_element?(view, "#transcript-turn-1 .badge", "talking to it")
    assert has_element?(view, "#transcript-turn-1 .badge", "to assistant 92%")
    assert has_element?(view, "#transcript-turn-1 .badge", "answerable 97%")

    assistant(
      view,
      {:conversation, %{role: "assistant", message_id: "m1", text: "Lima.", status: "playing"}}
    )

    assert has_element?(view, "#transcript-reply-assistant-m1 .badge", "speaking")

    assistant(
      view,
      {:conversation, %{role: "assistant", message_id: "m1", text: "Lima.", status: "completed"}}
    )

    assert has_element?(view, "#transcript-reply-assistant-m1", "Lima.")
    refute has_element?(view, "#transcript-reply-assistant-m1 .badge")
  end

  test "each assistant's decision on a turn joins the same entry, with its own answers", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/r/test")
    render_hook(view, "client", %{"state" => "joined", "participant_id" => "p1"})

    turn = fn outcome, why, answers ->
      {:decision,
       %{
         source: "p1/mic",
         speaker: "Ada",
         text: "What's the capital of Peru?",
         outcome: outcome,
         why: why,
         decision: %{answers: answers, latency_ms: 500}
       }}
    end

    addressee = %{"choice" => "group", "confidence" => 0.81}

    assistant(
      view,
      turn.(:listen, :not_addressed, %{
        "addressee" => addressee,
        "answerable_assistant" => %{"probability" => 0.3},
        "answerable_atlas" => %{"probability" => 0.94}
      })
    )

    assistant(
      view,
      turn.(:wait, :open_question, %{
        "addressee" => addressee,
        "capital" => %{"probability" => 0.97}
      }),
      "atlas"
    )

    assert has_element?(view, "#transcript-turn-1-assistant .badge", "listened")
    assert has_element?(view, "#transcript-turn-1-assistant .badge", "atlas could answer 94%")
    assert has_element?(view, "#transcript-turn-1-atlas .badge", "waited")
    assert has_element?(view, "#transcript-turn-1-atlas .badge", "capital 97%")
    refute has_element?(view, "#transcript-turn-2")

    assistant(view, {:waiting, %{speaker: "Ada", ms: 2500}}, "atlas")
    assert has_element?(view, "#waiting-atlas", "Atlas is waiting to see if anyone answers Ada")
  end

  test "one entry per turn even when the assistants split speech differently", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/r/test")
    render_hook(view, "client", %{"state" => "joined", "participant_id" => "p1"})

    turn = fn text, outcome ->
      {:decision,
       %{
         source: "p1/mic",
         speaker: "Ada",
         text: text,
         outcome: outcome,
         why: :not_addressed,
         decision: nil
       }}
    end

    # Atlas hears it as one turn, and decides first.
    assistant(view, turn.("I can't hear either of you. Can you hear me?", :listen), "atlas")
    refute has_element?(view, "#transcript-turn-1")

    # The assistant hears two turns; Atlas's decision joins the first.
    assistant(view, turn.("I can't hear either of you.", :listen))
    assistant(view, turn.("Can you hear me?", :listen))

    assert has_element?(view, "#transcript-turn-1", "I can't hear either of you.")
    assert has_element?(view, "#transcript-turn-1-atlas")
    assert has_element?(view, "#transcript-turn-2", "Can you hear me?")
    refute has_element?(view, "#transcript-turn-3")
    refute render(view) =~ "I can't hear either of you. Can you hear me?"
  end

  test "the assistant's set_theme tool switches every page in the room", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/r/themes")

    call = %{id: "c1", name: "set_theme", args: %{"theme" => "dark"}}

    assert %{response: %{result: "ok", theme: "dark"}} =
             Meet.Assistant.set_theme(call, %{room_id: "themes"})

    assert_push_event(view, "set-theme", %{theme: "dark"})

    assert %{response: %{result: "error"}} =
             Meet.Assistant.set_theme(%{call | args: %{"theme" => "purple"}}, %{room_id: "themes"})
  end

  test "pushes voice timeline events for assistant states, waterfall spans, interruptions, latency, and turns",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/r/timeline-test")
    refute has_element?(view, "#voice-timeline")

    render_hook(view, "client", %{"state" => "joined", "participant_id" => "p1"})
    assert has_element?(view, "#voice-timeline")

    send(
      view.pid,
      {:octoroom, "timeline-test", {:worker, :updated, %{id: "assistant", state: "thinking"}}}
    )

    assert_push_event(view, "timeline_event", %{
      type: "agent_state",
      id: "assistant",
      state: "thinking"
    })

    send(
      view.pid,
      {:octoroom, "timeline-test", {:worker, :updated, %{id: "assistant", state: "speaking"}}}
    )

    assert_push_event(view, "timeline_event", %{
      type: "agent_state",
      id: "assistant",
      state: "speaking"
    })

    assistant(
      view,
      {:conversation,
       %{role: "assistant", message_id: "m1", text: "Actually—", status: "interrupted"}}
    )

    assert_push_event(view, "timeline_event", %{type: "interruption", agent: "assistant"})

    send(
      view.pid,
      {:octoroom, "timeline-test", {:worker, :updated, %{id: "assistant", state: "listening"}}}
    )

    assert_push_event(view, "timeline_event", %{
      type: "agent_state",
      id: "assistant",
      state: "listening"
    })

    assistant(view, {:latency, %{transcript: 180, llm: 410, audio: 620}})

    assert_push_event(view, "timeline_event", %{
      type: "reply_latency",
      agent: "assistant",
      audio_ms: 620
    })

    assistant(view, {
      :decision,
      %{
        source: "p1/mic",
        speaker: "Ada",
        text: "Mm-hmm.",
        outcome: :listen,
        why: :not_addressed,
        decision: nil
      }
    })

    assert_push_event(view, "timeline_event", %{
      type: "user_turn",
      lane_id: "p1",
      text: "Mm-hmm.",
      outcome: "listen"
    })

    # Telemetry spans recorded by TraceStore stream straight into the room's Voice Timeline.
    ms = &System.convert_time_unit(&1, :millisecond, :native)

    :telemetry.execute(
      [:octoroom_agent, :processor, :async, :stop],
      %{duration: ms.(350), first_output_duration: ms.(190), outputs: 4},
      %{
        room_id: "timeline-test",
        agent_id: "assistant",
        turn_id: 1,
        processor: :llm,
        task: :reply,
        provider: :openrouter,
        model: "nvidia/nemotron-3.5-lightning",
        status: :ok
      }
    )

    assert_push_event(view, "timeline_event", %{
      type: "stage_spans",
      spans: [%{agent: "assistant", kind: "llm", first_output_ms: ttft}]
    })

    assert_in_delta ttft, 190.0, 2.0
  end
end
