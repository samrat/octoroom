defmodule HelloWeb.AgentLiveTest do
  use HelloWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  defp agent(view, event),
    do: send(view.pid, {:octoroom, "test", {:worker_event, "assistant", {:agent, event}}})

  defp said(view, text), do: agent(view, {:conversation, %{role: "user", text: text}})

  defp replied(view, id, text),
    do: agent(view, {:conversation, %{role: "assistant", message_id: id, text: text}})

  @latency %{transcript: 600, llm: 900, audio: 1_200}

  test "renders the page with the join button and recorded questions", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    assert has_element?(view, "#agent[phx-hook=Agent]")
    assert has_element?(view, "#join", "Join")
    assert has_element?(view, ~s(button.ask[data-src="/questions/0.wav"]))
  end

  test "the greeting isn't a reply", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    replied(view, "a0", "Hi there!")
    refute render(view) =~ "Hi there!"
  end

  test "times arriving before the reply go on it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    said(view, "What is the capital of France?")
    agent(view, {:latency, @latency})
    render_hook(view, "heard", %{"ms" => 1_480.4})
    replied(view, "a1", "Paris.")

    assert has_element?(view, "#reply-a1", "What is the capital of France?")
    assert has_element?(view, "#reply-a1", "1200 ms")
    assert has_element?(view, "#reply-a1", "1480 ms")
    assert has_element?(view, "#median", "1480 ms")
  end

  test "times arriving after the reply go on it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    said(view, "Name a primary colour.")
    replied(view, "a1", "Red.")
    agent(view, {:latency, @latency})
    render_hook(view, "heard", %{"ms" => 1_500})

    assert has_element?(view, "#reply-a1", "900 ms")
    assert has_element?(view, "#reply-a1", "1500 ms")
  end

  test "a typed turn has the agent's times but nothing heard", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")
    agent(view, {:decision, %{why: :typed}})
    said(view, "hello")
    replied(view, "a1", "Hi!")
    agent(view, {:latency, @latency})
    render_hook(view, "heard", %{"ms" => 999})

    assert has_element?(view, "#reply-a1", "typed")
    assert has_element?(view, "#reply-a1", "1200 ms")
    refute has_element?(view, "#reply-a1", "999 ms")
  end

  test "renders the voice stage, timeline, and pushes partial captions and waterfall spans", %{
    conn: conn
  } do
    {:ok, view, html} = live(conn, ~p"/")
    assert has_element?(view, "canvas[data-agent-orb]")
    assert has_element?(view, "#voice-timeline")
    assert has_element?(view, "#workbench")

    [_, room] = Regex.run(~r/data-room="([^"]+)"/, html)

    agent(view, {:transcription, %{status: "partial", text: "What is the"}})
    assert_push_event(view, "partial", %{text: "What is the"})

    said(view, "What is the capital of France?")
    agent(view, {:latency, @latency})

    assert_push_event(view, "timeline_event", %{
      type: "reply_latency",
      agent: "assistant",
      audio_ms: 1_200
    })

    # Telemetry spans recorded by TraceStore stream straight into the room's Voice Timeline.
    :telemetry.execute(
      [:octoroom_agent, :processor, :async, :stop],
      %{
        duration: System.convert_time_unit(320, :millisecond, :native),
        first_output_duration: System.convert_time_unit(140, :millisecond, :native),
        outputs: 4
      },
      %{
        room_id: room,
        agent_id: "assistant",
        processor: :llm,
        task: :reply,
        model: "gemini-3.5-flash-lite",
        status: :ok
      }
    )

    assert_push_event(view, "timeline_event", %{
      type: "stage_spans",
      spans: [%{agent: "assistant", kind: "llm", label: "llm (gemini-3.5-flash-lite)"}]
    })

    agent(
      view,
      {:conversation,
       %{role: "assistant", message_id: "a1", text: "Paris—", status: "interrupted"}}
    )

    assert_push_event(view, "timeline_event", %{type: "interruption", agent: "assistant"})
  end

  test "displays clinic tools, live tool call cards, and updated appointments", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")
    assert has_element?(view, "#tool-chips", "check_availability")
    assert has_element?(view, "#tool-chips", "book_appointment")
    assert has_element?(view, "#appointments")

    [_, room] = Regex.run(~r/data-room="([^"]+)"/, html)

    next_weekday =
      Stream.iterate(Hello.Clinic.today(), &Date.add(&1, 1))
      |> Enum.find(&(Date.day_of_week(&1) in 1..5))
      |> Date.to_iso8601()

    Hello.Assistant.check_availability(
      %{id: "call-1", name: "check_availability", args: %{"date" => next_weekday}},
      %{room_id: room}
    )

    assert has_element?(view, "#active-tool", "check_availability")

    assert_push_event(view, "tool_call", %{
      id: "call-1",
      name: "check_availability",
      status: "ok"
    })

    %{response: %{appointment: appt}} =
      Hello.Assistant.book_appointment(
        %{
          id: "call-2",
          name: "book_appointment",
          args: %{"date" => next_weekday, "time" => "14:00", "patient_name" => "Ada"}
        },
        %{room_id: room}
      )

    assert has_element?(view, "#appt-#{appt.code}", "Ada")

    assert_push_event(view, "tool_call", %{
      id: "call-2",
      name: "book_appointment",
      status: "ok",
      result_text: result_text
    })

    assert result_text =~ appt.code
  end

  test "lets the user switch pipelines from the header dropdown", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    assert has_element?(view, "#pipeline-select")
    assert has_element?(view, ~s(#agent[data-pipeline="openai_live"]))
    assert has_element?(view, "#pipeline-label", "OpenAI gpt-live-1.1")

    view
    |> element("form[phx-change=select_pipeline]")
    |> render_change(%{"pipeline" => "gemini_live"})

    assert has_element?(view, ~s(#agent[data-pipeline="gemini_live"]))
    assert has_element?(view, "#pipeline-label", "Gemini 3.8 Live")
    assert has_element?(view, "#tool-chips")

    view
    |> element("form[phx-change=select_pipeline]")
    |> render_change(%{"pipeline" => "cascaded_nemotron"})

    assert has_element?(view, ~s(#agent[data-pipeline="cascaded_nemotron"]))
    assert has_element?(view, "#pipeline-label", "AssemblyAI EU → Nemotron 3.5 Lightning → AssemblyAI EU")

    view
    |> element("form[phx-change=select_pipeline]")
    |> render_change(%{"pipeline" => "booking"})

    assert has_element?(view, ~s(#agent[data-pipeline="booking"]))
    assert has_element?(view, "#pipeline-label", "AssemblyAI EU → Clef Flash Script → AssemblyAI EU")
    refute has_element?(view, "#tool-chips")

    # Every assistant pipeline preset builds a valid pipeline spec and room worker spec.
    for preset <- Hello.Assistant.pipelines(), preset.agent == Hello.Assistant do
      {front, back} = Hello.Assistant.build_pipeline(preset.id)
      assert is_nil(front) or match?(%Octoroom.Agent.Pipeline.Spec{}, front)
      assert match?(%Octoroom.Agent.Pipeline.Spec{}, back)
    end

    room = %Octoroom.Room{
      id: "r1",
      participants: [
        %Octoroom.Participant{id: "p1", meta: %{name: "Guest", pipeline: "gemini_live"}}
      ],
      assigns: %{}
    }

    assert [%{id: "assistant", args: %{agent: Hello.Assistant, args: %{pipeline: "gemini_live"}}}] =
             Hello.Room.workers(room)

    room_override = %{room | assigns: %{pipeline: "cascaded_gemini"}}

    assert [
             %{
               id: "assistant",
               args: %{agent: Hello.Assistant, args: %{pipeline: "cascaded_gemini"}}
             }
           ] =
             Hello.Room.workers(room_override)
  end
end
