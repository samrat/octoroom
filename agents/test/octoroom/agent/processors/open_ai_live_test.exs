defmodule Octoroom.Agent.Processors.OpenAILiveTest do
  use ExUnit.Case, async: true

  import Octoroom.Agent.Pipeline.Spec

  alias Octoroom.Agent.{Frames, Tool}
  alias Octoroom.Agent.Pipeline.Test
  alias Octoroom.Agent.Processors.OpenAILive

  def add_row(call, _ctx), do: %{id: call.id, name: call.name, response: %{result: "ok"}}

  defp start(opts \\ []) do
    test = self()

    tools = [
      %Tool{
        name: "add_row",
        description: "Adds a row.",
        parameters: %{type: "object", properties: %{}},
        handler: {__MODULE__, :add_row}
      }
    ]

    processor(
      :openai,
      Octoroom.Agent.Processors.OpenAILive,
      [
        model: "gpt-live-1.1",
        delegation: [model: "gpt-5.4-mini"],
        send: &send(test, {:to_openai, &1}),
        tools: tools,
        context: %{room_id: "r"}
      ] ++ opts
    )
    |> Test.start!(ctx: %{owner: test})
    |> Test.push(%Frames.Start{})
    |> live({:session_started, %{"id" => "live_1"}})
  end

  defp live(harness, event), do: Test.info(harness, :openai, {:openai_live_socket, event})

  test "websocket transport resamples 16 kHz to 24 kHz once started, mutes on pause and unmutes" do
    harness =
      processor(:openai, OpenAILive,
        model: "gpt-live-1.1",
        transport: :websocket,
        send: &send(self(), {:sent, &1})
      )
      |> Test.start!()
      |> Test.push(%Frames.InputAudio{audio: <<100::little-signed-16, 200::little-signed-16>>})

    refute_received {:sent, {:audio, _}}

    frame_16k = :binary.copy(<<100::little-signed-16>>, 320)

    harness =
      harness
      |> live({:session_started, %{"id" => "live_1"}})
      |> Test.push(%Frames.InputAudio{audio: frame_16k, sample_rate: 16_000})

    assert_received {:sent, {:audio, pcm_24k}}
    assert byte_size(pcm_24k) == 960

    harness = live(harness, {:audio, <<3, 3>>, sample_rate: 24_000})
    assert [%Frames.OutputAudio{audio: <<3, 3>>, sample_rate: 24_000}] = Test.outputs(harness)

    # A quiet moment mutes input so OpenAI Live feeds silence; new audio unmutes first.
    Process.sleep(210)
    harness = Test.fire_timer(harness, :openai, :audio_end)
    assert_received {:sent, :mute}

    Test.push(harness, %Frames.InputAudio{audio: frame_16k, sample_rate: 16_000})
    assert_received {:sent, :unmute}
    assert_received {:sent, {:audio, _}}
  end

  test "webrtc transport (default) forwards raw input audio with sample rate without mute timers" do
    frame_16k = :binary.copy(<<100::little-signed-16>>, 320)

    harness =
      processor(:openai, OpenAILive,
        model: "gpt-live-1.1",
        send: &send(self(), {:sent, &1})
      )
      |> Test.start!()
      |> live({:session_started, %{"id" => "live_1"}})
      |> Test.push(%Frames.InputAudio{audio: frame_16k, sample_rate: 16_000})

    assert_received {:sent, {:connect, [transport: :webrtc, setup: _]}}
    assert_received {:sent, {:audio, ^frame_16k, sample_rate: 16_000}}
    refute Test.timer_pending?(harness, :openai, :audio_end)
  end

  test "commits transcripts and pushes AssistantMessage when the reply settles" do
    harness =
      start()
      |> live({:transcription, :user, "add "})
      |> live({:transcription, :user, "Acme"})
      |> live({:audio, <<0, 0>>, sample_rate: 24_000})
      |> live({:transcription, :assistant, "Done."})

    # Starting the assistant reply commits the pending user transcript.
    assert_received {:voice_pipeline, _, {:conversation, %{role: "user", text: "add Acme"}}}

    Process.sleep(620)
    harness = Test.fire_timer(harness, :openai, :assistant_idle)

    assert_received {:voice_pipeline, _,
                     {:conversation, %{role: "assistant", text: "Done.", status: "completed"}}}

    assert [%Frames.Start{}, %Frames.OutputAudio{}, %Frames.AssistantMessage{text: "Done."}] =
             Test.outputs(harness)
  end

  test "interrupted from outside drops in-flight output until idle, then plays new replies" do
    harness =
      start()
      |> live({:audio, <<0, 0>>, sample_rate: 24_000})
      |> live({:transcription, :assistant, "Well, the"})
      |> Test.push(%Frames.Interruption{})
      |> live({:audio, <<9, 9>>, sample_rate: 24_000})

    assert_received {:voice_pipeline, _,
                     {:conversation, %{role: "assistant", text: "Well, the", interrupted: true}}}

    refute Enum.any?(Test.outputs(harness), &match?(%Frames.OutputAudio{audio: <<9, 9>>}, &1))

    Process.sleep(620)
    harness = Test.fire_timer(harness, :openai, :assistant_idle)
    refute Enum.any?(Test.outputs(harness), &match?(%Frames.AssistantMessage{}, &1))

    harness = live(harness, {:audio, <<1, 1>>, sample_rate: 24_000})
    assert %Frames.OutputAudio{audio: <<1, 1>>} = List.last(Test.outputs(harness))
  end

  test "someone starting a turn after a reply settles notifies :user_speaking once" do
    harness =
      start()
      |> live({:audio, <<0, 0>>, sample_rate: 24_000})

    Process.sleep(620)

    harness =
      harness
      |> Test.fire_timer(:openai, :assistant_idle)
      |> live({:transcription, :user, "wait"})
      |> live({:transcription, :user, " no"})

    assert Enum.count(Test.notifications(harness), &(&1 == :user_speaking)) == 1
  end

  test "typed turns, prompts and say/3 go to the model as commentary" do
    harness =
      start()
      |> Test.push(%Frames.Transcription{text: "hello", speaker: "Priya", source: "p/mic"})
      |> Test.push(%Frames.Prompt{text: "Sum up."})
      |> Test.push([
        %Frames.LLMResponseStart{},
        %Frames.LLMText{text: "Hi!"},
        %Frames.LLMResponseEnd{}
      ])

    assert_received {:to_openai, {:commentary, "[Priya] hello"}}

    assert_received {:to_openai,
                     {:commentary, "[From the app, not said by anyone on the call] Sum up."}}

    assert_received {:to_openai, {:commentary, "[From the app] Say this, word for word" <> _}}

    assert_received {:voice_pipeline, _,
                     {:conversation, %{role: "user", text: "hello", speaker: "Priya"}}}

    assert [%Frames.Start{}] = Test.outputs(harness)
  end

  test "parallel tool calls submit all outputs before sending one response.create" do
    harness =
      live(
        start(),
        {:tool_call,
         [
           %{id: "c1", name: "add_row", args: %{}},
           %{id: "c2", name: "add_row", args: %{}}
         ]}
      )

    assert_receive {:octoroom_agent_async_tool_result, %{call_id: id1}} = r1
    assert_receive {:octoroom_agent_async_tool_result, %{call_id: id2}} = r2

    harness = Test.info(harness, :openai, r1)
    assert_received {:to_openai, {:tool_output, ^id1, %{result: "ok"}}}
    assert_received {:voice_pipeline, _, {:tool_result, %{call_id: ^id1, name: "add_row"}}}
    refute_received {:to_openai, :response_create}

    Test.info(harness, :openai, r2)
    assert_received {:to_openai, {:tool_output, ^id2, %{result: "ok"}}}
    assert_received {:voice_pipeline, _, {:tool_result, %{call_id: ^id2, name: "add_row"}}}
    assert_received {:to_openai, :response_create}
  end

  test "notifies client delegations and pushes server errors upstream" do
    harness =
      start(delegation: :client)
      |> live({:delegation_created, %{"id" => "del_1"}})
      |> live({:error, %{"code" => "rate_limit", "message" => "slow down"}})

    assert {:delegation, %{"id" => "del_1"}} in Test.notifications(harness)
    assert [{%{"code" => "rate_limit", "message" => "slow down"}, false}] = Test.errors(harness)
  end

  test "restores saved transcript in instructions on restart" do
    items = [
      %{role: "user", text: "I'm Alice.", speaker: "Alice"},
      %{role: "assistant", text: "Hi Alice."},
      %{role: "user", text: "hmm"}
    ]

    processor(:openai, Octoroom.Agent.Processors.OpenAILive,
      model: "gpt-live-1.1",
      send: &send(self(), {:sent, &1}),
      instructions: "Be brief."
    )
    |> Test.start!(ctx: %{resume: %{handle: nil, items: items}})

    assert_received {:sent, {:connect, connect}}
    instruction = connect[:setup][:instructions]
    assert instruction =~ ~r/^Be brief\./
    assert instruction =~ "[Alice] I'm Alice.\nYou: Hi Alice.\n[someone] hmm"
  end

  test "restores saved tool results alongside the transcript in instructions on restart" do
    items = [
      %{role: "user", text: "Check slots.", speaker: "Alice", at: 1_000},
      %{role: "assistant", text: "9 AM is open.", at: 3_000}
    ]

    tool_results = [
      %{
        call_id: "c1",
        name: "check_availability",
        args: ~s({"date":"2026-11-27"}),
        response: ~s({"slots":["09:00"]}),
        at: 2_000
      }
    ]

    processor(:openai, Octoroom.Agent.Processors.OpenAILive,
      model: "gpt-live-1.1",
      send: &send(self(), {:sent, &1}),
      instructions: "Be brief."
    )
    |> Test.start!(ctx: %{resume: %{handle: nil, items: items, tool_results: tool_results}})

    assert_received {:sent, {:connect, connect}}
    instruction = connect[:setup][:instructions]

    assert instruction =~
             "[Alice] Check slots.\n" <>
               ~s|[Tool] check_availability({"date":"2026-11-27"}) -> {"slots":["09:00"]}\n| <>
               "You: 9 AM is open."
  end

  test "restore option controls transcript, tool results, and notice" do
    items = [%{role: "user", text: "Check slots.", speaker: "Alice", at: 1_000}]
    tool_results = [%{call_id: "c1", name: "check", response: "open", at: 2_000}]

    processor(:openai, Octoroom.Agent.Processors.OpenAILive,
      model: "gpt-live-1.1",
      send: &send(self(), {:sent, &1}),
      instructions: "Be brief.",
      restore: [history: false, tool_results: true, notice: false]
    )
    |> Test.start!(ctx: %{resume: %{handle: nil, items: items, tool_results: tool_results}})

    assert_received {:sent, {:connect, connect}}
    assert connect[:setup][:instructions] == "Be brief.\n\n[Tool] check() -> open"

    processor(:openai, Octoroom.Agent.Processors.OpenAILive,
      model: "gpt-live-1.1",
      send: &send(self(), {:sent, &1}),
      instructions: "Be brief.",
      restore: false
    )
    |> Test.start!(ctx: %{resume: %{handle: nil, items: items, tool_results: tool_results}})

    assert_received {:sent, {:connect, fresh}}
    assert fresh[:setup][:instructions] == "Be brief."
  end

  test "sends initial_text once session_started and Start have both arrived" do
    harness = start(initial_text: "Greet them.")
    assert Test.timer_pending?(harness, :openai, :initial_text)
    Test.fire_timer(harness, :openai, :initial_text)
    assert_received {:to_openai, {:commentary, "Greet them."}}
  end

  test "forwards idle_timeout_s and wake_policy to setup and notifies pause/resume" do
    harness =
      processor(:openai, OpenAILive,
        model: "gpt-live-1.1",
        idle_timeout_s: 15,
        wake_policy: [type: :speech, vad_threshold: 0.6],
        send: &send(self(), {:sent, &1})
      )
      |> Test.start!()
      |> live({:session_paused, %{"type" => "session.paused"}})
      |> live({:session_resumed, %{"type" => "session.resumed"}})

    assert_received {:sent, {:connect, connect}}
    assert connect[:setup][:idle_timeout_s] == 15
    assert connect[:setup][:wake_policy] == [type: :speech, vad_threshold: 0.6]
    assert :session_paused in Test.notifications(harness)
    assert :session_resumed in Test.notifications(harness)
  end

  test "requires a model and validates options" do
    assert {:error, {:no_model, OpenAILive}} = OpenAILive.init([], %{})

    assert_raise ArgumentError, fn ->
      OpenAILive.init([model: "gpt-live-1.1", idle_timeout_s: 4], %{})
    end
  end
end
