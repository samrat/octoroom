defmodule Octoroom.Agent.Processors.GeminiLiveTest do
  use ExUnit.Case, async: true

  import Octoroom.Agent.Pipeline.Spec

  alias Octoroom.Agent.{Frames, Tool}
  alias Octoroom.Agent.Pipeline.Test

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
      :gemini,
      Octoroom.Agent.Processors.GeminiLive,
      [send: &send(test, {:to_gemini, &1}), tools: tools, context: %{room_id: "r"}] ++ opts
    )
    |> Test.start!(ctx: %{owner: test})
    |> Test.push(%Frames.Start{})
    |> live(:setup_complete)
  end

  defp live(harness, event), do: Test.info(harness, :gemini, {:gemini_live_socket, event})

  test "sends audio once set up, and plays what the model says" do
    harness =
      processor(:gemini, Octoroom.Agent.Processors.GeminiLive, send: &send(self(), {:sent, &1}))
      |> Test.start!()
      |> Test.push(%Frames.InputAudio{audio: <<1, 1>>})

    refute_received {:sent, {:audio, _}}

    harness = harness |> live(:setup_complete) |> Test.push(%Frames.InputAudio{audio: <<2, 2>>})
    assert_received {:sent, {:audio, <<2, 2>>}}

    harness = live(harness, {:audio, <<3, 3>>, sample_rate: 24_000})
    assert [%Frames.OutputAudio{audio: <<3, 3>>, sample_rate: 24_000}] = Test.outputs(harness)

    # A quiet moment tells the model the stream paused.
    Process.sleep(210)
    Test.fire_timer(harness, :gemini, :audio_end)
    assert_received {:sent, :audio_end}
  end

  test "a finished turn goes into the conversation and ends the reply" do
    harness =
      start()
      |> live({:transcription, :user, "add Acme", true})
      |> live({:audio, <<0, 0>>, sample_rate: 24_000})
      |> live({:transcription, :assistant, "Done.", false})
      |> live(:turn_complete)

    assert_received {:voice_pipeline, _, {:conversation, %{role: "user", text: "add Acme"}}}

    assert_received {:voice_pipeline, _,
                     {:conversation, %{role: "assistant", text: "Done.", status: "completed"}}}

    assert [%Frames.Start{}, %Frames.OutputAudio{}, %Frames.AssistantMessage{text: "Done."}] =
             Test.outputs(harness)
  end

  test "the model's own interruption goes downstream once" do
    harness =
      start()
      |> live({:audio, <<0, 0>>, sample_rate: 24_000})
      |> live({:transcription, :assistant, "Well, the", false})
      |> live(:interrupted)

    assert Test.interrupted?(harness)

    assert_received {:voice_pipeline, _,
                     {:conversation, %{role: "assistant", text: "Well, the", interrupted: true}}}

    # What follows is a new reply, and plays.
    harness = live(harness, {:audio, <<1, 1>>, sample_rate: 24_000})
    assert %Frames.OutputAudio{audio: <<1, 1>>} = List.last(Test.outputs(harness))
  end

  test "interrupted from outside, it drops the rest of the reply being generated" do
    harness =
      start()
      |> live({:audio, <<0, 0>>, sample_rate: 24_000})
      |> Test.push(%Frames.Interruption{})
      |> live({:audio, <<9, 9>>, sample_rate: 24_000})
      |> live(:turn_complete)

    refute Enum.any?(Test.outputs(harness), &match?(%Frames.OutputAudio{audio: <<9, 9>>}, &1))
    refute Enum.any?(Test.outputs(harness), &match?(%Frames.AssistantMessage{}, &1))

    harness = live(harness, {:audio, <<1, 1>>, sample_rate: 24_000})
    assert %Frames.OutputAudio{audio: <<1, 1>>} = List.last(Test.outputs(harness))
  end

  test "someone starting a turn after the reply is generated is reported, once" do
    harness =
      start()
      |> live({:audio, <<0, 0>>, sample_rate: 24_000})
      |> live(:turn_complete)
      |> live({:transcription, :user, "wait", false})
      |> live({:transcription, :user, " no", false})

    assert Enum.count(Test.notifications(harness), &(&1 == :user_speaking)) == 1
  end

  test "typed turns, prompts and say/3 go to the model as text" do
    harness =
      start()
      |> Test.push(%Frames.Transcription{text: "hello", speaker: "Priya", source: "p/mic"})
      |> Test.push(%Frames.Prompt{text: "Sum up."})
      |> Test.push([
        %Frames.LLMResponseStart{},
        %Frames.LLMText{text: "Hi!"},
        %Frames.LLMResponseEnd{}
      ])

    assert_received {:to_gemini, {:text, "[Priya] hello"}}

    assert_received {:to_gemini,
                     {:text, "[From the app, not said by anyone on the call] Sum up."}}

    assert_received {:to_gemini, {:text, "[From the app] Say this, word for word" <> _}}

    assert_received {:voice_pipeline, _,
                     {:conversation, %{role: "user", text: "hello", speaker: "Priya"}}}

    assert [%Frames.Start{}] = Test.outputs(harness)
  end

  test "tool calls run and their results go back to the model" do
    harness = live(start(), {:tool_call, [%{id: "c1", name: "add_row", args: %{}}]})

    assert_receive {:octoroom_agent_async_tool_result, _} = result
    Test.info(harness, :gemini, result)

    assert_received {:to_gemini,
                     {:tool_response, [%{id: "c1", name: "add_row", response: %{result: "ok"}}]}}
  end

  test "each new resumption handle goes to the agent, to save" do
    start() |> live({:resumption, "h1"})

    assert_received {:voice_pipeline, _, {:memory, %{gemini_handle: %{handle: "h1", at: at}}}}

    assert is_integer(at)
  end

  test "resumes a saved session, and has the transcript for a new one" do
    items = [
      %{role: "user", text: "I'm Alice.", speaker: "Alice"},
      %{role: "assistant", text: "Hi Alice."},
      %{role: "user", text: "hmm"}
    ]

    processor(:gemini, Octoroom.Agent.Processors.GeminiLive,
      send: &send(self(), {:sent, &1}),
      instructions: "Be brief."
    )
    |> Test.start!(ctx: %{resume: %{handle: "h1", items: items}})

    assert_received {:sent, {:connect, connect}}
    assert connect[:handle] == "h1"
    instruction = connect[:fallback_setup][:system_instruction]
    assert instruction =~ ~r/^Be brief\./
    assert instruction =~ "[Alice] I'm Alice.\nYou: Hi Alice.\n[someone] hmm"
  end

  test "sends the initial text once set up and started" do
    harness = start(initial_text: "Greet them.")
    assert Test.timer_pending?(harness, :gemini, :initial_text)
    Test.fire_timer(harness, :gemini, :initial_text)
    assert_received {:to_gemini, {:text, "Greet them."}}
  end
end
