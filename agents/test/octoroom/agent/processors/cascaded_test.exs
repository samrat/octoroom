defmodule Octoroom.Agent.Processors.CascadedTest do
  # The cascaded stages as one chain, end to end, with fake providers.
  use ExUnit.Case, async: true

  import Octoroom.Agent.Pipeline.Spec

  alias Octoroom.Agent.Frames
  alias Octoroom.Agent.Pipeline.Test, as: Harness
  alias Octoroom.Agent.Processors

  defmodule WeatherTool do
    def run(call, context),
      do:
        {%{id: call.id, name: call.name, response: %{conditions: "sunny"}}, %{type: "checked"},
         context}
  end

  @weather %Octoroom.Agent.Tool{
    name: "get_weather",
    description: "Weather",
    parameters: [],
    handler: {WeatherTool, :run},
    progress_message: "One moment."
  }

  # First round: a preamble and a tool call. Second round: the answer.
  defp fake_llm(test_pid) do
    fn opts, emit ->
      send(test_pid, {:llm_request, opts})

      if Enum.any?(opts[:input], &match?(%ReqLLM.Message{role: :tool}, &1)) do
        emit.({:text_delta, "It's sunny."})
        {:ok, %{text: "It's sunny.", function_calls: [], continuation: []}}
      else
        emit.({:text_delta, "Let me check."})
        emit.({:tool_call_delta, %{}})
        call = %{id: "c1", name: "get_weather", args: %{"city" => "Lisbon"}}
        {:ok, %{text: "Let me check.", function_calls: [call], continuation: []}}
      end
    end
  end

  defp fake_tts do
    fn text, on_audio ->
      on_audio.("audio:" <> text)
      :ok
    end
  end

  defp spec(test_pid) do
    processor(:vad, Processors.VAD, analyzer: :none)
    |> processor(:stt, Processors.STT, provider: :soniox, model: "stt-rt-v6")
    |> processor(:turns, Processors.STTTurns, vad: true)
    |> processor(:context, Processors.Context)
    |> processor(:llm, Processors.LLM, request: fake_llm(test_pid))
    |> processor(:tools, Processors.Tools)
    |> processor(:chunker, Processors.TextChunker)
    |> processor(:tts, Processors.TTS, synthesize: fake_tts())
    |> processor(:collector, Processors.AssistantCollector)
  end

  defp ctx, do: %{owner: self(), instructions: "Be brief.", tools: [@weather], context: %{}}

  test "a spoken question, a tool round, and the answer" do
    harness =
      spec(self())
      |> Harness.start!(ctx: ctx())
      |> Harness.push(%Frames.VADUserStartedSpeaking{})
      |> Harness.info(:stt, {:stt, {:partial, "what's the"}})
      |> Harness.info(:stt, {:stt, {:final, "What's the weather?"}})

    assert Harness.interrupted?(harness)

    assert_received {:llm_request, first}

    assert [
             %{role: "system", content: "Be brief."},
             %{role: "user", content: "What's the weather?"}
           ] =
             first[:input]

    assert_received {:llm_request, _second}

    spoken = harness |> Harness.outputs(Frames.OutputAudio) |> Enum.map(& &1.audio)
    assert spoken == ["audio:Let me check.", "audio:It's sunny."]

    # The reply goes into the history once its audio has played.
    refute {:text, "Let me check. It's sunny."} in Harness.notifications(harness)
    harness = Harness.fire_timer(harness, :collector, :played)

    notices = Harness.notifications(harness)
    assert {:transcription, %{status: "partial", text: "what's the"}} in notices
    assert {:transcription, %{status: "final", text: "What's the weather?"}} in notices
    assert {:control, %{type: "checked"}} in notices
    assert {:text, "Let me check. It's sunny."} in notices

    assert_received {:voice_pipeline, _,
                     {:conversation, %{role: "user", text: "What's the weather?"}}}

    assert_received {:voice_pipeline, _,
                     {:conversation,
                      %{role: "assistant", text: "Let me check. It's sunny.", status: "completed"}}}

    history = Harness.state(harness, :context).history
    assert List.last(history) == %{role: "assistant", content: "Let me check. It's sunny."}

    assert Enum.any?(
             history,
             &(&1.role == "user" and &1.content =~ ~s|get_weather({"city":"Lisbon"})| and
                 &1.content =~ ~s|"sunny"|)
           )
  end

  test "barge-in before any audio kills the reply, and nothing was said" do
    harness =
      spec(self())
      |> Harness.start!(ctx: ctx(), async: :manual)
      |> Harness.info(:stt, {:stt, {:final, "Tell me a story."}})

    # The reply streams a little, then the user talks over it.
    [{:llm, :reply}] = Harness.pending_tasks(harness)
    [{id, _fun}] = harness.tasks

    {commands, core} =
      Octoroom.Agent.Pipeline.Core.async_message(
        harness.core,
        id,
        {:llm_event, {:text_delta, "Once upon"}}
      )

    harness = Enum.reduce(commands, %{harness | core: core}, &apply_command/2)

    harness = Harness.push(harness, %Frames.VADUserStartedSpeaking{})

    assert Harness.pending_tasks(harness) == []

    # The LLM wrote "Once upon", but none of it was spoken.
    refute_received {:voice_pipeline, _, {:conversation, %{role: "assistant"}}}

    assert Harness.state(harness, :context).history == [
             %{role: "user", content: "Tell me a story."}
           ]
  end

  test "a when_idle result waits until the reply is done" do
    test_pid = self()

    plain_llm = fn opts, emit ->
      send(test_pid, {:llm_request, opts})
      emit.({:text_delta, "Sure."})
      {:ok, %{text: "Sure.", function_calls: [], continuation: []}}
    end

    harness =
      spec(self())
      |> replace(:llm, processor(:llm, Processors.LLM, request: plain_llm))
      |> Harness.start!(ctx: %{ctx() | tools: []}, async: :manual)
      |> Harness.info(:stt, {:stt, {:final, "Plan my trip."}})

    result = %{
      call_id: "t1",
      name: "plan_trip",
      response: %{plan: "Lisbon"},
      scheduling: :when_idle
    }

    harness = Harness.info(harness, :tools, {:octoroom_agent_async_tool_result, result})

    # The reply is still running, so the result waits.
    assert Harness.pending_tasks(harness) == [{:llm, :reply}]
    assert Harness.state(harness, :tools).name == :responding

    # The reply finishes; the result starts the next turn.
    harness = Harness.run_tasks(harness)
    assert_received {:llm_request, _first}
    assert_received {:llm_request, request}
    assert List.last(request[:input]).content =~ "plan_trip tool finished"
    assert Harness.state(harness, :tools).name == :idle
  end

  defp apply_command({:output, frame}, harness),
    do: %{harness | outputs: [frame | harness.outputs]}

  defp apply_command({:notify, e}, harness),
    do: %{harness | notifications: [e | harness.notifications]}

  defp apply_command({:start_task, id, fun}, harness),
    do: %{harness | tasks: harness.tasks ++ [{id, fun}]}

  defp apply_command(_command, harness), do: harness
end
